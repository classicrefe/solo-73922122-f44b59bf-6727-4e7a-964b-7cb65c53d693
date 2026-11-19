#!/usr/bin/env bash
# 演示 2：重复键导致构建失败 -> 原数据保留、无效索引被安全清理 -> 去重后重试成功。
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

echo "== 1. 清理并制造重复 (lab_no, report_no) 数据 =="
psql_exec -c "DROP INDEX IF EXISTS uq_reports_lab_no_report_no;" \
          -c "TRUNCATE reports RESTART IDENTITY;" \
          -c "DELETE FROM index_build_rounds;" >/dev/null
psql_exec -c "
INSERT INTO reports(lab_no, report_no, measured) VALUES
 ('LAB-001','DUP-1',1),('LAB-001','DUP-1',2),
 ('LAB-001','DUP-2',3),('LAB-002','DUP-1',4);"
BEFORE="$(psql_exec -tA -c 'SELECT count(*) FROM reports;')"
echo "构建前 reports 行数 = $BEFORE"

echo "== 2. 发起构建，预期失败（duplicate_key） =="
c -X POST "$API_BASE/index/build" >/dev/null
wait_status failed 30
c "$API_BASE/index/status" | python3 -m json.tool

echo "== 3. 核对：原数据一行未少；残留索引已清理（查不到该索引） =="
AFTER="$(psql_exec -tA -c 'SELECT count(*) FROM reports;')"
echo "失败后 reports 行数 = $AFTER （应等于 $BEFORE）"
[[ "$BEFORE" == "$AFTER" ]] || { echo "DATA LOST!"; exit 1; }
psql_exec -c "SELECT count(*) AS leftover_index_count FROM pg_class WHERE relname='uq_reports_lab_no_report_no';"

echo "== 4. 去重：保留每组 id 最小的一条 =="
psql_exec -c "
DELETE FROM reports r USING (
  SELECT id, row_number() OVER (PARTITION BY lab_no, report_no ORDER BY id) rn FROM reports
) d WHERE r.id=d.id AND d.rn>1;"
psql_exec -c "SELECT lab_no, report_no, count(*) FROM reports GROUP BY 1,2 HAVING count(*)>1;"

echo "== 5. 重新发起构建，预期 complete；之后补录重复键被 409 拒绝 =="
c -X POST "$API_BASE/index/build" >/dev/null
wait_status complete 30
c -X POST "$API_BASE/reports" -d '{"lab_no":"LAB-001","report_no":"DUP-1","measured":999}' || true
psql_exec -c "SELECT count(*) AS rows_after_retry FROM reports;"
echo "DEMO-2 OK"
