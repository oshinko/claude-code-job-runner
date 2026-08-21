#!/usr/bin/env bash
set -Eeuo pipefail

readonly runner=/usr/local/bin/claude-code-job-runner
test_root="$(mktemp -d /tmp/claude-runner-test.XXXXXX)"

cleanup() {
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local output="$1"
  local expected="$2"
  [[ "${output}" == *"${expected}"* ]] \
    || fail "expected output to contain: ${expected}"
}

mkdir -p "${test_root}/bin"
cat >"${test_root}/bin/claude" <<'EOF'
#!/usr/bin/env sh
printf 'stub-cwd=%s\n' "${PWD}"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'stub-branch=%s\n' "$(git branch --show-current)"
fi
EOF
chmod +x "${test_root}/bin/claude"

runner_env=(
  env
  "PATH=${test_root}/bin:${PATH}"
  CLAUDE_CODE_OAUTH_TOKEN=test
  MAX_TURNS=1
)

plain_project="${test_root}/plain-project"
mkdir -p "${plain_project}"
printf 'Follow the project instructions.\n' >"${plain_project}/AGENTS.md"

plain_output="$(
  "${runner_env[@]}" \
    PROJECT_LOCATION="${plain_project}" \
    "${runner}" 2>&1
)"
assert_contains "${plain_output}" "Using local directory ${plain_project}"
assert_contains "${plain_output}" "stub-cwd=${plain_project}"

if non_git_revision_output="$(
  "${runner_env[@]}" \
    PROJECT_LOCATION="${plain_project}" \
    GIT_REVISION=main \
    "${runner}" 2>&1
)"; then
  fail 'a non-Git directory accepted GIT_REVISION'
fi
assert_contains "${non_git_revision_output}" 'GIT_REVISION cannot be used when PROJECT_LOCATION is not inside a Git working tree'

if legacy_output="$(
  "${runner_env[@]}" \
    REPOSITORY_URL="${plain_project}" \
    "${runner}" 2>&1
)"; then
  fail 'the removed REPOSITORY_URL variable was accepted'
fi
assert_contains "${legacy_output}" 'PROJECT_LOCATION is required'

git_project="${test_root}/git-project"
git init --quiet --initial-branch=main "${git_project}"
git -C "${git_project}" config user.name 'Runner Test'
git -C "${git_project}" config user.email 'runner-test@example.invalid'
mkdir -p "${git_project}/nested"
printf 'Follow the project instructions.\n' >"${git_project}/AGENTS.md"
printf 'Follow the project instructions.\n' >"${git_project}/nested/AGENTS.md"
printf 'main\n' >"${git_project}/nested/revision.txt"
git -C "${git_project}" add .
git -C "${git_project}" commit --quiet -m 'main revision'
git -C "${git_project}" switch --quiet --create target
printf 'target\n' >"${git_project}/nested/revision.txt"
git -C "${git_project}" commit --quiet -am 'target revision'
git -C "${git_project}" switch --quiet main

git_output="$(
  "${runner_env[@]}" \
    PROJECT_LOCATION="${git_project}/nested" \
    GIT_REVISION=target \
    "${runner}" 2>&1
)"
assert_contains "${git_output}" "Using local Git project ${git_project}/nested (Git root: ${git_project})"
assert_contains "${git_output}" 'Switching to Git revision target'
assert_contains "${git_output}" "stub-cwd=${git_project}/nested"
assert_contains "${git_output}" 'stub-branch=target'
[[ "$(git -C "${git_project}" branch --show-current)" == 'target' ]] \
  || fail 'the local Git working tree did not remain on the selected revision'
[[ "$(<"${git_project}/nested/revision.txt")" == 'target' ]] \
  || fail 'the local Git working tree content was not switched in place'

git -C "${git_project}" switch --quiet main
git -C "${git_project}" switch --quiet --create without-project
git -C "${git_project}" rm --quiet -r nested
git -C "${git_project}" commit --quiet -m 'remove nested project'
git -C "${git_project}" switch --quiet target

if missing_project_output="$(
  "${runner_env[@]}" \
    PROJECT_LOCATION="${git_project}/nested" \
    GIT_REVISION=without-project \
    "${runner}" 2>&1
)"; then
  fail 'a Git revision without the selected project directory was accepted'
fi
assert_contains "${missing_project_output}" 'PROJECT_LOCATION does not exist at the selected GIT_REVISION'

remote_output="$(
  "${runner_env[@]}" \
    PROJECT_LOCATION="file://${git_project}" \
    GIT_REVISION=main \
    "${runner}" 2>&1
)"
assert_contains "${remote_output}" "Cloning file://${git_project}"
assert_contains "${remote_output}" 'stub-cwd=/workspace/claude-job.'
assert_contains "${remote_output}" '/project'
assert_contains "${remote_output}" 'stub-branch=main'

printf 'All entrypoint smoke tests passed.\n'
