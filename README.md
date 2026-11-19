# 检验报告质控服务（唯一性保障 + 测值漂移核算）

为持续补录的检验报告表 `reports` 提供两项质控能力：

1. 在线建立 **(实验室号, 报告号)** 唯一索引，防止重复报告入仓
   （`CREATE UNIQUE INDEX CONCURRENTLY`，FastAPI + PostgreSQL）；
2. 按**实验室号**与 `reports.created_at` 的 **UTC 日期**核算测值整体漂移：
   比较当日测值中位数与此前七个 UTC 日全部测值中位数，单份报告未越界也能发现整天偏移。

## 1. 快速启动（Docker Compose）

```bash
docker compose up --build
# API:   http://localhost:8000
# 文档:  http://localhost:8000/docs   （Swagger UI，可直接发起请求）
# OpenAPI: http://localhost:8000/openapi.json
```

- 首次启动 PostgreSQL 自动执行 `sql/01_schema.sql` 建表（幂等）。
- 健康检查：`GET /health`。

## 2. 数据模型

`reports`（`sql/01_schema.sql`）：

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | BIGINT IDENTITY 主键 | 主键流水号 |
| `lab_no` | TEXT NOT NULL | 实验室号 |
| `report_no` | TEXT NOT NULL | 实验室内报告号 |
| `measured` | INTEGER NOT NULL | 整数测值 |

目标唯一索引：`uq_reports_lab_no_report_no ON reports (lab_no, report_no)`，
键为「实验室号 + 报告号」，即**实验室内报告号唯一**（不同实验室允许相同报告号）。

另有轮次表 `index_build_rounds` 持久化每次构建的状态、后端 PID 与错误信息，用于重启接续。

漂移结论表 `drift_conclusions`（每实验室+UTC 日期一条，唯一约束 `(lab_no, calc_date)`）：

| 列 | 类型 | 说明 |
|---|---|---|
| `status` | TEXT | `valid`=两侧均有报告；`insufficient_data`=任一侧无报告 |
| `needs_review` | BOOLEAN | `abs(drift_diff) > 10` 时为 TRUE，需排查 |
| `current_day_median` | DOUBLE | 当日（calc_date 这个 UTC 日）全部测值中位数 |
| `baseline_median` | DOUBLE | 此前七个 UTC 日 `[calc_date-7, calc_date)` 全部测值中位数 |
| `drift_diff` | DOUBLE | 当日中位数 − 基线中位数 |
| `is_stale` | BOOLEAN | 结论生成后相关报告被增改删，已过期，重新核算后恢复 FALSE |
| `computed_at` | TIMESTAMPTZ | 本次核算时间 |

## 3. API

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/reports` | 单条补录；唯一索引生效后重复键返回 `409`，原数据不变 |
| POST | `/reports/batch` | 批量补录，重复键逐条跳过，返回成功/跳过明细 |
| GET | `/reports` | 分页查询报告 |
| POST | `/index/build` | 发起/复用 `CREATE UNIQUE INDEX CONCURRENTLY`（202） |
| GET | `/index/status` | 查询轮次状态 + `pg_index` 中索引的真实有效性 |
| POST | `/index/cancel` | 受理取消（202 `cancel_requested`），SQL 确认停止后才 `cancelled` |
| POST | `/drift/conclusions` | 核算并保存漂移结论（query：`lab_no`、可选 `calc_date`=UTC 日期、`force`） |
| GET | `/drift/conclusions/{lab_no}/{calc_date}` | 查询单条已保存结论；未核算过返回 `404` |
| GET | `/drift/conclusions` | 分页列出结论，可选 `lab_no` 过滤；过期结论 `is_stale=true` |

`POST /drift/conclusions` 语义：

- 已有**未过期**结论且未传 `force=true`：直接复用，返回 `200` 且 `reused=true`；
- 结论缺失、已过期或 `force=true`：重新核算，返回 `201`；
- 任一侧无报告：`status=insufficient_data`（同样落库，可查询、可被过期标记覆盖）；
- 差值绝对值**严格大于 10** 才 `needs_review=true`（恰好 10 不标记）；
- 中位数用 `percentile_cont(0.5)`（偶数条取中间两值的平均）。

## 4. 漂移核算的并发与一致性设计

- **同一已提交视图**：`recompute_drift(p_lab_no, p_calc_date)` 是单个数据库函数，
  当日侧与基线侧两条中位数查询在同一事务内执行；UTC 切日用半开区间
  `[当日 00:00 UTC, 次日 00:00 UTC)`，不依赖会话时区。
- **核算与写入不发布漏读结论**：函数在任何数据读取之前先取本实验室的
  **事务级咨询锁**（`pg_advisory_xact_lock`，键由 `drift_advisory_key(lab_no)` 派生）；
  `reports` 上的行级触发器对每次 INSERT/UPDATE/DELETE 争用同一把锁。
  - 写入先持锁未提交：核算在锁上等待，绝不拿旧快照继续；锁到手后 READ COMMITTED
    的每条语句取新快照，直接看到已提交写入；
  - 核算先持锁：同实验室写入等待，核算提交后写入才执行，触发器随即将该结论标为
    `is_stale=true`——不存在“漏读变更却仍有效”的结论。
- **过期范围**：日期为 d 的报告会进入结论 D 的当日侧（D=d）或基线侧（D∈[d+1,d+7]），
  因此触发器把同实验室 `calc_date ∈ [d, d+7]` 的结论标过期；UPDATE 覆盖
  **旧、新两个实验室号 × 旧、新两个日期窗口**（改实验室号/创建时间均生效）。
- **回滚不改变结论**：过期标记由触发器在写事务内完成，写事务 ROLLBACK 则标记一并
  撤销；核算函数的读数与 upsert 同事务，任何失败整体回滚，不留半份结果。
- **在线可用性**：锁按实验室细分，不同实验室互不阻塞；全程无表锁，
  补录与 `CREATE UNIQUE INDEX CONCURRENTLY` 可同时进行。触发器多键加锁按固定顺序，
  避免死锁；应用层对 `40P01` 做有限幂等重试，耗尽则返回 `409` 且不写任何结论。
- **API 与独立 SQL 一视同仁**：过期逻辑全部在数据库触发器/函数内，
  不经 API 的 `sql/02_backfill_examples.sql`、手工 DML、`sql/04_drift.sql`
  同样受保护；也可直接 `SELECT recompute_drift(...)` 核算。

构建轮次状态机：

```
running ──索引有效──▶ complete
running ──重复键等失败──▶ failed（安全清理无效索引，reports 原数据不动，去重后可重试）
running ──受理取消──▶ cancel_requested ──后端 SQL 确认停止──▶ cancelled
索引已有效时再发起/取消：直接报 complete，绝不删除有效索引
```

## 5. 唯一索引构建的关键设计如何满足需求

- **构建期间补录不阻塞**：使用 `CONCURRENTLY`，不持表锁，普通 INSERT/UPDATE 正常提交。
- **同一时刻只运行一轮，重复发起复用**：
  数据库层用部分唯一索引 `uq_index_rounds_one_active` 保证全局最多一个活跃轮次；
  应用层再次发起时返回同一轮（`reused=true`），不新开。
- **重复键失败保留原数据、去重后可重试**：失败只产生无效索引，`reports` 一行不动；
  系统安全清理无效索引后，用 `sql/03_dedupe.sql` 去重即可重新发起。
- **取消两阶段、不误伤**：
  1. `POST /index/cancel` 先落 `cancel_requested` 并立即返回 202；
  2. 仅对轮次记录在案的构建后端 PID 调用 `pg_cancel_backend`（不触碰补录连接）；
  3. watcher 轮询 `pg_stat_activity`，**确认该后端的 CREATE INDEX 真正停止**后才报
     `cancelled`；若取消未生效而索引已建成，则如实报 `complete` 并保留索引。
- **API 重启接续，不重跑、不虚报**：启动时以系统目录为准对账——
  构建仍在跑则只挂 watcher 接续跟踪（`restarted=true`，同一 backend PID，不重发 DDL）；
  后端已停且索引无效则裁决 `failed/cancelled` 并清理；索引有效则报 `complete`。
- **失败残留安全清理**：只删除经 `pg_index` 确认 `indisvalid=false` 的索引；
  有效唯一索引永远不会被删除。DROP 带 `lock_timeout` 重试，不被长事务无限挂起。

## 6. 独立 SQL

- `sql/02_backfill_examples.sql`：不依赖 API 的补录示例（单条/批量/外部表，含 `ON CONFLICT DO NOTHING`）。
- `sql/03_dedupe.sql`：重复键排查与去重（保留每组最早一条）。
- `sql/04_drift.sql`：漂移核算独立入口（直接调用 `recompute_drift`、批量重算、
  `CREATE INDEX CONCURRENTLY` 补建范围索引、写操作触发过期的示例与说明）。

## 7. 演示

```bash
# 前置：一个运行中的 API 与 PostgreSQL（本地或 Compose）。
# 本地无 Docker 时可用环境变量覆盖连接，见 demo/common.sh。
bash demo/01_long_transaction.sh   # 长事务拖慢构建 + 构建期补录照常提交
bash demo/02_duplicate_key.sh      # 重复键失败->原数据保留->去重重试成功->409
bash demo/03_restart_recovery.sh   # API 重启接续跟踪，不重跑、不虚报
bash demo/04_cancel.sh             # 取消受理/确认、不误伤补录、有效索引不删除
```

> 受限沙箱若禁止进程信号，`pg_cancel_backend` 无法中止后端；演示 4 会如实展示
> “取消已受理、索引最终建成则报 complete 且保留”，并用等价的「后端已停止」现场
> 演示 `cancelled` 裁决与清理。标准 Docker/宿主环境中信号正常，可直接得到 `cancelled`。

## 8. 运行测试

```bash
export DATABASE_URL=postgresql://postgres@<host>:<port>/<db>
pip install -r requirements.txt pytest httpx a2wsgi
pytest -q
```

共 26 个用例：`tests/test_api.py`（9 个，补录/在线建索引/取消/重启接续）与
`tests/test_drift.py`（17 个，核算规则、阈值边界、UTC 切日、触发器过期窗口、
改实验室号/创建时间、回滚、咨询锁交错、失败不留半份、与 CIC 共存）。

## 9. 目录结构

```
app/            FastAPI 应用（main 路由、service 构建编排、drift 漂移核算、db 访问层、schemas）
sql/            建表/函数/触发器、补录示例、去重脚本、漂移独立 SQL
demo/           四个端到端演示 + 长事务持有助手
tests/          pytest 关键功能自测（26 个用例）
Dockerfile, docker-compose.yml, requirements.txt
```
