"""漂移核算服务：当日中位数 vs 此前七个 UTC 日中位数。

并发正确性由数据库侧机制保证（见 sql/01_schema.sql 中的 recompute_drift 与触发器）：

1. recompute_drift 在任何数据读取之前，先获取本实验室的事务级咨询锁；
   reports 写触发器争用同一把锁，核算与同实验室写入因此严格串行，
   但不同实验室互不阻塞，也不持表锁——补录与 CREATE INDEX CONCURRENTLY 保持可用；
2. 调用方使用 READ COMMITTED：事务开始时若锁被占用则等待，锁到手后函数内
   两条中位数查询都按已提交最新数据取快照（等价于同一已提交视图），
   不会发布“漏读此前已提交变更却仍有效”的结论；
   持锁期间发生的同实验室写入会阻塞到核算提交，然后由触发器把该结论标为过期；
3. 整个核算（读数 + upsert 结论）在单个事务内完成，任何失败整体回滚，
   不会留下半份结果；触发器对死锁做了固定顺序加锁，应用层对 40P01 做有限重试。

写报告（含改实验室号/测值/创建时间、删除）对结论的过期标记完全由数据库
触发器在写事务内完成：API 与独立 SQL 一视同仁，写事务回滚则标记一并撤销。
"""
from __future__ import annotations

import logging
from datetime import date, datetime, timezone
from typing import Any

import psycopg
from fastapi import HTTPException, status

from . import db

log = logging.getLogger("drift")

# 40P01 = deadlock_detected：触发器已按固定顺序加锁，理论上不应发生；仍兜底重试。
_MAX_ATTEMPTS = 3


def _today_utc() -> date:
    return datetime.now(timezone.utc).date()


def _to_view(row: dict[str, Any], reused: bool = False) -> dict[str, Any]:
    return {
        "id": row["id"],
        "lab_no": row["lab_no"],
        "calc_date": row["calc_date"],
        "status": row["status"],
        "needs_review": row["needs_review"],
        "current_day_median": row["current_day_median"],
        "baseline_median": row["baseline_median"],
        "drift_diff": row["drift_diff"],
        "threshold": row["threshold"],
        "is_stale": row["is_stale"],
        "computed_at": row["computed_at"],
        "reused": reused,
    }


def get_conclusion(lab_no: str, calc_date: date) -> dict[str, Any] | None:
    """读取已保存结论；从未核算过返回 None。"""
    with db.pool().connection() as conn:
        row = conn.execute(
            "SELECT * FROM drift_conclusions WHERE lab_no = %s AND calc_date = %s",
            (lab_no, calc_date),
        ).fetchone()
    return dict(row) if row else None


def list_conclusions(lab_no: str | None, limit: int, offset: int) -> dict[str, Any]:
    with db.pool().connection() as conn:
        if lab_no is not None:
            rows = conn.execute(
                "SELECT * FROM drift_conclusions WHERE lab_no = %s "
                "ORDER BY calc_date DESC, id DESC LIMIT %s OFFSET %s",
                (lab_no, limit, offset),
            ).fetchall()
            total = conn.execute(
                "SELECT count(*) AS n FROM drift_conclusions WHERE lab_no = %s",
                (lab_no,),
            ).fetchone()["n"]
        else:
            rows = conn.execute(
                "SELECT * FROM drift_conclusions "
                "ORDER BY calc_date DESC, id DESC LIMIT %s OFFSET %s",
                (limit, offset),
            ).fetchall()
            total = conn.execute(
                "SELECT count(*) AS n FROM drift_conclusions"
            ).fetchone()["n"]
    return {"total": total, "items": [_to_view(dict(r)) for r in rows]}


def compute_drift(lab_no: str, calc_date: date | None = None,
                  force: bool = False) -> tuple[dict[str, Any], int]:
    """核算并保存结论。

    * force=False（默认）：已存在且未过期的结论直接复用（reused=true，HTTP 200）；
    * force=True 或结论缺失/已过期：重新核算（HTTP 201）；
    * 任一侧无报告：status=insufficient_data，同样落库，可被后续查询与过期标记覆盖。

    整个核算在单个 READ COMMITTED 事务内完成（函数内部先取实验室咨询锁）；
    死锁按幂等函数安全重试，重试耗尽不写入任何结论。
    """
    calc_date = calc_date or _today_utc()

    if not force:
        existing = get_conclusion(lab_no, calc_date)
        if existing is not None and not existing["is_stale"]:
            return _to_view(existing, reused=True), 200

    last_exc: Exception | None = None
    for attempt in range(1, _MAX_ATTEMPTS + 1):
        try:
            with db.pool().connection() as conn:
                # READ COMMITTED：函数在内部先取咨询锁，等锁结束后按最新已提交
                # 数据取快照；读数与 upsert 在同一事务，失败整体回滚。
                # 显式设置而非依赖默认值，池内复用也无副作用（值相同）。
                conn.isolation_level = psycopg.IsolationLevel.READ_COMMITTED
                with conn.transaction():
                    row = conn.execute(
                        "SELECT * FROM recompute_drift(%s, %s)",
                        (lab_no, calc_date),
                    ).fetchone()
                conn.commit()
            return _to_view(dict(row), reused=False), 201
        except psycopg.errors.DeadlockDetected as exc:
            # 触发器已固定加锁顺序，正常不会到达；到达时按幂等函数安全重试。
            last_exc = exc
            log.warning(
                "drift recompute for lab=%s date=%s deadlock (attempt %d/%d), retrying",
                lab_no, calc_date, attempt, _MAX_ATTEMPTS,
            )
            continue

    # 重试耗尽：不写入任何东西（事务均已回滚），如实上报 409 交由调用方稍后重试。
    log.error("drift recompute for lab=%s date=%s failed after %d attempts: %s",
              lab_no, calc_date, _MAX_ATTEMPTS, last_exc)
    raise HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail={
            "code": "drift_recompute_busy",
            "message": "核算遇到数据库死锁且重试耗尽，本次未写入任何结论，请稍后重新发起",
            "pg_sqlstate": getattr(last_exc, "sqlstate", None),
            "pg_error": str(last_exc).strip() if last_exc else None,
        },
    )
