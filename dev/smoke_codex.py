#!/usr/bin/env python3

import json
import os
import socket
import subprocess
import sys
from pathlib import Path


def git_short_sha(workspace_path: Path) -> str:
    try:
        output = subprocess.check_output(
            ["git", "-C", str(workspace_path), "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return "unknown-sha"
    return output.strip() or "unknown-sha"


def main() -> int:
    prompt = sys.argv[1] if len(sys.argv) > 1 else ""
    workspace_path = Path(os.environ["WORKSPACE_PATH"])
    workpad_path = Path(os.environ["WORKPAD_PATH"])
    result_path = Path(os.environ["RESULT_PATH"])
    issue_path = Path(os.environ["ISSUE_PATH"])

    issue = {}
    if issue_path.exists():
        issue = json.loads(issue_path.read_text())

    host = socket.gethostname()
    sha = git_short_sha(workspace_path)
    identifier = issue.get("identifier", "SMOKE")

    workpad_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.parent.mkdir(parents=True, exist_ok=True)

    workpad_path.write_text(
        "\n".join(
            [
                "### Environment",
                f"`{host}:{workspace_path}@{sha}`",
                "",
                "### Plan",
                "- [x] Clone the repository into the remote workspace.",
                "- [x] Write the required Symphony artifacts from inside the K3s job.",
                "",
                "### Acceptance Criteria",
                "- [x] Temporal can dispatch a workflow to the worker.",
                "- [x] The worker can create and observe a K3s job.",
                "- [x] The K3s job can update the workpad and run result.",
                "",
                "### Validation",
                "- [x] `./dev/temporal-k3s smoke`",
                f"- [x] Prompt bytes: {len(prompt.encode('utf-8'))}",
                "",
                "### Notes",
                f"- Smoke workflow completed for `{identifier}`.",
                f"- Repository HEAD inside the remote workspace: `{sha}`.",
            ]
        )
        + "\n"
    )

    result_path.write_text(
        json.dumps(
            {
                "status": "succeeded",
                "targetState": "Human Review",
                "summary": "Temporal/K3s smoke workflow completed successfully.",
                "validation": ["./dev/temporal-k3s smoke"],
                "blockedReason": None,
                "needsContinuation": False,
            }
        )
        + "\n"
    )

    print(
        json.dumps(
            {
                "event": "smoke_complete",
                "identifier": identifier,
                "workspace": str(workspace_path),
                "sha": sha,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
