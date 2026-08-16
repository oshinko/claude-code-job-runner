#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_PROMPT='AGENTS.mdに記載された指示に従い、必要な関連文書を参照して作業を完了してください。'
readonly prompt="${PROMPT:-${DEFAULT_PROMPT}}"

work_dir=''
askpass_dir=''
claude_pid=''
repo_dir=''

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

require_env REPOSITORY_URL
require_env MAX_TURNS

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
  fail 'set exactly one of CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY, not both'
fi
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail 'set exactly one of CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY'
fi

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

export GIT_TERMINAL_PROMPT=0
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  create_askpass
  export GIT_ASKPASS="${askpass_dir}/askpass.sh"
fi

if [[ "${REPOSITORY_URL}" == /* && -z "${REPOSITORY_REVISION:-}" ]]; then
  [[ -d "${REPOSITORY_URL}" ]] \
    || fail 'a local REPOSITORY_URL must point to an existing directory'

  repo_dir="$(cd -- "${REPOSITORY_URL}" && pwd -P)"
  git config --global --add safe.directory "${repo_dir}"
  repository_root="$(git -C "${repo_dir}" rev-parse --show-toplevel 2>/dev/null)" \
    || fail 'a local REPOSITORY_URL must point to a Git repository root accessible by the runner user'
  [[ "${repository_root}" == "${repo_dir}" ]] \
    || fail 'a local REPOSITORY_URL must point to the Git repository root, not a subdirectory'

  log "Using local repository ${repo_dir}"
else
  repository_is_local=0
  if [[ "${REPOSITORY_URL}" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]]; then
    require_env GITHUB_TOKEN
  elif [[ "${REPOSITORY_URL}" == /* ]]; then
    repository_is_local=1
    [[ -d "${REPOSITORY_URL}" ]] \
      || fail 'a local REPOSITORY_URL must point to an existing directory'
    repository_source="$(cd -- "${REPOSITORY_URL}" && pwd -P)"
    git config --global --add safe.directory "${repository_source}"
    repository_root="$(git -C "${repository_source}" rev-parse --show-toplevel 2>/dev/null)" \
      || fail 'a local REPOSITORY_URL must point to a Git repository accessible by the runner user'
    [[ "${repository_root}" == "${repository_source}" ]] \
      || fail 'a local REPOSITORY_URL must point to the Git repository root, not a subdirectory'
  else
    fail 'REPOSITORY_URL must be an https://github.com/<owner>/<repo>[.git] URL or an absolute container path'
  fi

  clone_args=(clone)
  efficient_revision_kind=''
  if [[ -z "${REPOSITORY_REVISION:-}" ]]; then
    clone_args+=(--single-branch)
  elif (( repository_is_local )); then
    if git -C "${repository_source}" show-ref --verify --quiet "refs/heads/${REPOSITORY_REVISION}"; then
      efficient_revision_kind='branch'
    elif git -C "${repository_source}" show-ref --verify --quiet "refs/tags/${REPOSITORY_REVISION}"; then
      efficient_revision_kind='tag'
    fi
  else
    remote_refs="$(git ls-remote --heads --tags "${REPOSITORY_URL}" \
      "refs/heads/${REPOSITORY_REVISION}" "refs/tags/${REPOSITORY_REVISION}")" \
      || fail 'failed to inspect remote refs for REPOSITORY_REVISION'
    remote_branch_ref=''
    remote_tag_ref=''
    while IFS=$'\t' read -r _ remote_ref_name; do
      if [[ "${remote_ref_name}" == "refs/heads/${REPOSITORY_REVISION}" ]]; then
        remote_branch_ref="${remote_ref_name}"
      elif [[ "${remote_ref_name}" == "refs/tags/${REPOSITORY_REVISION}" ]]; then
        remote_tag_ref="${remote_ref_name}"
      fi
    done <<<"${remote_refs}"

    if [[ -n "${remote_branch_ref}" ]]; then
      efficient_revision_kind='branch'
    elif [[ -n "${remote_tag_ref}" ]]; then
      efficient_revision_kind='tag'
    fi
  fi

  if [[ -n "${efficient_revision_kind}" ]]; then
    clone_args+=(--single-branch --branch "${REPOSITORY_REVISION}")
  fi

  work_dir="$(mktemp -d /workspace/claude-job.XXXXXX)"
  repo_dir="${work_dir}/repo"

  log "Cloning ${REPOSITORY_URL}"
  git "${clone_args[@]}" \
    -- \
    "${REPOSITORY_URL}" \
    "${repo_dir}"

  if [[ -n "${REPOSITORY_REVISION:-}" && -z "${efficient_revision_kind}" ]]; then
    revision_kind='detached'
    revision_to_resolve="${REPOSITORY_REVISION}"
    if git -C "${repo_dir}" show-ref --verify --quiet "refs/heads/${REPOSITORY_REVISION}"; then
      revision_kind='local-branch'
      revision_to_resolve="refs/heads/${REPOSITORY_REVISION}"
    elif git -C "${repo_dir}" show-ref --verify --quiet "refs/remotes/origin/${REPOSITORY_REVISION}"; then
      revision_kind='remote-branch'
      revision_to_resolve="refs/remotes/origin/${REPOSITORY_REVISION}"
    elif git -C "${repo_dir}" show-ref --verify --quiet "refs/tags/${REPOSITORY_REVISION}"; then
      revision_to_resolve="refs/tags/${REPOSITORY_REVISION}"
    fi

    resolved_revision="$(git -C "${repo_dir}" rev-parse --verify --end-of-options "${revision_to_resolve}^{commit}" 2>/dev/null)" \
      || fail 'REPOSITORY_REVISION must resolve to a commit available in the cloned repository'

    log "Checking out revision ${REPOSITORY_REVISION}"
    if [[ "${revision_kind}" == 'local-branch' ]]; then
      git -C "${repo_dir}" switch "${REPOSITORY_REVISION}"
    elif [[ "${revision_kind}" == 'remote-branch' ]]; then
      git -C "${repo_dir}" switch --track --create "${REPOSITORY_REVISION}" "refs/remotes/origin/${REPOSITORY_REVISION}"
    else
      git -C "${repo_dir}" switch --detach "${resolved_revision}"
    fi
  fi
fi

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
claude "${claude_args[@]}" "${prompt}" &
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
