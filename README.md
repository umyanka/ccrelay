# ccrelay

Claude Codeが5時間レート制限に達したとき、次の枠が開いたら自動的に再開させる軽量ラッパースクリプトです。

## 概要

- 5時間枠を使い切ってTUIが止まったとき、新しい枠が開くのを待って自動で再開します。それ以外のTUI操作（承認、質問への回答など）はすべて人間が行います。
- ユーザーの返事待ち、操作中、タスク完了時など、再開すべきでない状況では再開しません。
- 単一のbashスクリプトで、`-p`（非対話モード）や`--dangerously-skip-permissions`、`tmux`、TTYスクレイピングは使いません。
- 既存セッションに後からアタッチできます。

## 必要なもの

- `bash`, `jq`, `claude` CLI

## インストール / アンインストール

```sh
# スクリプトをPATHの通った場所に置いて実行権限を付ける
curl -fsSL https://raw.githubusercontent.com/umyanka/ccrelay/refs/heads/main/ccrelay -o ~/.local/bin/ccrelay
chmod +x ~/.local/bin/ccrelay

# statuslineフックを導入する（変更内容を表示した上でY/n確認あり）
ccrelay install
```

```sh
# statuslineフックを解除し、状態ディレクトリ(~/.claude/ccrelay)を削除する（Y/n確認あり）
ccrelay uninstall

# スクリプト自体はuninstallでは消さないので、不要なら手動で削除する
rm ~/.local/bin/ccrelay
```

## 使い方

```sh
ccrelay [-r|--resume ID] [claudeに渡す引数...]
```

```sh
# ccrelayを有効にして新規セッションを起動
ccrelay

# claude本体への引数もそのまま渡せる
ccrelay --model opus

# 既存セッションに後からccrelayを被せて監視する。IDはclaude終了時に表示される "Resume this session with: claude --resume <uuid>" の値
ccrelay -r 80f26c29-91b6-496c-acc3-53c0aa6ac453
```

サブコマンドやオプションの一覧は `ccrelay --help` を参照してください。`ccrelay status` で現在把握しているセッションの枠状態を確認できます。

## トラブルシューティング

- **statuslineの表示がおかしくなった** → `ccrelay uninstall` で元のcommandに戻します。うまく戻らない場合は最新の `settings.json.ccrelay-*.bak` から手動で復元してください
- **再開が起きない** → `ccrelay status` で対象セッションの使用率とリセット時刻を確認してください。使用率が閾値未満だと再開しません

## 技術情報

- [仕組みと設定](./DESIGN.md)
- [類似ツールとの比較](./COMPARISON.md)
