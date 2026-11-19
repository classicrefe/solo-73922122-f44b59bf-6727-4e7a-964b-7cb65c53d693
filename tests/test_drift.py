"""漂移核算自测：中位数/阈值、不足数据、过期窗口、回滚、交错正确性与在线可用性。

数据通过显式 created_at 注入，避免依赖“当前 UTC 日期”。
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

import psycopg
import pytest

from app import db as dbmod
from app.config import settings

D = date(2026, 11, 19)
DAY0 = datetime(2026, 11, 19, 12, tzinfo=timezone.utc)


def _insert(conn, lab, report_no, measured, created_at):
    conn.execute(
        "INSERT INTO reports(lab_no, report_no, measured, created_at) "
        "VALUES (%s,%s,%s,%s)",
        (lab, report_no, measured, created_at),
    )


def _seed_baseline_and_day(client, lab="L1", day_values=(30, 40, 50),
                           base_values=(10, 20, 30, 40)):
    """基线日 D-7..D-1 各一条；当日 D 若干条。"""
    with dbmod.pool().connection() as conn:
        for i, v in enumerate(base_values):
            _insert(conn, lab, f"B{i}", v, DAY0 - timedelta(days=7 - i))
        for i, v in enumerate(day_values):
            _insert(conn, lab, f"D{i}", v, DAY0)
        conn.commit()


def _conclusion(client, lab, d):
    r = client.get(f"/drift/conclusions/{lab}/{d.isoformat()}")
    assert r.status_code == 200, r.text
    return r.json()


# ------------------------------ 核算规则 ---------------------------------

def test_drift_median_threshold_and_persistence(client):
    _seed_baseline_and_day(client)  # 基线中位 25；当日 30,40,50 中位 40；差 15
    r = client.post("/drift/conclusions",
                    params={"lab_no": "L1", "calc_date": D.isoformat()})
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["status"] == "valid"
    assert body["current_day_median"] == 40.0
    assert body["baseline_median"] == 25.0
    assert body["drift_diff"] == 15.0
    assert body["threshold"] == 10.0
    assert body["needs_review"] is True
    assert body["is_stale"] is False
    assert body["reused"] is False

    # 已保存可查询，且默认复用未过期结论
    assert _conclusion(client, "L1", D)["needs_review"] is True
    again = client.post("/drift/conclusions",
                        params={"lab_no": "L1", "calc_date": D.isoformat()})
    assert again.status_code == 200 and again.json()["reused"] is True


def test_drift_boundary_diff_equal_to_threshold_not_flagged(client):
    _seed_baseline_and_day(client, day_values=(30, 35, 40))  # 当日中位 35，差恰好 10
    body = client.post("/drift/conclusions",
                       params={"lab_no": "L1", "calc_date": D.isoformat()}).json()
    assert body["drift_diff"] == 10.0
    assert body["needs_review"] is False


def test_drift_even_count_median_uses_continuous_percentile(client):
    # 当日偶数条：30 与 99 的连续百分位中位数为 64.5
    _seed_baseline_and_day(client, day_values=(30, 99))
    body = client.post("/drift/conclusions",
                       params={"lab_no": "L1", "calc_date": D.isoformat()}).json()
    assert body["status"] == "valid"
    assert body["current_day_median"] == 64.5


def test_drift_insufficient_data_when_either_side_empty(client):
    # 只有当日、没有基线
    with dbmod.pool().connection() as conn:
        _insert(conn, "NEWLAB", "X", 50, DAY0)
        conn.commit()
    r = client.post("/drift/conclusions",
                    params={"lab_no": "NEWLAB", "calc_date": D.isoformat()})
    assert r.status_code == 201
    body = r.json()
    assert body["status"] == "insufficient_data"
    assert body["needs_review"] is False
    assert body["drift_diff"] is None
    # 不足数据同样落库可查
    assert _conclusion(client, "NEWLAB", D)["status"] == "insufficient_data"

    # 只有基线、当日为空
    r2 = client.post("/drift/conclusions",
                     params={"lab_no": "NEWLAB",
                             "calc_date": (D + timedelta(days=1)).isoformat()})
    assert r2.json()["status"] == "insufficient_data"


def test_drift_default_date_is_today_utc(client):
    today = datetime.now(timezone.utc).date()
    r = client.post("/drift/conclusions", params={"lab_no": "L1"})
    assert r.status_code == 201
    assert r.json()["calc_date"] == today.isoformat()


def test_drift_missing_conclusion_returns_404(client):
    r = client.get(f"/drift/conclusions/L1/{D.isoformat()}")
    assert r.status_code == 404
    assert r.json()["detail"]["code"] == "conclusion_not_found"


def test_drift_listing_and_filter(client):
    _seed_baseline_and_day(client)
    client.post("/drift/conclusions", params={"lab_no": "L1", "calc_date": D.isoformat()})
    client.post("/drift/conclusions", params={"lab_no": "L2", "calc_date": D.isoformat()})
    listing = client.get("/drift/conclusions").json()
    assert listing["total"] >= 2
    only_l1 = client.get("/drift/conclusions", params={"lab_no": "L1"}).json()
    assert only_l1["total"] == 1 and only_l1["items"][0]["lab_no"] == "L1"


# ------------------------ 触发器：过期/窗口/回滚 ---------------------------

def test_writes_mark_conclusions_stale_in_same_transaction(client):
    _seed_baseline_and_day(client)
    client.post("/drift/conclusions", params={"lab_no": "L1", "calc_date": D.isoformat()})

    # API 写入（INSERT）：当日结论过期
    client.post("/reports", json={"lab_no": "L1", "report_no": "NEW", "measured": 99})
    assert _conclusion(client, "L1", D)["is_stale"] is True

    # force 重新核算恢复有效
    r = client.post("/drift/conclusions",
                    params={"lab_no": "L1", "calc_date": D.isoformat(), "force": True})
    assert r.status_code == 201 and r.json()["is_stale"] is False


def test_stale_window_is_report_date_through_plus_seven_days(client):
    _seed_baseline_and_day(client)
    client.post("/drift/conclusions", params={"lab_no": "L1", "calc_date": D.isoformat()})

    # D-7 的报告变更：D 在 [D-7, D-7+7] 窗口内 -> 过期
    with dbmod.pool().connection() as conn:
        conn.execute("UPDATE reports SET measured = measured + 1 WHERE report_no='B0'")
        conn.commit()
    assert _conclusion(client, "L1", D)["is_stale"] is True

    # 重新核算后，D-8 的插入不在任何影响 D 的窗口内 -> 不过期
    client.post("/drift/conclusions",
                params={"lab_no": "L1", "calc_date": D.isoformat(), "force": True})
    with dbmod.pool().connection() as conn:
        _insert(conn, "L1", "OUTSIDE", 1, DAY0 - timedelta(days=8))
        conn.commit()
    assert _conclusion(client, "L1", D)["is_stale"] is False


def test_lab_change_invalidates_both_old_and_new_windows(client):
    _seed_baseline_and_day(client)
    client.post("/drift/conclusions", params={"lab_no": "L1", "calc_date": D.isoformat()})
    client.post("/drift/conclusions", params={"lab_no": "L2", "calc_date": D.isoformat()})

    with dbmod.pool().connection() as conn:
        conn.execute("UPDATE reports SET lab_no='L2' WHERE report_no='D0'")
        conn.commit()

    assert _conclusion(client, "L1", D)["is_stale"] is True
    assert _conclusion(client, "L2", D)["is_stale"] is True


def test_created_at_change_invalidates_old_and_new_date_windows(client):
    _seed_baseline_and_day(client)
    # 再核算 D+1：当日为空 -> 不足数据，但同样是一条可被标过期的结论
    d_plus_1 = D + timedelta(days=1)
    client.post("/drift/conclusions", params={"lab_no": "L1", "calc_date": D.isoformat()})
    client.post("/drift/conclusions",
                params={"lab_no": "L1", "calc_date": d_plus_1.isoformat()})

    # 把一条当日报告改到 D+1：旧窗口（含 D）与新窗口（含 D+1）都要过期
    with dbmod.pool().connection() as conn:
        conn.execute(
            "UPDATE reports SET created_at = %s WHERE report_no='D1'",
            (DAY0 + timedelta(days=1),),
        )
        conn.commit()
    assert _conclusion(client, "L1", D)["is_stale"] is True
    assert _conclusion(client, "L1", d_plus_1)["is_stale"] is True


def test_standalone_sql_delete_marks_stale_and_rollback_restores(client):
    """独立 SQL（不经 API）的 DELETE 同样触发过期；ROLLBACK 后结论保持有效。"""
    _seed_baseline_and_day(client)
    client.post("/drift/conclusions", params={"lab_no": "L1", "calc_date": D.isoformat()})

    standalone = psycopg.connect(settings.database_url)
    try:
        standalone.execute("BEGIN")
        standalone.execute("DELETE FROM reports WHERE report_no='D0'")
        inside = standalone.execute(
            "SELECT is_stale FROM drift_conclusions "
            "WHERE lab_no='L1' AND calc_date=%s", (D,),
        ).fetchone()[0]
        assert inside is True
        standalone.execute("ROLLBACK")
    finally:
        standalone.close()

    # 回滚：行与过期标记一并撤销，结论仍有效
    assert _conclusion(client, "L1", D)["is_stale"] is False
    with dbmod.pool().connection() as conn:
        n = conn.execute(
            "SELECT count(*) n FROM reports WHERE report_no='D0'"
        ).fetchone()["n"]
    assert n == 1

    # 提交删除：结论过期，重新核算才能恢复
    with dbmod.pool().connection() as conn:
        conn.execute("DELETE FROM reports WHERE report_no='D1'")
        conn.commit()
    assert _conclusion(client, "L1", D)["is_stale"] is True
    client.post("/drift/conclusions",
                params={"lab_no": "L1", "calc_date": D.isoformat(), "force": True})
    assert _conclusion(client, "L1", D)["is_stale"] is False


def test_truncate_marks_all_conclusions_stale_and_rollback_restores(client):
    """TRUNCATE 不经行级触发器：语句级触发器把全部结论标过期；回滚则撤销。"""
    _seed_baseline_and_day(client)
    client.post("/drift/conclusions", params={"lab_no": "L1", "calc_date": D.isoformat()})

    standalone = psycopg.connect(settings.database_url)
    try:
        standalone.execute("BEGIN")
        standalone.execute("TRUNCATE reports")
        inside = standalone.execute(
            "SELECT is_stale FROM drift_conclusions "
            "WHERE lab_no='L1' AND calc_date=%s", (D,),
        ).fetchone()[0]
        assert inside is True
        standalone.execute("ROLLBACK")
    finally:
        standalone.close()
    assert _conclusion(client, "L1", D)["is_stale"] is False

    # 提交 TRUNCATE 后结论过期，且报告确已清空
    with dbmod.pool().connection() as conn:
        conn.execute("TRUNCATE reports")
        conn.commit()
    assert _conclusion(client, "L1", D)["is_stale"] is True
    with dbmod.pool().connection() as conn:
        assert conn.execute("SELECT count(*) n FROM reports").fetchone()["n"] == 0


def test_compute_failure_leaves_no_half_result(client):
    _seed_baseline_and_day(client)
    standalone = psycopg.connect(settings.database_url)
    try:
        standalone.execute("BEGIN")
        standalone.execute(
            "SELECT * FROM recompute_drift('L1', %s)", (D,),
        )
        assert standalone.execute(
            "SELECT count(*) FROM drift_conclusions WHERE lab_no='L1' AND calc_date=%s",
            (D,),
        ).fetchone()[0] == 1
        standalone.execute("ROLLBACK")
    finally:
        standalone.close()
    # 整份结论随回滚撤销
    r = client.get(f"/drift/conclusions/L1/{D.isoformat()}")
    assert r.status_code == 404


# ------------------------------ 交错正确性 --------------------------------

def test_advisory_lock_serializes_same_lab_but_not_other_labs(client):
    """try-lock 证明锁键按实验室互斥；不同实验室互不阻塞（在线可用性）。"""
    with dbmod.pool().connection() as conn:
        conn.execute("BEGIN")
        got = conn.execute(
            "SELECT pg_try_advisory_xact_lock(drift_advisory_key('L1')) AS ok"
        ).fetchone()["ok"]
        assert got is True
        # 另一个连接拿同实验室键失败（生产中表现为等待，而非读到旧快照后发布）
        other = psycopg.connect(settings.database_url)
        try:
            assert other.execute(
                "SELECT pg_try_advisory_xact_lock(drift_advisory_key('L1'))"
            ).fetchone()[0] is False
            # 不同实验室立即成功
            assert other.execute(
                "SELECT pg_try_advisory_xact_lock(drift_advisory_key('OTHER'))"
            ).fetchone()[0] is True
        finally:
            other.close()
        conn.execute("COMMIT")

    # 锁随事务释放后立即可用
    other = psycopg.connect(settings.database_url)
    try:
        assert other.execute(
            "SELECT pg_try_advisory_xact_lock(drift_advisory_key('L1'))"
        ).fetchone()[0] is True
        other.rollback()
    finally:
        other.close()


def test_read_committed_compute_sees_write_committed_while_lock_was_held(client):
    """确定性交错：写入未提交时核算拿不到锁；写入提交后，RC 事务内的核算语句
    取新快照，直接读到新测值（当日 30,40,50 加 99 后中位 45.0；漏读则为 40.0）。"""
    _seed_baseline_and_day(client)
    writer = psycopg.connect(settings.database_url)
    computer = psycopg.connect(settings.database_url)
    try:
        writer.execute("BEGIN")
        writer.execute(
            "INSERT INTO reports(lab_no, report_no, measured, created_at) "
            "VALUES ('L1','RACE',99,%s)",
            (DAY0 + timedelta(hours=6),),
        )
        computer.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
        # 写入未提交：核算无法获得实验室锁（生产中在此等待）
        assert computer.execute(
            "SELECT pg_try_advisory_xact_lock(drift_advisory_key('L1'))"
        ).fetchone()[0] is False
        writer.commit()  # 写入提交并释放锁
        # 锁可用后函数才执行读数：RC 新快照包含 RACE
        # 种子当日为 30,40,50，加入 99 后四条中位数 = (40+50)/2 = 45.0；
        # 若漏读 RACE，中位数只会是 40.0。
        row = computer.execute(
            "SELECT * FROM recompute_drift('L1', %s)", (D,),
        ).fetchone()
        computer.commit()
        assert row[5] == 45.0 and row[9] is False
    finally:
        writer.close()
        computer.close()


def test_earlier_conclusion_marked_stale_by_later_committed_write(client):
    """核算先提交、写入后提交：后到写入的触发器把既有有效结论标过期，
    绝不存在“漏读变更却仍有效”的结论。"""
    _seed_baseline_and_day(client)
    client.post("/drift/conclusions", params={"lab_no": "L1", "calc_date": D.isoformat()})
    with dbmod.pool().connection() as conn:
        _insert(conn, "L1", "LATE", 99, DAY0 + timedelta(hours=8))
        conn.commit()
    assert _conclusion(client, "L1", D)["is_stale"] is True


# ------------------------------ 在线可用性 --------------------------------

def test_backfill_and_drift_coexist_with_concurrent_index_build(client):
    """漂移触发器/核算与 CREATE UNIQUE INDEX CONCURRENTLY 同时工作，补录不阻塞。"""
    import time

    from conftest import poll_status

    _seed_baseline_and_day(client)
    blocker = psycopg.connect(settings.database_url)
    blocker.execute("BEGIN")
    blocker.execute(
        "INSERT INTO reports(lab_no, report_no, measured) VALUES ('HOLD','X',0)"
    )
    try:
        client.post("/index/build")
        time.sleep(2)
        # 构建等待长事务期间：补录立即成功，漂移核算同样立即完成（不同实验室无锁冲突）
        r = client.post("/reports",
                        json={"lab_no": "L1", "report_no": "ONLINE", "measured": 77})
        assert r.status_code == 201
        drift_r = client.post("/drift/conclusions",
                              params={"lab_no": "L1", "calc_date": D.isoformat()})
        assert drift_r.status_code in (200, 201)
    finally:
        blocker.rollback()
        blocker.close()
    poll_status(client, "complete")
    # 唯一索引生效：先插入一行，再重复同键被 409 拒绝（blocker 行已随其回滚撤销）
    first = client.post("/reports",
                        json={"lab_no": "HOLD", "report_no": "X", "measured": 1})
    assert first.status_code == 201
    dup = client.post("/reports",
                      json={"lab_no": "HOLD", "report_no": "X", "measured": 2})
    assert dup.status_code == 409
    # 漂移功能在唯一索引环境下照常工作
    again = client.post("/drift/conclusions",
                        params={"lab_no": "L1", "calc_date": D.isoformat(), "force": True})
    assert again.status_code == 201 and again.json()["is_stale"] is False
