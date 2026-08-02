#!/usr/bin/env python3
"""Release Please guard validation and regression simulations.

The inline CI guard checks two things:
1) Release Please config shape and initial-version policy.
2) Manifest transition policy by comparing the base manifest revision to HEAD.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, Tuple


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def semver_to_tuple(version: str) -> Tuple[int, int, int]:
    m = SEMVER.fullmatch(version)
    if not m:
        fail(f"Invalid semver format: {version!r}")
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)))


def load_json(path: Path) -> Dict:
    try:
        return json.loads(path.read_text())
    except OSError as err:
        fail(f"Unable to read JSON file {path}: {err}")
    except ValueError as err:
        fail(f"Invalid JSON in {path}: {err}")
    return {}


def package_version(payload: Dict, *, path: str) -> str:
    version = payload.get(path)
    if not isinstance(version, str):
        fail(f"Manifest entry for {path!r} missing or non-string: {payload!r}")
    return version


def load_manifest_from_ref(ref: str, *, manifest_path: str) -> Dict:
    obj = f"{ref}:{manifest_path}"
    result = subprocess.run(
        ["git", "show", obj],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail(f"Unable to read manifest from revision {ref!r}: {result.stderr.strip() or result.stdout.strip()}")
    try:
        return json.loads(result.stdout)
    except ValueError as err:
        fail(f"Manifest at {ref!r} is not valid JSON: {err}")
    return {}


def check_transition(base_version: str, head_version: str) -> tuple[bool, str]:
    base_match = SEMVER.fullmatch(base_version)
    if not base_match:
        return False, f"Invalid base semver format: {base_version!r}"
    head_match = SEMVER.fullmatch(head_version)
    if not head_match:
        return False, f"Invalid head semver format: {head_version!r}"

    base = (int(base_match.group(1)), int(base_match.group(2)), int(base_match.group(3)))
    head = (int(head_match.group(1)), int(head_match.group(2)), int(head_match.group(3)))

    if head < base:
        return False, f"Manifest version regression from {base_version} to {head_version} is not allowed"

    if base_version == "0.0.0" and head_version not in ("0.0.0", "0.1.0"):
        return (
            False,
            "Bootstrap policy mismatch: base 0.0.0 may only remain 0.0.0 (bootstrap PR) or move to 0.1.0",
        )

    return True, ""


def validate_config(config_path: str) -> None:
    config = load_json(Path(config_path))
    if not isinstance(config, dict):
        fail("Release Please config must be a JSON object")

    expected_schema = "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json"
    schema_url = config.get("$schema")
    if schema_url != expected_schema:
        fail(f"Release Please config $schema must be {expected_schema!r}, got {schema_url!r}")

    release_type = config.get("release-type")
    if not isinstance(release_type, str) or not release_type:
        fail("Release Please config must define a top-level non-empty release-type")

    packages = config.get("packages")
    if not isinstance(packages, dict) or not packages:
        fail("Release Please config must define a non-empty packages map")

    root_pkg = packages.get(".")
    if not isinstance(root_pkg, dict):
        fail("Release Please config packages['.'] must be an object")

    initial_version = root_pkg.get("initial-version")
    if not isinstance(initial_version, str):
        fail("Release Please config packages['.'].initial-version must be a string")
    if initial_version != "0.1.0":
        fail(
            f"Expected release-please initial-version for path '.' to be '0.1.0', got {initial_version!r}"
        )


def validate_manifest_schema(manifest: Dict, *, manifest_path: str) -> None:
    if not isinstance(manifest, dict):
        fail(f"Manifest at {manifest_path!r} must be a JSON object")
    if "." not in manifest:
        fail(f"Manifest at {manifest_path!r} must contain the '.' key")
    for key, value in manifest.items():
        if not isinstance(key, str) or not key:
            fail(f"Manifest contains invalid package key: {key!r}")
        if not isinstance(value, str):
            fail(f"Manifest version for {key!r} must be a string")
        semver_to_tuple(value)


def validate_transition(base_version: str, head_version: str) -> None:
    ok, reason = check_transition(base_version, head_version)
    if not ok:
        fail(reason)


def run_guard(config_path: str, manifest_path: str, event_path: str, event_name: str) -> None:
    validate_config(config_path)

    if event_name != "pull_request":
        print("Skipping manifest transition guard outside pull_request event.")
        return

    if not Path(event_path).is_file():
        fail(f"Missing GITHUB_EVENT_PATH file: {event_path!r}")

    event = load_json(Path(event_path))
    pull_request = event.get("pull_request")
    if not isinstance(pull_request, dict):
        fail("GitHub event payload missing pull_request for pull_request event")

    base = pull_request.get("base")
    if not isinstance(base, dict):
        fail("Unable to read pull_request.base from event payload")

    base_ref = base.get("sha")
    if not isinstance(base_ref, str):
        fail("Unable to read pull_request.base.sha from event payload")

    head = load_json(Path(manifest_path))
    validate_manifest_schema(head, manifest_path=manifest_path)
    head_version = package_version(head, path=".")

    base = load_manifest_from_ref(base_ref, manifest_path=manifest_path)
    validate_manifest_schema(base, manifest_path=f"{base_ref}:{manifest_path}")
    base_version = package_version(base, path=".")

    validate_transition(base_version, head_version)
    print(
        f"Release Please bootstrap/transition guard passed for base={base_version}, head={head_version}"
    )


def simulate() -> None:
    pass_count = 0
    total = 0

    cases = [
        ("bootstrap config PR keeps manifest unchanged at 0.0.0", "0.0.0", "0.0.0", True),
        ("initial release PR moves 0.0.0 -> 0.1.0", "0.0.0", "0.1.0", True),
        ("reject bootstrap jump 0.0.0 -> 1.0.0", "0.0.0", "1.0.0", False),
        ("post-release config PR keeps 0.1.0 unchanged", "0.1.0", "0.1.0", True),
        ("future release 0.1.0 -> 0.2.0", "0.1.0", "0.2.0", True),
        ("future release 0.1.0 -> 1.0.0", "0.1.0", "1.0.0", True),
        ("backward transition 0.2.0 -> 0.1.0 blocked", "0.2.0", "0.1.0", False),
        ("malformed version blocked", "0.1.0", "bad", False),
    ]

    for description, base_version, head_version, should_pass in cases:
        total += 1
        try:
            success, _ = check_transition(base_version, head_version)
        except SystemExit:
            success = False

        if success != should_pass:
            fail(
                f"Regression scenario failed: {description}. base={base_version}, head={head_version} "
                f"expected={should_pass!r}, actual={success!r}"
            )

        pass_count += 1
        print(f"ok {pass_count} - {description}")

    print(f"1..{total}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate Release Please config/manifest transitions")
    parser.add_argument("--config", default=".github/release-please/config.json")
    parser.add_argument("--manifest", default=".github/release-please/manifest.json")
    parser.add_argument("--event-name", default="")
    parser.add_argument("--event-path", default="")
    parser.add_argument("--simulate", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.simulate:
        simulate()
        return

    run_guard(
        config_path=args.config,
        manifest_path=args.manifest,
        event_path=args.event_path,
        event_name=args.event_name,
    )


if __name__ == "__main__":
    main()
