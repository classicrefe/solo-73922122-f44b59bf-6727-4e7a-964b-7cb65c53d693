# 检验报告实验室内报告号唯一性保障服务

为持续补录的检验报告表 `reports` 在线建立 **(实验室号, 报告号)** 唯一索引，防止重复报告入仓。
技术栈：FastAPI + PostgreSQL（`CREATE UNIQUE INDEX CONCURRENTLY`）。

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

## 3. API

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/reports` | 单条补录；唯一索引生效后重复键返回 `409`，原数据不变 |
| POST | `/reports/batch` | 批量补录，重复键逐条跳过，返回成功/跳过明细 |
| GET | `/reports` | 分页查询报告 |
| POST | `/index/build` | 发起/复用 `CREATE UNIQUE INDEX CONCURRENTLY`（202） |
| GET | `/index/status` | 查询轮次状态 + `pg_index` 中索引的真实有效性 |
| POST | `/index/cancel` | 受理取消（202 `cancel_requested`），SQL 确认停止后才 `cancelled` |

构建轮次状态机：

```
running ──索引有效──▶ complete
running ──重复键等失败──▶ failed（安全清理无效索引，reports 原数据不动，去重后可重试）
running ──受理取消──▶ cancel_requested ──后端 SQL 确认停止──▶ cancelled
索引已有效时再发起/取消：直接报 complete，绝不删除有效索引
```

## 4. 关键设计如何满足需求

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

## 5. 独立 SQL

- `sql/02_backfill_examples.sql`：不依赖 API 的补录示例（单条/批量/外部表，含 `ON CONFLICT DO NOTHING`）。
- `sql/03_dedupe.sql`：重复键排查与去重（保留每组最早一条）。

## 6. 演示

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

## 7. 运行测试

```bash
export DATABASE_URL=postgresql://postgres@<host>:<port>/<db>
pip install -r requirements.txt pytest httpx a2wsgi
pytest -q
```

## 8. 目录结构

```
app/            FastAPI 应用（main 路由、service 构建编排、db 访问层、schemas）
sql/            建表、补录示例、去重脚本
demo/           四个端到端演示 + 长事务持有助手
tests/          pytest 关键功能自测（9 个用例）
Dockerfile, docker-compose.yml, requirements.txt
```
