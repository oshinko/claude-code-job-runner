# Claude Code Docker Runner

GitHubリポジトリをコンテナ内へcloneし、リポジトリルートの `AGENTS.md` を起点にClaude Codeを非対話実行するrunnerです。commit、push、Git identityなどのGitワークフローはrunnerでは判断せず、Claude Codeが `AGENTS.md` に従って実行します。

## 動作の流れ

1. 必須設定と認証情報を検証します。
2. `GITHUB_TOKEN` を使って指定ブランチを一時ディレクトリへcloneし、同じ認証をClaude Codeから利用できるようにします。
3. `{repo_root}/AGENTS.md` の存在、非空、UTF-8を確認します。
4. repoルートで次の要領によりClaude Codeを起動します。

   ```console
   claude -p \
     --append-system-prompt-file ./AGENTS.md \
     --permission-mode bypassPermissions \
     --output-format stream-json \
     --verbose \
     "AGENTS.mdに記載された指示に従い、必要な関連文書を参照して作業を完了してください。"
   ```

5. Claude Codeの終了コードをrunnerの終了コードとして返します。runnerによるcommit、push、差分保存は行いません。

通常モードで起動するため、リポジトリに `CLAUDE.md`、Claude Code skills、hooks、plugins、MCP設定がある場合は、それらもClaude Codeの標準仕様に従って読み込まれます。`AGENTS.md` 自体はClaude Codeの自動検出対象ではないため、`--append-system-prompt-file` で明示的に追加しています。

## Docker Composeで実行する

Docker Compose 2.24.0以降を使用します。設定例をコピーし、対象repo、Git、Claude Codeの認証情報を入力してください。

PowerShell:

```powershell
Copy-Item .env.example .env
```

Bash:

```console
cp .env.example .env
```

`.env` では `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` のどちらか一方だけに値を設定します。その後、次のコマンドでイメージのbuildと1回限りのrunner実行を行えます。

```console
docker compose run --rm --build runner
```

2回目以降、Dockerfileやrunnerを変更していなければ `--build` を省略できます。

```console
docker compose run --rm runner
```

別名の環境ファイルを使う場合は、`RUNNER_ENV_FILE` で指定します。

PowerShell:

```powershell
$env:RUNNER_ENV_FILE = '.env.production'
docker compose run --rm runner
```

Bash:

```console
RUNNER_ENV_FILE=.env.production docker compose run --rm runner
```

`.env` と `*.env` はGitの追跡対象から除外されています。秘密値を含むため共有、commit、ログへの貼り付けを行わず、Linuxではファイル権限も実行ユーザーだけが読めるようにしてください。

## イメージを直接buildする

```console
docker build -t claude-code-runner:2.1.220 .
```

Claude Codeのバージョンはbuild argumentで変更できます。

```console
docker build \
  --build-arg CLAUDE_CODE_VERSION=2.1.220 \
  -t claude-code-runner:custom .
```

自動更新は無効です。バージョンを更新するときはbuild argumentを変更してイメージを再buildしてください。

## 必須設定

| 変数 | 内容 |
| --- | --- |
| `REPOSITORY_URL` | `https://github.com/<owner>/<repo>.git` 形式のURL |
| `GITHUB_TOKEN` | 対象repoとタスクに必要な最小権限を持つtoken |
| `MAX_TURNS` | Claude Codeの最大agentic turn数。1以上の整数 |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth認証。API keyとは排他的 |
| `ANTHROPIC_API_KEY` | Anthropic API認証。OAuth tokenとは排他的 |

Claude認証は `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` のどちらか一方だけを指定します。

任意設定:

| 変数 | 内容 |
| --- | --- |
| `GIT_BRANCH` | checkoutする既存ブランチ。未指定または空の場合は `main` |
| `MAX_BUDGET_USD` | 指定時に `--max-budget-usd` として渡す正数 |
| `CLAUDE_MODEL` | 指定時に `--model` として渡すmodel名またはalias |

## docker runによる実行例

OAuth tokenを使う例です。

```console
docker run --rm \
  -e REPOSITORY_URL=https://github.com/example/project.git \
  -e GIT_BRANCH=main \
  -e GITHUB_TOKEN \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e MAX_TURNS=30 \
  claude-code-runner:2.1.220
```

API keyを使う場合は `CLAUDE_CODE_OAUTH_TOKEN` の代わりに `ANTHROPIC_API_KEY` を渡します。秘密値をコマンドラインへ直接書かず、呼び出し元のsecret管理機能から環境変数として注入してください。

## プロジェクト固有のツールを追加する

runner本体は特定言語のビルド環境を同梱しません。対象プロジェクトに必要なSDKやパッケージを派生イメージへ追加します。

```dockerfile
FROM claude-code-runner:2.1.220

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
USER runner
```

元イメージのentrypointはそのまま継承されます。

## Gitワークフロー

commitやpushが必要なrepoでは、その実施条件、Git identity、コミット方針を `AGENTS.md` に記載してください。例えば次のように指示できます。

```markdown
- 実装と検証が成功した場合は、変更内容に適したメッセージでcommitし、現在のブランチへpushする
- commit前に次のrepoローカル設定を行う
  - `git config user.name "Example Bot"`
  - `git config user.email "example-bot@example.com"`
- 調査、レビュー、計画だけのタスクではcommitおよびpushを行わない
```

runnerはClaude Code終了後にGit操作を補完・検査しません。commitしない実行で一時作業ツリーに残った差分は、コンテナ終了時に破棄されます。

## セキュリティ上の前提

このrunnerは `bypassPermissions` でClaude Codeを起動します。対象は自身で管理する信頼済みリポジトリに限定してください。

`GITHUB_TOKEN` はcredential URLへ保存しませんが、Claude Code自身がGit操作を行えるように、そのプロセスから利用可能です。次の条件を守ってください。

- GitHub fine-grained tokenまたはGitHub Appの短寿命tokenを使う。
- tokenの対象を実行対象repoだけに限定する。
- cloneだけならContents read、pushさせる場合はContents writeとし、タスクに不要な権限を付与しない。
- 第三者の未検証repoや未信頼のpull requestを実行しない。
- runnerコンテナへSSH鍵、クラウド資格情報、ホストのDocker socketをmountしない。

tokenをClaude Codeから分離する必要がある場合は、このrunnerではなくcheckout、Claude Code、pushを別コンテナまたはCI jobへ分離してください。
