# tipsy-oncall

Tipsy 后端**全链路值班排障** skill。把 4 个 MCP(Bytebase / SigNoz / aliyun-sls / Logfire) + 3 条直连通道(Redis RunCommand OpenAPI / ES REST / memory 服务 curl) + 1 个 CLI(coolify) + Chrome 兜底(nimbalyst-browser) 串成**一条只读排查流水线**,并以「现象 / 通道 / 查询 / 结论 / 后续」五段格式输出结论。

## 定位

- **只做排查,不做变更**。写告警走 `grafana-as-code`,tipsy-studio 走 `logfire-ops`,改代码走标准 PR。
- **可开源**:所有 URL / 实例 ID / token / AK/SK 走 `~/github/my_dot_files/secrets.sh`,skill 目录里只有占位符和字段字典。
- **prod / test / preview 三环境显式**:每次查询前先说清环境,实例名/URL 都跟环境绑定。

## 覆盖能力

| 组件 | 通道 | 触发场景 |
|---|---|---|
| MySQL(`tipsy` prod / `fantasy` test) | Bytebase MCP | 业务表数据核对 |
| PostgreSQL(`tipsy_memory`) | Bytebase MCP | mempoint 落库、summary 校验 |
| Lindorm(`tipsy-lindorm`) | Bytebase 试 → DMS 兜底 | 聊天原文、账单 |
| Redis | R-KVStore RunCommand OpenAPI → DMS 兜底 | 缓存、pending 队列、limiter |
| Elasticsearch | 标准 REST → Kibana 兜底 | 角色可见性、推荐位、搜索 |
| SLS 日志(tipsy-backend Go) | aliyun-sls MCP | 报错堆栈、性能日志 |
| ARMS Prometheus 指标 | aliyun-sls `cms_execute_promql` | P99、错误率、熔断状态 |
| SigNoz APM(tipsy-memory Py) | SigNoz MCP | ingest / retrieve trace / log |
| Logfire(tipsy-studio) | Logfire MCP(通常转 logfire-ops) | sunrise、AI coding agent |
| memory 服务黑盒 | 直连 curl `/v1/memory/*` | ingest / retrieve / summary / delete |
| Coolify 副服务 | `coolify` CLI | 部署状态、logs |
| 预览环境 | `scripts/env-detect.sh` | `{commit_id}-{build}.api.dev.fantacy.live` |

## 安装

```bash
cd ~/github/my-awesome-skills/skills/tipsy-oncall
./install.sh                # 安装到 ~/.claude/skills/tipsy-oncall/ + 追加 secrets 块 + MCP 体检
./install.sh --dry-run      # 预览
./install.sh --force        # 覆盖本地已有同名(⚠️)
./install.sh --replace-legacy  # 显式清理旧的项目级 tipsy-debug skill
./install.sh --uninstall    # 卸载(不动 secrets.sh、不动 MCP)
```

安装完:

1. 打开 `~/github/my_dot_files/secrets.sh`,找到 `# tipsy-oncall skill (auto-append by install.sh)` 这个 marker 块,把里面所有 `""` 换成真实值。参考 `secrets.example.sh` 里每个键的说明。
2. `claude mcp list` 确认 `bytebase / signoz / logfire / aliyun-sls` 全部 `✓ Connected`。缺哪个就手动加(install.sh 输出会给样板命令)。
3. 重启 Claude Code 或开新对话,输入"查 prod 环境的 xxx"触发 skill。

## 与其它 skill 的关系

```
                   ┌─────────────────────────┐
                   │       用户问题           │
                   └────────────┬────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
   排查(读为主)            告警/看板变更             tipsy-studio
   tipsy-oncall           grafana-as-code             logfire-ops
        │                       │                       │
   Bytebase / SLS /       Grafana Provisioning     Logfire dashboards
   SigNoz / Redis /       ARMS Prometheus          / alerts / traces
   ES / Coolify /
   Chrome 兜底
```

**歧义时先反问**:"读一下告警"三个 skill 都能命中,先问用户"你要看的是基础设施指标(内存/时延) / 应用 telemetry(sunrise/newapi) / 还是 backend 日志报错?"

## 目录结构

```
tipsy-oncall/
├── SKILL.md               # frontmatter + §0 决策树 + §1 铁律 + §3 五段报告硬约束
├── README.md              # 你现在看的
├── install.sh             # 安装/卸载/legacy 清理/MCP 体检/secrets append
├── secrets.example.sh     # secrets.sh 追加块示例(含真实值格式示范)
├── references/            # 按需加载的分层文档(15 份)
│   ├── decision-tree.md          # 完整决策树
│   ├── mysql-postgres.md         # Bytebase MCP MySQL / PG 查询 recipe
│   ├── lindorm.md                # Lindorm 字段字典 + Bytebase/DMS 双路径
│   ├── redis.md                  # R-KVStore RunCommand + Chrome 兜底
│   ├── elasticsearch.md          # ES REST + Chrome Kibana 兜底
│   ├── sls-logs.md               # aliyun-sls MCP 查询模板
│   ├── signoz.md                 # SigNoz APM/trace 模板
│   ├── prometheus.md             # cms_execute_promql 用法
│   ├── metric-pitfalls.md        # 5 大 PromQL 陷阱
│   ├── logfire.md                # tipsy-studio pointer
│   ├── coolify.md                # coolify CLI 覆盖范围
│   ├── memory-direct.md          # /v1/memory/* curl recipe
│   ├── environments.md           # 三环境隔离 + 预览环境定位
│   ├── trace-crosslink.md        # trace_id 全链路下钻
│   └── report-format.md          # 五段报告详解
└── scripts/               # 可执行 shell 封装(7 个)
    ├── env-detect.sh
    ├── redis-cmd.sh
    ├── es-search.sh
    ├── memory-retrieve.sh
    ├── coolify-status.sh
    ├── mempoint-timeline.sh
    └── trace-crosslink.sh
```

## 卸载

```bash
./install.sh --uninstall
```

**不会自动做的事**(手动清理):

- 不动 `~/github/my_dot_files/secrets.sh` 的 tipsy-oncall marker 块(可能你还有本地脚本在用)。手动删就是把 `# tipsy-oncall skill (auto-append)` 到 `# end of tipsy-oncall skill` 之间整块删掉。
- 不移除 4 个 MCP server(可能被其它 skill 共用)。要移除:`claude mcp remove <name> -s user`。
- 不删项目级 `.claude/skills/tipsy-debug/`。想清理旧的走 `./install.sh --replace-legacy`(见下)。

## 处理旧的项目级 tipsy-debug

`~/github/tipsy-backend/.claude/skills/tipsy-debug/` 是项目级 skill,能力已被 tipsy-oncall 全量覆盖。**默认不动**,想清理:

```bash
./install.sh --replace-legacy
```

会**只删** `~/github/tipsy-backend/.claude/skills/tipsy-debug/`(不动 worktrees、不动 `.agents/`)。删前会打印 `git status` 让你确认它没有未提交改动。

## 常见问题

**Q: skill 触发不到怎么办**
A: `claude mcp list` 看 MCP 是否连通;`ls ~/.claude/skills/tipsy-oncall/SKILL.md` 看是否装上;重启 Claude Code 会话。

**Q: 我不想要 auto-append 到 secrets.sh**
A: 从 `secrets.example.sh` 手动复制想要的行到你自己的 secrets 文件即可。install.sh 的 append 是幂等的:已存在的键跳过、不覆盖你手改过的值。

**Q: prod / test 我只有一个环境的凭证**
A: 另一个环境的键留 `""` 即可;`§2 前置` 的自检只在你真的走那个环境的通道时才 fail。

**Q: MCP 断线**
A: `bytebase / logfire / aliyun-sls` 用 stdio,会自愈;15s 内不通就在浏览器打开 `$TIPSY_BYTEBASE_URL/mcp` 重授权。别在断线状态空转。
