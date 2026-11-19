-- ============================================================
-- 漂移核算独立 SQL（不依赖 API 即可执行）
--
-- 前提：01_schema.sql 已执行（表、recompute_drift 函数、reports 触发器均已就位）。
-- 核算规则与 API 完全一致，且使用同一套数据库对象：
--   * 两侧中位数取自同一事务快照（同一已提交视图）；
--   * 任一侧无报告 -> insufficient_data；
--   * |当日中位数 - 基线中位数| > 10 -> needs_review = TRUE；
--   * 结论写入 drift_conclusions，供 API/SQL 查询；
--   * reports 的任何增改删由触发器在同一事务内把窗口内旧结论标为过期；
--   * 函数先取本实验室事务级咨询锁，与补录写入串行但不阻塞其它实验室，
--     也不与 CREATE INDEX CONCURRENTLY 冲突。
-- ============================================================

-- 1) 核算单个（实验室, UTC 日期）。
SELECT recompute_drift('LAB-001', DATE '2026-11-19');

-- 2) 查看某实验室某日结论（过期的结论 is_stale=TRUE，重新核算后恢复 FALSE）。
SELECT lab_no, calc_date, status, needs_review,
       current_day_median, baseline_median, drift_diff,
       is_stale, computed_at
FROM   drift_conclusions
WHERE  lab_no = 'LAB-001' AND calc_date = DATE '2026-11-19';

-- 3) 批量重算某实验室若干 UTC 日期（在各自的函数事务/同一调用事务内完成，
--    单条失败不会留下半份结论——upsert 与读数在同一事务里整体回滚）。
WITH days(d) AS (
    SELECT generate_series(DATE '2026-11-13', DATE '2026-11-19', INTERVAL '1 day')::date
)
SELECT (recompute_drift('LAB-001', d)).*
FROM   days;

-- 4) 对已经在线上跑的大表补建范围扫描索引（不会阻塞补录，也不阻塞触发器/核算）。
--    全新环境由 01_schema.sql 直接 CREATE INDEX，无需执行本句。
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_reports_lab_created_at
    ON reports (lab_no, created_at);

-- 5) 写操作示例：触发器自动把受影响日期（created_at 的 UTC 日）及其后七日
--    同实验室结论标为过期；ROLLBACK 时过期标记随事务一并撤销，结论保持不变。
BEGIN;
UPDATE reports
SET    measured = measured + 1,
       lab_no   = 'LAB-002',                         -- 改实验室号：旧、新两个窗口都会被标过期
       created_at = created_at + INTERVAL '2 hours'  -- 改创建时间：旧、新两个日期窗口都会被标过期
WHERE  id = 123;
-- 核对受影响结论后：COMMIT 保留过期标记；ROLLBACK 则结论原样不变。
COMMIT;
