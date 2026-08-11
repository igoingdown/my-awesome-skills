# tool-bridge 试点：保姆级教程

把 `lindorm-chat-history` 接到团队的 **tool-bridge**（`https://tool-bridge.fantacy.live`）网关上，作为**可选后端**。
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

> **试点已跑通（含拉原文）。** 实测结论：TB 有两套引擎——搜索侧 `chatsearch_*`(ES) 禁正文且无 sender_type；
> **宽表侧 `lindorm_query`(SQL) 可拿 content + sender_type 真值**。所以 `--backend tool-bridge` 已实现
> count / page / **export（拉原文落本机）**；批量多 UID 用 `tb_chat_batch.sh`（严格串行护 devbox）。
> 详见 SKILL.md「tool-bridge 后端」节。下面步骤 1-2 保留作换 key 时的参考。

---

## 第 1 步（唯一需要你动手）：换 SK

浏览器打开：

```
https://tool-bridge.fantacy.live/login
```

1. 跳转企业飞书 OAuth，用你的飞书账号授权（本企业成员即准入，不校验邮箱域）。
2. 回调页会**一次性明文**显示你的 **SK** 和 **BaseURL** —— 立即复制，明文只显示这一次。
3. 把这两个值贴给我（在对话里发给我即可），或按第 2 步自己填。

关于这把 key，先知道几点：

- **有效期 90 天**，过期重新走 `/login`。
- 同一人再次登录会 **rotate**（旧 key 先删再签），所以每人同时只持有一把登录 key。
  ⚠️ 如果你别处已经在用这把 key，重新登录会让旧的失效。
- 登录**不会**自动绑定 `plugins/meego` 的操作人身份——那条通路仍需管理员显式配 `userKeys` 映射（见附录第 2 节，别按“登录即绑定”预期它）。
- 普通 token 作用域固定为 `mcp/** + plugins/** + skills/**` 的 read/call/write；
  `system/**`、`device/**` 看不见（admin 才有）。

> 安全提醒：SK 等价于一段时间内你在网关上的全部权限。只贴给我用于填 secrets，
> 不要提交进任何 git 仓库；secrets.sh 本身就在仓库外（`~/github/my_dot_files/`）。

---

## 第 2 步：填 secrets（我可以代填）

我已经在 `~/github/my_dot_files/secrets.sh` 末尾预置了待填占位块：

```bash
# --- tool-bridge 网关（lindorm-chat-history 试点用）---
export TB_BASE_URL="https://tool-bridge.fantacy.live"
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

1. `~tree` 全树（普通 token 应只见 mcp / plugins / skills 三棵）。
2. `mcp/tipsy` 工具索引里有没有 `chatsearch_*` / `lindorm_*` / `sls_*` / `feishu_read_doc`。
3. `plugins/bytebase` 只读通道（若原文其实在 MySQL/PG，可绕过 chatsearch 的正文限制）。
4. 逐个 `chatsearch_*` 工具的入参 schema，看返回**有没有逐条原文/content 字段**。

---

## 第 4 步：接线结果（已定稿）

**核心张力**曾是：本 skill 的价值是「拉聊天**原文**」，而 `chatsearch_*` 只能 count/聚合、禁正文。
**实测破解**：tipsy 源还有宽表侧 `lindorm_query`(SQL)，能 `SELECT content` + `sender_type` 真值。
所以最终接线：

- **count** → 宽表 `SELECT COUNT(*) WHERE rev_user_id=<REV>`。
- **page / export（原文）** → 宽表 `lindorm_query` 分页取原文落本机（含 sender_type）。
- **批量多 UID** → `tb_chat_batch.sh` 串行 + 限速。

用法示例：
```bash
# 单 UID 取近期 1000 条原文（含 sender_type）落本机
bash query_chat_history.sh <uid> --backend tool-bridge --size 1000 --export /tmp/chat.jsonl
# rev_user_id 是负数时加 --reversed
bash query_chat_history.sh -9223219043268000945 --reversed --backend tool-bridge --export /tmp/chat.jsonl
# 10 个 UID 批量（严格串行，护 devbox）
bash tb_chat_batch.sh --uids "u1,u2,...,u10" --size 1000 --outdir /tmp/chat_out
```

默认后端仍是 lindorm 直连，TB 是纯增量，不返工。守则见 SKILL.md「实现里必须守的坑」与 [[devbox-query-pressure-discipline]]。

---

## 现在就能用的东西（不依赖 SK）

- **通用 TB 调用器** `tb_call.sh`：拿到 SK 后可直接渐进发现，不用记 API：
  ```bash
  bash skills/lindorm-chat-history/tb_call.sh tree 2                     # 看全树
  bash skills/lindorm-chat-history/tb_call.sh help mcp/tipsy             # 看某源工具索引
  bash skills/lindorm-chat-history/tb_call.sh help mcp/tipsy/<工具名>     # 看单工具入参 schema
  bash skills/lindorm-chat-history/tb_call.sh call <path> '<json>'       # 调用
  ```
- **主脚本的 lindorm 直连**：完全不受影响，一切照旧。

---

## 附：普通 token 用不了的三块能力，怎么打通（2026-08-06 实测）

全树验证发现，普通 token 虽能**看见** 6 mcp + 4 plugins + 2 skillhub，但三块实际用不了。逐条解法：

### tb CLI 前置（Expo 授权、meego 验证都要用）

`@tool-bridge/cli` 已装，但**只在 Node≥22 下能跑**（本机默认 node v14 会崩，先 `nvm use 24`）：

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm use 24
source ~/github/my_dot_files/secrets.sh
tb login --base-url "$TB_BASE_URL" --sk "$TB_SK"   # 非交互，SK 从 secrets
tb whoami                                          # 应显示 auth: ok
```

### 1. 飞书：用本地 lark-cli，不用平台那套

`plugins/feishu` 走租户 `tenant_access_token`（**应用身份**），只能读那个应用被授权过的文档，
建知识库/写受限库会报 `131006`/`1770032`。**本机已装 `lark-cli`（你本人身份，天然有自己文档权限）**——
建文档/读私有文档/写知识库全走它，忽略 feishu 节点即可。读 docx：
`lark-cli docs +fetch --doc <id或URL> --doc-format markdown`。

### 2. Meego：两条通路，`mcp/meego` 已实测可用（读+评论），`plugins/meego` 仍需管理员绑定

Meego 有两个入口，别混：

- **`mcp/meego`（固定身份，读+评论已跑通）**：不需要绑定即可用，读类（列工作项类型、按 MQL 查、查状态、查评论）与 `add_comment` 都实测成功。代价是写操作署名是那个固定身份、不是你本人。适合“查我要关注的需求/缺陷、给某条留言”这类日常。
- **`plugins/meego`（以调用方身份落地）**：要写操作显示成你本人才走这条，报 `未绑定 Meego 操作人身份` 时**需管理员**在网关该节点 `providerConfig.userKeys` 加 `{"<你的SK>":"<你的user_key>"}`（user_key 用邮箱经 `query_user` 反查）。**飞书登录不会自动建这条映射**，别指望登录即绑定。

用 `mcp/meego` 时几个必踩的坑（都实测过）：
- **几乎每个工具都要 `project_key`**，而它无法自动列举，只能从 Meego 网页 URL 里取（形如路径中的空间标识）；传错或漏传即失败。
- **字段 label 因工作项类型而异**：缺陷类的标题字段名与需求类不同，写 MQL / 解析返回前先确认目标类型的字段名，别套用另一类的。
- 返回体尾部可能拼有诊断串，解析时先剥掉再取数据；评论定位要用真实数字 ID。
- 查“某条缺陷现在是进行中还是已解决”要显式 select 状态字段，默认查询不带它。

### 3. Expo：需管理员授权（普通 token 无 register scope）

Expo = 跨平台 App 平台（React Native/EAS 云构建/OTA/TestFlight）。`mcp/expo` 给 Agent 查
Expo 文档/EAS Build 历史/Update 渠道/TestFlight 崩溃。**自己授权不了**：`tb tool auth mcp/expo`
实测报 `no scope grants 'register' on 'mcp/expo'`——普通 token 没有注册/授权挂载点的权限。
须管理员用 admin token 跑 `tb tool auth mcp/expo` 完成 OAuth，或给你的 SK 授 register scope；
前提是你有能访问团队项目的 Expo 账号。

## 报错速查（TB 侧）

| 现象 | 原因 | 处理 |
|---|---|---|
| `permission_denied: missing or unrecognized secret key` | SK 没填 / 填错 / 已过期或被 rotate | 重走第 1 步换 SK |
| `~tree` 看不到 `system`/`device` | 普通 token 无该 scope | 正常，非报错；需 admin 能力找管理员 |
| 调 `chatsearch_*` 报字段/工具名不存在 | 手册工具名与线上不一致 | 跑 `tb_probe.sh` 看真实 schema，把真名填进 `LINDORM_TB_*` |
| count 返回 0 | 用了 user_id 而非 rev_user_id | 索引字段是 rev_user_id，脚本已自动反转；核对反转口径 |
