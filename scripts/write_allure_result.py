#!/usr/bin/env python3
"""Write one attributed Allure result for a CI stage."""

from __future__ import annotations

import argparse
import hashlib
import json
import time
import uuid
from pathlib import Path


STATUS_MAP = {
    "success": "passed",
    "failure": "failed",
    "cancelled": "skipped",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--suite", required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--status", choices=sorted(STATUS_MAP), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    identity = f"{args.module}:{args.suite}:{args.name}"
    result_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, identity))
    history_id = hashlib.sha256(identity.encode()).hexdigest()
    stop = int(time.time() * 1000)
    result = {
        "uuid": result_uuid,
        "historyId": history_id,
        "testCaseId": history_id,
        "name": args.name,
        "fullName": identity,
        "status": STATUS_MAP[args.status],
        "statusDetails": (
            {"message": f"GitHub Actions stage finished with {args.status}"}
            if args.status != "success"
            else {}
        ),
        "stage": "finished",
        "start": stop - 1,
        "stop": stop,
        "labels": [
            {"name": "framework", "value": "github-actions"},
            {"name": "language", "value": "bash"},
            {"name": "suite", "value": args.suite},
            {"name": "epic", "value": "integration"},
        ],
    }

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / f"{result_uuid}-result.json").write_text(
        json.dumps(result) + "\n", encoding="utf-8"
    )
    (args.output / "ci-env-fragment.properties").write_text(
        f"{args.module}.Module={args.module}\n{args.module}.Suite={args.suite}\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
