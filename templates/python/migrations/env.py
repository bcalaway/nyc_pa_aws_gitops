"""Alembic environment: points migrations at the app's own database and models."""

from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine

from app.db import database_url
from app.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def _url() -> str:
    url = database_url()
    if not url:
        raise SystemExit(
            "No database configured: set POSTGRES_PASSWORD (and APP_NAME), or DATABASE_URL, "
            "before running Alembic."
        )
    return url


def run_migrations_offline() -> None:
    context.configure(url=_url(), target_metadata=target_metadata, literal_binds=True, compare_type=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = create_engine(_url())
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
