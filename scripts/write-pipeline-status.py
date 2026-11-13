#!/usr/bin/env python3
"""Write the dashboard ``pipeline.json`` snapshot from the GitHub Actions API.

The snapshot contains the *real* state of the current workflow run and of
every job in it. Nothing is guessed: if the API cannot be reached the script
exits non-zero and the dashboard keeps showing the previous snapshot (or
"Not configured" if there never was one).

The script reads the standard GitHub Actions environment variables, so it is
meant to be called from inside a workflow job::

    python3 scripts/write-pipeline-status.py --output pipeline.json

Environment variables used
--------------------------
GITHUB_TOKEN          API token (the built-in GITHUB_TOKEN is enough)
GITHUB_REPOSITORY     "owner/repo"
GITHUB_RUN_ID         The id of the current workflow run
GITHUB_WORKFLOW       Workflow name
GITHUB_SHA            Commit SHA
GITHUB_REF            Git ref
GITHUB_ACTOR          Who triggered the run
GITHUB_SERVER_URL     GitHub server base URL
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

API_VERSION = "2022-11-28"
TIMEOUT_SECONDS = 30


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="pipeline.json to write")
    parser.add_argument("--api-url", default=os.getenv("GITHUB_API_URL", "https://api.github.com"))
    return parser.parse_args()


def api_get(url: str, token: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": "devops-cicd-dashboard",
        },
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


def parse_time(value: str | None) -> float | None:
    if not value:
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=UTC)
    return stamp.timestamp()


def main() -> int:
    args = parse_args()

    token = os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN") or ""
    repository = os.getenv("GITHUB_REPOSITORY", "")
    run_id = os.getenv("GITHUB_RUN_ID", "")
    server_url = os.getenv("GITHUB_SERVER_URL", "https://github.com")

    if not token or not repository or not run_id:
        print(
            "ERROR: GITHUB_TOKEN, GITHUB_REPOSITORY and GITHUB_RUN_ID are required.",
            file=sys.stderr,
        )
        return 1

    run_url = f"{args.api_url}/repos/{repository}/actions/runs/{run_id}"
    try:
        run = api_get(run_url, token)
        jobs_payload = api_get(f"{run_url}/jobs?per_page=100", token)
    except (
        urllib.error.URLError,
        urllib.error.HTTPError,
        TimeoutError,
        json.JSONDecodeError,
    ) as exc:
        print(f"ERROR: could not query the GitHub Actions API: {exc}", file=sys.stderr)
        return 1

    jobs = jobs_payload.get("jobs") or []
    stages = []
    for job in jobs:
        stages.append(
            {
                "name": job.get("name") or job.get("id"),
                "status": job.get("status") or "unknown",
                "conclusion": job.get("conclusion"),
                "started_at": job.get("started_at"),
                "completed_at": job.get("completed_at"),
                "url": job.get("html_url"),
            }
        )

    run_status = run.get("status") or "unknown"
    run_conclusion = run.get("conclusion")
    derived = False
    if not run_conclusion:
        # The run is still in progress (we are inside a job). Derive the
        # conclusion from the finished jobs so the dashboard shows something
        # truthful, and flag it as derived.
        conclusions = [job.get("conclusion") for job in jobs if job.get("conclusion")]
        if any(item == "failure" for item in conclusions):
            run_conclusion = "failure"
        elif (
            conclusions
            and all(item == "success" for item in conclusions)
            and run_status == "completed"
        ):
            run_conclusion = "success"
        else:
            run_conclusion = "in_progress"
        derived = True

    started_at = parse_time(run.get("run_started_at") or run.get("created_at"))
    completed_at = parse_time(run.get("updated_at"))
    duration = None
    if started_at and completed_at and run_status == "completed":
        duration = max(0.0, completed_at - started_at)

    ref = os.getenv("GITHUB_REF", "") or run.get("head_branch") or ""
    branch = ref.replace("refs/heads/", "") if ref else (run.get("head_branch") or "")

    payload = {
        "generated_at": datetime.now(UTC).isoformat(),
        "status": run_status,
        "conclusion": run_conclusion,
        "conclusion_derived": derived,
        "workflow": os.getenv("GITHUB_WORKFLOW") or run.get("name") or "",
        "commit": run.get("head_sha") or os.getenv("GITHUB_SHA", ""),
        "branch": branch,
        "run_url": run.get("html_url") or f"{server_url}/{repository}/actions/runs/{run_id}",
        "run_number": run.get("run_number"),
        "actor": (run.get("actor") or {}).get("login") or os.getenv("GITHUB_ACTOR", ""),
        "started_at": run.get("run_started_at"),
        "completed_at": run.get("updated_at") if run_status == "completed" else None,
        "duration_seconds": duration,
        "stages": stages,
    }

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(f"Pipeline status written to {output_path}: {run_conclusion} ({len(stages)} jobs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
