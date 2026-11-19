-- ============================================================
-- 去重脚本：CREATE UNIQUE INDEX CONCURRENTLY 因重复键失败后使用。
-- 仅排查/清理 (lab_no, report_no) 重复，保留每组最早入仓的一条（id 最小）。
-- 去重后可重新通过 API 发起构建。
-- ============================================================

-- 1) 先查看有哪些重复键及重复条数（只读，安全）。
SELECT lab_no, report_no, count(*) AS dup_rows,
       min(id) AS keep_id, array_agg(id ORDER BY id) AS all_ids
FROM   reports
GROUP  BY lab_no, report_no
HAVING count(*) > 1
ORDER  BY dup_rows DESC, lab_no, report_no;

-- 2) 确认后删除重复行（保留 id 最小的原始记录，其余原样删除；可先包在事务里核对）。
BEGIN;

DELETE FROM reports r
USING (
    SELECT id,
           row_number() OVER (PARTITION BY lab_no, report_no ORDER BY id) AS rn
    FROM   reports
) d
WHERE r.id = d.id
  AND d.rn > 1;

-- 3) 事务内复核：应返回 0 行。
SELECT lab_no, report_no, count(*)
FROM   reports
GROUP  BY lab_no, report_no
HAVING count(*) > 1;

COMMIT;   -- 核对无误再提交；如有疑问执行 ROLLBACK;
