#!/usr/bin/env python3
"""Build the dashboard ``security.json`` snapshot from a Trivy JSON report.

The report is produced by the real Trivy scan in the GitHub Actions pipeline
(``.github/workflows/ci.yml``). This script only reshapes it - it never
invents numbers. If the report is missing the script fails loudly instead of
writing an empty "all clear" summary.

Usage::

    python3 scripts/build-security-summary.py \
        --trivy trivy-image.json \
        --output security.json \
        --image ghcr.io/owner/devops-cicd-app:sha-abc123
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trivy", required=True, help="Trivy JSON report")
    parser.add_argument("--output", required=True, help="security.json to write")
    parser.add_argument("--image", default="", help="Image that was scanned")
    parser.add_argument(
        "--policy",
        default="CRITICAL=0,HIGH=0",
        help="Policy that the pipeline enforces (informational only)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    report_path = Path(args.trivy)
    if not report_path.is_file():
        print(f"ERROR: Trivy report not found: {report_path}", file=sys.stderr)
        return 1

    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: could not read {report_path}: {exc}", file=sys.stderr)
        return 1

    counts = {name: 0 for name in SEVERITIES}
    vulnerabilities: list[dict] = []

    for result in report.get("Results") or []:
        for vuln in result.get("Vulnerabilities") or []:
            severity = str(vuln.get("Severity") or "UNKNOWN").upper()
            if severity not in counts:
                severity = "UNKNOWN"
            counts[severity] += 1
            vulnerabilities.append(
                {
                    "vulnerability_id": vuln.get("VulnerabilityID") or "",
                    "severity": severity,
                    "pkg_name": vuln.get("PkgName") or "",
                    "installed_version": vuln.get("InstalledVersion") or "",
                    "fixed_version": vuln.get("FixedVersion") or "",
                    "target": vuln.get("Target") or "",
                }
            )

    vulnerabilities.sort(key=lambda item: SEVERITIES.index(item["severity"]))

    payload = {
        "generated_at": datetime.now(UTC).isoformat(),
        "scanned_at": datetime.now(UTC).isoformat(),
        "scanned_image": args.image,
        "policy": args.policy,
        "counts": {
            "CRITICAL": counts["CRITICAL"],
            "HIGH": counts["HIGH"],
            "MEDIUM": counts["MEDIUM"],
            "LOW": counts["LOW"],
            "UNKNOWN": counts["UNKNOWN"],
            "total": sum(counts.values()),
        },
        "vulnerabilities": vulnerabilities[:200],
    }

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(
        f"Security summary written to {output_path}: "
        f"CRITICAL={counts['CRITICAL']} HIGH={counts['HIGH']} "
        f"MEDIUM={counts['MEDIUM']} LOW={counts['LOW']} (total {sum(counts.values())})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
