# tool-bridge 接入：保姆级教程

把 `lindorm-chat-history` 接到你团队的 **tool-bridge** 网关（地址放本地 secrets 的 `$TB_BASE_URL`）上，作为**可选后端**。
lindorm 直连仍是默认后端——故障域不收敛，TB 挂了照样能查。

> 我（Claude）已经把所有能自动做的都做完了（脚本、集成、探测工具、配置占位）。
> **你只需要做一件人工的事：第 1 步用浏览器登录换 SK。** 换完把值告诉我，剩下的我接着跑。

---

## 全流程一览

| 步骤 | 谁做 | 状态 |
|---|---|---|
| 0. 集成 TB 后端到脚本、写探测工具、预置 secrets 占位 | Claude | ✅ 已完成 |
| 1. 浏览器登录 `/login` 换取 SK + BaseURL | 你（唯一人工步骤） | ✅ 已完成 |
| 2. 把 SK/BaseURL 填进 secrets.sh | Claude | ✅ 已完成 |
| 3. 跑 `tb_probe.sh` 实测 TB 到底能干什么 | Claude | ✅ 已完成 |
| 4. 按实测结果对齐工具名/入参，定稿接线 | Claude | ✅ 已完成 |
| 5. 更新 SKILL.md 与持久记忆 | Claude | ✅ 已完成 |

> **已跑通（含拉原文）。** 实测结论：网关有两套引擎——搜索侧计数/聚合工具(ES) 禁正文且无 sender_type；
> **宽表侧 SQL 查询工具可拿 content + sender_type 真值**。所以 `--backend tool-bridge` 已实现
> count / page / **export（拉原文落本机）**；批量多 UID 用 `tb_chat_batch.sh`（严格串行护共享 devbox）。
> 详见 SKILL.md「tool-bridge 后端」节。下面步骤 1-2 保留作换 key 时的参考。

---

## 第 1 步（唯一需要你动手）：换 SK

浏览器打开你网关的登录页：

```
$TB_BASE_URL/login
```

1. 跳转你组织的 OAuth，用你的账号授权。
2. 回调页会**一次性明文**显示你的 **SK** 和 **BaseURL** —— 立即复制，明文只显示这一次。
3. 把这两个值贴给我（在对话里发给我即可），或按第 2 步自己填。

关于这把 key，先知道几点：

- **有有效期**，过期重新走 `/login`（具体时长以你网关策略为准）。
- 同一人再次登录通常会 **rotate**（旧 key 先删再签），所以每人同时只持有一把登录 key。
  ⚠️ 如果你别处已经在用这把 key，重新登录会让旧的失效。
- 登录可能**自动绑定你的操作人身份**（本用途用不到，但要知道）。
- 普通 token 的作用域由网关策略决定（通常是各挂载点的 read/call/write，管理员专属挂载点看不见）。

> 安全提醒：SK 等价于一段时间内你在网关上的全部权限。只贴给我用于填 secrets，
> 不要提交进任何 git 仓库；secrets.sh 本身就在仓库外（`~/github/my_dot_files/`）。

---

## 第 2 步：填 secrets（我可以代填）

我已经在 `~/github/my_dot_files/secrets.sh` 末尾预置了待填占位块：

```bash
# --- tool-bridge 网关（lindorm-chat-history 用）---
export TB_BASE_URL="https://your-tool-bridge.example.com"
export TB_SK=""   # ← 浏览器 /login 换来的 key 填这里
```

你把 SK 贴给我，我用工具写进去（不回显值）。或你自己编辑填 `TB_SK`。

---

## 第 3 步：探测（我来跑）

拿到 SK 后，第一件事**不是**直接用，而是自证 TB 能干什么。这是本 skill 的铁律
（"宣布查得到/查不到之前先实测，别凭手册一句话下结论"）。跑：

```bash
bash skills/lindorm-chat-history/tb_probe.sh
```

它会实测四件事并给判定：

1. `~tree` 全树（受权限裁剪，普通 token 通常只见 mcp / plugins / skills 几棵）。
2. 你的聊天数据源（env `TB_CHAT_SOURCE`）工具索引里有没有 检索/查询/日志/文档读取 类工具。
3. 只读查库源（env `TB_DB_SOURCE`）通道（若原文其实在 MySQL/PG，可绕过搜索侧的正文限制）。
4. 逐个候选检索工具（env `TB_PROBE_TOOLS`）的入参 schema，看返回**有没有逐条原文/content 字段**。

---

## 第 4 步：接线结果（已定稿）

**核心张力**曾是：本 skill 的价值是「拉聊天**原文**」，而搜索侧计数工具只能 count/聚合、禁正文。
**实测破解**：同一源还有宽表侧 SQL 查询工具，能 `SELECT content` + `sender_type` 真值。
所以最终接线：

- **count** → 宽表 `SELECT COUNT(*) WHERE rev_user_id=<REV>`。
- **page / export（原文）** → 宽表 SQL 查询分页取原文落本机（含 sender_type）。
- **批量多 UID** → `tb_chat_batch.sh` 串行 + 限速。

用法示例：
```bash
# 单 UID 取近期 1000 条原文（含 sender_type）落本机
bash query_chat_history.sh <uid> --backend tool-bridge --size 1000 --export /tmp/chat.jsonl
# rev_user_id 是负数时加 --reversed
bash query_chat_history.sh <负数 rev_user_id> --reversed --backend tool-bridge --export /tmp/chat.jsonl
# 10 个 UID 批量（严格串行，护共享 devbox）
bash tb_chat_batch.sh --uids "u1,u2,...,u10" --size 1000 --outdir /tmp/chat_out
```

默认后端仍是 lindorm 直连，TB 是纯增量，不返工。守则见 SKILL.md「实现里必须守的坑」。

---

## 现在就能用的东西（不依赖 SK）

- **通用 TB 调用器** `tb_call.sh`：拿到 SK 后可直接渐进发现，不用记 API：
  ```bash
  bash skills/lindorm-chat-history/tb_call.sh tree 2                     # 看全树
  bash skills/lindorm-chat-history/tb_call.sh help mcp/<你的源>          # 看某源工具索引
  bash skills/lindorm-chat-history/tb_call.sh help mcp/<你的源>/<工具名>  # 看单工具入参 schema
  bash skills/lindorm-chat-history/tb_call.sh call <path> '<json>'       # 调用
  ```
- **主脚本的 lindorm 直连**：完全不受影响，一切照旧。

---

## 附：网关上部分源用不了时怎么打通（通用经验）

`tb_call.sh tree` 能**看见**的源不等于都能**用**——普通 token 的作用域、各源的授权/绑定状态都会挡路。
下面是与具体网关无关的通用套路（你自己网关的真实节点名/报错码用 `tb_probe.sh` 实测为准）：

### tb CLI 前置

网关 CLI 可能只在较新 Node 下能跑（老版本会崩），用前先切版本：

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use <受支持的 node 版本>
source ~/github/my_dot_files/secrets.sh
tb login --base-url "$TB_BASE_URL" --sk "$TB_SK"   # 非交互，SK 从 secrets
tb whoami                                          # 应显示 auth: ok
```

### 1. 飞书文档：优先用本地 lark-cli

网关侧飞书节点常走**应用身份**(tenant_access_token)，只能读该应用被授权过的文档，建/写受限库会报权限码。
**本机 `lark-cli`（你本人身份）**天然有自己文档权限，建文档/读私有文档/写知识库全走它更省事。读 docx：
`lark-cli docs +fetch --doc <id或URL> --doc-format markdown`。

### 2. 需绑定操作人身份的源

有的源要管理员把你的 SK 绑到你的操作人身份才能用；未绑时连只读都可能 `permission_denied`。
绑定后写操作署名成你本人。**替代**：若该源另有**固定挂载身份**的入口，可开箱即用，但写操作署名不是你——
落地前想清楚署名归属。

### 3. 需 OAuth / 特殊 scope 授权的源

有的源要 OAuth 授权或「注册挂载点」scope，普通 token 没有，得管理员用 admin token 授权，
前提是你有能访问对应项目的账号。

## 报错速查（TB 侧）

| 现象 | 原因 | 处理 |
|---|---|---|
| `permission_denied: missing or unrecognized secret key` | SK 没填 / 填错 / 已过期或被 rotate | 重走第 1 步换 SK |
| `~tree` 看不到管理员专属挂载点 | 普通 token 无该 scope | 正常，非报错；需 admin 能力找管理员 |
| 调工具报字段/工具名不存在 | 手册工具名与你网关线上不一致 | 跑 `tb_probe.sh` 看真实 schema，把真名填进 `LINDORM_TB_*` |
| count 返回 0 | 用了 user_id 而非 rev_user_id | 宽表字段是 rev_user_id，脚本已自动反转；核对反转口径 |
