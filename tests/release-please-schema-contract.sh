#!/usr/bin/env bash

set -euo pipefail

RELEASE_PLEASE_VERSION=${RELEASE_PLEASE_VERSION:-17.6.0}
CONFIG_SCHEMA_URL=https://raw.githubusercontent.com/googleapis/release-please/v${RELEASE_PLEASE_VERSION}/schemas/config.json
MANIFEST_SCHEMA_URL=https://raw.githubusercontent.com/googleapis/release-please/v${RELEASE_PLEASE_VERSION}/schemas/manifest.json
CONFIG_PATH=${CONFIG_PATH:-.github/release-please/config.json}
MANIFEST_PATH=${MANIFEST_PATH:-.github/release-please/manifest.json}
BASE_REF=${BASE_REF:-}

WORK_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cat > "$WORK_DIR/validate_release_schema.py" <<'EOF_VALIDATE'
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
  local log_file="$4"

  if ! python3 "$WORK_DIR/validate_release_schema.py" "$schema_url" "$data_file" > "$log_file" 2>&1; then
    cat "$log_file" >&2
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
  local expect_message="$5"
  local log_file="$6"

  TOTAL=$((TOTAL + 1))
  if validate_json_schema "$label" "$schema" "$file" "$log_file"; then
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

    if [[ -n "$expect_message" ]] && ! grep -qF "$expect_message" "$log_file"; then
      echo "not ok - $label (unexpected validation message)" >&2
      echo "Expected: $expect_message" >&2
      echo "Actual messages: $(cat "$log_file")" >&2
      return 1
    fi

    echo "ok - $label (expected failure)"
  fi
}

run_case "checked-out config validates against Release Please config schema" 1 "$CONFIG_PATH" "$CONFIG_SCHEMA_URL" "" "$WORK_DIR/checked-out-config.log"
run_case "checked-out manifest validates against Release Please manifest schema" 1 "$MANIFEST_PATH" "$MANIFEST_SCHEMA_URL" "" "$WORK_DIR/checked-out-manifest.log"

if [[ -n "$BASE_REF" ]] && [[ ! "$BASE_REF" =~ ^0+$ ]]; then
  if ! git rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1; then
    echo "Unable to resolve BASE_REF=$BASE_REF to a commit" >&2
    exit 1
  fi

  git show "$BASE_REF:$CONFIG_PATH" > "$WORK_DIR/base-config.json"
  git show "$BASE_REF:$MANIFEST_PATH" > "$WORK_DIR/base-manifest.json"

  run_case "base main config validates against Release Please config schema" 1 "$WORK_DIR/base-config.json" "$CONFIG_SCHEMA_URL" "" "$WORK_DIR/base-config.log"
  run_case "base main manifest validates against Release Please manifest schema" 1 "$WORK_DIR/base-manifest.json" "$MANIFEST_SCHEMA_URL" "" "$WORK_DIR/base-manifest.log"
else
  echo "Skipping base revision contract validation: BASE_REF is unset, zero, or empty"
fi

cat > "$WORK_DIR/invalid-config.json" <<'EOF_CONFIG_INVALID'
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

cat > "$WORK_DIR/invalid-manifest.json" <<'EOF_MANIFEST_INVALID'
{
  ".": 1
}
EOF_MANIFEST_INVALID

run_case "schema-invalid config candidate fails" 0 "$WORK_DIR/invalid-config.json" "$CONFIG_SCHEMA_URL" "not of type" "$WORK_DIR/invalid-config.log"
run_case "schema-invalid manifest candidate fails" 0 "$WORK_DIR/invalid-manifest.json" "$MANIFEST_SCHEMA_URL" "is not of type 'string'" "$WORK_DIR/invalid-manifest.log"

echo "1..$TOTAL"
