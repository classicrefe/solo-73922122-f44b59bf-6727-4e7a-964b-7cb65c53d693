#!/usr/bin/env python3
"""演示用长事务持有器。

用法：
  python3 long_tx_holder.py <DATABASE_URL> <信号目录> <模式:write|read>

行为：
  1. 打开连接并 BEGIN；write 模式执行一条未提交 INSERT（能阻塞 CIC），
     read 模式仅 SELECT 持有快照；
  2. 把后端 PID 写入 <信号目录>/pid；
  3. 等待 <信号目录>/commit 或 <信号目录>/rollback 文件出现后执行对应动作并退出。

该进程独立于演示脚本，避免 bash coproc 因管道/SIGHUP 提前结束。
"""
import os
import sys
import time
import pathlib

import psycopg


def main() -> None:
    dsn, signal_dir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    sig = pathlib.Path(signal_dir)
    sig.mkdir(parents=True, exist_ok=True)
    for name in ("commit", "rollback"):
        p = sig / name
        if p.exists():
            p.unlink()

    conn = psycopg.connect(dsn)
    conn.execute("BEGIN")
    # 每次用唯一键，避免唯一索引已存在时 INSERT 冲突（read 模式则完全不写）。
    unique_suffix = f"{os.getpid()}-{int(time.time() * 1000)}"
    if mode == "write":
        conn.execute(
            "INSERT INTO reports(lab_no, report_no, measured) "
            "VALUES ('LONG-TX', %s, 1)",
            (f"HOLD-{unique_suffix}",),
        )
    else:
        conn.execute("SELECT 1 FROM reports")
    pid = conn.execute("SELECT pg_backend_pid()").fetchone()[0]
    (sig / "pid").write_text(str(pid))
    sys.stderr.write(f"long tx started, backend pid={pid}, mode={mode}\n")
    sys.stderr.flush()

    deadline = time.time() + 300
    while time.time() < deadline:
        if (sig / "commit").exists():
            conn.commit()
            sys.stderr.write("long tx committed\n")
            break
        if (sig / "rollback").exists():
            conn.rollback()
            sys.stderr.write("long tx rolled back\n")
            break
        time.sleep(0.2)
    conn.close()


if __name__ == "__main__":
    main()
