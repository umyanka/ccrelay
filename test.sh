#!/bin/bash
# ccrelay のテスト。モックclaudeと加速したタイマーで、判定ロジックとリレー動作を検証する。
# 実際の5時間枠やclaude本体には一切依存しない。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CCRELAY="$HERE/ccrelay"

WORK="$(mktemp -d /tmp/claude/ccrelay-test.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export CCRELAY_HOME="$WORK/home"
export CCRELAY_IDLE_SEC=2
export CCRELAY_USED_THRESHOLD=90
export CCRELAY_POLL_SEC=1
export CCRELAY_GRACE_SEC=2
mkdir -p "$CCRELAY_HOME/windows"

# デフォルトでは「導入済み」settings.jsonを見せる。install/uninstall/is_installed系のテストは
# 個別にCCRELAY_SETTINGSを指定してこのデフォルトを上書きする。
export CCRELAY_SETTINGS="$WORK/global-settings.json"
echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash $CCRELAY_HOME/statusline-hook.sh ''\"}}" > "$CCRELAY_SETTINGS"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
ng()   { FAIL=$((FAIL+1)); echo "  NG: $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else ng "$3 (expected=$2 got=$1)"; fi; }

now() { date +%s; }

# transcript を作る。$2 が "paused" ならマーカー入り。mtimeは $3 秒前に設定。
make_transcript() {
    local path="$1" kind="$2" age="${3:-0}"
    if [ "$kind" = "paused" ]; then
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"ユーザーの発言をお待ちしています [[PAUSED]]"}]}}' > "$path"
    else
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"作業を続けています"}]}}' > "$path"
    fi
    touch -d "@$(( $(now) - age ))" "$path"
}

make_window() { # $1=path $2=r5 $3=used5 $4=transcript
    echo "{\"sid\":\"x\",\"r5\":$2,\"used5\":$3,\"transcript\":\"$4\"}" > "$1"
}

echo "== unit: is_paused =="
TR="$WORK/tr_paused.jsonl"; make_transcript "$TR" paused
"$CCRELAY" __is_paused "$TR"; check "$?" 0 "マーカーありを一時停止中と判定"
TR2="$WORK/tr_work.jsonl"; make_transcript "$TR2" work
"$CCRELAY" __is_paused "$TR2"; check "$?" 1 "マーカーなしは非一時停止"

echo "== unit: should_relay 判定マトリクス =="
N="$(now)"

# 再開すべき: 枠リセット済み + 高使用率 + アイドル + 未完了
WIN="$WORK/w_yes.json"; TR="$WORK/t_yes.jsonl"
make_transcript "$TR" work 10; make_window "$WIN" "$((N-100))" 95 "$TR"
"$CCRELAY" __should_relay "$WIN" "$TR"; check "$?" 0 "全条件成立で再開"

# 使用量が低い → 再開しない（使用量ガード）
WIN="$WORK/w_low.json"; TR="$WORK/t_low.jsonl"
make_transcript "$TR" work 10; make_window "$WIN" "$((N-100))" 10 "$TR"
"$CCRELAY" __should_relay "$WIN" "$TR"; check "$?" 1 "低使用率はガードで抑止"

# まだアイドルでない → 再開しない
WIN="$WORK/w_busy.json"; TR="$WORK/t_busy.jsonl"
make_transcript "$TR" work 0; make_window "$WIN" "$((N-100))" 95 "$TR"
"$CCRELAY" __should_relay "$WIN" "$TR"; check "$?" 1 "アクティブ中は再開しない"

# 枠がまだリセットされていない → 再開しない
WIN="$WORK/w_future.json"; TR="$WORK/t_future.jsonl"
make_transcript "$TR" work 10; make_window "$WIN" "$((N+1000))" 95 "$TR"
"$CCRELAY" __should_relay "$WIN" "$TR"; check "$?" 1 "枠リセット前は再開しない"

# 一時停止マーカーあり → 再開しない
WIN="$WORK/w_paused.json"; TR="$WORK/t_paused.jsonl"
make_transcript "$TR" paused 10; make_window "$WIN" "$((N-100))" 95 "$TR"
"$CCRELAY" __should_relay "$WIN" "$TR"; check "$?" 1 "一時停止中は再開しない"

echo "== unit: resolve_sid (-r/--resume) =="
OUT="$("$CCRELAY" __resolve_sid existing-sid-1)"
check "$OUT" "sid=existing-sid-1 is_new=0" "resume_arg指定時はそのIDを採用しis_new=0"

OUT="$("$CCRELAY" __resolve_sid)"
[[ "$OUT" == sid=*-*-*-*-*\ is_new=1 ]] && ok "resume_arg省略時はUUIDを新規採番しis_new=1" || ng "resume_arg省略時 ($OUT)"

echo "== unit: is_installed =="
SETTINGS_NONE="$WORK/settings_none.json"
CCRELAY_SETTINGS="$SETTINGS_NONE" "$CCRELAY" __is_installed
check "$?" 1 "settings.jsonが無ければ未導入と判定"

SETTINGS_OTHER="$WORK/settings_other.json"
echo '{"statusLine":{"type":"command","command":"bash /orig/statusline.sh"}}' > "$SETTINGS_OTHER"
CCRELAY_SETTINGS="$SETTINGS_OTHER" "$CCRELAY" __is_installed
check "$?" 1 "フック未導入のstatusLineコマンドは未導入と判定"

SETTINGS_HOOKED="$WORK/settings_hooked.json"
HOOK_HOME="$WORK/hook_home"
echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash $HOOK_HOME/statusline-hook.sh ''\"}}" > "$SETTINGS_HOOKED"
CCRELAY_HOME="$HOOK_HOME" CCRELAY_SETTINGS="$SETTINGS_HOOKED" "$CCRELAY" __is_installed
check "$?" 0 "HOOK_PREFIXに前方一致すれば導入済みと判定"

echo "== unit: CLI引数パーサ (-r/--resume) =="
ARGMOCK="$WORK/argmock"
cat > "$ARGMOCK" <<'ARGMOCK'
#!/bin/bash
echo "ARGS: $*"
ARGMOCK
chmod +x "$ARGMOCK"

OUT="$(CCRELAY_CLAUDE_BIN="$ARGMOCK" "$CCRELAY" -r cli-existing-sid 2>&1)"
echo "$OUT" | grep -q -- '--resume cli-existing-sid' && ok "-r は claude本体の --resume として既存IDでresumeする" || ng "-r の解釈 ($OUT)"

OUT="$(CCRELAY_CLAUDE_BIN="$ARGMOCK" "$CCRELAY" --resume=cli-existing-sid2 2>&1)"
echo "$OUT" | grep -q -- '--resume cli-existing-sid2' && ok "--resume=VALUE 形式も解釈される" || ng "--resume=VALUE の解釈 ($OUT)"

OUT="$(CCRELAY_CLAUDE_BIN="$ARGMOCK" "$CCRELAY" --resume 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -q "値が必要" && ok "-r/--resume に値がない場合はエラー終了" || ng "-r/--resume 値なしガード (rc=$rc, $OUT)"
echo "$OUT" | grep -q "使い方:" && ok "-r/--resume 値なしエラー時にも使い方を表示" || ng "エラー時の使い方表示 ($OUT)"

echo "== CLI: --help =="
OUT="$("$CCRELAY" --help 2>&1)"; rc=$?
check "$rc" 0 "--help は正常終了"
echo "$OUT" | grep -q "使い方:" && ok "--help に使い方が表示される" || ng "--help の内容 ($OUT)"
echo "$OUT" | grep -q "ccrelay install" && ok "--help にinstallサブコマンドが記載される" || ng "--help にinstallの記載がない ($OUT)"

echo "== integration: モックclaudeでリレー2回 → クリーン終了 =="
MOCK="$WORK/mock-claude"
export MOCK_LOG="$WORK/mock.log"
export MOCK_CNT="$WORK/mock.cnt"
export MOCK_TRDIR="$WORK/transcripts"
export MOCK_MAX=3
mkdir -p "$MOCK_TRDIR"
cat > "$MOCK" <<'MOCK'
#!/bin/bash
sid=""; prev=""
for a in "$@"; do case "$prev" in --session-id|--resume) sid="$a";; esac; prev="$a"; done
n=$(( $(cat "$MOCK_CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$MOCK_CNT"
echo "INVOKE n=$n: $*" >> "$MOCK_LOG"
if [ "$n" -ge "${MOCK_MAX:-3}" ]; then echo "CLEAN_EXIT n=$n" >> "$MOCK_LOG"; exit 0; fi
now=$(date +%s); tr="$MOCK_TRDIR/$sid.jsonl"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"作業中 n='"$n"'"}]}}' > "$tr"
mkdir -p "$CCRELAY_HOME/windows"
echo "{\"sid\":\"$sid\",\"r5\":$((now-5)),\"r7\":$((now+99999)),\"used5\":95,\"transcript\":\"$tr\"}" > "$CCRELAY_HOME/windows/$sid.json"
echo "RUNNING n=$n sid=$sid" >> "$MOCK_LOG"
trap 'exit 143' TERM INT
sleep 600 & wait
MOCK
chmod +x "$MOCK"
export CCRELAY_CLAUDE_BIN="$MOCK"

WRAP_LOG="$WORK/wrap.log"
timeout 60 "$CCRELAY" -w bar > "$WRAP_LOG" 2>&1
rc=$?

invokes=$(grep -c '^INVOKE' "$MOCK_LOG" 2>/dev/null || echo 0)
resumes=$(grep -c 'INVOKE.*--resume' "$MOCK_LOG" 2>/dev/null || echo 0)
relays=$(grep -c '新しい枠でセッションを再開します' "$WRAP_LOG" 2>/dev/null || echo 0)

check "$(grep -c 'INVOKE n=1: --session-id' "$MOCK_LOG")" 1 "初回は --session-id で新規起動"
check "$invokes" 3 "claudeが計3回起動された"
check "$resumes" 2 "2回とも --resume で再開された"
[ "$relays" -ge 2 ] && ok "リレーが2回以上発生 ($relays)" || ng "リレー回数不足 ($relays)"
check "$(grep -c 'CLEAN_EXIT n=3' "$MOCK_LOG")" 1 "3回目はクリーン終了でループ停止"
[ "$rc" -ne 124 ] && ok "タイムアウトせず完了" || ng "60秒でタイムアウト（ハング）"

check "$(grep -c 'INVOKE n=1:.*\[\[PAUSED\]\]' "$MOCK_LOG")" 0 "初回起動には自動継続メッセージを含めない"
check "$(grep -c 'INVOKE n=2:.*\[\[PAUSED\]\]' "$MOCK_LOG")" 1 "リレー後の再開には自動継続メッセージを含む"

echo "== integration: 未導入時はclaudeを起動せず終了する =="
QUICK_MOCK="$WORK/quick-mock"
QUICK_MOCK_LOG="$WORK/quick-mock.log"
cat > "$QUICK_MOCK" <<'QM'
#!/bin/bash
echo "INVOKE: $*" >> "$QUICK_MOCK_LOG"
exit 0
QM
chmod +x "$QUICK_MOCK"

UNINSTALLED_SETTINGS="$WORK/settings_uninstalled.json"
echo '{}' > "$UNINSTALLED_SETTINGS"
OUT="$(CCRELAY_SETTINGS="$UNINSTALLED_SETTINGS" CCRELAY_CLAUDE_BIN="$QUICK_MOCK" QUICK_MOCK_LOG="$QUICK_MOCK_LOG" CCRELAY_HOME="$WORK/uninstalled-home" timeout 10 "$CCRELAY" 2>&1)"; rc=$?
check "$rc" 1 "未導入時は終了コード1"
echo "$OUT" | grep -q "'ccrelay install' でインストールしてください" && ok "未導入時に案内メッセージが出る" || ng "未導入時の案内メッセージが出ない ($OUT)"
[ ! -e "$QUICK_MOCK_LOG" ] && ok "未導入時はclaudeを起動しない" || ng "未導入時なのにclaudeが起動された ($(cat "$QUICK_MOCK_LOG"))"

INSTALLED_SETTINGS="$WORK/settings_installed2.json"
HOOK_HOME2="$WORK/hook_home2"
echo "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash $HOOK_HOME2/statusline-hook.sh ''\"}}" > "$INSTALLED_SETTINGS"
OUT="$(CCRELAY_SETTINGS="$INSTALLED_SETTINGS" CCRELAY_CLAUDE_BIN="$QUICK_MOCK" QUICK_MOCK_LOG="$QUICK_MOCK_LOG" CCRELAY_HOME="$HOOK_HOME2" timeout 10 "$CCRELAY" 2>&1)"
[ -e "$QUICK_MOCK_LOG" ] && ok "導入済み時はclaudeが起動される" || ng "導入済みなのにclaudeが起動されない ($OUT)"
rm -f "$QUICK_MOCK_LOG"

echo "== install/uninstall: Y/n確認プロンプト =="
INSTALL_HOME="$WORK/install-home"
SETTINGS="$WORK/settings.json"
echo '{"statusLine":{"type":"command","command":"bash /orig/statusline.sh"}}' > "$SETTINGS"

OUT="$(echo n | CCRELAY_HOME="$INSTALL_HOME" CCRELAY_SETTINGS="$SETTINGS" "$CCRELAY" install 2>&1)"; rc=$?
check "$rc" 1 "install: nで中止すると終了コード1"
[ ! -e "$INSTALL_HOME/statusline-hook.sh" ] && ok "install: nで中止するとフックは作成されない" || ng "install: nで中止してもフックが作成された"
grep -q "orig/statusline.sh" "$SETTINGS" && ok "install: nで中止するとsettings.jsonは変更されない" || ng "install: nで中止してもsettings.jsonが変更された ($OUT)"

OUT="$(echo y | CCRELAY_HOME="$INSTALL_HOME" CCRELAY_SETTINGS="$SETTINGS" "$CCRELAY" install 2>&1)"; rc=$?
check "$rc" 0 "install: yで承認すると終了コード0"
[ -x "$INSTALL_HOME/statusline-hook.sh" ] && ok "install: yで承認するとフックが作成される" || ng "install: yで承認してもフックが作成されない ($OUT)"
grep -q "statusline-hook.sh" "$SETTINGS" && ok "install: yで承認するとsettings.jsonがラップされる" || ng "install: yで承認してもsettings.jsonがラップされない ($OUT)"

OUT="$(echo n | CCRELAY_HOME="$INSTALL_HOME" CCRELAY_SETTINGS="$SETTINGS" "$CCRELAY" uninstall 2>&1)"; rc=$?
check "$rc" 1 "uninstall: nで中止すると終了コード1"
[ -d "$INSTALL_HOME" ] && ok "uninstall: nで中止すると状態ディレクトリが残る" || ng "uninstall: nで中止したのに状態ディレクトリが消えた ($OUT)"

OUT="$(echo y | CCRELAY_HOME="$INSTALL_HOME" CCRELAY_SETTINGS="$SETTINGS" "$CCRELAY" uninstall 2>&1)"; rc=$?
check "$rc" 0 "uninstall: yで承認すると終了コード0"
[ ! -d "$INSTALL_HOME" ] && ok "uninstall: yで承認すると状態ディレクトリが削除される" || ng "uninstall: yで承認しても状態ディレクトリが残った ($OUT)"
grep -q "orig/statusline.sh" "$SETTINGS" && ! grep -q "statusline-hook.sh" "$SETTINGS" \
    && ok "uninstall: yで承認するとsettings.jsonが元に戻る" || ng "uninstall: yで承認してもsettings.jsonが戻らない ($OUT)"

echo
echo "==== PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
