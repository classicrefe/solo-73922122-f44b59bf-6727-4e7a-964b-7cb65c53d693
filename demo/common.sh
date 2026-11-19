#!/usr/bin/env bash
# 演示公共配置。用法：source ./common.sh
set -euo pipefail

API_BASE="${API_BASE:-http://127.0.0.1:8000}"
# psql 连接串：本地自测指向 pgserver 实例；Docker 环境可在外部覆盖。
PSQL_URL="${PSQL_URL:-postgresql://postgres@127.0.0.1:55432/demo_api}"
# 自动探测 psql：优先 PATH，其次 pgserver 自带二进制。
if ! command -v psql >/dev/null 2>&1; then
  PGBIN_GUESS="$(python3 -c 'import pgserver,pathlib;print(pathlib.Path(pgserver.__file__).parent/"pginstall"/"bin"/"psql")' 2>/dev/null || true)"
  if [[ -n "$PGBIN_GUESS" && -x "$PGBIN_GUESS" ]]; then
    PSQL_BIN="$PGBIN_GUESS"
  else
    PSQL_BIN="psql"
  fi
else
  PSQL_BIN="psql"
fi
PSQL=("$PSQL_BIN" "$PSQL_URL" -v ON_ERROR_STOP=1)

c() { curl -sS -H 'Content-Type: application/json' "$@"; echo; }

wait_status() {
  # wait_status <期望 status> [最大秒数]
  local want="$1" timeout_s="${2:-60}" i=0 st
  while (( i < timeout_s )); do
    st="$(curl -sS "$API_BASE/index/status" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))')"
    [[ "$st" == "$want" ]] && return 0
    sleep 1; i=$((i+1))
  done
  echo "TIMEOUT waiting for status=$want, last=$st" >&2
  return 1
}

psql_exec() { "${PSQL[@]}" "$@"; }
