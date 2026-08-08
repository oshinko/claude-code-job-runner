#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_PROMPT='AGENTS.mdに記載された指示に従い、必要な関連文書を参照して作業を完了してください。'

work_dir=''
askpass_dir=''
claude_pid=''

log() {
  printf '[claude-code-job-runner] %s\n' "$*" >&2
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
  GITHUB_TOKEN \
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

readonly git_branch="${GIT_BRANCH:-main}"
git check-ref-format --branch "${git_branch}" >/dev/null 2>&1 \
  || fail 'GIT_BRANCH is not a valid branch name'
export GIT_BRANCH="${git_branch}"

[[ "${MAX_TURNS}" =~ ^[1-9][0-9]*$ ]] \
  || fail 'MAX_TURNS must be a positive integer'

if [[ -n "${MAX_BUDGET_USD:-}" ]]; then
  [[ "${MAX_BUDGET_USD}" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] \
    || fail 'MAX_BUDGET_USD must be a positive number'
  awk -v value="${MAX_BUDGET_USD}" 'BEGIN { exit !(value > 0) }' \
    || fail 'MAX_BUDGET_USD must be greater than zero'
fi

create_askpass() {
  askpass_dir="$(mktemp -d /tmp/claude-git-askpass.XXXXXX)"
  cat >"${askpass_dir}/askpass.sh" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "${GITHUB_TOKEN}" ;;
esac
EOF
  chmod 0700 "${askpass_dir}/askpass.sh"
}

work_dir="$(mktemp -d /workspace/claude-job.XXXXXX)"
repo_dir="${work_dir}/repo"

create_askpass
export GIT_ASKPASS="${askpass_dir}/askpass.sh"
export GIT_TERMINAL_PROMPT=0

log "Cloning ${REPOSITORY_URL} branch ${git_branch}"
git clone \
  --single-branch \
  --branch "${git_branch}" \
  -- \
  "${REPOSITORY_URL}" \
  "${repo_dir}"

cd "${repo_dir}"

[[ -f ./AGENTS.md && ! -L ./AGENTS.md ]] \
  || fail 'the repository root must contain a regular, non-symlink AGENTS.md file'
[[ -s ./AGENTS.md ]] || fail 'AGENTS.md must not be empty'
iconv -f UTF-8 -t UTF-8 ./AGENTS.md >/dev/null 2>&1 \
  || fail 'AGENTS.md must be valid UTF-8'

claude_args=(
  -p
  --append-system-prompt-file ./AGENTS.md
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
claude "${claude_args[@]}" "${DEFAULT_PROMPT}" &
claude_pid=$!
wait "${claude_pid}"
claude_status=$?
claude_pid=''
set -e

if (( claude_status != 0 )); then
  log "Claude Code exited with status ${claude_status}"
  exit "${claude_status}"
fi

log 'Claude Code completed successfully'
