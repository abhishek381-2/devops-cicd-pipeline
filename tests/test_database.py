"""Tests for the database layer and the User model."""

from __future__ import annotations

import pytest
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.database import db as _db
from app.models import User


class TestUserModel:
    def test_user_fields(self, app):
        with app.app_context():
            user = User(name="Alan Turing", email="alan@example.com")
            _db.session.add(user)
            _db.session.commit()

            assert user.id is not None
            assert user.name == "Alan Turing"
            assert user.email == "alan@example.com"
            assert user.created_at is not None

    def test_to_dict_serialises_iso_timestamp(self, app):
        with app.app_context():
            user = User(name="Katherine Johnson", email="kj@example.com")
            _db.session.add(user)
            _db.session.commit()

            data = user.to_dict()
            assert set(data.keys()) == {"id", "name", "email", "created_at"}
            assert isinstance(data["created_at"], str)
            assert "T" in data["created_at"]

    def test_email_is_unique(self, app):
        with app.app_context():
            _db.session.add(User(name="First", email="dup@example.com"))
            _db.session.commit()

            _db.session.add(User(name="Second", email="dup@example.com"))
            with pytest.raises(IntegrityError):
                _db.session.commit()
            _db.session.rollback()

    def test_name_cannot_be_null(self, app):
        with app.app_context():
            _db.session.add(User(name=None, email="noname@example.com"))
            with pytest.raises(SQLAlchemyError):
                _db.session.commit()
            _db.session.rollback()

    def test_count_query(self, app, sample_user):
        with app.app_context():
            count = _db.session.scalar(select(func.count()).select_from(User))
        assert count == 1


class TestConfiguration:
    """The DSN is assembled from the POSTGRES_* variables - the place where
    passwords with special characters ('@', '/', ':') most often break.

    Note: the config *classes* are evaluated at import time, so the class
    attribute can only be re-tested by reloading the module. The helper
    function reads os.environ on every call and is tested directly.
    """

    def test_database_url_is_built_from_postgres_variables(self, monkeypatch):
        from app.config import _build_database_url

        monkeypatch.delenv("DATABASE_URL", raising=False)
        monkeypatch.setenv("POSTGRES_USER", "appuser")
        monkeypatch.setenv("POSTGRES_PASSWORD", "s3cret")
        monkeypatch.setenv("POSTGRES_HOST", "db")
        monkeypatch.setenv("POSTGRES_PORT", "5432")
        monkeypatch.setenv("POSTGRES_DB", "devops_cicd")

        assert _build_database_url() == "postgresql+psycopg2://appuser:s3cret@db:5432/devops_cicd"

    def test_special_characters_in_the_password_are_encoded(self, monkeypatch):
        from app.config import _build_database_url

        monkeypatch.delenv("DATABASE_URL", raising=False)
        monkeypatch.setenv("POSTGRES_USER", "appuser")
        monkeypatch.setenv("POSTGRES_PASSWORD", "p@ss:w/rd#1")
        monkeypatch.setenv("POSTGRES_HOST", "db")
        monkeypatch.setenv("POSTGRES_PORT", "5432")
        monkeypatch.setenv("POSTGRES_DB", "devops_cicd")

        uri = _build_database_url()
        assert uri.startswith("postgresql+psycopg2://appuser:")
        assert "p%40ss%3Aw%2Frd%231" in uri
        assert "@db:5432/devops_cicd" in uri

    def test_explicit_database_url_wins(self):
        import importlib
        import os

        from app import config as config_module

        original = os.environ.get("DATABASE_URL")
        os.environ["DATABASE_URL"] = "postgresql+psycopg2://u:p@host:5432/db"
        try:
            reloaded = importlib.reload(config_module)
            assert reloaded.BaseConfig.SQLALCHEMY_DATABASE_URI == (
                "postgresql+psycopg2://u:p@host:5432/db"
            )
        finally:
            # Restore the environment AND the module state for the other tests.
            if original is None:
                os.environ.pop("DATABASE_URL", None)
            else:
                os.environ["DATABASE_URL"] = original
            importlib.reload(config_module)


class TestSessionManagement:
    def test_session_rollback_discards_uncommitted_changes(self, app):
        with app.app_context():
            _db.session.add(User(name="Temp", email="temp@example.com"))
            _db.session.rollback()
            count = _db.session.scalar(select(func.count()).select_from(User))
        assert count == 0

    def test_connection_pool_is_configured(self, app):
        """pool_pre_ping must stay enabled so stale connections are recycled."""
        assert app.config["SQLALCHEMY_ENGINE_OPTIONS"]["pool_pre_ping"] is True


class TestSchemaManagement:
    def test_create_all_is_idempotent(self, app):
        from app.database import create_all

        with app.app_context():
            create_all(app)
            create_all(app)
            count = _db.session.scalar(select(func.count()).select_from(User))
        assert count == 0

    def test_users_table_exists_right_after_startup(self):
        """Regression: the ORM models must be imported BEFORE create_all() runs.

        If app.routes (and therefore app.models) is imported too late, the
        SQLAlchemy metadata is empty, create_all() silently creates nothing
        and every query fails with "no such table: users".
        """
        from app import create_app
        from app.database import db

        fresh_app = create_app("testing")
        with fresh_app.app_context():
            tables = list(db.inspect(db.engine).get_table_names())
        assert "users" in tables


class TestCLICommands:
    def test_init_db_command(self, app, runner):
        result = runner.invoke(args=["init-db"])
        assert result.exit_code == 0

    def test_seed_db_command_is_idempotent(self, app, runner):
        first = runner.invoke(args=["seed-db", "--count", "3"])
        second = runner.invoke(args=["seed-db", "--count", "3"])
        assert first.exit_code == 0
        assert second.exit_code == 0
        with app.app_context():
            count = _db.session.scalar(select(func.count()).select_from(User))
        assert count == 3
