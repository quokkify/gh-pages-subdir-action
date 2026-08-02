#!/usr/bin/env bash

set -euo pipefail

RELEASE_PLEASE_VERSION=${RELEASE_PLEASE_VERSION:-16.16.0}
CONFIG_SCHEMA_URL=https://raw.githubusercontent.com/googleapis/release-please/v${RELEASE_PLEASE_VERSION}/schemas/config.json
MANIFEST_SCHEMA_URL=https://raw.githubusercontent.com/googleapis/release-please/v${RELEASE_PLEASE_VERSION}/schemas/manifest.json
CONFIG_PATH=${CONFIG_PATH:-.github/release-please/config.json}
MANIFEST_PATH=${MANIFEST_PATH:-.github/release-please/manifest.json}
BASE_REF=${BASE_REF:-origin/main}

TMPDIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

cat > "$TMPDIR/validate_release_schema.py" <<'EOF_VALIDATE'
import json
import sys
import urllib.request
from pathlib import Path
from jsonschema import Draft202012Validator


def load_json(path: str):
    if path.startswith("http://") or path.startswith("https://"):
        with urllib.request.urlopen(path) as fh:
            return json.loads(fh.read().decode("utf-8"))
    with Path(path).open("r", encoding="utf-8") as fh:
        return json.loads(fh.read())


def main(schema_ref: str, data_path: str) -> int:
    schema = load_json(schema_ref)
    validator = Draft202012Validator(schema)

    with Path(data_path).open("r", encoding="utf-8") as fh:
        data = json.loads(fh.read())

    errors = list(validator.iter_errors(data))
    if not errors:
        return 0

    for error in errors:
        print(error.message)
    return 1


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: validate_release_schema.py <schema_ref> <data_path>", file=sys.stderr)
        raise SystemExit(2)

    sys.exit(main(sys.argv[1], sys.argv[2]))
EOF_VALIDATE

validate_json_schema() {
  local label="$1"
  local schema_url="$2"
  local data_file="$3"

  if ! python3 "$TMPDIR/validate_release_schema.py" "$schema_url" "$data_file" > /tmp/release-please-schema-validation.log 2>&1; then
    cat /tmp/release-please-schema-validation.log >&2
    echo "Schema validation failed for ${label}" >&2
    return 1
  fi
}

TOTAL=0
run_case() {
  local label="$1"
  local expect_pass="$2"
  local file="$3"
  local schema="$4"

  TOTAL=$((TOTAL + 1))
  if validate_json_schema "$label" "$schema" "$file"; then
    if [[ "$expect_pass" == "1" ]]; then
      echo "ok - $label"
    else
      echo "not ok - $label (expected failure)" >&2
      return 1
    fi
  else
    if [[ "$expect_pass" == "1" ]]; then
      echo "not ok - $label" >&2
      return 1
    fi
    echo "ok - $label (expected failure)"
  fi
}

run_case "checked-out config validates against Release Please config schema" 1 "$CONFIG_PATH" "$CONFIG_SCHEMA_URL"
run_case "checked-out manifest validates against Release Please manifest schema" 1 "$MANIFEST_PATH" "$MANIFEST_SCHEMA_URL"

git show "$BASE_REF:.github/release-please/config.json" > "$TMPDIR/base-config.json"
git show "$BASE_REF:.github/release-please/manifest.json" > "$TMPDIR/base-manifest.json"

run_case "base main config validates against Release Please config schema" 1 "$TMPDIR/base-config.json" "$CONFIG_SCHEMA_URL"
run_case "base main manifest validates against Release Please manifest schema" 1 "$TMPDIR/base-manifest.json" "$MANIFEST_SCHEMA_URL"

cat > "$TMPDIR/invalid-config.json" <<'EOF_CONFIG_INVALID'
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "simple",
  "include-component-in-tag": "false",
  "changelog-path": "CHANGELOG.md",
  "packages": {
    ".": {
      "package-name": "gh-pages-subdir-action",
      "initial-version": "0.1.0"
    }
  }
}
EOF_CONFIG_INVALID

cat > "$TMPDIR/invalid-manifest.json" <<'EOF_MANIFEST_INVALID'
{
  ".": 1
}
EOF_MANIFEST_INVALID

run_case "schema-invalid config candidate fails" 0 "$TMPDIR/invalid-config.json" "$CONFIG_SCHEMA_URL"
run_case "schema-invalid manifest candidate fails" 0 "$TMPDIR/invalid-manifest.json" "$MANIFEST_SCHEMA_URL"

echo "1..$TOTAL"
