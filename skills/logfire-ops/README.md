# logfire-ops skill

把「Logfire 看板运维 + 定期巡检 + trace 根因分析 + 量化决策」打包成一个 Claude Code skill，给团队同学共用。属于 [my-awesome-skills](https://github.com/igoingdown/my-awesome-skills) 仓库下的一个 skill。

## 一键安装

两条路径：

**A. 单装本 skill（含 MCP 配置/体检，推荐首次使用）**

```bash
cd skills/logfire-ops
./install.sh
```

**B. 批量同步整个仓库的 skill**（仓库根的 `sync.sh`，只拷文件、不配 MCP）

```bash
./sync.sh   # 在仓库根运行；首次仍需跑一次 A 或手动 claude mcp add 接上 logfire MCP
```

`install.sh` 会：

1. 把 skill 复制到 `~/.claude/skills/logfire-ops/`（全局，所有项目可用）。
2. 配置 `logfire` MCP server（HTTP transport + 你的 read token，user scope）。

> 如果你**已经**配过 logfire MCP 且连接正常，脚本会自动跳过这步、不需要 token。
> 配置存在但连不上（比如之前 add 时没带 token），脚本会提示你加 `--force-mcp` 重配。
> 没配过的话，会提示你粘贴 read token（输入不回显）。

### Read token 怎么拿

Logfire → 选 **tipsy** 项目 → **Settings** → **Read tokens** → **Create**。
token 形如 `pylf_v2_us_...`，是只读密钥。可以每人建一个，也可以团队共用一个。

> ⚠️ token 是密钥，**不要**提交进仓库或写进脚本。脚本本身不内置任何 token。

### 其它安装姿势

```bash
LOGFIRE_READ_TOKEN=pylf_... ./install.sh   # 非交互（CI/批量）
./install.sh --token pylf_...              # 直接传
./install.sh --dry-run                     # 预览，不实际改文件
./install.sh --skill-only                  # 只装 skill
./install.sh --mcp-only                    # 只配 MCP
./install.sh --force-mcp                   # 重配已有的 logfire MCP
./install.sh --force                       # 覆盖本地已有同名 skill
./install.sh --region eu                   # EU 区（默认 us）
./install.sh --uninstall                   # 卸载
./install.sh --help
```

## 验证

```bash
claude mcp list   # 应看到：logfire ... ✓ Connected
```

在 Claude Code 里说下面任意一句，就会触发 `logfire-ops`：

- 「读一下线上告警 / 报警群」
- 「在 ddd 看板加个 5xx 趋势 panel」
- 「每 10 分钟巡检一下生产有没有新 5xx」
- 「这个报错帮我看下根因」（给 trace_id / project_id）
- 「这个 bug 一天就几次，值得修吗」

## 常见问题（踩坑实录）

以下都是真实安装中遇到过的问题与解法。

### 1. 用 `sync.sh` 装完 skill，MCP 没配上

**症状**：skill 列表里有 `logfire-ops`，但 `claude mcp list` 里没有 `logfire`，skill 跑起来说连不上 MCP。

**原因**：`sync.sh` 只拷贝 skill 文件、不配 MCP，而且以前同步完什么提示都没有。

**解法**：补跑一次 `./install.sh --mcp-only`。（现在 `sync.sh` 同步后会自动体检 logfire MCP，缺配置会打印接法指引。）

### 2. 已有一条无 token 的 logfire MCP 配置，重跑 install.sh 不生效

**症状**：`claude mcp list` 显示 `logfire ... ! Needs authentication`；重跑 `install.sh` 却输出「logfire MCP 已配置，保持原样」。

**原因**：脚本默认不动已有配置（怕覆盖你手动配好的），哪怕它没带 token。

**解法**：加 `--force-mcp` 强制重配：

```bash
LOGFIRE_READ_TOKEN=pylf_... ./install.sh --mcp-only --force-mcp
```

### 3. 忘了 read token 存在哪，不想再新建一个

Logfire 网页上 token **创建后就不再显示完整值**（Settings → Read tokens 里只有前缀），但配置过的机器上通常留有副本。token 都以 `pylf_` 开头，一条命令扫常见位置：

```bash
grep -rho 'pylf_[a-zA-Z0-9_]*' \
  ~/.claude.json ~/.logfire/ ~/.cursor/mcp.json ~/.codex/config.toml \
  ~/.zshrc ~/.zshenv ~/.zprofile ~/.bash_profile 2>/dev/null | sort -u
```

| 位置 | 说明 |
|---|---|
| `~/.claude.json` | Claude Code 的 MCP 配置（本脚本写入的就是这里），token 在 `mcpServers.logfire` 的 Authorization header 里 |
| `~/.cursor/mcp.json`、`~/.codex/config.toml` | 给 Cursor / Codex 配过 logfire MCP 的话 |
| `~/.logfire/default.toml` | `logfire auth` 的登录凭据（**不是** read token） |
| 项目下 `.logfire/logfire_credentials.json` | write token（**不是** read token） |

> MCP 需要的是 **read token**（`pylf_v2_us_...`）。从 `~/.claude.json` / `~/.cursor/mcp.json` 里翻出来的就是它，跨机器可复用。

### 4. SSH 到服务器上装，浏览器 OAuth 走不通

官方文档对 Claude Code 的首选方式是 `claude mcp add --transport http logfire <url>`，然后在会话里用 `/mcp` 走浏览器 OAuth。但 OAuth 回调打到 localhost，**SSH 远程会话（没配端口转发）走不通**。

**解法**：无头/远程环境直接用 read token（Bearer header）——也就是本脚本的默认方式。

### 5. MCP 配好了，当前已打开的 Claude Code 会话里还是用不了

MCP 工具在**会话启动时**加载，配置完成不会注入已经打开的会话。

**解法**：重开会话（或 `claude --resume <会话ID>` 回到原会话），再用 `claude mcp list` 确认 `✓ Connected`。

### 6. 要不要用官方本地的 logfire-mcp 包？

不要。它已废弃（GitHub 仓库归档、STDIO 包不再更新），官方现在只推荐 hosted 远程 MCP：`https://logfire-us.pydantic.dev/mcp`（EU 区换 `logfire-eu`）。本 skill 用的就是 hosted 方式，不需要装任何本地包。

## 能力一览

| 能力 | 说明 |
|---|---|
| 查询 / 捞日志 | `query_run` 查 `records`，含 schema、过滤铁律、配方 |
| 看板 panel 增改删 | 基于真实 Perses JSON 模板，增/改/删 panel、建看板、配变量 |
| 定期巡检 + 告警 | `/loop` 周期巡检 + Logfire alert（读告警=读 Logfire，不是飞书群） |
| trace 根因分析 | 按 trace 下钻 → 读应用层错误 → 回代码验证 → 给方案 |
| 量化决策 | 频率 × 影响面 × 严重度 × 趋势，判断值不值得修 |

## 目录结构

```
skills/logfire-ops/
├── SKILL.md                      # 入口：四类能力路由 + 三条铁律
├── install.sh                    # 一键安装（拷 skill + 配/体检 MCP）
├── README.md                     # 本文件
└── references/
    ├── query-cookbook.md         # records schema + 查询配方
    ├── dashboard-panels.md       # panel 增改删（真实 Perses 模板）
    ├── monitoring-loop.md        # /loop 巡检 + alert
    ├── rca-trace.md              # trace 根因分析方法论
    └── quant-decision.md         # 量化「值不值得修」
```

## 卸载

```bash
./install.sh --uninstall            # 推荐：带 marker 识别，安全删除
# 或手动：rm -rf ~/.claude/skills/logfire-ops
claude mcp remove logfire -s user   # 如需移除 MCP（可能被其它 skill 共用）
```
