"""Database layer: engine/session lifecycle and connectivity probing."""

from __future__ import annotations

import logging
import time

from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

logger = logging.getLogger(__name__)

# Single shared SQLAlchemy object. Models import this instance.
db = SQLAlchemy()


def init_db(app: Flask) -> None:
    """Bind the SQLAlchemy extension to the Flask application.

    A failure here (missing driver, malformed DSN) is logged but NOT raised:
    the application must still start so that ``/health`` can report the
    database as down and the orchestrator can act on it. Crashing at import
    time would only produce a container that restart-loops without any
    useful diagnostics.
    """
    try:
        db.init_app(app)
    except Exception as exc:  # noqa: BLE001 - the app must survive a bad DB config
        logger.error(
            "Database initialisation FAILED - the app will start but /health "
            "will report the database as down: %s",
            exc,
            extra={"error": str(exc)},
        )
        return

    logger.info(
        "Database initialised",
        extra={"engine": app.config.get("SQLALCHEMY_DATABASE_URI", "").split("@")[-1]},
    )


def check_database_connection(
    timeout: float | None = None,
) -> tuple[bool, str | None]:
    """Probe the database with a trivial ``SELECT 1``.

    Returns ``(is_healthy, error_message)``. Never raises: the health endpoint
    must be able to report a broken database instead of crashing.
    """
    started = time.perf_counter()
    try:
        with db.engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        logger.info("Database health probe OK", extra={"latency_ms": elapsed_ms})
        return True, None
    except SQLAlchemyError as exc:
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        message = f"{type(exc).__name__}: {exc}".split("\n")[0][:300]
        logger.error(
            "Database health probe FAILED",
            extra={"latency_ms": elapsed_ms, "error": message},
        )
        return False, message
    except Exception as exc:  # pragma: no cover - defensive, non-SQLAlchemy errors
        message = f"{type(exc).__name__}: {exc}"[:300]
        logger.error("Database health probe FAILED (unexpected)", extra={"error": message})
        return False, message


def create_all(app: Flask) -> None:
    """Create tables. Used by the ``flask init-db`` CLI command."""
    with app.app_context():
        db.create_all()
        logger.info("Database schema created")


def seed(app: Flask, count: int = 5) -> int:
    """Insert a handful of demo users. Idempotent: existing emails are skipped."""
    from app.models import User

    created = 0
    with app.app_context():
        for i in range(1, count + 1):
            email = f"user{i}@example.com"
            exists = db.session.query(User).filter_by(email=email).first()
            if exists:
                continue
            db.session.add(User(name=f"Demo User {i}", email=email))
            created += 1
        db.session.commit()
    logger.info("Seed complete", extra={"rows_created": created})
    return created
