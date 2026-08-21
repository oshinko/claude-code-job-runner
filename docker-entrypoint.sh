#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_PROMPT='AGENTS.mdに記載された指示に従い、必要な関連文書を参照して作業を完了してください。'
readonly prompt="${PROMPT:-${DEFAULT_PROMPT}}"

work_dir=''
askpass_dir=''
claude_pid=''
project_dir=''

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

require_env PROJECT_LOCATION
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
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    fail "failed to ${operation} ${PROJECT_LOCATION}; see the Git error above. Check the project location, network, and protocol-specific authentication"
  fi
  fail "failed to ${operation} ${PROJECT_LOCATION}; see the Git error above. GITHUB_TOKEN is only offered to the GITHUB_SERVER_URL host (github.com by default); check that host and the token's repository access"
}

switch_git_revision() {
  local git_root="$1"
  local revision_kind='detached'
  local revision_to_resolve="${GIT_REVISION}"
  local resolved_revision=''

  if git -C "${git_root}" show-ref --verify --quiet "refs/heads/${GIT_REVISION}"; then
    revision_kind='local-branch'
    revision_to_resolve="refs/heads/${GIT_REVISION}"
  elif git -C "${git_root}" show-ref --verify --quiet "refs/remotes/origin/${GIT_REVISION}"; then
    revision_kind='remote-branch'
    revision_to_resolve="refs/remotes/origin/${GIT_REVISION}"
  elif git -C "${git_root}" show-ref --verify --quiet "refs/tags/${GIT_REVISION}"; then
    revision_to_resolve="refs/tags/${GIT_REVISION}"
  fi

  resolved_revision="$(git -C "${git_root}" rev-parse --verify --end-of-options "${revision_to_resolve}^{commit}" 2>/dev/null)" \
    || fail 'GIT_REVISION must resolve to a commit available in the Git repository'

  log "Switching to Git revision ${GIT_REVISION}"
  if [[ "${revision_kind}" == 'local-branch' ]]; then
    git -C "${git_root}" switch "${GIT_REVISION}"
  elif [[ "${revision_kind}" == 'remote-branch' ]]; then
    git -C "${git_root}" switch --track --create "${GIT_REVISION}" "refs/remotes/origin/${GIT_REVISION}"
  else
    git -C "${git_root}" switch --detach "${resolved_revision}"
  fi
}

export GIT_TERMINAL_PROMPT=0
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  configure_github_askpass
  export GIT_ASKPASS="${askpass_dir}/askpass.sh"
fi
git config --global protocol.ext.allow always

if [[ "${PROJECT_LOCATION}" == /* ]]; then
  [[ -d "${PROJECT_LOCATION}" ]] \
    || fail 'a local PROJECT_LOCATION must point to an existing directory'

  project_dir="$(cd -- "${PROJECT_LOCATION}" && pwd -P)"
  git_root=''
  project_relative_path=''

  if detected_git_root="$(git -c safe.directory='*' -C "${project_dir}" rev-parse --show-toplevel 2>/dev/null)"; then
    git_root="$(cd -- "${detected_git_root}" && pwd -P)"
    case "${project_dir}" in
      "${git_root}") ;;
      "${git_root}"/*) project_relative_path="${project_dir#"${git_root}"/}" ;;
      *) fail 'Git reported a top-level directory that does not contain PROJECT_LOCATION' ;;
    esac

    git config --global --add safe.directory "${git_root}"
    log "Using local Git project ${project_dir} (Git root: ${git_root})"

    if [[ -n "${GIT_REVISION:-}" ]]; then
      switch_git_revision "${git_root}"

      project_candidate="${git_root}"
      if [[ -n "${project_relative_path}" ]]; then
        project_candidate="${git_root}/${project_relative_path}"
      fi
      [[ -d "${project_candidate}" ]] \
        || fail 'PROJECT_LOCATION does not exist at the selected GIT_REVISION'
      project_dir="$(cd -- "${project_candidate}" && pwd -P)"
      case "${project_dir}" in
        "${git_root}"|"${git_root}"/*) ;;
        *) fail 'PROJECT_LOCATION resolves outside the Git working tree at the selected GIT_REVISION' ;;
      esac
    fi
  else
    [[ -z "${GIT_REVISION:-}" ]] \
      || fail 'GIT_REVISION cannot be used when PROJECT_LOCATION is not inside a Git working tree'
    log "Using local directory ${project_dir}"
  fi
else
  clone_args=(clone)
  efficient_revision_kind=''
  if [[ -z "${GIT_REVISION:-}" ]]; then
    clone_args+=(--single-branch)
  else
    if ! remote_refs="$(git ls-remote --heads --tags -- "${PROJECT_LOCATION}" \
      "refs/heads/${GIT_REVISION}" "refs/tags/${GIT_REVISION}")"; then
      fail_git_operation 'inspect remote refs for'
    fi
    remote_branch_ref=''
    remote_tag_ref=''
    while IFS=$'\t' read -r _ remote_ref_name; do
      if [[ "${remote_ref_name}" == "refs/heads/${GIT_REVISION}" ]]; then
        remote_branch_ref="${remote_ref_name}"
      elif [[ "${remote_ref_name}" == "refs/tags/${GIT_REVISION}" ]]; then
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
    clone_args+=(--single-branch --branch "${GIT_REVISION}")
  fi

  work_dir="$(mktemp -d /workspace/claude-job.XXXXXX)"
  project_dir="${work_dir}/project"

  log "Cloning ${PROJECT_LOCATION}"
  if ! git "${clone_args[@]}" \
    -- \
    "${PROJECT_LOCATION}" \
    "${project_dir}"; then
    fail_git_operation 'clone'
  fi

  if [[ -n "${GIT_REVISION:-}" && -z "${efficient_revision_kind}" ]]; then
    switch_git_revision "${project_dir}"
  fi
fi

cd "${project_dir}"

[[ -f ./AGENTS.md && ! -L ./AGENTS.md ]] \
  || fail 'the project directory must contain a regular, non-symlink AGENTS.md file'
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
