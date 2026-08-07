# Claude Code Docker Runner

GitHubリポジトリをコンテナ内へcloneし、リポジトリルートの `AGENTS.md` を起点にClaude Codeを非対話実行するrunnerです。Claude Codeが正常終了して変更が残った場合、runnerが1つのcommitを作成し、指定されたブランチへ直接pushします。

## 動作の流れ

1. 必須設定と認証情報を検証します。
2. `GITHUB_TOKEN` を使って指定ブランチを一時ディレクトリへcloneします。
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

5. Claude Codeが成功し、Gitメタデータが変更されていない場合だけ、全差分をrunner管理の1コミットにします。
6. 指定ブランチへ通常のfast-forward pushを行います。force pushや自動rebaseはしません。

通常モードで起動するため、リポジトリに `CLAUDE.md`、Claude Code skills、hooks、plugins、MCP設定がある場合は、それらもClaude Codeの標準仕様に従って読み込まれます。`AGENTS.md` 自体はClaude Codeの自動検出対象ではないため、`--append-system-prompt-file` で明示的に追加しています。

## イメージのbuild

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
| `GIT_BRANCH` | cloneおよび直接pushするブランチ |
| `GITHUB_TOKEN` | 対象repoのContents read/writeを持つtoken |
| `GIT_AUTHOR_NAME` | commit author名 |
| `GIT_AUTHOR_EMAIL` | commit authorメールアドレス |
| `GIT_COMMIT_MESSAGE` | runnerが作るcommitのメッセージ |
| `MAX_TURNS` | Claude Codeの最大agentic turn数。1以上の整数 |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code OAuth認証。API keyとは排他的 |
| `ANTHROPIC_API_KEY` | Anthropic API認証。OAuth tokenとは排他的 |

Claude認証は `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` のどちらか一方だけを指定します。

任意設定:

| 変数 | 内容 |
| --- | --- |
| `MAX_BUDGET_USD` | 指定時に `--max-budget-usd` として渡す正数 |
| `CLAUDE_MODEL` | 指定時に `--model` として渡すmodel名またはalias |

## 実行例

OAuth tokenを使う例です。

```console
docker run --rm \
  -e REPOSITORY_URL=https://github.com/example/project.git \
  -e GIT_BRANCH=main \
  -e GITHUB_TOKEN \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e GIT_AUTHOR_NAME=claude-code-runner \
  -e GIT_AUTHOR_EMAIL=claude-code-runner@example.invalid \
  -e 'GIT_COMMIT_MESSAGE=chore: apply automated changes' \
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

## 終了条件

- Claude Codeが失敗した場合: 非ゼロ終了し、commit/pushしません。
- Claude Codeが変更を作らなかった場合: ゼロ終了し、commit/pushしません。
- Claude Codeがcommit、ref、Git設定、Git hookを変更した場合: 非ゼロ終了し、pushしません。
- remote branchが実行中に先行した場合: pushが失敗します。force pushや自動rebaseは行いません。
- branch protectionが直接pushを拒否した場合: 非ゼロ終了します。

## セキュリティ上の前提

このrunnerは `bypassPermissions` でClaude Codeを起動します。対象は自身で管理する信頼済みリポジトリに限定してください。

`GITHUB_TOKEN` はClaude Code子プロセスの環境から除外し、Gitのcredential URLにも保存しません。ただし、clone、Claude実行、pushを同じコンテナ・同じUnixユーザーで行う構成であるため、OSレベルの完全な秘密分離ではありません。次の条件を守ってください。

- GitHub fine-grained tokenまたはGitHub Appの短寿命tokenを使う。
- tokenの対象を実行対象repoだけに限定する。
- Contents read/write以外の不要な権限を付与しない。
- 第三者の未検証repoや未信頼のpull requestを実行しない。
- runnerコンテナへSSH鍵、クラウド資格情報、ホストのDocker socketをmountしない。

より強い秘密分離が必要な場合は、checkout、Claude Code、pushを別コンテナまたはCI jobへ分離してください。
