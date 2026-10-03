"""Migrations run cleanly, and the models and migrations agree.

Runs against a throwaway SQLite file so it needs no Postgres; the template's
CI in nyc_pa_aws_gitops also runs `alembic upgrade head` against a real
Postgres 16 container.
"""

from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect

from app import db
from app.config import Settings

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def alembic_cfg(tmp_path, monkeypatch):
    url = f"sqlite:///{tmp_path / 'migrations.db'}"
    monkeypatch.setattr(db, "settings", Settings(database_url=url))
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.attributes["url"] = url
    return cfg


def _tables(cfg):
    return set(inspect(create_engine(cfg.attributes["url"])).get_table_names())


def test_upgrade_then_downgrade(alembic_cfg):
    command.upgrade(alembic_cfg, "head")
    assert "items" in _tables(alembic_cfg)
    command.downgrade(alembic_cfg, "base")
    assert "items" not in _tables(alembic_cfg)


def test_models_match_migrations(alembic_cfg):
    # Fails when a model changed without a matching migration -- the mistake
    # that broke todo-app's /api/todos in production once (docs/app-platform.md).
    command.upgrade(alembic_cfg, "head")
    command.check(alembic_cfg)
