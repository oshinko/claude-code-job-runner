# Claude Code Job Runner

Gitリポジトリをコンテナ内へcloneするか、ホストのローカルディレクトリをbind mountし、そのディレクトリの `AGENTS.md` を起点にClaude Codeを非対話実行するrunnerです。commit、push、Git identityなどのGitワークフローはrunnerでは判断せず、Claude Codeが `AGENTS.md` に従って実行します。

> このプロジェクトはAnthropicによる公式プロジェクトではありません。

## 動作の流れ

1. 必須設定と認証情報を検証します。
2. 次のどちらかの方法で対象プロジェクトを用意します。
   - リモートモード: 一時ディレクトリへcloneし、`GITHUB_TOKEN` が指定されていればcloneとClaude CodeからのGit操作に使用します。`GIT_REVISION` が指定されている場合はclone後にcheckoutします。
   - ローカルモード: bind mountされたディレクトリをそのまま使用します。Git working tree内で `GIT_REVISION` が指定されていれば、そのworking treeを直接switchします。
3. 対象ディレクトリ直下の `AGENTS.md` の存在、非空、UTF-8を確認します。
4. 対象ディレクトリで次の要領によりClaude Codeを起動します。

   ```console
   claude -p \
     --append-system-prompt-file ./AGENTS.md \
     --permission-mode bypassPermissions \
     --output-format stream-json \
     --verbose \
     "AGENTS.mdに記載された指示に従い、必要な関連文書を参照して作業を完了してください。"
   ```

5. Claude Codeの終了コードをrunnerの終了コードとして返します。runnerによるcommit、push、差分保存は行いません。

通常モードで起動するため、対象ディレクトリに `CLAUDE.md`、Claude Code skills、hooks、plugins、MCP設定がある場合は、それらもClaude Codeの標準仕様に従って読み込まれます。`AGENTS.md` 自体はClaude Codeの自動検出対象ではないため、`--append-system-prompt-file` で明示的に追加しています。

## Docker Composeで実行する

Docker Compose 2.24.0以降を使用します。設定例をコピーし、対象プロジェクト、Git、Claude Codeの認証情報を入力してください。

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

Composeではpip、npm、uvなどのパッケージ取得キャッシュを名前付きボリュームへ保存します。コンテナを削除してもキャッシュは残り、次回以降の依存関係セットアップで再利用されます。リモートモードでcloneしたリポジトリはジョブごとに作り直します。ローカルディレクトリを直接使用した場合は、`.venv`、`node_modules`、その他の作成されたファイルがホスト側にも残ります。

キャッシュを削除する場合は、runnerが動作していないことを確認して次を実行します。

```console
docker compose down --volumes
```

キャッシュは同じComposeプロジェクトの実行間で共有されます。書き換え可能な共有状態になるため、信頼境界が異なる対象プロジェクトには同じキャッシュボリュームを使用しないでください。

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

## ローカルディレクトリを使う

ローカル用Composeオーバーレイのテンプレートを `compose.override.yaml` へコピーします。このファイルはGitの追跡対象から除外され、通常の `docker compose` 実行時に自動で読み込まれます。

PowerShell:

```powershell
Copy-Item compose.override.local.yaml compose.override.yaml
```

Bash:

```console
cp compose.override.local.yaml compose.override.yaml
```

コピーした `compose.override.yaml` の `source` をホスト側の対象ディレクトリへ書き換えます。

```yaml
services:
  runner:
    volumes:
      - type: bind
        source: /path/to/project
        target: ${PROJECT_LOCATION}
```

続いて `.env` を次のように設定し、通常どおり実行します。

```dotenv
PROJECT_LOCATION=/workspace/local-project
GIT_REVISION=
```

```console
docker compose run --rm --build runner
```

`compose.override.local.yaml` はvolumeだけを追加し、環境変数は `compose.yaml` の `env_file` をそのまま使用します。`PROJECT_LOCATION` はmount先となるコンテナ内の絶対パスです。対象ディレクトリは `AGENTS.md` を含む必要があります。対象がGit working tree内にある場合、bind mountの所有者表現がコンテナと異なる環境でもGitが扱えるように、runnerは検出したGitルートをコンテナ内のGit `safe.directory` に登録します。

`.env` の `GIT_REVISION` が未指定または空の場合は、現在のディレクトリを直接使用し、Claude Codeによる編集、commitなどの変更もホスト側へ残ります。Git working treeの場合は、現在checkoutされているbranchと未コミットの差分を含む状態が使われます。重要な変更は事前にcommitまたは退避してください。

`GIT_REVISION` を指定した場合、対象がGit working tree内なら、検出したGitルートで指定されたブランチ、タグ、コミットハッシュ、その他のcommit-ishへ直接switchします。ローカルブランチへは通常どおりswitchし、`origin` のremote tracking branchだけが存在する場合はローカル追跡ブランチを作成します。タグ、コミットハッシュ、その他のcommit-ishはdetached HEADとしてswitchします。runnerは `--force` を使用せず、未コミット変更と競合すればGitのエラーを返します。switch後のbranch、HEAD、作業ツリーは復元しないため、状態変更はホスト側へ残ります。非Gitディレクトリでは `GIT_REVISION` を指定できません。

Linuxで権限エラーやGitの所有者エラーが発生する場合は、イメージbuild時の `CONTAINER_UID` と `CONTAINER_GID` を対象ディレクトリを所有するホストユーザーのUID、GIDに合わせてください。GitHub-hosted runnerで既存の公開イメージを使う場合は、後述の方法でworkspaceを書き込み可能にできます。pushも行わせる場合は、リモートに必要な権限を持つ `GITHUB_TOKEN` を設定できます。

## GitHub Container Registryから実行する

release済みのイメージはGitHub Container Registryから取得できます。`latest` はreleaseのたびに更新されるため、特定releaseを使う場合はversion tagまたはbuild識別tagを指定してください。

```console
docker pull ghcr.io/oshinko/claude-code-job-runner:1.2.3
```

```console
docker run --rm \
  -e PROJECT_LOCATION=https://github.com/example/project.git \
  -e GITHUB_TOKEN \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e MAX_TURNS=30 \
  ghcr.io/oshinko/claude-code-job-runner:1.2.3
```

公開イメージは `linux/amd64` と `linux/arm64` に対応します。runnerのversionはイメージtagで表し、イメージ内のClaude Code versionは `CLAUDE_CODE_VERSION` で独立して管理します。既存の `compose.yaml` は引き続きローカルでイメージをbuildします。

### イメージをreleaseする

`vMAJOR.MINOR.PATCH` 形式のGit tagをpushすると、GitHub Actionsが `v` を除いたversion tag、`latest`、build識別tagを1回のbuildで公開します。build識別tagは `<version>-gh<GitHub Actions run number>.g<commit SHAの先頭7桁>` 形式です。例えばrun numberが `42`、commit SHAが `abcdef0...` の `v1.2.3` から次の3つが作成されます。

- `ghcr.io/oshinko/claude-code-job-runner:1.2.3`
- `ghcr.io/oshinko/claude-code-job-runner:latest`
- `ghcr.io/oshinko/claude-code-job-runner:1.2.3-gh42.gabcdef0`

```console
git tag -a v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3
```

同じworkflow runを再実行した場合、run numberとcommit SHAは変わらないため、同じ3つのimage tagが更新されます。`main` ブランチへのpushではimageをbuild・公開しません。

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
| `PROJECT_LOCATION` | 対象プロジェクトの場所。ローカルディレクトリはコンテナ内の絶対パス、それ以外は `git clone` へ渡すGit source |
| `MAX_TURNS` | Claude Codeの最大agentic turn数。1以上の整数 |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth認証。API keyとは排他的 |
| `ANTHROPIC_API_KEY` | Anthropic API認証。OAuth tokenとは排他的 |

Claude認証は `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` のどちらか一方だけを指定します。

GitHubまたはGitHub Enterprise Serverの認証が必要な場合は次の設定も使用します。

| 変数 | 内容 |
| --- | --- |
| `GITHUB_TOKEN` | 対象のGitHub/GitHub Enterprise Server repoとタスクに必要な最小権限を持つtoken |
| `GITHUB_SERVER_URL` | tokenを渡すGitHub serverのURL。`GITHUB_TOKEN` 設定時の既定値は `https://github.com` |

絶対パス以外の `PROJECT_LOCATION` はschemeやhostを制限せず、そのままGitへ渡します。HTTPS、SSH、scp形式、`git://`、`file://`、Git remote helperなど、実行環境のGitが解釈できるsourceを使用できます。先頭が `/` の絶対パスはローカルディレクトリとしてcloneせず直接使用します。対象がGitルートまたはそのサブディレクトリなら親Git working treeを認識し、非GitディレクトリならGit操作を補完せずそのまま使用します。`ext::` remote helperも有効化されており任意コマンドを実行できるため、`PROJECT_LOCATION` は信頼できる呼び出し元だけが設定してください。

`GITHUB_TOKEN` は任意です。設定されるとrunnerはGit askpassを用意し、HTTPS認証先のauthority（hostとport）が `GITHUB_SERVER_URL` と一致する場合だけusername `x-access-token` とtokenを返します。`GITHUB_SERVER_URL` が空または未設定なら `https://github.com` として扱います。GitHub Enterprise ServerをGitHub Actionsから利用する場合はActionsが設定する値をそのまま渡せます。ローカル環境などでは対象serverのURLを明示してください。別host、SSH、その他のprotocolには `GITHUB_TOKEN` を返しません。remote refの確認またはcloneに失敗した場合、runnerはGitのエラーに加えて、tokenの有無に応じた確認事項を表示します。

任意設定:

| 変数 | 内容 |
| --- | --- |
| `GIT_REVISION` | switchまたはcheckoutするブランチ、タグ、コミットハッシュ、commit-ish。未指定時はリモートのデフォルトブランチを使用し、ローカルパスでは現在の状態を直接使用 |
| `MAX_BUDGET_USD` | 指定時に `--max-budget-usd` として渡す正数 |
| `CLAUDE_MODEL` | 指定時に `--model` として渡すmodel名またはalias |
| `PROMPT` | Claude Codeへ渡すタスク。未指定または空の場合はrunnerの既定文 |

`PROMPT`には実行ごとの短い指示を指定できます。詳細な要件は対象プロジェクト内の文書に置き、例えば `docs/tasks/example.mdを参照して実装してください。` のように指定します。複数行の長い指示は `.env` ではなく、対象プロジェクト内の文書で管理してください。

## docker runによる実行例

OAuth tokenを使う例です。

```console
docker run --rm \
  -e PROJECT_LOCATION=https://github.com/example/project.git \
  -e GIT_REVISION=main \
  -e GITHUB_TOKEN \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e MAX_TURNS=30 \
  claude-code-job-runner:2.1.233
```

API keyを使う場合は `CLAUDE_CODE_OAUTH_TOKEN` の代わりに `ANTHROPIC_API_KEY` を渡します。秘密値をコマンドラインへ直接書かず、呼び出し元のsecret管理機能から環境変数として注入してください。

ローカルディレクトリを直接mountする例です。

```console
docker run --rm \
  --mount type=bind,source=/path/to/project,target=/workspace/local-project \
  -e PROJECT_LOCATION=/workspace/local-project \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e MAX_TURNS=30 \
  claude-code-job-runner:2.1.233
```

### GitHub Actionsでcheckout済みのリポジトリを使う

GitHub-hosted runnerのworkspaceとコンテナ内の `runner` ユーザーではUID、GIDが異なるため、そのままbind mountすると書き込みに失敗する場合があります。コンテナの起動前にworkspaceを全ユーザーから書き込み可能にし、イメージの既定ユーザーで実行します。

```yaml
name: Run Claude Code

on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6

      - name: Make workspace writable
        run: sudo chmod -R a+rwX "$GITHUB_WORKSPACE"

      - name: Run Claude Code
        env:
          GITHUB_TOKEN: ${{ github.token }}
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
        run: |
          docker run --rm \
            --mount type=bind,source="$GITHUB_WORKSPACE",target=/workspace/local-project \
            -e PROJECT_LOCATION=/workspace/local-project \
            -e GITHUB_TOKEN \
            -e GITHUB_SERVER_URL \
            -e CLAUDE_CODE_OAUTH_TOKEN \
            -e MAX_TURNS=30 \
            ghcr.io/oshinko/claude-code-job-runner:1.2.3
```

`GIT_REVISION` は指定せず、checkout済みの作業ツリーを直接使用します。commit、pushを含むGit操作はコンテナ内で完結させてください。コンテナが新しく作成したファイルはUID、GID `10001:10001` の所有になる場合があります。この例では後続stepからworkspaceを更新しないことを前提とし、所有権は復元しません。

`chmod -R a+rwX` はworkspace内の全ディレクトリとファイルへ広い権限を付与します。信頼できるリポジトリとworkflowに限定し、同じjobで未信頼のコードを実行しないでください。

## 利用可能な開発環境

runnerにはNode.js 24 LTS、npm、Debian trixie提供のPython 3、pip、venv、C/C++ビルドツール、Git、OpenSSH client、curl、jq、ripgrep、unzipが含まれます。

SSH形式のrepository sourceは利用できますが、秘密鍵、SSH agent、SSH config、`known_hosts` はイメージに含まれません。接続先とタスクだけに権限を限定した専用credentialを呼び出し側で用意し、ホスト鍵を検証できる状態でコンテナへ提供してください。

Python依存関係はシステム環境へ直接インストールせず、対象プロジェクトの管理方式に従ってください。特に指定がなければ、Claude Codeは対象ディレクトリ内に仮想環境を作成できます。

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

このrunnerは `bypassPermissions` でClaude Codeを起動します。対象は自身で管理する信頼済みプロジェクトに限定してください。

`GITHUB_TOKEN` はcredential URLへ保存しませんが、Claude Code自身がGit操作を行えるように、そのプロセスとGit askpassから利用可能です。askpassは `GITHUB_SERVER_URL` とauthorityが一致するHTTPS接続だけにtokenを返します。ただしClaude Codeのプロセスからは環境変数自体を参照できるため、信頼できるリポジトリだけを使用してください。次の条件を守ってください。

- 認証付きGit操作が不要なら `GITHUB_TOKEN` をコンテナへ渡さない。
- GitHub fine-grained tokenまたはGitHub Appの短寿命tokenを使う。
- tokenの対象を実行対象repoだけに限定する。
- cloneだけならContents read、pushさせる場合はContents writeとし、タスクに不要な権限を付与しない。
- 第三者の未検証repoや未信頼のpull requestを実行しない。
- 不要なSSH鍵やクラウド資格情報、ホストのDocker socketをrunnerコンテナへmountしない。SSH認証が必要な場合も、対象repository専用の短寿命credentialまたは権限を限定したSSH agentを使用する。

GitHub Actionsでcheckout済みrepositoryからcredentialも除外したい場合は、`actions/checkout` に `persist-credentials: false` を指定してください。既定ではcheckout用credentialがrepositoryのGit設定に保持されるため、`GITHUB_TOKEN` 環境変数をコンテナへ渡さないだけではGit認証を完全に除外できません。

tokenをClaude Codeから分離する必要がある場合は、このrunnerではなくcheckout、Claude Code、pushを別コンテナまたはCI jobへ分離してください。
