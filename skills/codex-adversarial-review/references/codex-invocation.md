# CodeX 启动命令详解

## 固定配置（2026-10-26 用户定，所有 CodeX 评审默认这样跑）

| 项 | 取值 | 命令里怎么写 |
|---|---|---|
| 通道 | **官方订阅 CodeX**（ChatGPT 登录态） | `-c 'model_provider="openai"' -c 'forced_login_method="chatgpt"'` |
| 模型 | `gpt-6.1-sol`（界面名 GPT-6.1-Sol，用户口头叫「GPT-6.1 Solar」） | `-m gpt-6.1-sol` |
| 档位 | Ultrafast | `-c 'service_tier="ultrafast"' --enable ultrafast_mode` |
| 推理 | xhigh | `-c 'model_reasoning_effort="xhigh"'` |

- 两种模式都加 `-c 'agents.enabled=false' --disable multi_agent --disable multi_agent_v2`，关掉评审方进程内的子代理（只用 `--disable multi_agent` 关不掉，10-26 实测）。这和本 skill 的多路并行不冲突：多路是启动方起多个独立进程。
- **四项都在命令里显式写，并加 `--ignore-user-config` 不读 `~/.codex/config.toml`**（登录态仍从 `~/.codex` 读）。config 被别的会话或工具改过（10-16 实测 provider 段被整段删掉），靠默认值就可能悄悄换了通道、模型，或者关掉 ultrafast 开关（关掉开关时客户端不会打印降档 warning）。2026-10-26 用 codex 0.164.0 实跑确认这组参数可用：日志头 `provider: openai`，7 秒返回。
- 推理档：本模型的模型目录里 xhigh 之上还有 `max`（"Maximum reasoning depth"）和 `ultra`（"Maximum reasoning with automatic task delegation"，会自动派子任务，和反递归条款冲突，不用）。默认沿用实测过时长的 xhigh；要换 max 先实测一轮分面路的耗时再改。
- **换模型**：改这张表和 `scripts/run-one.sh` 的 `CODEX_REVIEW_MODEL` 默认值，再 `grep -rn 'gpt-6.1-sol'` 把 skill 里其余写到当前默认模型的地方一起改掉（监控从每路的 state 文件读期望模型，不用改）。用户宣布「现在用 X 做评审」时，当轮先跑一条最小评审确认 X 在官方通道下能调通、日志头是 `model: X`，再改这两处并同步运行时，回复里说一句「默认已切到 X」。同一句话被用户在多个 session 重复说，就是沉淀缺失。
- **本机 `codex` 要解析到包装脚本**（`command -v codex` 核一下）。包装脚本负责内存准入和出口代理；不要为了多开几路直接调底层二进制绕过准入，10-25 有一次这么干过，属于违规写法。

## 两种启动模式

### A. 打包只读模式（文档 / 分析报告 / runbook 默认用这个）

材料预先打进 prompt：文档全文、代码片段（每段标 `仓库 文件:行号（commit）`）、原始数据。评审方不能执行 shell 命令，也写不了文件。好处是最快，并且评审方越界写文件、连集群、污染宿主缓存这几类事故基本排除。

这个模式下评审方实际还剩哪些工具（2026-10-26 用本脚本实跑探针，让评审方自报工具清单并试写一个文件）：

- `apply_patch` 还在，但写文件被 read-only 策略拒绝：`patch rejected: writing is blocked by read-only sandbox`，文件没有落盘。所以 `--sandbox read-only` 不能去掉。
- 子代理工具（`collaboration.spawn_agent` 等）：只加 `--disable multi_agent` 时还在；加上 `-c 'agents.enabled=false' --disable multi_agent_v2` 后从工具清单里消失（同一探针复测）。prompt 里的反递归条款照样保留。
- 联网搜索工具、MCP 资源列举工具还在；不加载用户 config，所以 config 里配的 MCP 不会接进来（本机 `/etc/codex` 不存在，加了 `--ignore-user-config` 之后日志里也不再出现读 config 的 warning）。
- shell 类工具全部关闭。日志里的 `warning: Codex's Linux sandbox uses bubblewrap and needs access to create user namespaces.` 说的是命令执行沙箱在这台机器上起不来，pack 模式不执行命令，不受影响。

```bash
scripts/run-one.sh <轮次目录> <路名> pack            # 普通分面
scripts/run-one.sh <轮次目录> <路名> pack --search   # 外部取证那一路
```

脚本实际执行的核心命令（便于其他机器手写）：

```bash
env -i HOME=$HOME PATH=$PATH USER=$USER LANG=$LANG TERM=dumb KUBECONFIG=/nonexistent/kubeconfig TMPDIR=<轮次目录>/tmp-<路名> \
  timeout --kill-after=60 1500 codex [--search] exec -m gpt-6.1-sol \
  -c 'model_reasoning_effort="xhigh"' -c 'service_tier="ultrafast"' --enable ultrafast_mode \
  --ignore-user-config --skip-git-repo-check -c 'agents.enabled=false' --disable multi_agent --disable multi_agent_v2 \
  [-c 'web_search="live"'] \
  -c 'model_provider="openai"' -c 'forced_login_method="chatgpt"' \
  --sandbox read-only --ephemeral --cd <空目录> \
  --disable shell_tool --disable unified_exec ...（完整清单见脚本） \
  -o <轮次目录>/codex-review-<路名>.md - < <轮次目录>/codex-review-prompt-<路名>.md
```

- `env -i` + 白名单：评审进程只拿到 HOME、PATH、USER、LANG 等几个变量，任何 key/token 变量都不传（官方通道用登录态，不需要）。
- `--ephemeral`：不写会话记录。`--cd <空目录>`：工作目录里什么都没有。
- `-o`：把最后一条消息落成报告文件。prompt 里要求「全文作为最后一条消息输出，末行单独写 `END_OF_REVIEW`」，脚本按整行匹配这一行判断有没有跑完。
- **搜索**：取证路同时加顶层 `--search` 和 `-c 'web_search="live"'`。按 0.164.0 源码，`exec` 不一定转发顶层 `--search`，配置项才是确定生效的写法。其他路保持默认（默认也带搜索工具，10-26 实测没加 `--search` 的路也搜了 8 次），不用显式关。
- **单路 prompt 上限 1,048,576 字符（不是字节）**。超了 codex 直接返回 `input_too_large`，rc 仍是 0、报告为空。脚本超过 996,000 字符就拒绝启动；超了就按分面再拆小，或把原始证据改成一行一条的紧凑格式。

### B. 读码模式（代码 / PR，需要读仓库、跑测试）

```bash
CODEX_REVIEW_REPO=<仓库根> scripts/run-one.sh <轮次目录> <路名> code [--search]
```

读码模式要让评审方执行命令，而本机日志提示命令执行沙箱起不来（bubblewrap 建不了用户命名空间），所以用 `--dangerously-bypass-approvals-and-sandbox` 关掉沙箱。**这一模式没有安全边界**，只是减少配置继承、降低误伤概率：

- 10-26 实跑冒烟：评审方执行的命令里 `HOME`、`TMPDIR` 指向轮次目录、`KUBECONFIG=/nonexistent/kubeconfig`，环境变量只剩 PATH/LANG/USER 等和 codex 自己加的 `CODEX_*`，没有代理凭据和任何 key/token。

- 环境变量白名单（同 pack），评审方执行命令时再经 `shell_environment_policy.inherit="core"` 过滤一次。
- 评审方命令里的 HOME、TMPDIR 指到轮次目录下的 `home-<路名>`、`tmp-<路名>`，并加 `-c 'allow_login_shell=false'` 让命令走 `bash -c` 而不是 `bash -lc`：登录 shell 会执行 `/etc/profile.d/60-tmpdir.sh`，把 TMPDIR 改回全机共用的 `/var/tmp`（10-26 实测）；`KUBECONFIG` 指向不存在的文件。评审方会无视「别连集群」的指令去跑 kubectl（09-28 实测），这一条至少挡住默认 kubeconfig。
- prompt 里写可写路径白名单（见 `review-prompt-template.md` 的 code 模式约束段）。

评审方仍然可以用绝对路径读宿主文件、访问网络。所以：只用来评自己的仓库；被测代码一导入就联网的（如初始化时请求外部接口），任务书要求全程走断网启动器；送审前先 commit 在审改动（未跟踪文件也进 commit 或另存），再对工作区拍 sha256 快照，结束后比对，有差异先上报再处理。评审方做实验会在工作区写探针，收尾时按自己的理解清理，分不清哪些未跟踪文件是作者的。

## 重试、完成标记与退回通道（`scripts/run-one.sh`）

- **同一轮次目录里每个路名只跑一次**。脚本发现这一路已有产物就拒绝启动（rc=2），不覆盖旧文件；重跑换新轮次目录 `r<N+1>/`，或换路名（如 `<路名>-retry1`）。
- **内存准入先排队、后计时**：本机有 `memory-admission` 时，脚本先排队（最多 30 分钟，每分钟往日志写一行心跳，监控不会误判停滞），排到了再开始单次计时。预检和包装脚本自己的准入之间没有预约，余量恰好在这几秒里被别人吃掉时，包装脚本还会再排一次队，这段算进单次超时；超时了按普通失败重试。
- **尝试次数**：官方通道最多 4 次；鉴权失败切到退回通道后，退回通道另有最多 2 次，所以一路最多 6 次。普通失败之间等 60 秒（`CODEX_REVIEW_RETRY_SLEEP`），切换通道时不等。单次超时：官方通道 pack 1500 秒、code 3000 秒；退回通道 4200 秒。超时先发 TERM，60 秒后还不退就 KILL。
- 给 run-one.sh 发 TERM/INT/HUP：转发给正在跑的那次尝试并等它退出，状态记 `aborted`，监控按异常（exit 5）报。
- **环境变量白名单**：子 shell 里用 bash 内建 `export -n` 取消白名单外变量和函数的导出再 `exec`，脚本内部同名变量照常可用，变量值不出现在任何进程的命令行参数里。10-26 实测：调用方预先导出 `BIN`、`D`、`OUT` 等同名变量和一个导出函数，启动照常，评审进程环境里只有 HOME/PATH/LANG/USER/TERM/TMPDIR/KUBECONFIG 等；用随机假凭据扫全机 `/proc/*/cmdline`，官方和退回两种尝试期间都扫不到；退回通道的凭据变量只在退回那次尝试的环境里出现。
- **轮次目录要求**：属于自己、组和其他人不可写（`mkdir -m 700`）；路径不含双引号、反斜杠、控制字符；不在 `/tmp`、`/dev/shm`。同名占位用 bash `noclobber` 建锁文件：本机 `mkdir` 是 uutils 0.8.0，200 次并发测试里有 38 次两边都 `mkdir` 成功，不能当锁用。
- 成功的判据是 rc=0 **且**报告末行整行是 `END_OF_REVIEW`。只看 rc 会把截断的报告当成完成。
- 状态写进 `<轮次目录>/codex-<路名>.state`（pid、期望模型、第几次尝试、通道、状态、rc），监控读它；事件记录写进 `run.trace`（`ok` / `fail` / `FALLBACK` / `gave_up` / `refused`），只供人看。每份尝试日志第一行是 `[run-one] attempt=N channel=official|fallback ...`。
- 退出码：0 成功；1 尝试用完；2 参数或目录问题没启动；4 鉴权失败（`gave_up auth_fail`）；143 被终止。
- **官方通道鉴权失败时自动退回中转网关**（2026-10-26 用户定）：
  - 判据：尝试失败、rc 不是超时（124/137），并且日志里提示词回显之后的最后 200 行里有顶格的 `ERROR:` 行，内容是 `unexpected status 401/403`、`Failed to refresh token`、`Country, region, or territory not supported` 或要求重新登录（10-16 实测的真实报错形如 `ERROR: Failed to refresh token: 403 Forbidden: Country, region, or territory not supported`）。材料里引用的同样报错（在提示词回显里）不会触发，stub 实测过。
  - 已知局限：codex 不提供机器可读的错误类型，判据靠日志文本。读码模式下被测程序如果恰好打印同样形态的顶格行、随后 codex 又因别的原因失败，会误切到退回通道；后果是这一路变慢、走用户批准过的网关。反过来，codex 某些登录校验失败的报错不带 `ERROR:` 前缀，会按普通失败重试 4 次后放弃，这时看 run.trace 和日志尾部手工判断。
  - 退回配置在本机 `~/.config/codex-review/fallback.sh`（定义 `FALLBACK_ARGS` 数组和要额外放行的凭据变量名 `KEEP_ENV`；只写网关地址和变量名，不写密钥值，不进仓库）。退回时整组替换官方通道参数，退回通道另给 2 次尝试，run.trace 记一行 `FALLBACK`。
  - 退回之后**没有 ultrafast**（网关不支持，客户端会降到普通档）、**联网搜索不可用**（10-08 实测 web_search 调用为 0），单路耗时按本机网关的历史实测是 30~60 分钟。需要外部出处的那一路，要把关键网页预先抓下来打进材料。汇报里写明哪几路走了退回通道。
  - 退回配置不存在或为空、或网关也鉴权失败：记 `gave_up auth_fail`，以 4 退出。这时停下告诉用户需要 `! codex login`，不要自己改 `config.toml` 或 `auth.json`。

## 启动验收（`scripts/monitor.sh` 自动做，手动核也照这个）

日志开头那个头部块（两行 `--------` 之间）里必须是：

```
model: gpt-6.1-sol
provider: openai
reasoning effort: xhigh
```

只解析头部块，评审材料里出现同样的行不算数。并且在提示词回显之后、模型第一次动作（`codex` / `thinking` / `exec` 行）之前，**没有以 `warning:` 开头**的这一行：

```
warning: Configured service tier `ultrafast` is not advertised as supported for model `gpt-6.1-sol` and will be omitted from requests.
```

出现它就说明这一路没跑在 ultrafast 上（10-23 走网关的 r1~r3 就是这样慢下来的），停掉重来。不要整份日志搜 `is not advertised`：10-25 有一次评审正文引用了这几个字，整文件 grep 误报成降档。走退回通道的那次尝试不查 provider 和档位。

这套验收能证明的是「客户端按 ultrafast 发了请求、没有在客户端被降档」。服务端实际按什么档处理，日志里没有回执；非 ephemeral 会话的 rollout 会记录线程配置里的 service_tier，但那是客户端配置，不是服务端回执（pack 模式加了 `--ephemeral`，不留会话记录）。实际耗时（分面路几分钟）是旁证，汇报时说「已请求 ultrafast、未降档」，不说「已确认按 ultrafast 处理」。

## 健康监控（多路）

```bash
scripts/monitor.sh <轮次目录> <路名1> <路名2> ...   # 用 run_in_background 挂起
```

每 30 秒采样一次所有路，退出即通知：

| 退出码 | 含义 | 处置 |
|---|---|---|
| 0 | 全部路结束，每路都有完整报告且启动验收通过 | 起汇总路 |
| 2 | 某路日志超过 `CODEX_MONITOR_IDLE` 秒（默认 600）没增长 | 先 tail 看是不是长思考；判定卡死再按 SKILL.md 循环评审第 3 条列 kill 清单给用户确认 |
| 3 | 某路评审进程下面又起了 `codex exec`（递归转包，07-21 实测过，多烧一倍时间） | 报给用户处置，不自行 kill |
| 4 | 启动验收不过（模型或推理档不对、没走官方通道、ultrafast 被降档），或收尾时有路没有完整报告 | 停掉该路，换路名或新轮次目录重来；FALLBACK 的那次尝试只提示、不判失败 |
| 5 | 某路 180 秒内没启动（没有 state 文件），被终止（状态 aborted），或 run-one.sh 进程没了但状态不是 finished（被 kill -9） | 看 launcher 输出找原因，换路名重来 |
| 6 | 其余都通过，但有路的提示词回显和 prompt 文件对不上，降档没法自动核 | 人工看那一路日志开头；核不了就在汇报里写「档位未核实」，不说「未降档」 |

- 递归检测只认「程序本身是 codex、子命令是 exec」的进程（中间的选项可以带值，如 `codex -c model="x" exec`）。包装脚本 exec 之前的 bash 阶段、`timeout` 前缀、codex 自带的 `codex-code-mode-host`、评审方在 scratch 目录里跑的普通命令都不算（旧版 `pgrep -P $PID -f codex` 在后两种情况下误报过）。它看的是空格拼起来的命令行，配置值里恰好含 ` exec ` 或 codex 路径带空格时会误判；本脚本启动的命令都不是这种形态。它也假定评审主进程的程序名就是 `codex`：10-26 实测本机进程树是 `timeout ... codex exec` → `~/.codex/packages/app-server-daemon/current/bin/codex exec ...`，成立；换了入口程序名要重核。进程内子代理已用 `agents.enabled=false` 关掉。
- 进程存活按 state 里的 PID 加 `/proc/<pid>/cmdline` 含 `run-one.sh` 判断，不防 PID 被另一个 run-one.sh 复用（评审只跑几分钟，没做启动时间校验）。
- 跑得快的路可能在两次采样之间就结束了，监控收尾时会对每路最后一次尝试的日志补做启动验收。
- **时长预期**：官方通道 + ultrafast 下，分面路通常 1.5~4 分钟、汇总路 2.5 分钟左右（10-25 / 10-26 实测：10-26 r1 三路 155 秒全部结束，汇总路 153 秒；r2 三路 160 秒）。超过 10 分钟没结束的路单独报一次进度；超过单次超时（pack 25 分钟、code 50 分钟）脚本会自动重试，重试过的路在汇报里写明。
- 用户问进度时：`ps -o etime= -p <PID>`（跑了多久）+ `stat -c '%y %s' <日志>`（最后活动）+ `tail -c 500 <日志>`（正在做什么），再加 `cat <轮次目录>/run.trace`。

## 逐项要点

- **`--search` 必须放在顶层**（`codex --search exec ...`）。放到 `exec` 之后会报 `error: unexpected argument '--search' found`。取证路另加 `-c 'web_search="live"'`，见上文「搜索」。
- **`-` + stdin 重定向**喂 prompt：长文档不撞命令行长度限制。
- **`--skip-git-repo-check`**：轮次目录、空目录都不是 git 仓库。
- `-c` 的值是 TOML：`-c 'service_tier="ultrafast"'` 与旧写法 `-c service_tier='"ultrafast"'` 展开后相同。

## 没有包装脚本的机器

照上面「打包只读」的核心命令手写，固定配置四项不变（读码模式在 pack 命令基础上去掉 `--sandbox`/`--ephemeral`/`--disable` 那几项，加 `shell_environment_policy` 和 bypass）。没有内存准入时，自己先看个人内存余量再决定开几路。脚本需要 bash ≥ 4.4、python3、GNU coreutils。
