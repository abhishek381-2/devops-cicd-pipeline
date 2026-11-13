"""HTTP routes for the ``devops-cicd-app`` service.

Route map
---------
GET  /                -> DevOps monitoring dashboard (HTML)
GET  /health          -> liveness/readiness probe (JSON, unchanged contract)
GET  /api/users       -> list users
POST /api/users       -> create a user
GET  /api/stats       -> basic application statistics
GET  /api/dashboard   -> aggregated dashboard payload (JSON)
GET  /api/logs        -> recent deployment logs (JSON)
"""

from __future__ import annotations

import re
import time
from datetime import UTC, datetime

from flask import Blueprint, current_app, jsonify, render_template, request
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.database import check_database_connection, db
from app.models import User
from app.monitoring import build_payload, recent_logs

main_bp = Blueprint("main", __name__)

# Deliberately permissive-but-realistic e-mail check (not RFC 5322 in full).
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$")
MAX_NAME_LENGTH = 120
MAX_EMAIL_LENGTH = 255
MAX_PAGE_SIZE = 100


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _validate_payload(payload) -> tuple[dict | None, list[str]]:
    """Validate a user payload. Returns ``(cleaned, errors)``."""
    errors: list[str] = []

    if not isinstance(payload, dict):
        return None, ["Request body must be a JSON object"]

    name = payload.get("name")
    email = payload.get("email")

    if not isinstance(name, str) or not name.strip():
        errors.append("'name' is required and must be a non-empty string")
    elif len(name.strip()) > MAX_NAME_LENGTH:
        errors.append(f"'name' must be at most {MAX_NAME_LENGTH} characters")

    if not isinstance(email, str) or not email.strip():
        errors.append("'email' is required and must be a non-empty string")
    else:
        email = email.strip()
        if len(email) > MAX_EMAIL_LENGTH:
            errors.append(f"'email' must be at most {MAX_EMAIL_LENGTH} characters")
        elif not EMAIL_RE.match(email):
            errors.append("'email' must be a valid e-mail address")

    if errors:
        return None, errors

    return {"name": name.strip(), "email": email.strip().lower()}, []


# --------------------------------------------------------------------------- #
# Routes
# --------------------------------------------------------------------------- #
@main_bp.route("/", methods=["GET"])
def index():
    """DevOps monitoring dashboard (HTML).

    The JSON service banner that used to live here is still available at
    ``/api/stats`` and inside the dashboard payload (``/api/dashboard``), so
    nothing that consumed the old response is broken.
    """
    app = current_app
    return (
        render_template(
            "dashboard.html",
            app_name=app.config.get("APP_NAME", "devops-cicd-app"),
            app_version=app.config.get("APP_VERSION", "unknown"),
            app_env=app.config.get("APP_ENV", "development"),
        ),
        200,
    )


@main_bp.route("/api/dashboard", methods=["GET"])
def dashboard_data():
    """Aggregated payload powering the dashboard.

    Everything in here is real: the live health probe, the real DB latency,
    and the JSON snapshots written on the host by the metrics collector and
    by the CI/CD pipeline. Sections whose data source is not configured are
    reported as ``available: false`` - never as invented numbers.
    """
    started = time.perf_counter()
    db_ok, db_error = check_database_connection(timeout=current_app.config.get("HEALTH_DB_TIMEOUT"))
    latency_ms = round((time.perf_counter() - started) * 1000, 2)

    health = {
        "status": "healthy" if db_ok else "unhealthy",
        "checked_at": datetime.now(UTC).isoformat(),
        "latency_ms": latency_ms,
        "checks": {
            "database": {
                "status": "up" if db_ok else "down",
                "latency_ms": latency_ms,
                "error": db_error,
            }
        },
    }

    user_count = None
    if db_ok:
        try:
            user_count = db.session.query(User).count()
        except SQLAlchemyError:
            user_count = None

    payload = build_payload(
        app_name=current_app.config.get("APP_NAME", "devops-cicd-app"),
        app_version=current_app.config.get("APP_VERSION", "unknown"),
        app_env=current_app.config.get("APP_ENV", "development"),
        health=health,
        user_count=user_count,
        started_at=current_app.config.get("APP_STARTED_AT"),
    )
    return jsonify(payload), 200


@main_bp.route("/api/logs", methods=["GET"])
def logs():
    """Recent deployment logs read from the host's log directory."""
    try:
        limit = min(max(int(request.args.get("limit", 60)), 1), 500)
    except (TypeError, ValueError):
        limit = 60
    return jsonify(recent_logs(limit)), 200


@main_bp.route("/health", methods=["GET"])
def health():
    """Readiness probe.

    Returns **200** when the app and its database are healthy, **503** when a
    required dependency is unavailable. Docker, the CI health-check step and
    the rollback logic all key off this status code.
    """
    started = time.perf_counter()
    db_ok, db_error = check_database_connection(timeout=current_app.config.get("HEALTH_DB_TIMEOUT"))
    latency_ms = round((time.perf_counter() - started) * 1000, 2)

    payload = {
        "status": "healthy" if db_ok else "unhealthy",
        "application": current_app.config.get("APP_NAME", "devops-cicd-app"),
        "version": current_app.config.get("APP_VERSION", "unknown"),
        "environment": current_app.config.get("APP_ENV", "development"),
        "timestamp": _now_iso(),
        "checks": {
            "database": {
                "status": "up" if db_ok else "down",
                "latency_ms": latency_ms,
            }
        },
    }
    if db_error:
        payload["checks"]["database"]["error"] = db_error
        payload["error"] = "database_unavailable"

    return jsonify(payload), (200 if db_ok else 503)


@main_bp.route("/api/users", methods=["GET"])
def list_users():
    """Return a paginated list of users."""
    try:
        limit = min(max(int(request.args.get("limit", 50)), 1), MAX_PAGE_SIZE)
    except (TypeError, ValueError):
        limit = 50
    try:
        offset = max(int(request.args.get("offset", 0)), 0)
    except (TypeError, ValueError):
        offset = 0

    try:
        users = db.session.query(User).order_by(User.id.asc()).offset(offset).limit(limit).all()
        total = db.session.query(User).count()
    except SQLAlchemyError as exc:
        current_app.logger.error("Failed to list users: %s", exc, exc_info=True)
        return (
            jsonify(
                {
                    "error": "database_error",
                    "message": "Could not retrieve users from the database.",
                    "status": 503,
                }
            ),
            503,
        )

    return (
        jsonify(
            {
                "users": [u.to_dict() for u in users],
                "count": len(users),
                "total": total,
                "limit": limit,
                "offset": offset,
            }
        ),
        200,
    )


@main_bp.route("/api/users", methods=["POST"])
def create_user():
    """Create a user.

    Status codes
    ------------
    201 created | 400 invalid payload | 409 duplicate e-mail | 415 wrong
    content type | 503 database unavailable.
    """
    if not request.is_json:
        return (
            jsonify(
                {
                    "error": "unsupported_media_type",
                    "message": "Content-Type must be application/json",
                    "status": 415,
                }
            ),
            415,
        )

    payload = request.get_json(silent=True)
    if payload is None:
        return (
            jsonify(
                {
                    "error": "invalid_json",
                    "message": "Request body is not valid JSON",
                    "status": 400,
                }
            ),
            400,
        )

    cleaned, errors = _validate_payload(payload)
    if errors:
        return (
            jsonify({"error": "validation_error", "messages": errors, "status": 400}),
            400,
        )

    # Explicit duplicate check -> deterministic 409 instead of relying on the
    # database constraint (which also protects against a race).
    # NOTE: the query is inside the try block on purpose - if the table does
    # not exist (or the DB is down) we must return a clean 503 instead of an
    # unhandled 500.
    try:
        existing = db.session.query(User).filter_by(email=cleaned["email"]).first()
        if existing:
            return (
                jsonify(
                    {
                        "error": "duplicate_email",
                        "message": f"A user with email '{cleaned['email']}' already exists",
                        "status": 409,
                    }
                ),
                409,
            )

        user = User(name=cleaned["name"], email=cleaned["email"])
        db.session.add(user)
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
        return (
            jsonify(
                {
                    "error": "duplicate_email",
                    "message": f"A user with email '{cleaned['email']}' already exists",
                    "status": 409,
                }
            ),
            409,
        )
    except SQLAlchemyError as exc:
        db.session.rollback()
        current_app.logger.error("Failed to create user: %s", exc, exc_info=True)
        return (
            jsonify(
                {
                    "error": "database_error",
                    "message": "Could not create the user.",
                    "status": 503,
                }
            ),
            503,
        )

    return jsonify({"message": "User created successfully", "user": user.to_dict()}), 201


@main_bp.route("/api/stats", methods=["GET"])
def stats():
    """Basic application statistics."""
    db_ok, db_error = check_database_connection()

    user_count = None
    if db_ok:
        try:
            user_count = db.session.query(User).count()
        except SQLAlchemyError as exc:
            current_app.logger.error("Failed to count users: %s", exc, exc_info=True)
            user_count = None

    started_at = current_app.config.get("APP_STARTED_AT")
    uptime = None
    if started_at is not None:
        uptime = round(time.time() - started_at, 2)

    payload = {
        "application": current_app.config.get("APP_NAME", "devops-cicd-app"),
        "version": current_app.config.get("APP_VERSION", "unknown"),
        "environment": current_app.config.get("APP_ENV", "development"),
        "timestamp": _now_iso(),
        "database": {"status": "up" if db_ok else "down"},
        "users": {"count": user_count},
        "uptime_seconds": uptime,
    }
    if db_error:
        payload["database"]["error"] = db_error
    return jsonify(payload), 200
