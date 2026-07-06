# Lindorm 查聊天原文与账单

## 何时读

- 排查"某 session 最后 N 条聊天缺失/内容异常"、账单扣量核对、CoT 泄露落库剥离是否生效等场景,需要落到聊天原文与消费流水时读。
- MySQL 只有元数据(session、character、user、chat_room),真正的**聊天原文和账单流水**都在 Lindorm。SLS 只能看服务端日志、不是权威数据源。
- Redis/ES 也都不是聊天原文的权威源,别拿来对账。

## 实例与库名

| 环境 | 实例 | 库名 | 注意 |
|---|---|---|---|
| 线上 | `tipsy-lindorm` | `tipsy` | 与 MySQL 库同名 |
| 测试 | `tipsy-lindorm` | `fantacy` | **拼写是 fantacy,不是 fantasy**,历史遗留 |

同一实例挂两个库,靠 `database` 参数区分。测试库的 `fantacy` 拼写是历史坑,SQL 里打成 `fantasy` 会直接报库不存在,记得复制粘贴而不是手打。**别用 test 库替代 prod 数据看问题**,聊天原文完全不同。

## 路径一:Bytebase MCP(优先尝试)

如果 Bytebase 已挂 Lindorm 数据源,直接走 `mcp__bytebase__query_database`,传 `instance=tipsy-lindorm、database=tipsy`(或 `fantacy`)+ SQL。这是最安全通道,只读、有审计。

**识别 Bytebase 未接入 Lindorm 的信号**:返回 `unknown instance` / `datasource not found` / `no matching datasource`,说明 DBA 还没把 Lindorm 只读账号接进 Bytebase。看到就切路径二,不要在这条路径上反复重试。

`propose_database_change` 在铁律里已经禁用,不要用。

## 路径二:DMS + Chrome hook fetch(兜底)

DMS 是阿里云数据管理控制台,用 `$ALIYUN_DMS_LINDORM_URL_PROD` / `$ALIYUN_DMS_LINDORM_URL_TEST` 打开对应实例:

1. `browser_open_session` 打开对应 env 变量的 URL
2. 复用已有 SSO 会话进入实例的 SQL 窗口
3. 贴 SQL 执行
4. **不要抓 DOM**——DMS 结果表格用虚拟滚动,DOM 只保留当前视口若干行,几百行以上一定漏。改用 `browser_evaluate` 在页面里 hook `fetch`,拦截 DMS 的 XHR 返回体(结构化 JSON),再从原始 body 里读 rows。

hook 骨架在 evaluate 里跑:

```javascript
const origFetch = window.fetch;
window.__lastXhr = [];
window.fetch = (...args) => origFetch(...args).then(r => {
  const clone = r.clone();
  clone.json().then(j => window.__lastXhr.push({ url: args[0], body: j })).catch(()=>{});
  return r;
});
```

点执行 SQL 之后再 `browser_evaluate` 读 `window.__lastXhr` 拿最后一次响应体,里面就是完整 rows。详细模板见 nimbalyst-browser 兜底(SKILL.md §4)。

**SSO 每天掉一次**:阿里云 SSO 24h 过期,上午常见"点开 DMS 空白/回到登录页"。兜底:清 cookie 重登;仍不行让用户本地跑一次 `aliyun login` 或 `acs-cli login`,或让 nimbalyst-browser 复用已登录 profile。别死磕 headless 自动登。

## 主要表

**具体表名请查项目 llmdoc(`llmdoc/reference/` 下 lindorm/chat/billing 相关文档)或直接看 DMS 库表列表**,不要凭猜写 SQL。以下是常见候选,查询前先在 DMS 左侧目录树核对一遍:

- **聊天原文**:通常命名类似 `chat_history` / `chat_message`,分区键含 `session_id` 或 `chat_room_id`,时间字段常见 `create_time`
- **账单流水**:通常命名类似 `billing_log` / `consume_record`,分区键含 `user_id`,含 tokens/model/费用字段

不确定表名时,DMS 左边树点开对应库,把 candidate 表名贴给用户确认;或者查 tipsy-backend 源码里 Lindorm 客户端封装模块的 `TableName` 常量。

## Lindorm 常见坑

- **分区键必须在 WHERE**:HBase 派生,全表扫会被拒或直接跑到超时。`WHERE session_id = 'xxx'` 是刚需,或者用日期分区键(如按天分区的账单表)
- **不支持 JOIN**:两张表要关联,分两次查、程序侧拼。硬写 JOIN 报错还不友好
- **时间戳字段**:多为 bigint 毫秒(不是 datetime),转换用 `FROM_UNIXTIME(ts/1000)`,别把毫秒当秒。写 `WHERE create_time > '2025-01-01'` 会直接类型不匹配
- **ORDER BY + LIMIT**:按时间倒序拿最近 N 条,一定连同分区键约束一起写,否则可能触发全表扫描

## 下一步 / 相关

- MySQL 元数据(session_id、character_id、user_id、chat_room_id)从 `mysql-postgres.md` 拿
- 服务端日志、写库时序错乱定位走 `sls-logs.md`
- Memory 服务数据对账走 `memory-direct.md`(记忆不是聊天原文,只是引用 session_id)
- DMS Chrome hook fetch 的详细模板与 SSO 复用走 nimbalyst-browser 兜底(SKILL.md §4)

## 案例:查某 session 最后 3 条聊天原文

**现象**:用户反馈"最后一条消息发出去没响应,历史记录里也看不到"

**通道**:MySQL 拿 session_id/user_id → Lindorm 拉原文 → SLS 看写入时序

**查询**:先 `mcp__bytebase__query_database` 传 `database=tipsy`、SQL `SELECT * FROM chat_history WHERE session_id='xxx' ORDER BY create_time DESC LIMIT 3`;返回 `unknown instance`,切路径二 `$ALIYUN_DMS_LINDORM_URL_PROD` 打开 DMS、browser_evaluate hook fetch 拿 XHR。

**结论**:Lindorm 只有 2 条,最后一条 create_time 比 SLS 里 chat 服务的写入日志晚 8s——落地失败,SLS 再定位到 Lindorm 客户端超时后 fallback 逻辑漏写。用户端看不到、服务端也没兜底重投。