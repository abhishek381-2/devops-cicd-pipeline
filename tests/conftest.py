"""Shared pytest fixtures.

The suite runs against an in-memory SQLite database by default so that a
developer needs nothing but Python to execute it. Set ``TEST_DATABASE_URL`` to a
real PostgreSQL DSN to exercise the exact same tests against PostgreSQL - this
is what the CI pipeline does with a ``postgres`` service container.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# Make the project importable when pytest is invoked from the repo root.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

os.environ.setdefault("APP_ENV", "testing")
os.environ.setdefault("SECRET_KEY", "test-secret-key")


from app import create_app  # noqa: E402
from app.database import db as _db  # noqa: E402
from app.models import User  # noqa: E402


@pytest.fixture()
def app():
    """A fresh application instance with a clean database per test."""
    application = create_app("testing")
    application.config["APP_STARTED_AT"] = 1000.0

    with application.app_context():
        _db.create_all()
        # Ensure a clean slate even when the suite runs against a shared
        # PostgreSQL instance.
        _db.session.query(User).delete()
        _db.session.commit()

    yield application

    with application.app_context():
        _db.session.remove()
        _db.drop_all()


@pytest.fixture()
def client(app):
    """Flask test client."""
    return app.test_client()


@pytest.fixture()
def runner(app):
    """Flask CLI runner (used by the CLI-command tests)."""
    return app.test_cli_runner()


@pytest.fixture()
def sample_user(app):
    """A user persisted in the test database."""
    with app.app_context():
        user = User(name="Ada Lovelace", email="ada@example.com")
        _db.session.add(user)
        _db.session.commit()
        _db.session.refresh(user)
        return user.to_dict()
