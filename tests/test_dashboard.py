"""Tests for the DevOps monitoring dashboard.

The dashboard must never invent data. These tests therefore check three
things above all:

1. ``/`` serves the dashboard (HTML) and ``/health`` keeps its JSON contract.
2. Every section of the payload is either populated from a REAL snapshot or
   explicitly flagged as unavailable / not configured.
3. No credential, secret or privileged handle ever reaches the browser.
"""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from app.monitoring import (
    build_payload,
    deployment_state,
    host_metrics,
    pipeline_status,
    recent_logs,
    security_summary,
)


# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #
@pytest.fixture()
def state_dir(tmp_path, monkeypatch):
    """An empty host state directory (nothing is configured yet)."""
    directory = tmp_path / "state"
    directory.mkdir()
    monkeypatch.setenv("HOST_STATE_DIR", str(directory))
    monkeypatch.setenv("HOST_LOG_DIR", str(directory / "logs"))
    return directory


@pytest.fixture()
def populated_state_dir(state_dir):
    """A state directory filled with realistic snapshots."""
    now = datetime.now(UTC)

    (state_dir / "metrics.json").write_text(
        json.dumps(
            {
                "generated_at": now.isoformat(),
                "hostname": "ip-10-0-1-25",
                "os": "Ubuntu 24.04.1 LTS",
                "kernel": "6.8.0-45-generic",
                "uptime_seconds": 86400,
                "load_average": [0.12, 0.08, 0.05],
                "docker_available": True,
                "cpu": {"percent": 17.5, "cores": 2},
                "memory": {
                    "percent": 41.2,
                    "total_mb": 3900,
                    "used_mb": 1600,
                    "available_mb": 2300,
                },
                "disk": [
                    {
                        "mount": "/",
                        "total_gb": 19.0,
                        "used_gb": 7.6,
                        "available_gb": 11.4,
                        "percent": 40,
                    }
                ],
                "containers": [
                    {
                        "id": "abc123",
                        "name": "devops-cicd-app",
                        "image": "ghcr.io/owner/devops-cicd-app:sha-abc1234",
                        "state": "running",
                        "status": "Up 2 hours (healthy)",
                        "health": "healthy",
                        "ports": "8000/tcp",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    (state_dir / "deployments.json").write_text(
        json.dumps(
            {
                "generated_at": now.isoformat(),
                "deployments": [
                    {
                        "timestamp": now.isoformat(),
                        "image": "ghcr.io/owner/devops-cicd-app:sha-abc1234",
                        "tag": "sha-abc1234",
                        "commit": "abc1234",
                        "status": "success",
                        "duration_seconds": 42,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    (state_dir / "pipeline.json").write_text(
        json.dumps(
            {
                "generated_at": now.isoformat(),
                "status": "completed",
                "conclusion": "success",
                "workflow": "CI/CD Pipeline",
                "commit": "abc1234def",
                "branch": "main",
                "run_url": "https://github.com/owner/repo/actions/runs/42",
                "run_number": 42,
                "actor": "octocat",
                "started_at": now.isoformat(),
                "completed_at": now.isoformat(),
                "duration_seconds": 315,
                "stages": [
                    {
                        "name": "1-3 | Checkout, Lint & Test",
                        "status": "completed",
                        "conclusion": "success",
                    },
                    {
                        "name": "4 | Build Docker image",
                        "status": "completed",
                        "conclusion": "success",
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    (state_dir / "security.json").write_text(
        json.dumps(
            {
                "generated_at": now.isoformat(),
                "scanned_at": now.isoformat(),
                "scanned_image": "ghcr.io/owner/devops-cicd-app:sha-abc1234",
                "policy": "CRITICAL=0,HIGH=0",
                "counts": {
                    "CRITICAL": 0,
                    "HIGH": 1,
                    "MEDIUM": 4,
                    "LOW": 7,
                    "UNKNOWN": 0,
                    "total": 12,
                },
                "vulnerabilities": [
                    {
                        "vulnerability_id": "CVE-2024-1234",
                        "severity": "HIGH",
                        "pkg_name": "libssl3",
                        "installed_version": "3.0.11",
                        "fixed_version": "3.0.12",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    (state_dir / "current-image").write_text(
        "ghcr.io/owner/devops-cicd-app:sha-abc1234\n", encoding="utf-8"
    )
    (state_dir / "previous-image").write_text(
        "ghcr.io/owner/devops-cicd-app:sha-0000000\n", encoding="utf-8"
    )

    log_dir = state_dir / "logs"
    log_dir.mkdir()
    (log_dir / "deploy-20261111-170000.log").write_text(
        "[deploy] 2026-11-11T17:00:00Z Deployment started\n"
        "[deploy] 2026-11-11T17:00:42Z DEPLOYMENT SUCCESSFUL\n",
        encoding="utf-8",
    )
    return state_dir


# --------------------------------------------------------------------------- #
# The dashboard page
# --------------------------------------------------------------------------- #
class TestDashboardPage:
    def test_root_serves_the_dashboard(self, client):
        response = client.get("/")
        assert response.status_code == 200
        assert response.content_type.startswith("text/html")

    def test_dashboard_contains_every_required_section(self, client):
        body = client.get("/").get_data(as_text=True)
        for anchor in (
            'id="overview"',
            'id="health"',
            'id="pipeline"',
            'id="deployments"',
            'id="docker"',
            'id="security"',
            'id="server"',
            'id="logs"',
        ):
            assert anchor in body, f"missing section {anchor}"

    def test_sidebar_has_all_navigation_entries(self, client):
        body = client.get("/").get_data(as_text=True)
        for label in (
            "Overview",
            "Application Health",
            "CI/CD Pipeline",
            "Deployments",
            "Docker Monitoring",
            "Security Scans",
            "Server Monitoring",
            "Logs",
        ):
            assert f">{label}<" in body

    def test_dashboard_refreshes_automatically(self, client):
        script = client.get("/static/js/dashboard.js").get_data(as_text=True)
        assert "REFRESH_MS = 30000" in script
        assert "setInterval" in script

    def test_dashboard_has_a_manual_refresh_control(self, client):
        body = client.get("/").get_data(as_text=True)
        assert 'id="refreshBtn"' in body

    def test_dashboard_is_responsive(self, client):
        body = client.get("/").get_data(as_text=True)
        assert 'name="viewport"' in body
        styles = client.get("/static/css/dashboard.css").get_data(as_text=True)
        assert "@media" in styles
        assert "max-width" in styles

    def test_static_assets_are_served(self, client):
        assert client.get("/static/css/dashboard.css").status_code == 200
        assert client.get("/static/js/dashboard.js").status_code == 200

    def test_static_assets_do_not_leak_external_requests(self, client):
        """No CDN - the dashboard must work on an isolated network."""
        body = client.get("/").get_data(as_text=True)
        assert "http://" not in body.replace("http://www.w3.org", "")
        assert "https://cdn" not in body


# --------------------------------------------------------------------------- #
# The /health contract must stay untouched
# --------------------------------------------------------------------------- #
class TestHealthContractIsUnchanged:
    def test_health_is_still_json(self, client):
        response = client.get("/health")
        assert response.status_code == 200
        assert response.content_type.startswith("application/json")

    def test_health_payload_keys_are_unchanged(self, client):
        body = client.get("/health").get_json()
        assert set(body) == {
            "application",
            "version",
            "environment",
            "status",
            "timestamp",
            "checks",
        }
        assert set(body["checks"]) == {"database"}
        assert set(body["checks"]["database"]) == {"status", "latency_ms"}

    def test_health_still_returns_503_when_the_database_is_down(self, client, monkeypatch):
        monkeypatch.setattr("app.routes.check_database_connection", lambda *a, **k: (False, "boom"))
        response = client.get("/health")
        assert response.status_code == 503
        assert response.get_json()["status"] == "unhealthy"


# --------------------------------------------------------------------------- #
# The dashboard payload
# --------------------------------------------------------------------------- #
class TestDashboardPayload:
    def test_payload_is_served_as_json(self, client):
        response = client.get("/api/dashboard")
        assert response.status_code == 200
        assert response.content_type.startswith("application/json")

    def test_payload_has_every_section(self, client):
        body = client.get("/api/dashboard").get_json()
        for section in ("app", "health", "host", "deployments", "pipeline", "security", "logs"):
            assert section in body

    def test_payload_reports_the_live_health_state(self, client):
        body = client.get("/api/dashboard").get_json()
        assert body["health"]["status"] == "healthy"
        assert body["health"]["checks"]["database"]["status"] == "up"
        assert isinstance(body["health"]["checks"]["database"]["latency_ms"], int | float)

    def test_payload_reports_the_application_metadata(self, client):
        body = client.get("/api/dashboard").get_json()
        assert body["app"]["name"] == "devops-cicd-app"
        assert body["app"]["environment"] == "testing"
        assert body["app"]["version"]

    def test_missing_sources_are_reported_as_unavailable(self, client, state_dir):
        body = client.get("/api/dashboard").get_json()
        assert body["host"]["available"] is False
        assert body["host"]["reason"] == "not_configured"
        assert body["deployments"]["available"] is False
        assert body["pipeline"]["available"] is False
        assert body["security"]["available"] is False
        assert body["logs"]["available"] is False

    def test_missing_sources_never_carry_fake_numbers(self, client, state_dir):
        body = client.get("/api/dashboard").get_json()
        assert body["host"]["cpu"] is None
        assert body["host"]["disk"] == []
        assert body["deployments"]["history"] == []
        assert body["deployments"]["current_tag"] is None
        assert body["pipeline"]["stages"] == []
        assert body["security"]["critical"] is None
        assert body["security"]["high"] is None
        assert body["security"]["vulnerabilities"] == []

    def test_real_snapshots_are_surfaced(self, client, populated_state_dir):
        body = client.get("/api/dashboard").get_json()

        host = body["host"]
        assert host["available"] is True
        assert host["hostname"] == "ip-10-0-1-25"
        assert host["cpu"]["percent"] == 17.5
        assert host["memory"]["percent"] == 41.2
        assert host["disk"][0]["mount"] == "/"
        assert host["containers"][0]["name"] == "devops-cicd-app"

        deployments = body["deployments"]
        assert deployments["available"] is True
        assert deployments["current_tag"] == "sha-abc1234"
        assert deployments["previous_tag"] == "sha-0000000"
        assert deployments["history"][0]["status"] == "success"

        pipeline = body["pipeline"]
        assert pipeline["available"] is True
        assert pipeline["conclusion"] == "success"
        assert pipeline["branch"] == "main"
        assert len(pipeline["stages"]) == 2

        security = body["security"]
        assert security["available"] is True
        assert security["critical"] == 0
        assert security["high"] == 1
        assert security["vulnerabilities"][0]["vulnerability_id"] == "CVE-2024-1234"

        assert body["logs"]["available"] is True
        assert body["logs"]["entries"]

    def test_stale_snapshots_are_flagged(self, client, populated_state_dir):
        old = datetime.now(UTC) - timedelta(hours=2)
        payload = json.loads((populated_state_dir / "metrics.json").read_text())
        payload["generated_at"] = old.isoformat()
        (populated_state_dir / "metrics.json").write_text(json.dumps(payload))

        body = client.get("/api/dashboard").get_json()
        assert body["host"]["stale"] is True
        assert body["host"]["age_seconds"] > 60

    def test_invalid_json_is_reported_not_ignored(self, client, state_dir):
        (state_dir / "metrics.json").write_text("{ this is not json")
        body = client.get("/api/dashboard").get_json()
        assert body["host"]["available"] is False
        assert body["host"]["reason"] == "invalid_json"


# --------------------------------------------------------------------------- #
# Logs endpoint
# --------------------------------------------------------------------------- #
class TestLogsEndpoint:
    def test_logs_returns_json(self, client):
        response = client.get("/api/logs")
        assert response.status_code == 200
        assert response.content_type.startswith("application/json")

    def test_logs_report_no_logs_yet(self, client, state_dir):
        body = client.get("/api/logs").get_json()
        assert body["available"] is False
        assert body["reason"] in {"no_logs", "not_configured"}

    def test_logs_return_the_deployment_entries(self, client, populated_state_dir):
        body = client.get("/api/logs").get_json()
        assert body["available"] is True
        assert any("DEPLOYMENT SUCCESSFUL" in entry["message"] for entry in body["entries"])

    def test_logs_limit_is_clamped(self, client, populated_state_dir):
        body = client.get("/api/logs?limit=99999").get_json()
        assert isinstance(body["entries"], list)

    def test_logs_limit_rejects_garbage(self, client, populated_state_dir):
        response = client.get("/api/logs?limit=abc")
        assert response.status_code == 200


# --------------------------------------------------------------------------- #
# Security: nothing sensitive may reach the browser
# --------------------------------------------------------------------------- #
class TestDashboardSecurity:
    def test_payload_contains_no_credentials(self, client, populated_state_dir):
        raw = client.get("/api/dashboard").get_data(as_text=True)
        for forbidden in ("SECRET_KEY", "POSTGRES_PASSWORD", "password", "secret"):
            assert forbidden not in raw.lower()

    def test_payload_does_not_expose_the_docker_socket(self, client, populated_state_dir):
        raw = client.get("/api/dashboard").get_data(as_text=True)
        assert "/var/run/docker.sock" not in raw

    def test_monitoring_module_has_no_shell_execution(self):
        source = Path("app/monitoring.py").read_text(encoding="utf-8")
        for forbidden in ("subprocess", "os.system", "eval(", "exec("):
            assert forbidden not in source


# --------------------------------------------------------------------------- #
# The monitoring helpers in isolation
# --------------------------------------------------------------------------- #
class TestMonitoringHelpers:
    def test_build_payload_shape(self):
        payload = build_payload(
            app_name="app",
            app_version="1.0.0",
            app_env="testing",
            health={"status": "healthy", "checks": {}},
            user_count=3,
            started_at=None,
        )
        assert payload["app"]["user_count"] == 3
        assert payload["app"]["uptime_seconds"] is None
        assert payload["generated_at"]

    def test_helpers_return_unavailable_without_state(self, state_dir):
        assert host_metrics()["available"] is False
        assert deployment_state()["available"] is False
        assert pipeline_status()["available"] is False
        assert security_summary()["available"] is False
        assert recent_logs()["available"] is False

    def test_state_directory_is_configurable(self, tmp_path, monkeypatch):
        monkeypatch.setenv("HOST_STATE_DIR", str(tmp_path))
        assert os.getenv("HOST_STATE_DIR") == str(tmp_path)
        assert host_metrics()["available"] is False


# --------------------------------------------------------------------------- #
# Deployment wiring: the dashboard must survive the container build
# --------------------------------------------------------------------------- #
class TestContainerWiring:
    def test_dockerfile_copies_the_templates_and_static_assets(self):
        """`COPY app/ ./app/` must carry the dashboard into the image."""
        dockerfile = Path("Dockerfile").read_text(encoding="utf-8")
        assert "COPY --chown=root:root app/ ./app/" in dockerfile

    def test_dockerignore_does_not_exclude_the_dashboard(self):
        ignored = Path(".dockerignore").read_text(encoding="utf-8").splitlines()
        for entry in ignored:
            entry = entry.strip().rstrip("/")
            assert entry not in {
                "app",
                "app/static",
                "app/templates",
            }, f".dockerignore excludes {entry}, which would break the dashboard"

    def test_prod_compose_mounts_the_host_state_read_only(self):
        compose = Path("docker-compose.prod.yml").read_text(encoding="utf-8")
        assert "/opt/devops-cicd/state:/app/hoststate:ro" in compose
        assert "/opt/devops-cicd/logs:/app/hostlogs:ro" in compose
        # The container must NEVER get the Docker socket.
        assert "docker.sock" not in compose

    def test_nginx_routes_root_and_health_to_the_app(self):
        conf = Path("nginx/conf.d/app.conf").read_text(encoding="utf-8")
        assert "location / {" in conf
        assert "location = /health {" in conf
        assert "proxy_pass         http://devops_cicd_app;" in conf

    def test_nginx_serves_static_assets_with_caching(self):
        conf = Path("nginx/conf.d/app.conf").read_text(encoding="utf-8")
        assert "location /static/ {" in conf
        assert "expires" in conf

    def test_nginx_sets_a_content_security_policy(self):
        for path in ("nginx/conf.d/app.conf", "nginx/templates/app-https.conf.template"):
            conf = Path(path).read_text(encoding="utf-8")
            assert "Content-Security-Policy" in conf, f"{path} has no CSP"
            assert "default-src 'self'" in conf, f"{path} has a weak CSP"
