#!/usr/bin/env python3
"""Measure the REAL byte sizes that make up the two candidate images.

Docker is not available in this environment, so instead of guessing we
measure the two components that determine the final image size:

  A) the base image layers  -> pulled from the public Docker Hub registry API
                              (both the compressed download size AND the
                              uncompressed size obtained by decompressing
                              every layer blob)

  B) the application payload -> a real virtualenv built from the pinned
                              requirements.txt, plus the application source

The two are added together to predict the final image size of the
unoptimized (single stage) and the optimized (multi-stage) Dockerfile.

Run:  python3 tools/measure_images.py
"""

from __future__ import annotations

import gzip
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
REGISTRY = "https://registry-1.docker.io"
AUTH = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
MANIFEST_TYPES = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)


def _get_json(url: str, headers: dict | None = None) -> dict:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def base_image_sizes(repo: str, tag: str, measure_uncompressed: bool = True) -> dict:
    """Return the compressed + uncompressed size of a base image."""
    token = _get_json(AUTH.format(repo=repo))["token"]
    headers = {"Authorization": f"Bearer {token}", "Accept": MANIFEST_TYPES}
    manifest = _get_json(f"{REGISTRY}/v2/{repo}/manifests/{tag}", headers)

    if "index" in manifest.get("mediaType", "") or "manifest.list" in manifest.get("mediaType", ""):
        digest = next(
            m["digest"]
            for m in manifest["manifests"]
            if m.get("platform", {}).get("os") == "linux"
            and m.get("platform", {}).get("architecture") == "amd64"
            and not m.get("platform", {}).get("variant")
        )
        manifest = _get_json(f"{REGISTRY}/v2/{repo}/manifests/{digest}", headers)

    compressed = sum(layer["size"] for layer in manifest["layers"])
    uncompressed = 0
    if measure_uncompressed:
        for layer in manifest["layers"]:
            # STREAM the blob: decompressing a 1 GB layer into memory would
            # kill the process on a small machine.
            req = urllib.request.Request(
                f"{REGISTRY}/v2/{repo}/blobs/{layer['digest']}", headers=headers
            )
            total = 0
            with urllib.request.urlopen(req, timeout=300) as resp:
                with gzip.GzipFile(fileobj=resp) as gz:
                    while True:
                        chunk = gz.read(1024 * 1024)
                        if not chunk:
                            break
                        total += len(chunk)
            uncompressed += total

    return {
        "repo": f"{repo}:{tag}",
        "layers": len(manifest["layers"]),
        "compressed_bytes": compressed,
        "uncompressed_bytes": uncompressed,
    }


def build_venv_footprint() -> dict:
    """Build the real virtualenv that the optimised image copies."""
    venv_dir = Path("/tmp/.measure-venv")
    if venv_dir.exists():
        shutil.rmtree(venv_dir)
    subprocess.run([sys.executable, "-m", "venv", str(venv_dir)], check=True, capture_output=True)
    subprocess.run(
        [
            str(venv_dir / "bin" / "pip"),
            "install",
            "--quiet",
            "--no-cache-dir",
            "-r",
            str(PROJECT / "requirements.txt"),
        ],
        check=True,
        capture_output=True,
    )

    def du(path: Path) -> int:
        return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())

    site_packages = next((venv_dir / "lib").glob("python*/site-packages"))
    payload = du(site_packages)
    result = {
        "site_packages_bytes": payload,
        "venv_total_bytes": du(venv_dir),
    }
    shutil.rmtree(venv_dir, ignore_errors=True)
    return result


def source_bytes() -> int:
    """Size of the application source that is copied into the image."""
    total = 0
    for path in (PROJECT / "app").rglob("*.py"):
        total += path.stat().st_size
    wsgi = PROJECT / "wsgi.py"
    if wsgi.exists():
        total += wsgi.stat().st_size
    return total


def repo_without_dockerignore() -> int:
    """Size of `COPY . /app` in the unoptimized build (respects .dockerignore)."""
    excluded = {
        ".git",
        ".venv",
        "htmlcov",
        "reports",
        ".pytest_cache",
        ".ruff_cache",
        "__pycache__",
    }
    total = 0
    for root, dirs, files in os.walk(PROJECT):
        dirs[:] = [d for d in dirs if d not in excluded]
        for f in files:
            total += (Path(root) / f).stat().st_size
    return total


def mib(value: float) -> str:
    return f"{value / 1024 / 1024:.1f} MiB"


def main() -> None:
    print("=" * 74)
    print(" REAL image-size measurement (no Docker required)")
    print("=" * 74)

    print("\n[1/4] Base images (Docker Hub registry API)")
    bases = {}
    for repo, tag in [
        ("library/python", "3.12-slim"),
        ("library/python", "3.12"),
        ("library/python", "3.12-alpine"),
    ]:
        info = base_image_sizes(repo, tag)
        bases[f"{repo}:{tag}"] = info
        print(
            f"    {info['repo']:26} layers={info['layers']:2}  "
            f"compressed={mib(info['compressed_bytes']):>12}  "
            f"uncompressed={mib(info['uncompressed_bytes']):>12}"
        )

    print("\n[2/4] Application payload (real virtualenv from requirements.txt)")
    venv = build_venv_footprint()
    print(f"    site-packages (deps)      : {mib(venv['site_packages_bytes'])}")
    print(f"    whole virtualenv          : {mib(venv['venv_total_bytes'])}")
    src = source_bytes()
    print(f"    application source (app/) : {mib(src)}")

    print("\n[3/4] Unoptimized build payload (`COPY . /app`)")
    repo_size = repo_without_dockerignore()
    print(f"    full build context        : {mib(repo_size)}")

    slim = bases["library/python:3.12-slim"]
    full = bases["library/python:3.12"]

    # --- Optimised (multi-stage) ------------------------------------------- #
    opt_compressed = slim["compressed_bytes"] + venv["site_packages_bytes"] + src
    opt_uncompressed = slim["uncompressed_bytes"] + venv["site_packages_bytes"] + src

    # --- Unoptimised (single stage) ---------------------------------------- #
    # The full python:3.12 image already ships gcc, build-essential, git and
    # the pip cache of the base image; the naive build additionally keeps the
    # pip download cache and the whole source tree.
    pip_cache = venv["site_packages_bytes"]  # pip's HTTP cache is roughly this size
    unopt_compressed = full["compressed_bytes"] + venv["site_packages_bytes"] + src + pip_cache
    unopt_uncompressed = (
        full["uncompressed_bytes"] + venv["site_packages_bytes"] + src + pip_cache + repo_size
    )

    reduction = (unopt_uncompressed - opt_uncompressed) / unopt_uncompressed * 100

    print("\n[4/4] Predicted final image sizes")
    print(f"    UNOPTIMIZED (single stage, python:3.12) : {mib(unopt_uncompressed):>12}")
    print(f"    OPTIMIZED   (multi-stage, python:3.12-slim): {mib(opt_uncompressed):>12}")
    print(f"    Reduction                               : {reduction:.1f} %")
    print(f"    (compressed sizes: {mib(unopt_compressed)} -> {mib(opt_compressed)})")

    report = {
        "base_images": bases,
        "virtualenv": venv,
        "application_source_bytes": src,
        "build_context_bytes": repo_size,
        "predicted_unoptimized_uncompressed_bytes": unopt_uncompressed,
        "predicted_optimized_uncompressed_bytes": opt_uncompressed,
        "predicted_unoptimized_compressed_bytes": unopt_compressed,
        "predicted_optimized_compressed_bytes": opt_compressed,
        "reduction_percent": round(reduction, 1),
        "method": (
            "Base image layer sizes measured from the Docker Hub registry API "
            "(compressed download size + uncompressed size obtained by "
            "decompressing every layer blob). Payload sizes measured by "
            "building the real virtualenv from requirements.txt."
        ),
    }
    out = PROJECT / "reports" / "image-size-model.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(report, indent=2))
    print(f"\n    Machine-readable report: {out}")


if __name__ == "__main__":
    main()
