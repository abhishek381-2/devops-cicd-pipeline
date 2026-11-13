"""Tests for the ``/health`` endpoint - the contract the whole CI/CD pipeline
depends on (Docker HEALTHCHECK, CI post-deployment validation, rollback)."""

from __future__ import annotations

from unittest import mock

from app.database import check_database_connection


class TestHealthEndpoint:
    def test_health_returns_200_when_healthy(self, client):
        response = client.get("/health")
        assert response.status_code == 200

    def test_health_payload_is_structured(self, client):
        body = client.get("/health").get_json()
        assert body["status"] == "healthy"
        assert body["application"] == "devops-cicd-app"
        assert body["version"]
        assert body["environment"] == "testing"
        assert body["checks"]["database"]["status"] == "up"
        assert "timestamp" in body

    def test_health_reports_database_latency(self, client):
        body = client.get("/health").get_json()
        assert isinstance(body["checks"]["database"]["latency_ms"], int | float)

    def test_health_returns_503_when_database_is_down(self, client):
        with mock.patch(
            "app.routes.check_database_connection", return_value=(False, "connection refused")
        ):
            response = client.get("/health")
        assert response.status_code == 503
        body = response.get_json()
        assert body["status"] == "unhealthy"
        assert body["error"] == "database_unavailable"
        assert body["checks"]["database"]["status"] == "down"

    def test_health_is_cached_off(self, client):
        """The probe must reflect live state - no HTTP caching."""
        response = client.get("/health")
        assert "Cache-Control" not in response.headers


class TestDatabaseProbe:
    def test_probe_returns_true_when_reachable(self, app):
        with app.app_context():
            ok, error = check_database_connection()
        assert ok is True
        assert error is None

    def test_probe_returns_false_and_message_when_unreachable(self, app):
        from app.database import db

        with app.app_context():
            with mock.patch.object(db.engine, "connect", side_effect=RuntimeError("boom")):
                ok, error = check_database_connection()
        assert ok is False
        assert error is not None
        assert "boom" in error

    def test_probe_never_raises(self, app):
        from app.database import db

        with app.app_context():
            with mock.patch.object(db.engine, "connect", side_effect=Exception("catastrophe")):
                ok, error = check_database_connection()
        assert ok is False
        assert error
