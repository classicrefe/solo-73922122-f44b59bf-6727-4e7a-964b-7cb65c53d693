"""测试夹具：指向本地 PostgreSQL（环境变量 DATABASE_URL），每轮测试清库。"""
from __future__ import annotations

import os
import time
import uuid

import httpx
import psycopg
import pytest
from a2wsgi import ASGIMiddleware

from app import db as dbmod
from app.config import settings
from app.main import app
from app.service import service


@pytest.fixture(scope="session")
def anyio_backend():
    return "asyncio"


def _fresh_database() -> str:
    """在本地 PG 中为本次测试创建独立 database，返回连接串。"""
    base_url = os.getenv("DATABASE_URL", "postgresql://postgres@127.0.0.1:55432/postgres")
    # 解析出管理库连接串，替换 dbname。
    test_db = f"test_{uuid.uuid4().hex[:12]}"
    with psycopg.connect(base_url, autocommit=True) as admin:
        admin.execute(f'DROP DATABASE IF EXISTS {test_db}')
        admin.execute(f'CREATE DATABASE {test_db}')
    # 替换连接串中的库名。
    if "/" in base_url.split("//", 1)[1]:
        prefix, _old = base_url.rsplit("/", 1)
        return f"{prefix}/{test_db}"
    return f"{base_url}/{test_db}"


@pytest.fixture()
def client(monkeypatch):
    test_url = _fresh_database()
    monkeypatch.setenv("DATABASE_URL", test_url)
    # settings 是 frozen dataclass，直接改对象属性。
    object.__setattr__(settings, "database_url", test_url)
    dbmod.close_pool()
    dbmod.init_pool()
    dbmod.ensure_schema()
    # 复位服务内线程状态。
    with service._lock:
        service._thread = None
        service._watching_round_id = None

    # httpx 0.28 的 ASGITransport 仅支持异步；用 WSGI 适配在同步测试中驱动 ASGI 应用。
    c = httpx.Client(transport=httpx.WSGITransport(app=ASGIMiddleware(app)),
                     base_url="http://test")
    # 手动触发 startup（ASGITransport 不跑 lifespan）。
    service.reconcile_on_startup()
    yield c
    c.close()
    dbmod.close_pool()


def poll_status(client: httpx.Client, want: str, timeout_s: float = 45) -> dict:
    deadline = time.time() + timeout_s
    last = {}
    while time.time() < deadline:
        last = client.get("/index/status").json()
        if last.get("status") == want:
            return last
        time.sleep(0.5)
    raise AssertionError(f"status never reached {want}; last={last}")
