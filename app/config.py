"""Application configuration.

Configuration is driven exclusively by environment variables so the exact same
image can be promoted across environments without a rebuild.

Security notes
--------------
* No secret has a hard-coded fallback that is safe for production. ``SECRET_KEY``
  MUST be provided explicitly in production; the application refuses to boot
  with the insecure development default when ``APP_ENV=production``.
* ``DATABASE_URL`` may be supplied directly (12-factor style) or assembled
  from the individual ``POSTGRES_*`` variables. The password is URL-encoded so
  special characters such as ``@`` or ``/`` cannot break the DSN.
"""

from __future__ import annotations

import os
from urllib.parse import quote_plus


def _get_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _get_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _build_database_url() -> str:
    """Assemble a SQLAlchemy DSN from discrete POSTGRES_* variables."""
    user = os.getenv("POSTGRES_USER", "appuser")
    password = os.getenv("POSTGRES_PASSWORD", "")
    host = os.getenv("POSTGRES_HOST", "db")
    port = os.getenv("POSTGRES_PORT", "5432")
    name = os.getenv("POSTGRES_DB", "devops_cicd")
    auth = quote_plus(user)
    if password:
        auth = f"{auth}:{quote_plus(password)}"
    return f"postgresql+psycopg2://{auth}@{host}:{port}/{name}"


class BaseConfig:
    """Settings shared by every environment."""

    # --- Application identity -------------------------------------------------
    APP_NAME: str = os.getenv("APP_NAME", "devops-cicd-app")
    APP_VERSION: str = os.getenv("APP_VERSION", "1.0.0")
    APP_ENV: str = os.getenv("APP_ENV", "development")

    # --- Flask ----------------------------------------------------------------
    SECRET_KEY: str = os.getenv("SECRET_KEY", "dev-only-insecure-secret-key")
    JSON_SORT_KEYS = False
    MAX_CONTENT_LENGTH = _get_int("MAX_CONTENT_LENGTH", 1024 * 1024)  # 1 MiB
    PROPAGATE_EXCEPTIONS = False

    # --- HTTP server ----------------------------------------------------------
    APP_PORT: int = _get_int("APP_PORT", 8000)
    GUNICORN_WORKERS: int = _get_int("GUNICORN_WORKERS", 3)
    GUNICORN_THREADS: int = _get_int("GUNICORN_THREADS", 2)
    GUNICORN_TIMEOUT: int = _get_int("GUNICORN_TIMEOUT", 30)
    GUNICORN_MAX_REQUESTS: int = _get_int("GUNICORN_MAX_REQUESTS", 1000)
    GUNICORN_MAX_REQUESTS_JITTER: int = _get_int("GUNICORN_MAX_REQUESTS_JITTER", 50)

    # --- Database -------------------------------------------------------------
    POSTGRES_USER: str = os.getenv("POSTGRES_USER", "appuser")
    POSTGRES_HOST: str = os.getenv("POSTGRES_HOST", "db")
    POSTGRES_PORT: int = _get_int("POSTGRES_PORT", 5432)
    POSTGRES_DB: str = os.getenv("POSTGRES_DB", "devops_cicd")
    SQLALCHEMY_DATABASE_URI: str = os.getenv("DATABASE_URL") or _build_database_url()
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    SQLALCHEMY_ENGINE_OPTIONS = {
        "pool_pre_ping": True,  # transparently recycle dead connections
        "pool_recycle": _get_int("DB_POOL_RECYCLE", 1800),
        "pool_size": _get_int("DB_POOL_SIZE", 5),
        "max_overflow": _get_int("DB_MAX_OVERFLOW", 10),
        "pool_timeout": _get_int("DB_POOL_TIMEOUT", 10),
    }

    # --- Observability --------------------------------------------------------
    LOG_LEVEL: str = os.getenv("LOG_LEVEL", "INFO").upper()
    LOG_FORMAT: str = os.getenv("LOG_FORMAT", "json")  # json | text
    HEALTH_DB_TIMEOUT: float = float(os.getenv("HEALTH_DB_TIMEOUT", "3.0"))

    # --- Schema management ----------------------------------------------------
    # When enabled the app creates its tables on startup. This keeps the very
    # first deployment friction-free. In a mature project you would switch this
    # off and use Alembic migrations instead.
    AUTO_CREATE_TABLES: bool = _get_bool("AUTO_CREATE_TABLES", True)


class DevelopmentConfig(BaseConfig):
    DEBUG = True
    LOG_FORMAT = os.getenv("LOG_FORMAT", "text")


class TestingConfig(BaseConfig):
    """Used by pytest. Defaults to an in-memory SQLite DB so the suite runs
    anywhere, but honours TEST_DATABASE_URL so the exact same suite can be
    executed against a real PostgreSQL instance in CI."""

    TESTING = True
    DEBUG = False
    # Test-only constant: never used outside pytest. Production requires a
    # real SECRET_KEY and refuses to boot without one.
    SECRET_KEY = "test-secret-key"  # noqa: S105
    SQLALCHEMY_DATABASE_URI = os.getenv("TEST_DATABASE_URL", "sqlite+pysqlite:///:memory:")
    SQLALCHEMY_ENGINE_OPTIONS: dict = {"pool_pre_ping": True}
    LOG_FORMAT = "text"
    PROPAGATE_EXCEPTIONS = False


class ProductionConfig(BaseConfig):
    DEBUG = False
    LOG_FORMAT = os.getenv("LOG_FORMAT", "json")


def get_config(name: str | None = None):
    """Return the config class matching the requested environment."""
    env = (name or os.getenv("APP_ENV", "development")).strip().lower()
    mapping = {
        "development": DevelopmentConfig,
        "dev": DevelopmentConfig,
        "testing": TestingConfig,
        "test": TestingConfig,
        "production": ProductionConfig,
        "prod": ProductionConfig,
    }
    return mapping.get(env, DevelopmentConfig)
