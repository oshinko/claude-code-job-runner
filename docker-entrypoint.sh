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

# Empty credential variables still take precedence over WIF credentials in the
# Anthropic SDK, so remove empty values before selecting an authentication mode.
# https://platform.claude.com/docs/en/manage-claude/wif-reference#credential-precedence
auth_environment_names=(
  CLAUDE_CODE_OAUTH_TOKEN
  ANTHROPIC_API_KEY
  ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_PROFILE
  ANTHROPIC_FEDERATION_RULE_ID
  ANTHROPIC_ORGANIZATION_ID
  ANTHROPIC_SERVICE_ACCOUNT_ID
  ANTHROPIC_WORKSPACE_ID
  ANTHROPIC_IDENTITY_TOKEN_FILE
  ANTHROPIC_IDENTITY_TOKEN
)
for name in "${auth_environment_names[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    unset "${name}"
  fi
done

if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  fail 'ANTHROPIC_AUTH_TOKEN is not supported; use CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, or Workload Identity Federation'
fi
if [[ -n "${ANTHROPIC_PROFILE:-}" ]]; then
  fail 'ANTHROPIC_PROFILE is not supported; configure Workload Identity Federation with environment variables'
fi

wif_environment_names=(
  ANTHROPIC_FEDERATION_RULE_ID
  ANTHROPIC_ORGANIZATION_ID
  ANTHROPIC_SERVICE_ACCOUNT_ID
  ANTHROPIC_WORKSPACE_ID
  ANTHROPIC_IDENTITY_TOKEN_FILE
  ANTHROPIC_IDENTITY_TOKEN
)
wif_is_configured=0
for name in "${wif_environment_names[@]}"; do
  if [[ -n "${!name:-}" ]]; then
    wif_is_configured=1
    break
  fi
done

authentication_mode_count=0
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  ((authentication_mode_count += 1))
fi
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  ((authentication_mode_count += 1))
fi
if (( wif_is_configured )); then
  require_env ANTHROPIC_FEDERATION_RULE_ID
  require_env ANTHROPIC_ORGANIZATION_ID
  require_env ANTHROPIC_SERVICE_ACCOUNT_ID

  if [[ -n "${ANTHROPIC_IDENTITY_TOKEN_FILE:-}" && -n "${ANTHROPIC_IDENTITY_TOKEN:-}" ]]; then
    fail 'set exactly one of ANTHROPIC_IDENTITY_TOKEN_FILE or ANTHROPIC_IDENTITY_TOKEN, not both'
  fi
  if [[ -z "${ANTHROPIC_IDENTITY_TOKEN_FILE:-}" && -z "${ANTHROPIC_IDENTITY_TOKEN:-}" ]]; then
    fail 'set exactly one of ANTHROPIC_IDENTITY_TOKEN_FILE or ANTHROPIC_IDENTITY_TOKEN for Workload Identity Federation'
  fi
  if [[ -n "${ANTHROPIC_IDENTITY_TOKEN_FILE:-}" ]]; then
    [[ -f "${ANTHROPIC_IDENTITY_TOKEN_FILE}" && -r "${ANTHROPIC_IDENTITY_TOKEN_FILE}" ]] \
      || fail 'ANTHROPIC_IDENTITY_TOKEN_FILE must point to a readable file'
    [[ -s "${ANTHROPIC_IDENTITY_TOKEN_FILE}" ]] \
      || fail 'ANTHROPIC_IDENTITY_TOKEN_FILE must not be empty'
  fi

  ((authentication_mode_count += 1))
fi

if (( authentication_mode_count != 1 )); then
  fail 'set exactly one authentication method: CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, or Workload Identity Federation'
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
prompt_url="${1#*\'}"
if [ "${prompt_url}" = "$1" ]; then
  exit 0
fi
prompt_url="${prompt_url%%\'*}"
case "${prompt_url}" in
  http://*|https://*) ;;
  *) exit 0 ;;
esac
prompt_authority="${prompt_url#*://}"
prompt_authority="${prompt_authority%%[/?#]*}"
prompt_authority="${prompt_authority##*@}"
prompt_authority="$(printf '%s' "${prompt_authority}" | tr '[:upper:]' '[:lower:]')"
if [ "${prompt_authority}" != "${GITHUB_ASKPASS_AUTHORITY}" ]; then
  exit 0
fi
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "${GITHUB_TOKEN}" ;;
esac
EOF
  chmod 0700 "${askpass_dir}/askpass.sh"
}

configure_github_askpass() {
  local server_url="${GITHUB_SERVER_URL:-https://github.com}"
  local server_authority=''
  case "${server_url}" in
    http://*|https://*)
      server_authority="${server_url#*://}"
      server_authority="${server_authority%%[/?#]*}"
      ;;
    *)
      fail 'GITHUB_SERVER_URL must be an http:// or https:// URL when GITHUB_TOKEN is set'
      ;;
  esac
  [[ -n "${server_authority}" && "${server_authority}" != *'@'* ]] \
    || fail 'GITHUB_SERVER_URL must include a valid host without user information'
  export GITHUB_ASKPASS_AUTHORITY="${server_authority,,}"
  create_askpass
}

fail_git_operation() {
  local operation="$1"
  if [[ "${REPOSITORY_URL}" == /* ]]; then
    fail "failed to ${operation} local repository ${REPOSITORY_URL}; see the Git error above"
  fi
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    fail "failed to ${operation} ${REPOSITORY_URL}; see the Git error above. Check the repository source, network, and protocol-specific authentication"
  fi
  fail "failed to ${operation} ${REPOSITORY_URL}; see the Git error above. GITHUB_TOKEN is only offered to the GITHUB_SERVER_URL host (github.com by default); check that host and the token's repository access"
}

export GIT_TERMINAL_PROMPT=0
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  configure_github_askpass
  export GIT_ASKPASS="${askpass_dir}/askpass.sh"
fi
git config --global protocol.ext.allow always

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
  if [[ "${REPOSITORY_URL}" == /* ]]; then
    repository_is_local=1
    [[ -d "${REPOSITORY_URL}" ]] \
      || fail 'a local REPOSITORY_URL must point to an existing directory'
    repository_source="$(cd -- "${REPOSITORY_URL}" && pwd -P)"
    git config --global --add safe.directory "${repository_source}"
    repository_root="$(git -C "${repository_source}" rev-parse --show-toplevel 2>/dev/null)" \
      || fail 'a local REPOSITORY_URL must point to a Git repository accessible by the runner user'
    [[ "${repository_root}" == "${repository_source}" ]] \
      || fail 'a local REPOSITORY_URL must point to the Git repository root, not a subdirectory'
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
    if ! remote_refs="$(git ls-remote --heads --tags -- "${REPOSITORY_URL}" \
      "refs/heads/${REPOSITORY_REVISION}" "refs/tags/${REPOSITORY_REVISION}")"; then
      fail_git_operation 'inspect remote refs for'
    fi
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
  if ! git "${clone_args[@]}" \
    -- \
    "${REPOSITORY_URL}" \
    "${repo_dir}"; then
    fail_git_operation 'clone'
  fi

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
