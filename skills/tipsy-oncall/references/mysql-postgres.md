# MySQL & PostgreSQL 排障 —— Bytebase MCP 只读查库

这份文档解决"值班时想直接查业务表 / 记忆表验证一手数据"的场景，覆盖 tipsy-backend 三个数据库实例的 Bytebase MCP 只读接入。当排障进入"用户说 X 没落库 / 记忆没进 / 角色被谁改过"、"UI 层数据和后台对不上"这类需要直接 SELECT 的分支时读它。所有写操作一律禁用；只读遵守 SKILL.md §1 铁律 1（默认只读）和铁律 3（时间统一 UTC）。

## 三个实例映射

| 用途 | 实例（instance） | 库（database） | 引擎 |
|---|---|---|---|
| 线上业务表（角色/会话/用户/关系/账单元数据…） | `tipsy-backend-prod-mysql-sj6z` | `tipsy` | MySQL |
| 测试业务表（同上，测试环境） | `tipsy-backend-test-mysql-v8kd` | `fantasy` | MySQL |
| 记忆库（mempoints / summaries / character_call_summary…） | `tipsy-memory` | `tipsy_memory` | PostgreSQL |

- 线上/测试 MySQL 的库名不同（`tipsy` vs `fantasy`），Bytebase 一般能按库名自动路由，**但当两侧同时存在同名库或不确定时，必须显式 `instance=` 收窄**。尤其是查 `character` / `session` / `user` 这类跨环境同名表时，只写 database 会解析到错误环境，造成"线上问题在测试库找不到踪迹"。
- 记忆库全局只有一套 `tipsy_memory`（线上测试共库、按 `user_id`/`character_id` 逻辑隔离），排 mempoint / summary 时直接 `database="tipsy_memory"` 就行，`instance="tipsy-memory"` 可加可不加。
- Lindorm（聊天原文、账单流水）不在这里，走另外通道，见 `lindorm.md`。

## 常用 Bytebase MCP tool

| tool | 场景 | 关键参数 |
|---|---|---|
| `mcp__bytebase__query_database` | 90% 排障就是它，跑 SELECT | `database`（必填）、`statement`（必填）、`instance`（同名/不确定时必填）、`limit`（默认 100，最大 1000） |
| `mcp__bytebase__get_schema` | 建 SQL 前先看表结构 | `database`、`instance`、`table` |
| `mcp__bytebase__search_api` | 忘了某个 OpenAPI 用法 | `q="ListInstances"` 等 |
| `mcp__bytebase__call_api` | 列实例 / 查连通性 | `operationId="InstanceService/ListInstances"` |

关键约束（**铁律**）：

- **禁用 `mcp__bytebase__propose_database_change`**。任何 DDL / DML 的变更提案都会走进人工审批流，值班用不上，只会污染 Bytebase 面板。SKILL.md §1 铁律 1 明确"只读默认"，值班期间不发起任何写操作或变更提案。
- `query_database` 默认只返 **100 行**，最大 1000。**判"没有 / 全部"结论前先看命中数是不是撞了默认 100**——只要输出恰好 100 条，第一反应就是"限流截断了"，加 `limit=1000` 或改 `count(*)` 复核后再下结论，不然会得出"只有 100 个符合条件的角色"这种假结论。
- MySQL 关键字 `character` 是保留字。**查角色表必须反引号**：`` SELECT * FROM `character` WHERE character_id = ? ``。忘了会报 `You have an error in your SQL syntax`。
- 表里 `created_at`、`updated_at`、`deleted_at` **一律 UTC**。给用户回消息前必须 `+8h` 与 SLS / 客服反馈的北京时间对齐（SKILL.md §1 铁律 3），否则会得出"消息晚于操作"这种时序错乱结论。

## mempoints 表（记忆库核心）

在 `tipsy_memory` 库，PostgreSQL：

- 核心字段：`user_id` / `character_id` / `session_id` / `content`（记忆正文）/ `importance` / `source_trace_id` / `created_at`(UTC) / `deleted_at`（软删，NULL=存活）。
- `extra` 是 **jsonb**，是排 mempoint 时的关键：
  - `batch_turns`：这条 mempoint 由多少轮对话攒成，默认 4 轮
  - `start_turn` / `end_turn`（或 `min_msg_id` / `max_msg_id`）：这条 mempoint 覆盖的 seq 区间，delete 是"**区间相交即删**"，不是精确删
- 判"某 uid+cid 到底有几条现存 mempoint"必须加 `deleted_at IS NULL`；忘了会把历史软删的一起数进来，得出"入库了呀"的假阳性结论。
- 字段名（`start_turn`/`end_turn` vs `min_msg_id`/`max_msg_id`）会随版本迭代，写 SQL 前先 `get_schema` 或 `SELECT extra FROM mempoints LIMIT 1` 看一眼。

## 常用查询模板

某会话最近 N 条消息属于哪些角色（业务库，注意反引号）：

```sql
SELECT id, `character`.character_id, sender_type, created_at
FROM message
JOIN `character` ON message.character_id = `character`.character_id
WHERE session_id = '<SID>'
ORDER BY created_at DESC
LIMIT 50;
```

某 user+character 现存的所有 mempoint（记忆库）：

```sql
SELECT id, session_id,
       extra->>'batch_turns' AS batch,
       extra->>'start_turn' AS s, extra->>'end_turn' AS e,
       importance, created_at, LEFT(content, 60) AS preview
FROM mempoints
WHERE user_id = '<UID>' AND character_id = '<CID>' AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT 200;
```

某角色最近改动（业务库，判断是不是被作者/审核回退过）：

```sql
SELECT character_id, updated_at, hidden_in_review, review_state
FROM `character`
WHERE character_id = '<CID>'
ORDER BY updated_at DESC LIMIT 10;
```

## 401 / token 过期

Bytebase MCP 报 `401 access token expired` / `unauthorized` 时：

1. 停止当前会话的任何 Bytebase 调用，不要在过期 token 上重试空转（SKILL.md §1 铁律 4：token 不落盘、不重试）。
2. 让用户走 `/mcp` 命令重授权 Bytebase（浏览器 OAuth，不需要在会话里贴任何 token）。
3. 重授权成功后重新调用即可，参数不变；不要用 `$ALIYUN_ACCESS_KEY_ID` 或 secrets.sh 里的其他变量去"手工签名"绕过 OAuth。

## 排障案例：用户说"记忆没入库"

- 现象：客服转来用户反馈"我聊了一下午，AI 没记得任何事"。
- 通道：直接查记忆库 `mempoints`，不看 backend SLS（SKILL.md §1 铁律 8：mempoint 成功路径 SLS 静默）。
- 查询：`SELECT COUNT(*), MAX(created_at) FROM mempoints WHERE user_id='<UID>' AND character_id='<CID>' AND deleted_at IS NULL;`
- 结论：若 count > 0 且 `max(created_at)` 在最近一小时内则**已入库**——问题在检索侧（retrieve 触发条件、max_msg_id 传参、summary 覆盖）；若 count = 0 或 max 停在很久前，才是"确实没入库"，再去看 mempoint 区间是否被历史 `[N+1,∞)` delete 相交清空、或 Redis dedup key 是否残留。

## 下一步 / 相关

- `lindorm.md`：查聊天原文和 ES 索引（Bytebase 不覆盖 Lindorm/ES）
- `memory-direct.md`：不方便查 DB 时直连 `$TIPSY_MEMORY_URL_PROD/TEST` 的 `/v1/memory/retrieve` 兜底
- `sls-logs.md`：backend / memory 服务日志查法，尤其"成功路径静默"如何绕
- SKILL.md §1 铁律 1、3、4、8：只读默认、UTC 统一、token 不落盘、mempoint SLS 静默