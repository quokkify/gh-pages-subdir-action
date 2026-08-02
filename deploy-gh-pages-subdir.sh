#!/usr/bin/env bash
# Publish one workspace directory into a subdirectory on a GitHub Pages branch.
set -euo pipefail

error() {
  echo "::error::$*" >&2
  exit 2
}

[[ -n "${INPUT_TOKEN:-}" ]] || error "token is required"
[[ -n "${GITHUB_WORKSPACE:-}" && -d "$GITHUB_WORKSPACE" ]] || error "GITHUB_WORKSPACE must point to an existing directory"
[[ -n "${GITHUB_REPOSITORY:-}" ]] || error "GITHUB_REPOSITORY is required"

validate_relative_path() {
  local value="$1"
  local label="$2"
  case "$value" in
    ""|/*|.|./*|*/./*|..|../*|*/../*|*/..) error "$label must be a safe relative path" ;;
  esac
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || error "$label must not contain newlines"
}

validate_relative_path "$INPUT_PUBLISH_DIR" "publish-dir"
validate_relative_path "$INPUT_DESTINATION_DIR" "destination-dir"
case "$INPUT_DESTINATION_DIR" in
  .git|.git/*|*/.git|*/.git/*) error "destination-dir must not contain a .git path component" ;;
esac

RETENTION_COUNT="${INPUT_RETENTION_COUNT:-0}"
[[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || error "retention-count must be a non-negative integer"
RETENTION_COUNT=$((10#$RETENTION_COUNT))
if (( RETENTION_COUNT > 0 )); then
  retention_dest_name="${INPUT_DESTINATION_DIR##*/}"
  [[ "$retention_dest_name" =~ ^pr-[0-9]+$ ]] || error "retention-count requires destination-dir basename pr-N"
fi

BRANCH="${INPUT_BRANCH:-gh-pages}"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || error "branch contains unsupported characters"
[[ "$BRANCH" != -* && "$BRANCH" != */ && "$BRANCH" != */. && "$BRANCH" != *..* && "$BRANCH" != *'@{'* ]] || error "branch is not a safe Git ref"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || error "branch is not a valid Git branch name"

PUB="$(
  cd "$GITHUB_WORKSPACE"
  python3 - "$INPUT_PUBLISH_DIR" <<'PY'
import os
import sys

workspace = os.path.realpath(os.getcwd())
candidate = os.path.realpath(os.path.join(workspace, sys.argv[1]))
if os.path.commonpath((candidate, workspace)) != workspace:
    raise SystemExit("publish-dir resolves outside GITHUB_WORKSPACE")
print(candidate)
PY
)" || error "publish-dir resolves outside GITHUB_WORKSPACE"
[[ -d "$PUB" ]] || error "publish-dir not found: $INPUT_PUBLISH_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Keep credentials out of command-line arguments and the generated remote URL.
cat > "$WORK/git-askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "${1:-}" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) printf '%s\n' "${INPUT_TOKEN}" ;;
  *) printf '\n' ;;
esac
ASKPASS
chmod 700 "$WORK/git-askpass"
export GIT_ASKPASS="$WORK/git-askpass"
export GIT_TERMINAL_PROMPT=0

REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}.git"
git clone --quiet --no-checkout "$REPO_URL" "$WORK/repo"
R="$WORK/repo"
cd "$R"

# Keep repository content from installing or replacing hooks that run with the
# publication token in scope. This remains a defense if destination validation
# regresses in a future change.
mkdir "$WORK/empty-hooks"
git config core.hooksPath "$WORK/empty-hooks"

if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  git fetch --quiet origin "$BRANCH"
  git checkout --quiet -B "$BRANCH" "origin/$BRANCH"
else
  git checkout --quiet --orphan "$BRANCH"
  git rm -rf --quiet . 2>/dev/null || true
fi

DEST="$(python3 - "$R" "$INPUT_DESTINATION_DIR" <<'PY'
import os
import sys

repo = os.path.realpath(sys.argv[1])
destination = os.path.realpath(os.path.join(repo, sys.argv[2]))
if os.path.commonpath((destination, repo)) != repo:
    raise SystemExit("destination-dir resolves outside the pages checkout")
print(destination)
PY
)" || error "destination-dir resolves outside the pages checkout"
mkdir -p "$DEST"
rsync -a --delete "$PUB/" "$DEST/"

prune_old_reports() {
  (( RETENTION_COUNT > 0 )) || return 0

  local parent dest_name candidate rel timestamp
  parent="${INPUT_DESTINATION_DIR%/*}"
  [[ "$parent" != "$INPUT_DESTINATION_DIR" ]] || parent="."

  local -a entries=()
  for candidate in "$R/$parent"/pr-*; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    dest_name="${candidate##*/}"
    [[ "$dest_name" =~ ^pr-[0-9]+$ ]] || continue
    rel="${parent%/.}/$dest_name"
    [[ "$parent" != "." ]] || rel="$dest_name"
    if [[ "$rel" == "$INPUT_DESTINATION_DIR" ]]; then
      # The publication in this run is always the newest entry, even when two
      # commits share the same second-level Git timestamp.
      timestamp=9999999999
    else
      timestamp="$(git log -1 --format=%ct -- "$rel" 2>/dev/null || true)"
      [[ "$timestamp" =~ ^[0-9]+$ ]] || timestamp=0
    fi
    entries+=("${timestamp}"$'\t'"${rel}")
  done

  local -a keep=()
  while IFS=$'\t' read -r timestamp rel; do
    [[ -n "$rel" ]] || continue
    if (( ${#keep[@]} < RETENTION_COUNT )); then
      keep+=("$rel")
    else
      echo "Pruning old gh-pages report: $rel"
      rm -rf -- "${R:?}/${rel:?}"
    fi
  done < <(printf '%s\n' "${entries[@]}" | sort -t $'\t' -k1,1nr -k2,2)
}

prune_old_reports
touch "$R/.nojekyll"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -A

if git diff --cached --quiet; then
  echo "No changes to push to $BRANCH."
  exit 0
fi

git commit --quiet -m "docs(pages): deploy $INPUT_DESTINATION_DIR"

# Re-read the remote tip and lease the update. A single retry handles a concurrent
# publisher without overwriting a sibling deployment or silently losing its update.
for attempt in 1 2; do
  expected_sha="$(git ls-remote --heads origin "$BRANCH" | awk 'NR == 1 { print $1 }')"
  if [[ -n "$expected_sha" ]]; then
    git fetch --quiet origin "$BRANCH"
    if git merge-base HEAD "origin/$BRANCH" >/dev/null 2>&1; then
      if ! git rebase --quiet "origin/$BRANCH"; then
        git rebase --abort >/dev/null 2>&1 || true
        error "unable to rebase onto origin/$BRANCH before publishing $INPUT_DESTINATION_DIR (possible content conflict)"
      fi
    elif ! git merge --quiet --no-edit --allow-unrelated-histories "origin/$BRANCH"; then
      git merge --abort >/dev/null 2>&1 || true
      error "unable to combine concurrent orphan branch origin/$BRANCH before publishing $INPUT_DESTINATION_DIR (possible content conflict)"
    fi
    git push --quiet --force-with-lease="refs/heads/$BRANCH:$expected_sha" origin "HEAD:$BRANCH" && exit 0
  else
    git push --quiet --force-with-lease="refs/heads/$BRANCH:" origin "HEAD:$BRANCH" && exit 0
  fi
  if [[ "$attempt" == 1 ]]; then
    echo "Concurrent update detected; retrying gh-pages push." >&2
  fi
done

error "unable to publish $INPUT_DESTINATION_DIR after two lease-protected push attempts"
