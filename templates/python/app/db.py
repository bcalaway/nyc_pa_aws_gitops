from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError

from app.config import settings


def _engine():
    # No password configured means this app either hasn't been onboarded
    # to Postgres yet or doesn't use it -- both are valid states, not an
    # error, so callers get a clean "not connected" instead of a crash.
    if not settings.postgres_password:
        return None
    url = (
        f"postgresql+psycopg2://{settings.app_name}:{settings.postgres_password}"
        f"@{settings.postgres_host}:5432/{settings.app_name}"
    )
    return create_engine(url, pool_pre_ping=True)


def check_connection() -> bool:
    engine = _engine()
    if engine is None:
        return False
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except SQLAlchemyError:
        return False
