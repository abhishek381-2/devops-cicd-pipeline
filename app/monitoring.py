"""Infrastructure monitoring data for the dashboard.

Design principles
-----------------
* **No fake data.** Every value returned by this module comes from a real
  source: the live application, the real PostgreSQL server, or a JSON snapshot
  written on the EC2 host. When a source is missing the section reports
  ``Unavailable`` / ``Not configured`` instead of a plausible-looking number.
* **No Docker socket, no shell, no credentials.** The Flask container never
  talks to the Docker daemon and never reads the host filesystem directly.
  A small collector script (``scripts/collect-metrics.sh``) runs on the host
  and writes JSON snapshots into a state directory that is bind-mounted
  **read-only** into the container.
* **Honest about staleness.** Each snapshot carries its age; a snapshot older
  than ``HOST_STATE_MAX_AGE`` seconds is flagged as ``stale`` so the UI can
  say "data is 4 minutes old" instead of silently showing old numbers.

The state directory layout on the host::

    /opt/devops-cicd/state/
        metrics.json       # host CPU / memory / disk / docker containers
        deployments.json   # deployment history
        pipeline.json      # GitHub Actions run status (written by CI)
        security.json      # Trivy scan summary (written by CI)

and the deployment logs live in ``/opt/devops-cicd/logs``.

Both directories are mounted **read-only** into the container:

    /opt/devops-cicd/state -> /app/hoststate  (HOST_STATE_DIR)
    /opt/devops-cicd/logs  -> /app/hostlogs   (HOST_LOG_DIR)
"""

from __future__ import annotations

import json
import logging
import os
import platform
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Where the read-only host state mount lives inside the container.
DEFAULT_STATE_DIR = "/app/hoststate"

# The deployment logs live in a sibling directory on the host, so they get
# their own read-only mount and their own environment variable.
DEFAULT_LOG_DIR = "/app/hostlogs"

# A snapshot older than this is considered stale (the collector runs every
# minute, so 3 minutes = the collector is probably dead).
DEFAULT_MAX_AGE = 180


def _state_dir() -> Path:
    return Path(os.getenv("HOST_STATE_DIR", DEFAULT_STATE_DIR))


def _log_dir() -> Path:
    return Path(os.getenv("HOST_LOG_DIR", DEFAULT_LOG_DIR))


def _max_age() -> int:
    try:
        return int(os.getenv("HOST_STATE_MAX_AGE", DEFAULT_MAX_AGE))
    except ValueError:
        return DEFAULT_MAX_AGE


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _read_json(filename: str) -> tuple[Any | None, str | None]:
    """Read a JSON snapshot.

    Returns ``(data, error)``. ``error`` is ``None`` on success and explains
    why the data is missing otherwise.
    """
    path = _state_dir() / filename
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None, "not_configured"
    except PermissionError:
        return None, "permission_denied"
    except OSError as exc:
        return None, f"read_error: {type(exc).__name__}"

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None, "invalid_json"

    if isinstance(data, dict):
        age = None
        if data.get("generated_at"):
            try:
                stamp = datetime.fromisoformat(str(data["generated_at"]))
                if stamp.tzinfo is None:
                    stamp = stamp.replace(tzinfo=UTC)
                age = max(0, int(time.time() - stamp.timestamp()))
            except ValueError:
                age = None
        data["_age_seconds"] = age
        data["_stale"] = bool(age is not None and age > _max_age())
    return data, None


def _unavailable(reason: str = "not_configured") -> dict:
    return {"available": False, "reason": reason, "status": "unavailable"}


# --------------------------------------------------------------------------- #
# Host metrics (written by scripts/collect-metrics.sh on the EC2 host)
# --------------------------------------------------------------------------- #
def host_metrics() -> dict:
    """CPU / memory / disk / Docker container status of the host."""
    data, error = _read_json("metrics.json")
    if data is None:
        result = _unavailable(error or "not_configured")
        result.update(
            {
                "hostname": platform.node(),
                "os": f"{platform.system()} {platform.release()}",
                "containers": [],
                "cpu": None,
                "memory": None,
                "disk": [],
            }
        )
        return result

    return {
        "available": True,
        "reason": None,
        "stale": data.get("_stale", False),
        "age_seconds": data.get("_age_seconds"),
        "hostname": data.get("hostname"),
        "os": data.get("os"),
        "kernel": data.get("kernel"),
        "uptime_seconds": data.get("uptime_seconds"),
        "load_average": data.get("load_average"),
        "cpu": data.get("cpu"),
        "memory": data.get("memory"),
        "disk": data.get("disk") or [],
        "containers": data.get("containers") or [],
        "docker_available": data.get("docker_available", False),
        "collected_at": data.get("generated_at"),
    }


# --------------------------------------------------------------------------- #
# Deployment state
# --------------------------------------------------------------------------- #
def deployment_state() -> dict:
    """The currently deployed image plus the deployment history."""
    state_dir = _state_dir()
    current = previous = None
    try:
        current = (state_dir / "current-image").read_text(encoding="utf-8").strip() or None
    except OSError:
        current = None
    try:
        previous = (state_dir / "previous-image").read_text(encoding="utf-8").strip() or None
    except OSError:
        previous = None

    data, error = _read_json("deployments.json")
    history = []
    if isinstance(data, dict):
        history = data.get("deployments") or []

    return {
        "available": bool(current or history),
        "reason": None if (current or history) else (error or "not_configured"),
        "current_image": current,
        "current_tag": current.split(":")[-1] if current else None,
        "previous_image": previous,
        "previous_tag": previous.split(":")[-1] if previous else None,
        "history": history,
        "last_deployment": history[0] if history else None,
    }


# --------------------------------------------------------------------------- #
# CI/CD pipeline status (written by the GitHub Actions deploy job)
# --------------------------------------------------------------------------- #
def pipeline_status() -> dict:
    """Status of the last GitHub Actions run (from pipeline.json)."""
    data, error = _read_json("pipeline.json")
    if data is None:
        result = _unavailable(error or "not_configured")
        result.update({"stages": [], "status": "not_configured"})
        return result

    return {
        "available": True,
        "reason": None,
        "stale": data.get("_stale", False),
        "age_seconds": data.get("_age_seconds"),
        "status": data.get("status", "unknown"),
        "conclusion": data.get("conclusion"),
        "workflow": data.get("workflow"),
        "commit": data.get("commit"),
        "branch": data.get("branch"),
        "run_url": data.get("run_url"),
        "run_number": data.get("run_number"),
        "actor": data.get("actor"),
        "started_at": data.get("started_at"),
        "completed_at": data.get("completed_at"),
        "duration_seconds": data.get("duration_seconds"),
        "stages": data.get("stages") or [],
    }


# --------------------------------------------------------------------------- #
# Security scan summary (written by the Trivy stage of the pipeline)
# --------------------------------------------------------------------------- #
def security_summary() -> dict:
    """Trivy vulnerability summary for the deployed image."""
    data, error = _read_json("security.json")
    if data is None:
        result = _unavailable(error or "not_configured")
        result.update(
            {
                "critical": None,
                "high": None,
                "medium": None,
                "low": None,
                "unknown": None,
                "total": None,
                "vulnerabilities": [],
                "scanned_image": None,
                "scanned_at": None,
                "policy": None,
            }
        )
        return result

    counts = data.get("counts") or {}
    return {
        "available": True,
        "reason": None,
        "stale": data.get("_stale", False),
        "age_seconds": data.get("_age_seconds"),
        "scanned_image": data.get("scanned_image"),
        "scanned_at": data.get("scanned_at"),
        "critical": counts.get("CRITICAL"),
        "high": counts.get("HIGH"),
        "medium": counts.get("MEDIUM"),
        "low": counts.get("LOW"),
        "unknown": counts.get("UNKNOWN"),
        "total": counts.get("total"),
        "vulnerabilities": (data.get("vulnerabilities") or [])[:25],
        "policy": data.get("policy"),
    }


# --------------------------------------------------------------------------- #
# Logs
# --------------------------------------------------------------------------- #
def recent_logs(limit: int = 60) -> dict:
    """Tail the deployment logs that live on the host."""
    log_dir = _log_dir()
    try:
        candidates = sorted(log_dir.glob("*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return {"available": False, "reason": "not_configured", "files": [], "entries": []}

    if not candidates:
        return {"available": False, "reason": "no_logs", "files": [], "entries": []}

    entries: list[dict] = []
    files: list[dict] = []
    for path in candidates[:5]:
        try:
            stat = path.stat()
            files.append(
                {
                    "name": path.name,
                    "size_bytes": stat.st_size,
                    "modified_at": datetime.fromtimestamp(stat.st_mtime, UTC).isoformat(),
                }
            )
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                lines = handle.readlines()
        except OSError:
            continue
        for line in lines[-limit:]:
            entries.append(
                {
                    "file": path.name,
                    "timestamp": _extract_timestamp(line),
                    "level": _extract_level(line),
                    "message": line.rstrip("\n"),
                }
            )

    entries.reverse()
    return {"available": True, "reason": None, "files": files, "entries": entries[-limit:]}


def _extract_timestamp(line: str) -> str | None:
    """Pull the ISO timestamp out of a `[deploy] 2026-11-11 17:00:00 ...` line."""
    import re

    match = re.search(r"(\d{4}-\d{2}-\d{2}T?\d{2}:\d{2}:\d{2}Z?)", line)
    return match.group(1) if match else None


def _extract_level(line: str) -> str | None:
    import re

    match = re.search(r'"level"\s*:\s*"([A-Z]+)"', line)
    if match:
        return match.group(1)
    match = re.search(r"\b(ERROR|WARNING|WARN|INFO|DEBUG|CRITICAL)\b", line)
    return match.group(1) if match else None


# --------------------------------------------------------------------------- #
# Aggregated payload
# --------------------------------------------------------------------------- #
def build_payload(
    *,
    app_name: str,
    app_version: str,
    app_env: str,
    health: dict,
    user_count: int | None,
    started_at: float | None,
) -> dict:
    """Build the complete dashboard payload."""
    uptime = None
    if started_at is not None:
        uptime = round(time.time() - started_at, 2)

    return {
        "generated_at": _now_iso(),
        "app": {
            "name": app_name,
            "version": app_version,
            "environment": app_env,
            "uptime_seconds": uptime,
            "user_count": user_count,
        },
        "health": health,
        "host": host_metrics(),
        "deployments": deployment_state(),
        "pipeline": pipeline_status(),
        "security": security_summary(),
        "logs": recent_logs(),
    }
