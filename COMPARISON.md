# 先行事例との比較

「Claude Codeの5時間レート制限をまたいでセッションを自動再開する」問題に対する既存ツールと、ccrelayの設計を比較したメモ。

| ツール | 検出方法 | 介入タイミング | ccrelayとの主な違い |
|---|---|---|---|
| **ccrelay**（本リポジトリ） | statuslineフックが書く構造化JSON（`.rate_limits.five_hour.resets_at` / `used_percentage`） | 新しい枠が開いた後、アイドル5分＋直前枠の高使用率を確認してから `kill` → `--resume` | - |
| [smart_resume](https://github.com/karthiknitt/smart_resume)（karthiknitt） | transcript（JSONL）に書かれたClaudeのレート制限エラー文を`grep`で抽出 | 制限に当たった瞬間に`SIGINT`で割り込み、リセット時刻まで正確に1回`sleep`して再開 | UI文言スクレイピングのため表示フォーマット変更に弱い。速度優先の割り込み型。OS別に3スクリプト（macOS/WSL/Linux）＋946行のテストと規模が大きい |
| [autoclaude](https://github.com/henryaj/autoclaude)（henryaj, Go） | tmuxペインの表示文字列（`limit reached ∙ resets Xpm`）を3秒間隔でスクレイピング | 文言検出後に自動で`continue`を送信 | tmux必須。statuslineもtranscriptも使わず、TUIの描画そのものを監視する点が独自 |
| [claude-auto-resume](https://github.com/terryso/claude-auto-resume)（terryso） | `claude -p 'check'`を都度実行し、出力テキスト`Claude AI usage limit reached\|<timestamp>`をパース | 待機後 `claude --dangerously-skip-permissions -p '<prompt>'` で**非対話の`-p`モード**として再開 | ccrelayが明示的に避けている`-p`＋`--dangerously-skip-permissions`（承認プロンプトを全スキップし任意コマンドを自動実行）を前提にした設計。README冒頭にセキュリティ警告あり |
| [auto-claude-resume-after-limit-reset](https://github.com/Muminur/auto-claude-resume-after-limit-reset)（Muminur） | Stop hookがtranscriptを読み`status.json`に書き出し、daemonが5秒間隔でポーリング | tmux send-keys→PTY書き込み→xdotool/osascript/SendKeys→Windowsコンソール注入、の階層フォールバックで"continue"のキーストロークを送信。送信後もtranscriptをポーリングして再開成功を検証 | 3万行超のNode.js daemon。systemdサービス化、HMAC署名、レート制限イベントキュー、GUI、プラグイン機構まで備えるフル装備型。ccrelay（1ファイル290行のbash）とは規模が2桁近く違う |

## ccrelayの立ち位置

- 検出ソースを statusline の構造化JSONに限定し、UIスクレイピング（transcriptの英語エラー文やtmux画面の文字列）を避けている点が最大の差別化。
- 「制限に当たった瞬間への割り込み」（SIGINT等のキー注入）を、権限プロンプトやAskUserQuestion状態で効かないという理由で明示的に不採用としている（[DESIGN.md](./DESIGN.md)参照）。速度よりも「人間の作業を誤って落とさない」安全性を優先する設計。
- `session-id`単位でセッションを管理し複数セッションを`ccrelay status`で一覧できる点は、`claude`コマンド自体をaliasで上書きし単一セッションを前提にするツール群（smart_resume等）と異なる。
- インタラクティブTUIのままを維持する設計で、`-p`（非対話モード）や`--dangerously-skip-permissions`（承認スキップ）は使わない。statuslineフックはインタラクティブTUIでのみ発火するため、`-p`ではccrelayが依存する枠情報そのものが取得できない。claude-auto-resumeのように`-p`＋全承認スキップを前提にするツールとは、そもそも解こうとしている問題の前提が異なる。
