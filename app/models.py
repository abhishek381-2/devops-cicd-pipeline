"""SQLAlchemy ORM models."""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.database import db


def _utcnow() -> datetime:
    return datetime.now(UTC)


class User(db.Model):
    """A registered user of the application."""

    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False, index=True)
    email: Mapped[str] = mapped_column(String(255), nullable=False, unique=True, index=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=_utcnow, server_default=func.now()
    )

    def __repr__(self) -> str:  # pragma: no cover - debug helper
        return f"<User id={self.id} email={self.email!r}>"

    def to_dict(self) -> dict:
        """Serialisable representation. Never leaks internal state."""
        created = self.created_at
        if created is not None and created.tzinfo is None:
            created = created.replace(tzinfo=UTC)
        return {
            "id": self.id,
            "name": self.name,
            "email": self.email,
            "created_at": created.isoformat() if created else None,
        }
