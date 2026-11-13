"""Application factory for the ``devops-cicd-app`` Flask service.

Architecture
------------
``app/__init__.py`` (this file) wires the application together:
    config  -> logging  -> database  -> blueprints  -> error handlers

Keeping the factory pattern means tests can build an isolated application
instance with a different configuration (e.g. in-memory SQLite) without
monkey-patching globals.
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import sys
import time
import uuid
from typing import Any

from flask import Flask, g, jsonify, request

from app.config import get_config
from app.database import db, init_db

__version__ = "1.0.0"


# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #
class JsonFormatter(logging.Formatter):
    """Emit one JSON object per log line - easy for Loki/CloudWatch parsing."""

    def format(self, record: logging.LogRecord) -> str:
        import json

        payload: dict[str, Any] = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        request_id = getattr(record, "request_id", None)
        if request_id:
            payload["request_id"] = request_id
        latency = getattr(record, "latency_ms", None)
        if latency is not None:
            payload["latency_ms"] = latency
        error = getattr(record, "error", None)
        if error:
            payload["error"] = error
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(app: Flask) -> None:
    level = getattr(logging, app.config.get("LOG_LEVEL", "INFO"), logging.INFO)
    handler = logging.StreamHandler(sys.stdout)

    if app.config.get("LOG_FORMAT", "json") == "json":
        handler.setFormatter(JsonFormatter())
    else:
        handler.setFormatter(
            logging.Formatter(
                "%(asctime)s %(levelname)-8s [%(name)s] %(message)s",
                datefmt="%Y-%m-%d %H:%M:%S",
            )
        )

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level)

    # Gunicorn duplicates access logs through its own handlers; silence them so
    # that every line goes through our single structured formatter.
    logging.getLogger("gunicorn.error").handlers.clear()
    logging.getLogger("gunicorn.access").handlers.clear()
    logging.getLogger("gunicorn.error").propagate = True
    logging.getLogger("gunicorn.access").propagate = True

    app.logger.setLevel(level)


# --------------------------------------------------------------------------- #
# Request instrumentation
# --------------------------------------------------------------------------- #
def _register_request_hooks(app: Flask) -> None:
    @app.before_request
    def _before() -> None:
        g.request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex
        g.started_at = time.perf_counter()

    @app.after_request
    def _after(response):
        elapsed_ms = round(
            (time.perf_counter() - getattr(g, "started_at", time.perf_counter())) * 1000, 2
        )
        response.headers["X-Request-ID"] = getattr(g, "request_id", "-")
        response.headers["X-Content-Type-Options"] = "nosniff"
        app.logger.info(
            "request",
            extra={
                "request_id": getattr(g, "request_id", "-"),
                "latency_ms": elapsed_ms,
                "method": request.method,
                "path": request.path,
                "status": response.status_code,
            },
        )
        return response


# --------------------------------------------------------------------------- #
# Error handlers
# --------------------------------------------------------------------------- #
def _register_error_handlers(app: Flask) -> None:
    @app.errorhandler(404)
    def _not_found(_exc):
        return (
            jsonify(
                {
                    "error": "not_found",
                    "message": f"No route matches {request.method} {request.path}",
                    "status": 404,
                }
            ),
            404,
        )

    @app.errorhandler(405)
    def _method_not_allowed(_exc):
        return (
            jsonify(
                {
                    "error": "method_not_allowed",
                    "message": f"{request.method} is not allowed on {request.path}",
                    "status": 405,
                }
            ),
            405,
        )

    @app.errorhandler(400)
    def _bad_request(exc):
        return (
            jsonify(
                {
                    "error": "bad_request",
                    "message": getattr(exc, "description", "Malformed request"),
                    "status": 400,
                }
            ),
            400,
        )

    @app.errorhandler(413)
    def _too_large(_exc):
        return (
            jsonify(
                {
                    "error": "payload_too_large",
                    "message": "Request body exceeds the configured limit",
                    "status": 413,
                }
            ),
            413,
        )

    @app.errorhandler(Exception)
    def _unhandled(exc):
        # Never leak a stack trace to the client - log it, return a generic body.
        app.logger.error(
            "Unhandled exception: %s",
            exc,
            extra={"request_id": getattr(g, "request_id", "-"), "error": str(exc)},
            exc_info=True,
        )
        return (
            jsonify(
                {
                    "error": "internal_server_error",
                    "message": "An unexpected error occurred. Please try again later.",
                    "status": 500,
                }
            ),
            500,
        )


# --------------------------------------------------------------------------- #
# CLI commands
# --------------------------------------------------------------------------- #
def _register_cli(app: Flask) -> None:
    import click

    @app.cli.command("init-db")
    def init_db_command() -> None:
        """Create all database tables."""
        from app.database import create_all

        create_all(app)
        click.echo("Database schema created.")

    @app.cli.command("seed-db")
    @click.option("--count", default=5, help="Number of demo users to insert.")
    def seed_db_command(count: int) -> None:
        """Insert demo users (idempotent)."""
        from app.database import seed

        created = seed(app, count)
        click.echo(f"Seeded {created} new user(s).")


def _auto_create_tables(app: Flask) -> None:
    """Create the schema on startup when AUTO_CREATE_TABLES is enabled.

    Failures are logged but never crash the process: the app must still start
    so that ``/health`` can report *why* the database is not usable.
    """
    if not app.config.get("AUTO_CREATE_TABLES", True):
        return
    try:
        with app.app_context():
            db.create_all()
        app.logger.info("Database schema is up to date")
    except Exception as exc:  # noqa: BLE001 - never block the boot sequence
        app.logger.warning(
            "Could not create the database schema at startup: %s",
            exc,
            extra={"error": str(exc)},
        )


# --------------------------------------------------------------------------- #
# Factory
# --------------------------------------------------------------------------- #
def create_app(config_name: str | None = None) -> Flask:
    """Application factory used by Gunicorn, the CLI and the test-suite."""
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(get_config(config_name))
    app.config["APP_STARTED_AT"] = time.time()

    if app.config.get("APP_ENV", "development").lower() in {"production", "prod"}:
        if os.getenv("SECRET_KEY", "") in {"", "dev-only-insecure-secret-key"}:
            raise RuntimeError(
                "SECRET_KEY must be set to a strong random value when APP_ENV=production."
            )

    configure_logging(app)
    init_db(app)
    _register_request_hooks(app)
    _register_error_handlers(app)
    _register_cli(app)

    # The routes module imports app.models, which registers the ORM models
    # with SQLAlchemy's metadata. It MUST be imported before create_all()
    # runs, otherwise the metadata is still empty and no table is created.
    from app.routes import main_bp

    app.register_blueprint(main_bp)

    # Now that the models are known, make sure the schema exists.
    _auto_create_tables(app)

    app.extensions["app_version"] = app.config.get("APP_VERSION", __version__)
    return app


__all__ = ["create_app", "db", "__version__"]
