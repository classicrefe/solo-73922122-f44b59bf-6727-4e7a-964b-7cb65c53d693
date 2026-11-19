#!/usr/bin/env bash
# 演示 1：长事务拖慢 CONCURRENTLY 构建，且构建期间补录照常提交。
#
# 背景：CREATE INDEX CONCURRENTLY 需要等待所有可能修改旧快照的事务结束。
# 本脚本先开启一个持有 reports 表旧快照的长事务，再发起构建，
# 可观察到构建处于 running（等待快照），期间补录 INSERT 立即成功；
# 长事务提交后构建自动完成。
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

echo "== 1. 清理环境，补录两条基线数据 =="
psql_exec -c "DROP INDEX IF EXISTS uq_reports_lab_no_report_no;" \
          -c "TRUNCATE reports RESTART IDENTITY;" \
          -c "DELETE FROM index_build_rounds;" >/dev/null
c -X POST "$API_BASE/reports" -d '{"lab_no":"LAB-001","report_no":"R-1","measured":10}'
c -X POST "$API_BASE/reports" -d '{"lab_no":"LAB-001","report_no":"R-2","measured":20}'

echo "== 2. 用独立助手进程开启长事务（BEGIN + 未提交写，持有 reports 旧快照） =="
SIG_DIR="$(mktemp -d)"
python3 ./long_tx_holder.py "$PSQL_URL" "$SIG_DIR" write 2>/tmp/demo_longtx.log </dev/null &
HOLDER_PID=$!
for _ in $(seq 1 20); do [[ -f "$SIG_DIR/pid" ]] && break; sleep 0.3; done
LONG_PID="$(cat "$SIG_DIR/pid")"
echo "长事务后端 PID = $LONG_PID（holder 进程 $HOLDER_PID）"

echo "== 3. 发起 CREATE UNIQUE INDEX CONCURRENTLY（将被长事务拖住） =="
c -X POST "$API_BASE/index/build"
sleep 3
echo "-- 构建状态（应为 running，等待中）："
c "$API_BASE/index/status"

echo "== 4. 构建期间补录：必须立即成功，不被阻塞 =="
c -X POST "$API_BASE/reports" -d '{"lab_no":"LAB-002","report_no":"R-9","measured":99}'
psql_exec -c "SELECT count(*) AS rows_during_build FROM reports;"

echo "== 5. 提交长事务，构建应在数秒内自动完成 =="
touch "$SIG_DIR/commit"
wait "$HOLDER_PID" || true
wait_status complete 60
c "$API_BASE/index/status" | python3 -m json.tool

echo "== 6. 验证索引真实有效 =="
psql_exec -c "SELECT relname, indisunique, indisvalid, indisready
              FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
              WHERE relname='uq_reports_lab_no_report_no';"
echo "DEMO-1 OK"
