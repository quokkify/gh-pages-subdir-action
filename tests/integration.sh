#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
ACTION="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy-gh-pages-subdir.sh"
REAL_GIT="$(command -v git)"
PASS=0

pass() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$PASS" "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

new_remote() {
  local name="$1"
  REMOTE_ROOT="$ROOT/$name/remotes"
  WORKSPACE="$ROOT/$name/workspace"
  REMOTE="$REMOTE_ROOT/owner/repo.git"
  mkdir -p "$REMOTE_ROOT/owner" "$WORKSPACE/site"
  "$REAL_GIT" init --bare --quiet "$REMOTE"
  printf '<h1>%s</h1>\n' "$name" > "$WORKSPACE/site/index.html"
}

seed_pages() {
  local source="$ROOT/seed-$RANDOM"
  "$REAL_GIT" clone --quiet "$REMOTE" "$source"
  (
    cd "$source"
    "$REAL_GIT" switch --orphan gh-pages >/dev/null 2>&1
    "$REAL_GIT" config user.name tester
    "$REAL_GIT" config user.email tester@example.invalid
    "$@"
    "$REAL_GIT" add -A
    GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
      "$REAL_GIT" commit --quiet -m seed
    "$REAL_GIT" push --quiet origin gh-pages
  )
}

run_action() {
  env \
    INPUT_TOKEN='test-token-not-a-secret' \
    INPUT_PUBLISH_DIR="${INPUT_PUBLISH_DIR:-site}" \
    INPUT_DESTINATION_DIR="${INPUT_DESTINATION_DIR:-allure/pr-1}" \
    INPUT_BRANCH="${INPUT_BRANCH:-gh-pages}" \
    INPUT_RETENTION_COUNT="${INPUT_RETENTION_COUNT:-0}" \
    GITHUB_WORKSPACE="$WORKSPACE" \
    GITHUB_REPOSITORY='owner/repo' \
    GITHUB_SERVER_URL="file://$REMOTE_ROOT" \
    "$ACTION"
}

expect_fail() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "expected failure containing: $expected"
  fi
  [[ "$output" == *"$expected"* ]] || fail "missing failure message: $expected"
}

checkout_pages() {
  local destination="$1"
  "$REAL_GIT" clone --quiet --branch gh-pages "$REMOTE" "$destination"
}

new_remote validation
INPUT_PUBLISH_DIR='../outside' expect_fail 'publish-dir must be a safe relative path' run_action
pass 'rejects publish-dir path traversal'

mkdir -p "$ROOT/outside"
ln -s "$ROOT/outside" "$WORKSPACE/external-site"
INPUT_PUBLISH_DIR='external-site' expect_fail 'publish-dir resolves outside GITHUB_WORKSPACE' run_action
pass 'rejects publish-dir symlink traversal'

INPUT_PUBLISH_DIR=site INPUT_BRANCH='bad branch' expect_fail 'branch contains unsupported characters' run_action
pass 'rejects invalid branch names'

INPUT_BRANCH=gh-pages INPUT_RETENTION_COUNT='-1' expect_fail 'retention-count must be a non-negative integer' run_action
INPUT_RETENTION_COUNT=2 INPUT_DESTINATION_DIR='allure/latest' expect_fail 'retention-count requires destination-dir basename pr-N' run_action
pass 'rejects invalid retention configuration'
unset INPUT_PUBLISH_DIR INPUT_BRANCH INPUT_RETENTION_COUNT INPUT_DESTINATION_DIR

new_remote orphan
output="$(run_action 2>&1)"
[[ "$output" != *'test-token-not-a-secret'* ]] || fail 'token leaked in output'
checkout_pages "$ROOT/orphan-checkout"
[[ -f "$ROOT/orphan-checkout/allure/pr-1/index.html" ]] || fail 'orphan publish missing'
[[ -f "$ROOT/orphan-checkout/.nojekyll" ]] || fail '.nojekyll missing'
pass 'creates an orphan pages branch without exposing token output'

output="$(run_action 2>&1)"
[[ "$output" == *'No changes to push to gh-pages.'* ]] || fail 'no-op was not detected'
pass 'returns successfully on an unchanged publication'

new_remote siblings
seed_pages bash -c 'mkdir -p allure/pr-1 docs; printf old > allure/pr-1/index.html; printf docs > docs/index.html'
INPUT_DESTINATION_DIR='allure/pr-2' run_action >/dev/null
checkout_pages "$ROOT/siblings-checkout"
[[ -f "$ROOT/siblings-checkout/allure/pr-1/index.html" ]] || fail 'existing report removed'
[[ -f "$ROOT/siblings-checkout/docs/index.html" ]] || fail 'sibling docs removed'
[[ -f "$ROOT/siblings-checkout/allure/pr-2/index.html" ]] || fail 'new report missing'
pass 'preserves sibling paths while publishing a subdirectory'

INPUT_DESTINATION_DIR='allure/pr-3' INPUT_RETENTION_COUNT=1 run_action >/dev/null
checkout_pages "$ROOT/retention-checkout"
[[ -f "$ROOT/retention-checkout/allure/pr-3/index.html" ]] || fail 'new retained report missing'
[[ ! -e "$ROOT/retention-checkout/allure/pr-1" && ! -e "$ROOT/retention-checkout/allure/pr-2" ]] || fail 'old reports not pruned'
[[ -f "$ROOT/retention-checkout/docs/index.html" ]] || fail 'retention removed sibling docs'
pass 'retains only the newest pr-N reports without deleting siblings'
unset INPUT_DESTINATION_DIR INPUT_RETENTION_COUNT

new_remote destination-symlink
OUTSIDE_DEST="$ROOT/destination-outside"
mkdir -p "$OUTSIDE_DEST"
export OUTSIDE_DEST
seed_pages ln -s "$OUTSIDE_DEST" allure
INPUT_DESTINATION_DIR='allure/pr-9' expect_fail 'destination-dir resolves outside the pages checkout' run_action
[[ ! -e "$OUTSIDE_DEST/pr-9" ]] || fail 'destination symlink escaped checkout'
pass 'rejects destination symlink traversal'
unset INPUT_DESTINATION_DIR OUTSIDE_DEST

new_remote concurrent
seed_pages bash -c 'mkdir -p docs; printf base > docs/index.html'
WRAPPER_DIR="$ROOT/concurrent/bin"
mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER_DIR/git" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$GIT_ARG_LOG"
printf '\n' >> "$GIT_ARG_LOG"
if [[ "${1:-}" == push && ! -e "$GIT_INJECTED" ]]; then
  : > "$GIT_INJECTED"
  competitor="$(mktemp -d)"
  remote="$($REAL_GIT remote get-url origin)"
  "$REAL_GIT" clone --quiet --branch gh-pages "$remote" "$competitor"
  (
    cd "$competitor"
    "$REAL_GIT" config user.name competitor
    "$REAL_GIT" config user.email competitor@example.invalid
    mkdir -p sibling
    printf concurrent > sibling/index.html
    "$REAL_GIT" add sibling/index.html
    "$REAL_GIT" commit --quiet -m concurrent
    "$REAL_GIT" push --quiet origin gh-pages
  )
fi
exec "$REAL_GIT" "$@"
WRAPPER
chmod +x "$WRAPPER_DIR/git"
export REAL_GIT GIT_ARG_LOG="$ROOT/git-args.log" GIT_INJECTED="$ROOT/injected"
export PATH="$WRAPPER_DIR:$PATH"
INPUT_DESTINATION_DIR='allure/pr-7'
output="$(run_action 2>&1)"
[[ "$output" == *'Concurrent update detected; retrying gh-pages push.'* ]] || fail 'concurrent retry not observed'
[[ "$(<"$GIT_ARG_LOG")" != *'test-token-not-a-secret'* ]] || fail 'token appeared in git argv'
checkout_pages "$ROOT/concurrent-checkout"
[[ -f "$ROOT/concurrent-checkout/sibling/index.html" ]] || fail 'concurrent sibling update lost'
[[ -f "$ROOT/concurrent-checkout/allure/pr-7/index.html" ]] || fail 'publication lost after retry'
pass 'retries a lease conflict and preserves the concurrent sibling update'

printf '1..%d\n' "$PASS"
