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

-- 3) 漂移结论表：每个（实验室, UTC 日期）一条当前结论，重新核算以 upsert 覆盖。
CREATE TABLE IF NOT EXISTS drift_conclusions (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lab_no              TEXT NOT NULL,                  -- 实验室号
    calc_date           DATE NOT NULL,                  -- 被核算的 UTC 日期（reports.created_at 的 UTC 日）
    status              TEXT NOT NULL CHECK (status IN (
                            'valid',                    -- 两侧均有报告，结论有效（是否需排查见 needs_review）
                            'insufficient_data'         -- 当日或此前七个 UTC 日任一侧无报告
                        )),
    needs_review        BOOLEAN NOT NULL DEFAULT FALSE, -- |当日中位数 - 基线中位数| > 阈值（10）
    current_day_median  DOUBLE PRECISION,               -- 当日全部测值中位数
    baseline_median     DOUBLE PRECISION,               -- 此前七个 UTC 日全部测值中位数
    drift_diff          DOUBLE PRECISION,               -- 当日中位数 - 基线中位数
    threshold           DOUBLE PRECISION NOT NULL DEFAULT 10,
    is_stale            BOOLEAN NOT NULL DEFAULT FALSE, -- 结论生成后相关报告发生过增改删，需重新核算
    computed_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_drift_conclusions_lab_date UNIQUE (lab_no, calc_date)
);

COMMENT ON TABLE  drift_conclusions IS '按实验室号+UTC 日期的测值漂移核算结论；写报告触发器自动标过期';
COMMENT ON COLUMN drift_conclusions.is_stale IS 'TRUE 表示结论依赖的数据事后被改动，重新核算后恢复 FALSE';

-- 中位数按（实验室, 创建时间）做范围扫描的辅助索引；在线大表请改用 04 脚本中的
-- CREATE INDEX CONCURRENTLY 版本补建，避免在存量表上直接建索引阻塞补录。
CREATE INDEX IF NOT EXISTS idx_reports_lab_created_at
    ON reports (lab_no, created_at);

-- 每实验室一把事务级咨询锁的键：核算与写报告触发器按同一键串行，避免表锁。
-- 第二个参数是哈希种子，取值任意，只需全库一致（函数为 IMMUTABLE，两侧都经此函数取键）。
CREATE OR REPLACE FUNCTION drift_advisory_key(p_lab_no text)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT hashtextextended('drift:lab:' || p_lab_no, 4710359)
$$;

-- 漂移核算函数：调用方事务内执行，结论一次性 upsert（失败即整体回滚，不留半份结果）。
-- 函数在任何数据读取之前先获取本实验室的事务级咨询锁，与 reports 写触发器互斥；
-- 调用方使用 READ COMMITTED：等锁结束后函数内每条语句都取新快照，必然看到此前已
-- 提交的同实验室写入；持锁期间同实验室写入全部阻塞，两条中位数查询对该实验室数据
-- 等价于同一已提交视图。独立 SQL 直接调用本函数亦获得同等保证。
CREATE OR REPLACE FUNCTION recompute_drift(p_lab_no text, p_calc_date date)
RETURNS drift_conclusions
LANGUAGE plpgsql
AS $$
DECLARE
    v_day_n     bigint;
    v_day_med   double precision;
    v_base_n    bigint;
    v_base_med  double precision;
    v_diff      double precision;
    v_row       drift_conclusions;
BEGIN
    -- 与同实验室的报告写入（触发器持同一把锁）串行；不同实验室互不阻塞。
    PERFORM pg_advisory_xact_lock(drift_advisory_key(p_lab_no));

    -- 当日侧：created_at 的 UTC 日期 = p_calc_date，半开区间保证按 UTC 切日。
    SELECT count(*), percentile_cont(0.5) WITHIN GROUP (ORDER BY measured)
      INTO v_day_n, v_day_med
    FROM reports
    WHERE lab_no = p_lab_no
      AND created_at >= (p_calc_date AT TIME ZONE 'UTC')
      AND created_at < ((p_calc_date + 1) AT TIME ZONE 'UTC');

    -- 基线侧：此前七个 UTC 日 [p_calc_date-7, p_calc_date) 内的全部测值。
    -- 与当日侧处于同一事务、同一快照，即“同一已提交视图”。
    SELECT count(*), percentile_cont(0.5) WITHIN GROUP (ORDER BY measured)
      INTO v_base_n, v_base_med
    FROM reports
    WHERE lab_no = p_lab_no
      AND created_at >= ((p_calc_date - 7) AT TIME ZONE 'UTC')
      AND created_at < (p_calc_date AT TIME ZONE 'UTC');

    IF v_day_n = 0 OR v_base_n = 0 THEN
        INSERT INTO drift_conclusions (
            lab_no, calc_date, status, needs_review,
            current_day_median, baseline_median, drift_diff,
            threshold, is_stale, computed_at
        )
        VALUES (
            p_lab_no, p_calc_date, 'insufficient_data', FALSE,
            v_day_med, v_base_med, NULL,
            10, FALSE, now()
        )
        ON CONFLICT (lab_no, calc_date) DO UPDATE
            SET status = 'insufficient_data',
                needs_review = FALSE,
                current_day_median = EXCLUDED.current_day_median,
                baseline_median = EXCLUDED.baseline_median,
                drift_diff = NULL,
                threshold = EXCLUDED.threshold,
                is_stale = FALSE,
                computed_at = now();
    ELSE
        v_diff := v_day_med - v_base_med;
        INSERT INTO drift_conclusions (
            lab_no, calc_date, status, needs_review,
            current_day_median, baseline_median, drift_diff,
            threshold, is_stale, computed_at
        )
        VALUES (
            p_lab_no, p_calc_date, 'valid', abs(v_diff) > 10,
            v_day_med, v_base_med, v_diff,
            10, FALSE, now()
        )
        ON CONFLICT (lab_no, calc_date) DO UPDATE
            SET status = 'valid',
                needs_review = EXCLUDED.needs_review,
                current_day_median = EXCLUDED.current_day_median,
                baseline_median = EXCLUDED.baseline_median,
                drift_diff = EXCLUDED.drift_diff,
                threshold = EXCLUDED.threshold,
                is_stale = FALSE,
                computed_at = now();
    END IF;

    SELECT * INTO v_row
    FROM drift_conclusions
    WHERE lab_no = p_lab_no AND calc_date = p_calc_date;
    RETURN v_row;
END;
$$;

-- reports 写触发器：任何途径（API 或独立 SQL）的增改删都在同一事务内把受影响结论标过期。
-- 一份日期为 d 的报告可能进入结论 D 的当日侧（D=d）或基线侧（D∈[d+1,d+7]），
-- 因此受影响结论日期窗口为 [d, d+7]；改实验室号/创建时间时旧、新两个范围都要覆盖。
-- 触发器随写事务一起提交/回滚：写事务回滚则过期标记一并撤销，结论不变。
CREATE OR REPLACE FUNCTION trg_reports_drift_invalidate()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_key bigint;
    v_new_key bigint;
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM pg_advisory_xact_lock(drift_advisory_key(NEW.lab_no));
        UPDATE drift_conclusions SET is_stale = TRUE
        WHERE lab_no = NEW.lab_no
          AND calc_date BETWEEN (NEW.created_at AT TIME ZONE 'UTC')::date
                            AND (NEW.created_at AT TIME ZONE 'UTC')::date + 7
          AND is_stale = FALSE;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM pg_advisory_xact_lock(drift_advisory_key(OLD.lab_no));
        UPDATE drift_conclusions SET is_stale = TRUE
        WHERE lab_no = OLD.lab_no
          AND calc_date BETWEEN (OLD.created_at AT TIME ZONE 'UTC')::date
                            AND (OLD.created_at AT TIME ZONE 'UTC')::date + 7
          AND is_stale = FALSE;
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        v_old_key := drift_advisory_key(OLD.lab_no);
        v_new_key := drift_advisory_key(NEW.lab_no);
        -- 多键按固定顺序加锁，避免两个跨实验室更新互相等待形成死锁。
        IF v_old_key <= v_new_key THEN
            PERFORM pg_advisory_xact_lock(v_old_key);
            IF v_new_key <> v_old_key THEN
                PERFORM pg_advisory_xact_lock(v_new_key);
            END IF;
        ELSE
            PERFORM pg_advisory_xact_lock(v_new_key);
            PERFORM pg_advisory_xact_lock(v_old_key);
        END IF;

        -- 旧范围（旧实验室号 + 旧创建时间）。
        UPDATE drift_conclusions SET is_stale = TRUE
        WHERE lab_no = OLD.lab_no
          AND calc_date BETWEEN (OLD.created_at AT TIME ZONE 'UTC')::date
                            AND (OLD.created_at AT TIME ZONE 'UTC')::date + 7
          AND is_stale = FALSE;
        -- 新范围（新实验室号 + 新创建时间）；与旧范围重合时上面已标过，条件行会自动跳过。
        UPDATE drift_conclusions SET is_stale = TRUE
        WHERE lab_no = NEW.lab_no
          AND calc_date BETWEEN (NEW.created_at AT TIME ZONE 'UTC')::date
                            AND (NEW.created_at AT TIME ZONE 'UTC')::date + 7
          AND is_stale = FALSE;
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_reports_drift_invalidate ON reports;
CREATE TRIGGER trg_reports_drift_invalidate
    AFTER INSERT OR UPDATE OR DELETE ON reports
    FOR EACH ROW
    EXECUTE FUNCTION trg_reports_drift_invalidate();

-- TRUNCATE 不触发行级触发器：用语句级触发器把全部结论标过期，同样随事务提交/回滚。
CREATE OR REPLACE FUNCTION trg_reports_drift_invalidate_truncate()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE drift_conclusions SET is_stale = TRUE WHERE is_stale = FALSE;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_reports_drift_invalidate_truncate ON reports;
CREATE TRIGGER trg_reports_drift_invalidate_truncate
    AFTER TRUNCATE ON reports
    FOR EACH STATEMENT
    EXECUTE FUNCTION trg_reports_drift_invalidate_truncate();

COMMIT;
