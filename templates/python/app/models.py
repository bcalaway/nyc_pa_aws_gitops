"""SQLAlchemy models. A working example, not a requirement: replace `Item`
with the app's real tables.

Every change here needs a matching Alembic migration (`migrations/versions/`).
Generate one with:

    alembic revision --autogenerate -m "describe the change"

then read it before committing -- autogenerate is a draft, not a guarantee.
`tests/test_migrations.py` fails if the models and the migrations disagree,
so a forgotten migration is caught in CI instead of in production.
"""

from datetime import datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class Item(Base):
    __tablename__ = "items"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
