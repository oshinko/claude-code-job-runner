# Claude Code Job Runner

GitHubリポジトリをコンテナ内へcloneするか、ホストのローカルリポジトリをbind mountし、リポジトリルートの `AGENTS.md` を起点にClaude Codeを非対話実行するrunnerです。commit、push、Git identityなどのGitワークフローはrunnerでは判断せず、Claude Codeが `AGENTS.md` に従って実行します。

> このプロジェクトはAnthropicによる公式プロジェクトではありません。

## 動作の流れ

1. 必須設定と認証情報を検証します。
2. 次のどちらかの方法で対象リポジトリを用意します。
   - リモートモード: `GITHUB_TOKEN` を使って一時ディレクトリへcloneし、同じ認証をClaude Codeから利用できるようにします。`REPOSITORY_REVISION` が指定されている場合はclone後にcheckoutします。
   - ローカルモード: `REPOSITORY_REVISION` が空ならbind mountされた既存の作業ツリーをそのまま使用し、指定されていれば一時ディレクトリへcloneしてcheckoutします。
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

Composeではpip、npm、uvなどのパッケージ取得キャッシュを名前付きボリュームへ保存します。コンテナを削除してもキャッシュは残り、次回以降の依存関係セットアップで再利用されます。cloneしたリポジトリ、`.venv`、`node_modules` はジョブごとに作り直します。ローカル作業ツリーを直接使用した場合は、リポジトリ内に作成されたファイルがホスト側にも残ります。

キャッシュを削除する場合は、runnerが動作していないことを確認して次を実行します。

```console
docker compose down --volumes
```

キャッシュは同じComposeプロジェクトの実行間で共有されます。書き換え可能な共有状態になるため、信頼境界が異なるリポジトリには同じキャッシュボリュームを使用しないでください。

別名の環境ファイルを使う場合は、`ENV_FILE` で指定します。

PowerShell:

```powershell
$env:ENV_FILE = '.env.production'
docker compose run --rm runner
```

Bash:

```console
ENV_FILE=.env.production docker compose run --rm runner
```

`.env`、`*.env`、`compose.override.yaml` はGitの追跡対象から除外されています。秘密値を含むため共有、commit、ログへの貼り付けを行わず、Linuxではファイル権限も実行ユーザーだけが読めるようにしてください。

## ローカルリポジトリを使う

ローカル用Composeオーバーレイのテンプレートを `compose.override.yaml` へコピーします。このファイルはGitの追跡対象から除外され、通常の `docker compose` 実行時に自動で読み込まれます。

PowerShell:

```powershell
Copy-Item compose.override.local.yaml compose.override.yaml
```

Bash:

```console
cp compose.override.local.yaml compose.override.yaml
```

コピーした `compose.override.yaml` の `source` をホスト側のGitリポジトリルートへ書き換えます。

```yaml
services:
  runner:
    volumes:
      - type: bind
        source: /path/to/project
        target: ${REPOSITORY_URL}
```

続いて `.env` を次のように設定し、通常どおり実行します。

```dotenv
REPOSITORY_URL=/workspace/local-repository
REPOSITORY_REVISION=
```

```console
docker compose run --rm --build runner
```

`compose.override.local.yaml` はvolumeだけを追加し、環境変数は `compose.yaml` の `env_file` をそのまま使用します。`REPOSITORY_URL` はmount先となるコンテナ内の絶対パスです。対象リポジトリは `AGENTS.md` を含む必要があります。bind mountの所有者表現がコンテナと異なる環境でもGitが扱えるように、runnerはこのパスだけをコンテナ内のGit `safe.directory` に登録します。

`.env` の `REPOSITORY_REVISION` が未指定または空の場合は、現在checkoutされているブランチと未コミットの差分を含む作業ツリーを直接使用し、Claude Codeによる編集、commitなどの変更もホスト側へ残ります。重要な変更は事前にcommitまたは退避してください。

`REPOSITORY_REVISION` を指定した場合は、ローカルリポジトリを一時ディレクトリへcloneし、指定されたブランチ、タグ、コミットハッシュ、その他のcommit-ishをcheckoutして実行します。ブランチはローカルの追跡ブランチとして、それ以外はdetached HEADとしてcheckoutします。branchまたはtagと判定できる場合は `--single-branch --branch` で対象の履歴だけをcloneし、ハッシュやその他のcommit-ishでは解決に必要な履歴を取得するため通常のcloneを行います。指定対象はcloneで取得できる履歴に含まれている必要があります。ホスト作業ツリーの未コミット差分は含まれず、Claude Codeが一時cloneへ残した未commitの変更はコンテナ終了時に破棄されます。

Linuxで権限エラーやGitの所有者エラーが発生する場合は、イメージbuild時の `CONTAINER_UID` と `CONTAINER_GID` を対象リポジトリを所有するホストユーザーのUID、GIDに合わせてください。pushも行わせる場合は、リモートに必要な権限を持つ `GITHUB_TOKEN` を設定できます。

## GitHub Container Registryから実行する

release済みのイメージはGitHub Container Registryから取得できます。version tagは内容が固定されるため、再現性が必要な実行では `latest` ではなくversionを指定してください。

```console
docker pull ghcr.io/oshinko/claude-code-job-runner:1.2.3
```

```console
docker run --rm \
  -e REPOSITORY_URL=https://github.com/example/project.git \
  -e GITHUB_TOKEN \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e MAX_TURNS=30 \
  ghcr.io/oshinko/claude-code-job-runner:1.2.3
```

公開イメージは `linux/amd64` と `linux/arm64` に対応します。runnerのversionはイメージtagで表し、イメージ内のClaude Code versionは `CLAUDE_CODE_VERSION` で独立して管理します。既存の `compose.yaml` は引き続きローカルでイメージをbuildします。

### イメージをreleaseする

`vMAJOR.MINOR.PATCH` 形式のGit tagをpushすると、GitHub Actionsが `v` を除いたversion tagと `latest` を公開します。例えば `v1.2.3` から次の2つが作成されます。

- `ghcr.io/oshinko/claude-code-job-runner:1.2.3`
- `ghcr.io/oshinko/claude-code-job-runner:latest`

```console
git tag -a v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3
```

GitHub Container Registryのpackageは初回publish時にprivateで作成されます。公開イメージとして提供する場合は、初回workflow完了後にGitHubのpackage settingsでvisibilityをPublicへ変更してください。

## イメージを直接buildする

```console
docker build -t claude-code-job-runner:2.1.233 .
```

Claude Codeのバージョンはbuild argumentで変更できます。

```console
docker build \
  --build-arg CLAUDE_CODE_VERSION=2.1.233 \
  --build-arg CONTAINER_UID=10001 \
  --build-arg CONTAINER_GID=10001 \
  -t claude-code-job-runner:custom .
```

自動更新は無効です。バージョンを更新するときはbuild argumentを変更してイメージを再buildしてください。

`CONTAINER_UID` と `CONTAINER_GID` はコンテナ内の非root `runner` ユーザーへ割り当てる値で、既定値はどちらも `10001` です。通常は変更する必要はありません。

## 必須設定

| 変数 | 内容 |
| --- | --- |
| `REPOSITORY_URL` | GitHub HTTPS URL。ローカル用Composeではコンテナ内の絶対mountパス |
| `MAX_TURNS` | Claude Codeの最大agentic turn数。1以上の整数 |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth認証。API keyとは排他的 |
| `ANTHROPIC_API_KEY` | Anthropic API認証。OAuth tokenとは排他的 |

Claude認証は `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` のどちらか一方だけを指定します。

リモートモードでは次の設定も必須です。

| 変数 | 内容 |
| --- | --- |
| `GITHUB_TOKEN` | 対象repoとタスクに必要な最小権限を持つtoken |

ローカル用Composeでは `GITHUB_TOKEN` は任意で、pushなどに必要な場合だけ使用します。

任意設定:

| 変数 | 内容 |
| --- | --- |
| `REPOSITORY_REVISION` | checkoutするブランチ、タグ、コミットハッシュ、commit-ish。未指定時はリモートのデフォルトブランチを使用し、ローカルパスではcloneせず直接使用 |
| `MAX_BUDGET_USD` | 指定時に `--max-budget-usd` として渡す正数 |
| `CLAUDE_MODEL` | 指定時に `--model` として渡すmodel名またはalias |
| `PROMPT` | Claude Codeへ渡すタスク。未指定または空の場合はrunnerの既定文 |

`PROMPT`には実行ごとの短い指示を指定できます。詳細な要件はリポジトリ内の文書に置き、例えば `docs/tasks/example.mdを参照して実装してください。` のように指定します。複数行の長い指示は `.env` ではなく、リポジトリ内の文書で管理してください。

## docker runによる実行例

OAuth tokenを使う例です。

```console
docker run --rm \
  -e REPOSITORY_URL=https://github.com/example/project.git \
  -e REPOSITORY_REVISION=main \
  -e GITHUB_TOKEN \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e MAX_TURNS=30 \
  claude-code-job-runner:2.1.233
```

API keyを使う場合は `CLAUDE_CODE_OAUTH_TOKEN` の代わりに `ANTHROPIC_API_KEY` を渡します。秘密値をコマンドラインへ直接書かず、呼び出し元のsecret管理機能から環境変数として注入してください。

ローカルリポジトリを直接mountする例です。

```console
docker run --rm \
  --mount type=bind,source=/path/to/project,target=/workspace/local-repository \
  -e REPOSITORY_URL=/workspace/local-repository \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e MAX_TURNS=30 \
  claude-code-job-runner:2.1.233
```

## 利用可能な開発環境

runnerにはNode.js 24 LTS、npm、Debian trixie提供のPython 3、pip、venv、C/C++ビルドツール、Git、curl、jq、ripgrep、unzipが含まれます。

Python依存関係はシステム環境へ直接インストールせず、対象リポジトリの管理方式に従ってください。特に指定がなければ、Claude Codeはcloneしたリポジトリ内に仮想環境を作成できます。

```console
python -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

pip、npm、uvおよびXDG準拠ツールのキャッシュ先は `/home/runner/.cache` 以下に設定されています。uv自体は標準搭載せず、リポジトリの指示に従って導入します。

上記以外のSDKやシステムパッケージが必要な場合は、派生イメージへ追加します。

```dockerfile
FROM claude-code-job-runner:2.1.233

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends ruby \
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
