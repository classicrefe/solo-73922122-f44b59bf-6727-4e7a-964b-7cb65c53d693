-- ============================================================
-- 独立 SQL 补录示例（可直接在 psql / 调度器中执行，不依赖 API）
-- 目标表：reports(id 流水号主键, lab_no 实验室号, report_no 报告号, measured 整数测值)
-- ============================================================

-- 方式一：单条补录。唯一索引建成后，重复 (lab_no, report_no) 将被数据库拒绝，
-- 且整条语句回滚，已有数据原样保留。
INSERT INTO reports (lab_no, report_no, measured)
VALUES ('LAB-001', 'RPT-2026-0001', 1024);

-- 方式二：批量补录（来自临时/外部表，示例用 VALUES）。
-- ON CONFLICT DO NOTHING 在唯一索引建成后自动跳过重复行；
-- 在唯一索引尚未建成时它同样合法、不影响执行，便于索引构建前后使用同一套脚本。
INSERT INTO reports (lab_no, report_no, measured)
VALUES
    ('LAB-001', 'RPT-2026-0002', 1025),
    ('LAB-001', 'RPT-2026-0003', 1026),
    ('LAB-002', 'RPT-2026-0001', 2048)
ON CONFLICT DO NOTHING;

-- 方式三：从外部补录表整批装载（数仓常用形态）。
-- 假设外部表 stg_reports(lab_no, report_no, measured) 已由数据装载流程建好。
INSERT INTO reports (lab_no, report_no, measured)
SELECT s.lab_no, s.report_no, s.measured
FROM   stg_reports s
ON CONFLICT DO NOTHING;
