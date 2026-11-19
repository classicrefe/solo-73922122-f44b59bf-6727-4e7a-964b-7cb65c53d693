#!/usr/bin/env bash
# 演示 4：取消语义。
#   1) 构建受理取消后先返回 202（cancel_requested），后端 SQL 真正停止后才 cancelled；
#   2) 只针对记录在案的构建后端 PID，补录连接不受影响；
#   3) 索引已有效时取消请求直接报 complete，不删除有效索引；
#   4) 无效残留索引被安全清理（绝不删除有效索引）。
#
# 环境说明：本沙箱 seccomp 禁止一切跨进程信号，pg_cancel_backend 无法中止后端。
# 因此脚本同时展示两条路径：
#   A. 对存活构建发起取消 -> 始终先受理（cancel_requested）；若信号不生效而索引
#      最终建成，系统如实报 complete 且保留有效索引（不会误报取消、不会误删索引）。
#   B. 用一次必然失败的 CIC（重复键）合成“后端已停止 + 无效索引 + cancel_requested”，
#      展示 watcher/对账确认 SQL 停止后才裁决 cancelled 并清理残留。
#   在标准 Docker 环境中，pg_cancel_backend 可正常中止 A 中的等待后端，直接得到
#   cancelled，路径与 B 的裁决/清理完全相同。
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

echo "== 1. 清理并准备数据 =="
psql_exec -c "DROP INDEX IF EXISTS uq_reports_lab_no_report_no;" \
          -c "TRUNCATE reports RESTART IDENTITY;" \
          -c "DELETE FROM index_build_rounds;" >/dev/null
psql_exec -c "INSERT INTO reports(lab_no,report_no,measured)
              SELECT 'LAB','R-'||g, g FROM generate_series(1,20) g;"

echo "== 2. 开长事务（未提交写）拖住构建并发起 =="
SIG_DIR="$(mktemp -d)"
python3 ./long_tx_holder.py "$PSQL_URL" "$SIG_DIR" write 2>/tmp/demo_longtx4.log </dev/null &
HOLDER_PID=$!
for _ in $(seq 1 20); do [[ -f "$SIG_DIR/pid" ]] && break; sleep 0.3; done
BUILD="$(c -X POST "$API_BASE/index/build")"
echo "$BUILD" | python3 -m json.tool
BUILD_PID="$(echo "$BUILD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["backend_pid"])')"
for _ in $(seq 1 20); do
  BP="$(c "$API_BASE/index/status" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("backend_pid") or "")')"
  [[ -n "$BP" ]] && break; sleep 0.3
done
BUILD_PID="$(c "$API_BASE/index/status" | python3 -c 'import sys,json;print(json.load(sys.stdin)["backend_pid"])')"
echo "构建后端 PID = $BUILD_PID"

echo "== 3. 发起一个补录连接并保留会话（验证取消不会误伤它） =="
BF_SIG="$(mktemp -d)"
python3 - "$PSQL_URL" "$BF_SIG" <<'PY' &
import sys, time, pathlib, psycopg
dsn, sig = sys.argv[1], pathlib.Path(sys.argv[2]); sig.mkdir(parents=True, exist_ok=True)
conn = psycopg.connect(dsn); conn.execute("BEGIN")
conn.execute("INSERT INTO reports(lab_no,report_no,measured) VALUES ('LAB-X','BF-1',77)")
pid = conn.execute("SELECT pg_backend_pid()").fetchone()[0]
(sig / "pid").write_text(str(pid))
deadline = time.time() + 120
while time.time() < deadline and not (sig / "commit").exists():
    time.sleep(0.2)
conn.commit(); conn.close()
PY
BF_HOLDER=$!
for _ in $(seq 1 20); do [[ -f "$BF_SIG/pid" ]] && break; sleep 0.3; doneBACKFILL_PID="$(cat "$BF_SIG/pid")"
echo "补录事务 PID = $BACKFILL_PID（取消后应依然存活）"

echo "== 4. 取消：先得到 202 cancel_requested（绝不提前报 cancelled） =="
c -X POST "$API_BASE/index/cancel" | python3 -m json.tool
c "$API_BASE/index/status" | python3 -c '
import sys, json
s = json.load(sys.stdin)
assert s["status"] == "cancel_requested", s
print("OK: 取消已受理，状态仍为 cancel_requested，尚未误报取消")'

echo "== 5. 补录事务仍然存活（未误停补录） =="
psql_exec -tA -c "SELECT count(*) AS backfill_alive FROM pg_stat_activity WHERE pid=$BACKFILL_PID;"
touch "$BF_SIG/commit"; wait "$BF_HOLDER" || true
psql_exec -c "SELECT * FROM reports WHERE lab_no='LAB-X';"

echo "== 6. 提交长事务：信号生效则 cancelled；信号被沙箱拒绝则如实 complete 且保留索引 =="
touch "$SIG_DIR/commit"; wait "$HOLDER_PID" || true
# 等待终局（cancelled 或 complete 都算正确，取决于环境是否允许信号）
for i in $(seq 1 40); do
  ST="$(c "$API_BASE/index/status" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
  [[ "$ST" == "cancelled" || "$ST" == "complete" ]] && break
  sleep 1
done
c "$API_BASE/index/status" | python3 -m json.tool
case "$ST" in
  cancelled) echo "本环境支持信号：后端 SQL 已确认停止，裁决 cancelled" ;;
  complete)  echo "本沙箱禁止信号：取消未中止后端，索引建成后如实报 complete（有效索引保留）" ;;
esac

echo "== 7. 合成“后端已停止 + 无效索引 + cancel_requested”，演示确认停止后才 cancelled 并清理 =="
psql_exec -c "DROP INDEX IF EXISTS uq_reports_lab_no_report_no;" \
          -c "TRUNCATE reports RESTART IDENTITY;" \
          -c "DELETE FROM index_build_rounds;" >/dev/null
psql_exec -c "INSERT INTO reports(lab_no,report_no,measured) VALUES ('D','K',1),('D','K',2);"
# 必然失败的 CIC：留下无效索引，后端随即结束。
"$PSQL_BIN" "$PSQL_URL" -v ON_ERROR_STOP=0 -c \
  'CREATE UNIQUE INDEX CONCURRENTLY uq_reports_lab_no_report_no ON reports (lab_no, report_no);' >/dev/null 2>&1 || true
psql_exec -c "SELECT relname, indisvalid FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
              WHERE relname='uq_reports_lab_no_report_no';"
psql_exec -c "INSERT INTO index_build_rounds(round_id,status,index_name,backend_pid)
              VALUES (gen_random_uuid(),'cancel_requested','uq_reports_lab_no_report_no',999999);"
# 触发一次启动对账（生产中即 API 重启）：确认后端不在 -> cancelled，并后台清理无效索引。
( cd .. && DATABASE_URL="$PSQL_URL" python3 -c "
from app import db
db.init_pool()
from app.service import service
service.reconcile_on_startup()" )
for i in $(seq 1 30); do
  ST="$(c "$API_BASE/index/status" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
  [[ "$ST" == "cancelled" ]] && break; sleep 1
done
c "$API_BASE/index/status" | python3 -c '
import sys, json
s = json.load(sys.stdin)
assert s["status"] == "cancelled" and s["failure_type"] == "cancelled", s
print("OK: 确认 SQL 停止后才裁决 cancelled")'
for i in $(seq 1 30); do
  N="$(psql_exec -tA -c "SELECT count(*) FROM pg_class WHERE relname='uq_reports_lab_no_report_no';")"
  [[ "$N" == "0" ]] && break; sleep 1
done
psql_exec -c "SELECT count(*) AS leftover_index_count FROM pg_class WHERE relname='uq_reports_lab_no_report_no';"
echo "DEMO-4 OK"
