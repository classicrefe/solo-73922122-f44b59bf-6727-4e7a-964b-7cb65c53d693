-- 检验数仓报告表与索引构建轮次表
-- 幂等脚本，容器首次启动时由 PostgreSQL 自动执行（/docker-entrypoint-initdb.d）。

BEGIN;

-- 1) 报告主表
CREATE TABLE IF NOT EXISTS reports (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- 主键流水号
    lab_no       TEXT NOT NULL,                                     -- 实验室号（非空）
    report_no    TEXT NOT NULL,                                     -- 实验室内报告号（非空）
    measured     INTEGER NOT NULL,                                  -- 整数测值
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  reports            IS '持续补录的检验报告表';
COMMENT ON COLUMN reports.id         IS '主键流水号';
COMMENT ON COLUMN reports.lab_no     IS '实验室号';
COMMENT ON COLUMN reports.report_no  IS '实验室内报告号';
COMMENT ON COLUMN reports.measured   IS '整数测值';

-- 补录期间的普通辅助索引（非唯一），仅用于按实验室号/报告号查询与去重；
-- 唯一索引构建成功前，唯一性由补录 SQL 自行保证。
CREATE INDEX IF NOT EXISTS idx_reports_lab_report
    ON reports (lab_no, report_no);

-- 2) 唯一索引构建轮次表（状态持久化，API 重启后据此接续跟踪）
CREATE TABLE IF NOT EXISTS index_build_rounds (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    round_id    UUID NOT NULL UNIQUE,
    status      TEXT NOT NULL CHECK (status IN (
                    'running',        -- 构建中（含等待长事务阶段）
                    'complete',       -- 索引已有效
                    'failed',         -- 构建失败（如重复键），原数据保留，无效索引已清理
                    'cancel_requested', -- 已受理取消，等待后端 SQL 真正停止
                    'cancelled'       -- 后端 SQL 已确认停止且索引无效
                )),
    backend_pid INTEGER,                       -- 执行 CREATE INDEX 的 PostgreSQL 后端 PID
    index_name  TEXT NOT NULL,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    error       TEXT,                         -- 失败原因（如重复键明细）
    failure_type TEXT,                        -- duplicate_key / lock_timeout / other / cancelled
    restarted   BOOLEAN NOT NULL DEFAULT FALSE -- 是否为 API 重启后接续跟踪的轮次
);

COMMENT ON TABLE index_build_rounds IS 'CREATE UNIQUE INDEX CONCURRENTLY 构建轮次';

-- 同一时刻只允许一轮活跃构建（running 或 cancel_requested 各最多一条）。
-- 该约束在数据库层面兜底，即使多个 API 实例并发发起也不会出现两轮并发构建。
CREATE UNIQUE INDEX IF NOT EXISTS uq_index_rounds_one_active
    ON index_build_rounds ((1))
    WHERE status IN ('running', 'cancel_requested');

COMMIT;
