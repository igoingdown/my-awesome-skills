# bug-triage-loop 安装与移植说明

本 skill 是"个人 AI Bug Triage Agent"—— 用 Claude Code `/loop` 每 N 分钟从飞书 Bug 群拉新消息、挑一条真 bug 判定/定位/生成 review markdown 给你 approve,**严格串行、单人操作、零部署**。

本文档只讲**安装 / 凭证 / 移植**,不重复 SKILL.md 里的运行逻辑。

---

## 1. 会用到的工具 / 组件

### 1.1 CLI(本机必装)

| 工具 | 用途 | 缺了会怎样 |
|---|---|---|
| Claude Code | 唯一运行时。`/loop` 和 `Skill` 工具都在这里 | skill 根本跑不起来 |
| `lark-cli`(≥ 最新)| 飞书 API 全靠它(拉群历史、发私聊、下载附件、解析 open_id) | Step 4/12 直接失败 |
| `git`(≥ 2.5) | Step 7 用 `git worktree add --detach` 隔离多仓查代码 | 定位阶段无隔离,污染主 checkout |
| `jq` | Step 3/5/10 处理 JSONL 状态文件 | 状态过滤/写入全崩 |
| `python3` | 手动改 review-queue.jsonl 尾部状态时用(见 SKILL.md § 用户 review 后处理) | 仅影响故障恢复兜底 |
| `shasum`, `awk`, `tail`, `sed`, `grep`, `date` | Step 3/7/13 辅助 | 系统自带,通常不缺 |

### 1.2 MCP servers(**强烈推荐**,可选但缺了会严重降级)

以下 MCP server 由 Claude Code 侧独立配置,skill 通过 `Skill` 工具或直接调用它们的 `mcp__<server>__*` 工具访问。

| MCP | 用途 | 缺了的降级路径 |
|---|---|---|
| `aliyun-sls` | 查生产 SLS 日志(uid 精确命中、异常路径、tag=strong_signal 的核心来源) | 走 lark-cli 转 Grafana 网页 / 让子 agent 起 curl,极慢 |
| `bytebase` | 查 MySQL 主表 uid 状态、订单表、character 表 (`ground_truth` 主来源) | 无 `confirmed` 报告(必须一条现网数据 ground_truth) |
| `signoz` | trace / APM / P99 抖动 | 影响面估算精度降 |
| `logfire` | Python 服务(memory / recsys)观测 | memory 侧根因判定慢 |

MCP 是"可选但强烈推荐"。缺 MCP 时子 agent 需自己 curl / ssh 兜底,速度和证据 tag 都会降级。

### 1.3 子 Skill(Claude Code 里必须能被 `Skill` 工具索引到)

**硬依赖(装不齐 skill 无法工作)**:
- `lark-im` —— 拉群历史(`+chats-messages-get`)、发私聊(`+messages-send`)、下载附件(`+messages-resources-download`)
- `lark-contact` —— 姓名 ↔ open_id 解析(Step 12.5 找修复 commit author 的飞书身份)
- `lark-shared` —— lark-cli 认证 / 身份切换(bot vs user)/ scope 缺失排查

**软依赖(有则用,没有则走 MCP 直查)**:
- `lark-event` —— 长时事件订阅(bug 群实时消息;/loop 定时拉的另一路兜底)
- 项目侧 oncall / debug skill(如 `tipsy-oncall` / `tipsy-debug`)—— 封装了 SLS/DMS/Lindorm/Redis 查询和"现象/通道/查询/结论/后续"输出格式
- 项目侧 code-analyze skill(如 `bug-analyze`)—— 封装了"按现象反查代码"的搜索路径

无软依赖时,主 loop 让子 agent 自己 Read+grep+直调 MCP,精度和速度都会降。

---

## 2. 凭证管理

### 2.1 需要的凭证清单

| 凭证 | 用途 | 现存位置 | 谁生成 |
|---|---|---|---|
| `lark-cli` app_id + app_secret | bot 身份(发私聊、下载附件默认) | `~/.lark-cli/config.json` | `lark-cli config init --new` 引导录入 |
| `lark-cli` user access token | user 身份(拉群历史必须 user) | `~/.lark-cli/cache/` | `lark-cli auth login --domain all` OAuth 后写入 |
| `ALIYUN_SLS_AK_ID` + `ALIYUN_SLS_AK_SECRET` | aliyun-sls MCP 查生产日志 | `~/github/my_dot_files/secrets.sh` 里 `export` | 阿里云 RAM 子账号,自己去 RAM 控制台建 |
| `ALIYUN_SLS_ENDPOINT` / `SLS_PROJECT` / `LOGSTORE` | 日志库定位 | 同上 | 阿里云 SLS 控制台复制 |
| `TIPSY_BYTEBASE_URL` + bytebase token | bytebase MCP 查 MySQL | 同上(URL 里带 token) | bytebase 后台建 personal token |
| `ALIYUN_DMS_LINDORM_URL_*` | Lindorm(聊天历史)DMS 网关 | 同上 | 阿里云 DMS 后台生成 |
| `ALIYUN_DMS_ES_URL_PROD` + `ES_USERNAME/PASSWORD` | ES 直查 | 同上 | 阿里云 ES 控制台 |
| `COOLIFY_URL` + `COOLIFY_TOKEN` | (可选)部署状态 / 环境隔离查询 | 同上 | Coolify 后台 |
| `bug_chat_id` + `my_open_id` + `github_root` | **本 skill 的运行时配置**(非凭证) | `<skill>/docs/config.md` | 用户在 `docs/config.md` 里手填 |

### 2.2 凭证载入约定

- **`~/github/my_dot_files/secrets.sh`**:所有 API AK/SK/Token 都在这个文件里 `export VAR=xxx`,由用户手动维护,**不进任何 git**。通常在 shell rc (`~/.zshrc` / `~/.bashrc`) 里 `source ~/github/my_dot_files/secrets.sh`,让所有子进程默认继承。
- **MCP server 环境变量**:Claude Code 启动 MCP server 子进程时会继承 shell 环境。**关键陷阱**:如果 Claude Code 从 GUI(非 login shell)启动,`~/.zshrc` 里的 source 不会跑;需要把 secrets 显式写到 launchd plist 或者用 `env` 前置。
- **`~/.lark-cli/`**:CLI 用的目录,里面 `config.json` 存 app_id/app_secret(权限 600),`cache/` 存 OAuth token。**不要**手动改这两个,用 `lark-cli config init` / `lark-cli auth login` 操作。
- **`docs/config.md`**:本 skill 的**运行时配置**,由用户在装完 skill 后编辑,里面填的是 chat_id / open_id / 仓库映射,不是密钥;**可以进私有仓,不要进公开仓**(chat_id / open_id 属于身份数据)。

### 2.3 谁读什么

```
Claude Code 主进程
├── 读 shell 环境变量(经 launchd 或 login shell 注入)
│   ├── 拉起 aliyun-sls MCP server 子进程 → 读 ALIYUN_SLS_*
│   ├── 拉起 bytebase MCP server 子进程   → 读 TIPSY_BYTEBASE_URL
│   └── 拉起 signoz / logfire MCP server  → 读各自的 endpoint/token
│
└── 通过 Skill 工具启动 lark-im / lark-contact skill
    └── 这些 skill 内部 spawn lark-cli 子进程
        └── lark-cli 读 ~/.lark-cli/config.json + cache/
```

**bug-triage-loop skill 本身不读任何密钥文件**,它只读 `docs/config.md` 里的非机密配置,所有敏感调用都委托给上面的 skill/MCP。这是本 skill 的设计原则(SKILL.md § 严格约束里也写了)。

---

## 3. 移植到远程开发机(devbox / GitHub Codespaces / 云主机)

远程机的坑主要在**凭证注入 + 认证互动**两块。下面按顺序做。

### 3.1 装宿主环境(远程机上一次性)

```bash
# Claude Code(macOS/Linux)—— 参照官方
# https://docs.anthropic.com/en/docs/claude-code/quickstart

# Node.js + npm(≥ 20)
# 装了 nvm 就 nvm install --lts;没有就用发行版包管理

# 关键 CLI
npm install -g @lark/cli    # lark-cli(bot + user 双身份必需)

# 依赖工具
sudo apt install -y jq python3 git curl   # Linux
brew install jq python3 git curl          # macOS(通常已有)
```

### 3.2 注入凭证(**三选一**,不要硬编码到 skill 里)

#### (a) scp 同步 secrets.sh —— 私有机推荐

```bash
# 本地
scp ~/github/my_dot_files/secrets.sh <remote>:~/github/my_dot_files/secrets.sh
ssh <remote> 'chmod 600 ~/github/my_dot_files/secrets.sh'

# 远程机 shell rc(~/.zshrc / ~/.bashrc)
echo 'source ~/github/my_dot_files/secrets.sh' >> ~/.zshrc
```

⚠️ `secrets.sh` 权限 600,且**不进任何 git**(本地和远程 my_dot_files 都是私有仓)。

#### (b) 远程 secret manager —— 云平台推荐

- GitHub Codespaces:仓库 Settings → Secrets and variables → Codespaces → 一个个加 `ALIYUN_SLS_AK_ID` 等等。启动 codespace 时自动注入到环境变量。
- devbox / 其他云:各家有自己的 env 注入机制,把 §2.1 表里的每一项都设成 secret。

#### (c) sops / age 加密仓 —— 极私有场景

- 用 `sops --age` 把 secrets.sh 加密,加密后的 `secrets.enc.sh` 可以进 my_dot_files 仓
- 远程机装 sops + 私钥,shell rc 里 `eval "$(sops -d ~/github/my_dot_files/secrets.enc.sh)"`

**永远不要**:把 secrets 明文硬编码到 SKILL.md、docs/config.md、`.env` 提交进公开仓。

### 3.3 lark-cli 首次认证(远程机上必做一次)

lark-cli 的 OAuth 需要浏览器打开授权链接,远程机可能没浏览器,用二维码兜底:

```bash
# 1) bot 身份:填 app_id/app_secret
lark-cli config init --new
# 交互输入 app_id / app_secret(去飞书开放平台复制,不要泄露)

# 2) user 身份:OAuth
lark-cli auth login --domain all
# 输出 verification_url —— 在本地浏览器打开;或用二维码:
lark-cli auth qrcode <verification_url>   # 打印 ASCII 二维码扫码

# 3) 验证
lark-cli auth status --json --verify
# 期望看到 identities.user.tokenStatus == "valid"
```

**注意**:token 有有效期(飞书 user token 默认 30 天),过期后 skill 会失败,需要重跑 `lark-cli auth login`。

### 3.4 装依赖 skill(不在本仓的)

本仓只装 `bug-triage-loop`。它硬依赖 lark-im / lark-contact / lark-shared,可选依赖 lark-event 和项目侧 oncall/debug/code-analyze skill。

```bash
# lark-* 系(在 lark-cli 的 skill registry 里,一般跟 lark-cli 一起装)
lark-cli skills install lark-im lark-contact lark-shared lark-event

# 项目侧 skill(如果远程机也跑 tipsy)
# 直接 cp / clone 项目仓下的 .claude/skills/* 到 ~/.claude/skills/
```

**验证**:进 Claude Code 后输入 `/help` 或让它 `list available skills`,确认能看到 `lark-im` / `bug-triage-loop`。

### 3.5 装本 skill

```bash
# clone 本仓到远程机
git clone <this-repo-url> ~/github/my-awesome-skills

# 只装 bug-triage-loop(推荐,少污染)
cd ~/github/my-awesome-skills
./sync.sh bug-triage-loop
```

`sync.sh` 会把 skill 拷到 `~/.claude/skills/bug-triage-loop/` 和 `~/.agents/skills/bug-triage-loop/`,并把本 INSTALL.md 打印一遍提醒你走后续步骤。

### 3.6 调整 config.md

远程机上的 GitHub 工作目录路径通常和本机不同(比如 `/root/github/` 或 `/home/ubuntu/github/`):

```bash
$EDITOR ~/.claude/skills/bug-triage-loop/docs/config.md
```

关键改动:
1. `bug_chat_id` / `my_open_id` —— 填你自己的
2. `github_root` —— 远程机上的绝对路径
3. §"涉及的仓库"表里每一行的路径都要换到远程机上真实路径
4. §"涉及的仓库"表里的分支(如 `dev` vs `main`)按目标项目实际的默认分支填,不要照抄示例

### 3.7 fetch 候选仓(worktree 前置)

本 skill 用 `git worktree add --detach origin/<branch>` 隔离,要求远程机上每个候选仓已经 fetch 过:

```bash
for repo in ~/github/*/; do
  [[ -d "$repo/.git" ]] || continue
  git -C "$repo" fetch --all --prune 2>&1 | tail -1
done
```

不预 fetch 的话,首次跑 Step 7 会因 `origin/<branch>` 不存在报错。

### 3.8 state/ 目录不迁

`state/processed.jsonl` / `review-queue.jsonl` / `handoff-drafts/` **含真实事故内容和用户投诉细节**,不要跟公开 skill 一起同步。每台远程机各自 state 独立,首次跑就是空目录,skill 会自动生成。

- `sync.sh` 只拷 skill 目录本体,不动 `~/.claude/skills/<skill>/state/`(本 skill 的 state 不在 skill 目录里,skill 会写到运行目录下的 `state/`,取决于 Claude Code 启动路径)
- 如果非要迁旧 state 到新机(比如换机),手动 `rsync -av <old>:<state_dir> <new>:<state_dir>`,注意权限

### 3.9 MCP server 在远程机上部署

MCP server 是独立的 Node/Python 子进程,Claude Code 通过 stdio 唤起。远程机需要:

1. 装每个 MCP server 二进制(`npm i -g @xxx/mcp-server-aliyun-sls` 之类,或 clone 源码 build)
2. 在 Claude Code 的 MCP 配置文件里(路径视版本,通常在 `~/.config/claude/` 或 `~/.claude/mcp.json`)加 server 定义,并显式把 §2.1 表里的环境变量传给 server
3. 首次跑 Claude Code 后 `list mcp servers` 确认都 connected

**验证 MCP 通路**:让 Claude Code 跑一个只读 MCP 工具(比如 `mcp__aliyun-sls__list_projects`),能返回结果就说明凭证注入成功。

### 3.10 /loop 挂持久 session

远程机想让 skill 一直跑,需要 Claude Code 会话保持:

**方案 A —— 交互式(推荐调试期用)**:
```bash
tmux new -s bug-triage
claude
# 在 Claude Code 里:
/loop 5m /bug-triage-loop
# Ctrl+B D 断开 tmux,session 后台跑
```

**方案 B —— headless / SDK**(推荐生产用):
- 用 Claude Code SDK 或 headless 模式挂 `nohup` / systemd unit
- 具体参考 Claude Code 官方 SDK 文档

**注意**:关机或断连后 `/loop` 停,但 `state/` 里的 `processed.jsonl` 是持久化的,重连后重新 `/loop` 即可从上次 message_id 之后继续(SKILL.md Step 3/4)。

---

## 4. 装完自检清单

按顺序跑,每一步都能通就装完了:

```bash
# 1) 宿主
claude --version                # Claude Code 装好了
node -v && npm -v               # Node ≥ 20
lark-cli --version              # lark-cli 在 PATH
jq --version                    # jq 装好了
git --version                   # git ≥ 2.5

# 2) 凭证
lark-cli auth status --json --verify | jq .identities.user.tokenStatus
#   期望 "valid"
env | grep -c ^ALIYUN_SLS_AK_ID
#   期望 1(secrets.sh 已 source)

# 3) skill 可见
ls ~/.claude/skills/bug-triage-loop/SKILL.md
ls ~/.claude/skills/lark-im/SKILL.md          # 硬依赖
ls ~/.claude/skills/lark-contact/SKILL.md     # 硬依赖
ls ~/.claude/skills/lark-shared/SKILL.md      # 硬依赖

# 4) 配置填完
grep -E "^(bug_chat_id|my_open_id|github_root):" \
  ~/.claude/skills/bug-triage-loop/docs/config.md | grep -v FILL_ME | wc -l
#   期望 3(三个必填都填了)

# 5) MCP 通路(如果配了)
#   在 Claude Code 里:让它跑 mcp__aliyun-sls__list_projects,能返回不报错
#   在 Claude Code 里:让它跑 mcp__bytebase__search_api,能返回不报错

# 6) 手动跑一轮
claude "/bug-triage-loop"
#   期望:输出 "Step 0: 加载配置..." 一路到 "本轮无新消息" 或 "生成 review markdown"

# 7) 挂 /loop
claude "/loop 5m /bug-triage-loop"
```

任一步失败,回到本文对应章节复查。

---

## 5. 卸载

```bash
# 手动
rm -rf ~/.claude/skills/bug-triage-loop
rm -rf ~/.agents/skills/bug-triage-loop
# state/ 目录如果单独放了别的地方,自己按需清理

# 凭证不清(可能其他 skill 也在用)
```
