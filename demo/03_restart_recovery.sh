#!/usr/bin/env bash
# 演示 3：API 重启后接续跟踪仍在运行的构建，不重跑、不把无效索引报成功。
#
# 本脚本直接在本地以 uvicorn 启动 API（Docker 环境可用
# `docker compose restart api` 达到同等效果）。
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh

export DATABASE_URL="${DATABASE_URL:-postgresql://postgres@127.0.0.1:55432/demo_api}"
API_HOST_PORT="${API_HOST_PORT:-127.0.0.1:8000}"
HOST="$(echo "$API_HOST_PORT" | cut -d: -f1)"
PORT="$(echo "$API_HOST_PORT" | cut -d: -f2)"
# 重启后的新实例端口（沙箱禁止信号、无法停旧实例时尤其需要换端口；
# Docker 中可固定同端口，这里换端口不影响验证：两个实例连的是同一个 PostgreSQL）。
RESTART_PORT="${RESTART_PORT:-$((PORT + 1))}"
UVICORN_LOG=/tmp/demo_api_uvicorn.log
SIG_DIR="$(mktemp -d)"
API_PID_FILE=/tmp/demo_api.pid

start_api() {
  local use_port="${1:-$PORT}"
  # </dev/null 与全量重定向，避免后台 uvicorn 继承演示脚本的管道 fd
  # （否则外层 `| tail/grep` 会因服务长期运行而永远等不到 EOF）。
  ( cd .. && DATABASE_URL="$DATABASE_URL" nohup python3 -m uvicorn app.main:app \
      --host "$HOST" --port "$use_port" >> "$UVICORN_LOG" 2>&1 </dev/null &
    echo $! > "$API_PID_FILE"; disown || true )
  for _ in $(seq 1 30); do curl -sS "http://$HOST:$use_port/health" >/dev/null 2>&1 && break; sleep 1; done
}
stop_api() {
  # 优先用 PID 文件优雅停止；受限环境若禁止信号则跳过（新实例换端口启动）。
  if [[ -f "$API_PID_FILE" ]]; then
    kill "$(cat "$API_PID_FILE")" 2>/dev/null || true
  fi
  for _ in $(seq 1 6); do
    if ! curl -sS "$API_BASE/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
}

echo "== 1. 清理并准备无重复数据 =="
psql_exec -c "DROP INDEX IF EXISTS uq_reports_lab_no_report_no;" \
          -c "TRUNCATE reports RESTART IDENTITY;" \
          -c "DELETE FROM index_build_rounds;" >/dev/null
psql_exec -c "INSERT INTO reports(lab_no,report_no,measured)
              SELECT 'LAB','R-'||g, g FROM generate_series(1,50) g;"
: > "$UVICORN_LOG"

echo "== 2. 启动 API 进程 =="
start_api
c "$API_BASE/health"

echo "== 3. 用独立助手进程开长事务（未提交写）拖住构建，再发起 =="
python3 ./long_tx_holder.py "$PSQL_URL" "$SIG_DIR" write 2>/tmp/demo_longtx.log </dev/null &
HOLDER_PID=$!
for _ in $(seq 1 20); do [[ -f "$SIG_DIR/pid" ]] && break; sleep 0.3; done
LONG_PID="$(cat "$SIG_DIR/pid")"
echo "长事务后端 PID = $LONG_PID（holder 进程 $HOLDER_PID）"
c -X POST "$API_BASE/index/build" >/dev/null
sleep 3
FIRST_ROUND="$(c "$API_BASE/index/status")"
echo "$FIRST_ROUND" | python3 -m json.tool
FIRST_PID="$(echo "$FIRST_ROUND" | python3 -c 'import sys,json;print(json.load(sys.stdin)["backend_pid"])')"

echo "== 4. 重启 API（PostgreSQL 中的构建 SQL 不受影响；新实例端口 $RESTART_PORT） =="
stop_api
start_api "$RESTART_PORT"
API_BASE="http://$HOST:$RESTART_PORT"
echo "重启后访问：$API_BASE"

echo "== 5. 重启后查询：同一 round、同一 backend_pid、restarted=true、状态仍为 running =="
c "$API_BASE/index/status" | python3 -m json.tool
c "$API_BASE/index/status" | python3 -c '
import sys, json
s = json.load(sys.stdin)
assert s["backend_pid"] == '"$FIRST_PID"', "backend pid changed after restart!"
assert s["restarted"] is True and s["status"] == "running"
print("OK: 重启后复用同一后端，未重跑")'

echo "== 6. 提交长事务，接续的 watcher 跟踪到 complete（全程未重跑 CREATE INDEX） =="
touch "$SIG_DIR/commit"
wait $HOLDER_PID || true
wait_status complete 60
c "$API_BASE/index/status" | python3 -m json.tool
psql_exec -c "SELECT relname, indisunique, indisvalid FROM pg_index i
              JOIN pg_class c ON c.oid=i.indexrelid
              WHERE relname='uq_reports_lab_no_report_no';"
grep -c "attaching watcher" "$UVICORN_LOG" | sed 's/^/重启接续日志次数: /'
echo "DEMO-3 OK"
