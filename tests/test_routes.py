"""Tests for the HTTP routes (``/``, ``/api/users``, ``/api/stats``)."""

from __future__ import annotations

import json


class TestIndexRoute:
    """``/`` serves the DevOps monitoring dashboard (HTML).

    The JSON service banner that used to live on ``/`` moved to
    ``/api/stats`` and ``/api/dashboard`` - see ``tests/test_dashboard.py``.
    """

    def test_index_returns_200(self, client):
        response = client.get("/")
        assert response.status_code == 200

    def test_index_returns_html(self, client):
        response = client.get("/")
        assert response.content_type.startswith("text/html")

    def test_index_contains_the_dashboard(self, client):
        body = client.get("/").get_data(as_text=True)
        assert "DevOps Monitoring" in body
        assert "dashboard.css" in body
        assert "dashboard.js" in body

    def test_index_renders_the_application_metadata(self, client):
        body = client.get("/").get_data(as_text=True)
        assert "devops-cicd-app" in body
        assert "testing" in body

    def test_index_advertises_the_api_endpoints(self, client):
        body = client.get("/").get_data(as_text=True)
        assert "/health" in body
        assert "/api/logs" in body


class TestUsersRead:
    def test_list_users_empty(self, client):
        response = client.get("/api/users")
        assert response.status_code == 200
        body = response.get_json()
        assert body["users"] == []
        assert body["total"] == 0

    def test_list_users_returns_records(self, client, sample_user):
        body = client.get("/api/users").get_json()
        assert body["count"] == 1
        assert body["users"][0]["email"] == "ada@example.com"
        assert "created_at" in body["users"][0]

    def test_list_users_respects_limit(self, client, sample_user):
        body = client.get("/api/users?limit=1").get_json()
        assert body["limit"] == 1
        assert len(body["users"]) <= 1

    def test_list_users_clamps_invalid_limit(self, client):
        body = client.get("/api/users?limit=abc").get_json()
        assert body["limit"] == 50  # falls back to the default

    def test_list_users_returns_503_when_the_table_is_missing(self, app, client):
        """Regression: a missing table must produce a clean 503, not a 500."""
        from app.database import db as _db

        with app.app_context():
            _db.drop_all()

        response = client.get("/api/users")
        assert response.status_code == 503
        assert response.get_json()["error"] == "database_error"


class TestUsersCreate:
    def test_create_user_success(self, client):
        response = client.post(
            "/api/users",
            data=json.dumps({"name": "Grace Hopper", "email": "grace@example.com"}),
            content_type="application/json",
        )
        assert response.status_code == 201
        body = response.get_json()
        assert body["user"]["name"] == "Grace Hopper"
        assert body["user"]["email"] == "grace@example.com"
        assert body["user"]["id"] >= 1

    def test_create_user_normalises_email_case(self, client):
        response = client.post(
            "/api/users",
            data=json.dumps({"name": "Upper Case", "email": "Mixed@Example.COM"}),
            content_type="application/json",
        )
        assert response.status_code == 201
        assert response.get_json()["user"]["email"] == "mixed@example.com"

    def test_create_user_rejects_duplicate_email(self, client, sample_user):
        response = client.post(
            "/api/users",
            data=json.dumps({"name": "Impostor", "email": "ada@example.com"}),
            content_type="application/json",
        )
        assert response.status_code == 409
        assert response.get_json()["error"] == "duplicate_email"

    def test_create_user_rejects_missing_fields(self, client):
        response = client.post("/api/users", data=json.dumps({}), content_type="application/json")
        assert response.status_code == 400
        assert response.get_json()["error"] == "validation_error"
        assert len(response.get_json()["messages"]) == 2

    def test_create_user_rejects_invalid_email(self, client):
        response = client.post(
            "/api/users",
            data=json.dumps({"name": "Bad", "email": "not-an-email"}),
            content_type="application/json",
        )
        assert response.status_code == 400
        assert any("email" in m for m in response.get_json()["messages"])

    def test_create_user_rejects_non_json_content_type(self, client):
        response = client.post("/api/users", data="name=grace")
        assert response.status_code == 415

    def test_create_user_rejects_malformed_json(self, client):
        response = client.post("/api/users", data="{not-json", content_type="application/json")
        assert response.status_code == 400
        assert response.get_json()["error"] == "invalid_json"

    def test_create_user_rejects_oversized_name(self, client):
        response = client.post(
            "/api/users",
            data=json.dumps({"name": "x" * 500, "email": "long@example.com"}),
            content_type="application/json",
        )
        assert response.status_code == 400

    def test_create_user_returns_503_when_the_table_is_missing(self, app, client):
        """Regression: a missing table must produce a clean 503, not a 500."""
        from app.database import db as _db

        with app.app_context():
            _db.drop_all()

        response = client.post(
            "/api/users",
            data=json.dumps({"name": "Ghost", "email": "ghost@example.com"}),
            content_type="application/json",
        )
        assert response.status_code == 503
        assert response.get_json()["error"] == "database_error"


class TestStatsRoute:
    def test_stats_returns_200(self, client):
        response = client.get("/api/stats")
        assert response.status_code == 200

    def test_stats_reports_user_count(self, client, sample_user):
        body = client.get("/api/stats").get_json()
        assert body["users"]["count"] == 1
        assert body["database"]["status"] == "up"

    def test_stats_includes_version_and_environment(self, client):
        body = client.get("/api/stats").get_json()
        assert body["version"]
        assert body["environment"] == "testing"


class TestErrorHandling:
    def test_unknown_route_returns_json_404(self, client):
        response = client.get("/does-not-exist")
        assert response.status_code == 404
        assert response.get_json()["error"] == "not_found"

    def test_wrong_method_returns_405(self, client):
        response = client.delete("/api/users")
        assert response.status_code == 405
        assert response.get_json()["error"] == "method_not_allowed"

    def test_request_id_header_is_returned(self, client):
        response = client.get("/", headers={"X-Request-ID": "abc-123"})
        assert response.headers["X-Request-ID"] == "abc-123"
