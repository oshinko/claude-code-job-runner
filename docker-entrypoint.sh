#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_PROMPT='AGENTS.mdに記載された指示に従い、必要な関連文書を参照して作業を完了してください。'
readonly RUNNER_POLICY='Gitのcommitおよびpushは行わず、実装と検証までを完了してください。'

work_dir=''
askpass_dir=''
claude_pid=''

log() {
  printf '[claude-code-runner] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  if [[ -n "${askpass_dir}" && -d "${askpass_dir}" ]]; then
    rm -rf -- "${askpass_dir}"
  fi
  if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
    rm -rf -- "${work_dir}"
  fi
}

forward_signal() {
  local signal="$1"
  if [[ -n "${claude_pid}" ]]; then
    kill -s "${signal}" "${claude_pid}" 2>/dev/null || true
  fi
}

trap cleanup EXIT
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "${name} is required"
}

for required_name in \
  REPOSITORY_URL \
  GIT_BRANCH \
  GITHUB_TOKEN \
  GIT_AUTHOR_NAME \
  GIT_AUTHOR_EMAIL \
  GIT_COMMIT_MESSAGE \
  MAX_TURNS; do
  require_env "${required_name}"
done

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
  fail 'set exactly one of CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY, not both'
fi
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail 'set exactly one of CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY'
fi

[[ "${REPOSITORY_URL}" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]] \
  || fail 'REPOSITORY_URL must be an https://github.com/<owner>/<repo>[.git] URL without embedded credentials'

git check-ref-format --branch "${GIT_BRANCH}" >/dev/null 2>&1 \
  || fail 'GIT_BRANCH is not a valid branch name'

[[ "${MAX_TURNS}" =~ ^[1-9][0-9]*$ ]] \
  || fail 'MAX_TURNS must be a positive integer'

if [[ -n "${MAX_BUDGET_USD:-}" ]]; then
  [[ "${MAX_BUDGET_USD}" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] \
    || fail 'MAX_BUDGET_USD must be a positive number'
  awk -v value="${MAX_BUDGET_USD}" 'BEGIN { exit !(value > 0) }' \
    || fail 'MAX_BUDGET_USD must be greater than zero'
fi

[[ "${GIT_AUTHOR_NAME}" != *$'\n'* && "${GIT_AUTHOR_NAME}" != *$'\r'* ]] \
  || fail 'GIT_AUTHOR_NAME must be a single line'
[[ "${GIT_AUTHOR_EMAIL}" != *$'\n'* && "${GIT_AUTHOR_EMAIL}" != *$'\r'* ]] \
  || fail 'GIT_AUTHOR_EMAIL must be a single line'

readonly github_token="${GITHUB_TOKEN}"
unset GITHUB_TOKEN

create_askpass() {
  askpass_dir="$(mktemp -d /tmp/claude-git-askpass.XXXXXX)"
  cat >"${askpass_dir}/askpass.sh" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "${RUNNER_GITHUB_TOKEN}" ;;
esac
EOF
  chmod 0700 "${askpass_dir}/askpass.sh"
}

remove_askpass() {
  if [[ -n "${askpass_dir}" && -d "${askpass_dir}" ]]; then
    rm -rf -- "${askpass_dir}"
  fi
  askpass_dir=''
}

git_with_token() {
  create_askpass
  RUNNER_GITHUB_TOKEN="${github_token}" \
    GIT_ASKPASS="${askpass_dir}/askpass.sh" \
    GIT_TERMINAL_PROMPT=0 \
    "$@"
  local status=$?
  remove_askpass
  return "${status}"
}

metadata_manifest() {
  {
    find .git -mindepth 1 \
      ! -path .git/index \
      ! -path .git/index.lock \
      -printf '%y  %p  %l\n' | sort
    find .git -type f \
      ! -path .git/index \
      ! -path .git/index.lock \
      -print0 | sort -z | xargs -0 -r sha256sum
  } | sha256sum | awk '{ print $1 }'
}

work_dir="$(mktemp -d /workspace/claude-run.XXXXXX)"
repo_dir="${work_dir}/repo"

log "Cloning ${REPOSITORY_URL} branch ${GIT_BRANCH}"
git_with_token git clone \
  --single-branch \
  --branch "${GIT_BRANCH}" \
  -- \
  "${REPOSITORY_URL}" \
  "${repo_dir}"

cd "${repo_dir}"

[[ -f ./AGENTS.md && ! -L ./AGENTS.md ]] \
  || fail 'the repository root must contain a regular, non-symlink AGENTS.md file'
[[ -s ./AGENTS.md ]] || fail 'AGENTS.md must not be empty'
iconv -f UTF-8 -t UTF-8 ./AGENTS.md >/dev/null 2>&1 \
  || fail 'AGENTS.md must be valid UTF-8'

readonly baseline_head="$(git rev-parse --verify HEAD)"
readonly baseline_metadata="$(metadata_manifest)"

claude_args=(
  -p
  --append-system-prompt-file ./AGENTS.md
  --append-system-prompt "${RUNNER_POLICY}"
  --permission-mode bypassPermissions
  --max-turns "${MAX_TURNS}"
  --output-format stream-json
  --verbose
  --no-session-persistence
)

if [[ -n "${MAX_BUDGET_USD:-}" ]]; then
  claude_args+=(--max-budget-usd "${MAX_BUDGET_USD}")
fi
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  claude_args+=(--model "${CLAUDE_MODEL}")
fi

log 'Starting Claude Code'
set +e
env -u GITHUB_TOKEN -u RUNNER_GITHUB_TOKEN \
  claude "${claude_args[@]}" "${DEFAULT_PROMPT}" &
claude_pid=$!
wait "${claude_pid}"
claude_status=$?
claude_pid=''
set -e

if (( claude_status != 0 )); then
  fail "Claude Code exited with status ${claude_status}; changes will not be committed"
fi

[[ "$(git rev-parse --verify HEAD)" == "${baseline_head}" ]] \
  || fail 'Claude Code changed HEAD or created a commit; refusing to push'
[[ "$(metadata_manifest)" == "${baseline_metadata}" ]] \
  || fail 'Claude Code changed protected Git metadata; refusing to commit or push'

unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

if [[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  log 'Claude Code completed successfully and produced no changes'
  exit 0
fi

log 'Creating runner-managed commit'
git add -A
if git diff --cached --quiet; then
  log 'No committable changes remain after staging'
  exit 0
fi

git \
  -c core.hooksPath=/dev/null \
  -c user.name="${GIT_AUTHOR_NAME}" \
  -c user.email="${GIT_AUTHOR_EMAIL}" \
  commit --no-gpg-sign -m "${GIT_COMMIT_MESSAGE}"

log "Pushing commit to ${GIT_BRANCH}"
git_with_token git \
  -c core.hooksPath=/dev/null \
  push origin "HEAD:refs/heads/${GIT_BRANCH}"

log "Completed successfully at commit $(git rev-parse HEAD)"
