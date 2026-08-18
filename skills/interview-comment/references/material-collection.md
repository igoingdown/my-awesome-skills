# 阶段 0：材料采集（用户只贴飞书招聘链接时执行）

用户只给一个飞书招聘链接时，先自动完成简历与文字记录采集，产出标准目录结构后再进入评估流程。材料目录根为 `~/github/interviews/`。

**采集顺序**：0.1 打开页面 → **0.15 前置探针（判定本轮材料形态，决定后面各步怎么走）** → 0.2 简历 → 0.3 速记 → 0.4 代码考核（探针说有才做） → 0.5 完成检查。不要跳过 0.15，它决定后面所有分支。

## 可执行脚本（不要手抄 osascript，直接调这些文件）

浏览器自动化已固化为 skill 内的真实脚本，交互式会话与 hire-patrol 定时任务**共用同一套**。`$S` 指 `~/.claude/skills/interview-comment/scripts`（部署后路径；仓库内为 `skills/interview-comment/scripts`）。

| 脚本 | 作用 | 典型调用 |
|------|------|----------|
| `chrome-eval.sh` | **底层原语**：按 URL 定位标签页 → 注入 async 页面 JS → 轮询 → 分片取回。收敛了定位/转义/UTF-8/取回全部难点 | `chrome-eval.sh <url子串> -f <page-js> [超时秒]` |
| `chrome-eval.jxa.js` | 上面的 JXA 引擎，一般不直接调 | 由 `chrome-eval.sh` 调用 |
| `page/probe.js` | 0.15 前置探针，返回 `{resume, asr, coding, ...}` JSON | `chrome-eval.sh "hire/talent/<tid>" -f $S/page/probe.js` |
| `page/fetch-attachment.js` | 0.2 拉简历附件，返回 `{name,mime,b64}`（pdf/image 两路） | `chrome-eval.sh "hire/talent/<tid>" -f $S/page/fetch-attachment.js 20` |
| `page/extract-asr.js` | 0.3 抽全量面试速记，返回结构化 items JSON | `chrome-eval.sh "hire/talent/<tid>" -f $S/page/extract-asr.js 40` |
| `pdf2png.swift` | PDF 简历渲染多页纵向长图 | `swift $S/pdf2png.swift resume.pdf resume.png` |

`chrome-eval.sh` 退出码：`0` 成功（结果在 stdout）／`3` NOT_FOUND（页面没开/没加载）／`4` TIMEOUT／`5` 页面 JS 抛错／`2` 参数错或缺自动化权限（stderr 有 HINT）。**页面 JS 用 `-f` 传文件**（可自由含中文与引号，脚本内部走 base64，不用担心 shell 转义）。要临时改探测逻辑就编辑 `page/*.js`，不要在 md 里贴新片段。

> ⚠️ 若环境没有 Chrome 或不允许 AppleScript 自动化（如某些 CI/headless），`chrome-eval.sh` 会以退出码 2 报"缺自动化权限"或 5 报"Chrome not running"。此时无法走链接自动采集，需人工把 `resume.png` / `asr.md` 放到目标目录，再从 SKILL.md「执行流程」第 2 步（目录已就绪）继续。

## 0.1 打开页面并**按 URL 精确定位标签页**

运行环境决定用哪套浏览器控制方式，**不要混用**：

- **交互式会话**（用户在场）：可用 Claude Code 的 Chrome 集成（`claude --chrome` / `/chrome`，需 Claude in Chrome 扩展）。
- **无人值守 / launchd 定时任务**（如 hire-patrol）：**固定走 AppleScript，不要用 `/chrome` 集成**（launchd 环境没有交互式扩展，用集成会挂）。AppleScript 需 Chrome 菜单开启 查看→开发者→"允许 Apple 事件中的 JavaScript"。

打开页面：

```bash
open -a "Google Chrome" "<链接>"   # 等待 5-6 秒加载
```

⚠️ **不要用 `active tab of front window` 拿页面**。`open -a` 经常把 URL 开在后台标签，或前窗口停在别的文档——实测多次栽在这里（patrol 日志两次记录"落到别的窗口的飞书文档页"）。**标签页定位已由 `chrome-eval.sh` 内部按 URL 里的 `talent_id` 子串精确匹配处理**——所有页面 JS 都通过它执行，不用再手写 osascript 遍历标签。

拿页面标题确认命中（顺便验证自动化权限）：

```bash
S=~/.claude/skills/interview-comment/scripts
chrome-eval() { "$S/chrome-eval.sh" "$@"; }
chrome-eval "hire/talent/<talent_id>" -e 'return document.title'   # 应返回 "王芳平 - 招聘"
```

title 含候选人姓名。姓名转拼音全拼得到目录名（王芳平→wangfangping），`mkdir -p ~/github/interviews/<拼音>/00N`（本轮第几面就用几，1 面=001）。

`chrome-eval.sh` 退出码 3=页面没开/没加载完（多等几秒重试）；退出码 2 且 stderr 提示 "Not authorized"→ 缺自动化权限（launchd 环境需授权），直接判采集失败并按调用方约定通知，不要继续。

## 0.15 采集前置探针（决定后面各步怎么走）

跑 `page/probe.js`，一次性判定三件事，产出"采集清单"后再进入 0.2/0.3/0.4。这是把线性脚本改成"先探测再分支"的关键步骤——避免对不存在的速记、非 PDF 的简历硬套流程。

```bash
chrome-eval "hire/talent/<talent_id>" -f "$S/page/probe.js" 15
# → {"talent_id":"...","application_id":"...","resume":"image","att_name":"xxx.png","asr":"not_ready","coding":"no"}
```

`probe.js` 返回字段与判定：

1. **简历形态** → 决定 0.2 走哪条路。fetch `get_default_resume`（见 0.2）看 `data.default_attachment`：
   - 有附件且文件名/MIME 是 PDF → `resume=pdf`
   - 有附件但是图片（`.png/.jpg/.jpeg/.webp`，如 `1786416646302.png`）→ `resume=image`
   - 无附件（只有「标准简历」结构化页）→ `resume=standard`
2. **面试速记是否就绪** → 决定 0.3 采集还是跳过。在页面找「面试速记」入口（文本锚点，见 0.3）：
   - 有入口且点开后 section 条数 > 0 → `asr=ready`
   - 无入口 / 入口存在但内容为空 / 明显不完整（面试刚结束转写未就绪、或面试尚未进行）→ `asr=not_ready`
3. **是否有「代码考核」卡片** → 决定 0.4 做不做（**正向信号**）。在候选人页/评价区找「代码考核」卡片是否存在：
   - 存在 → `coding=yes`
   - 不存在 → `coding=no`

> ⚠️ **判本轮考没考编程题，以「代码考核」卡片是否存在为准**，**不要**用 `meeting_coding_status` 之类"会中状态"接口（它会后返回 `is_coding_enabled:false` 不代表没编程记录，曾据此误判、下修一整档，见 0.4）。

**探针短路规则**：若 `asr=not_ready` → **立即停止采集，不写任何 asr.md**，向调用方返回状态 `SKIPPED: 速记未就绪`（原因：面试未进行 / 转写未生成 / 内容不完整）。调用方（hire-patrol 或直接使用者）据此跳过该候选人、明天再试，绝不写残缺评价。速记就绪才继续 0.2 及之后。

## 0.2 采集简历 → resume.png（按 0.15 探针的 resume 形态分三路）

**路 A（`resume=pdf`）/ 路 B（`resume=image`）都用 `page/fetch-attachment.js` 拉附件**（它在页面内带 cookie fetch `get_default_resume` → 取 blob → 返回 `{name,mime,b64}`）：

```bash
cd ~/github/interviews/<拼音>/00N
chrome-eval "hire/talent/<talent_id>" -f "$S/page/fetch-attachment.js" 20 > att.json
python3 - <<'PY'
import json,base64,subprocess,sys
d=json.load(open("att.json"))
if "error" in d: sys.exit("attachment error: "+d["error"])   # 多半是 standard，转路 C
raw=base64.b64decode(d["b64"]); name=d["name"].lower()
if name.endswith(".pdf"):
    open("resume.pdf","wb").write(raw)              # 路 A
else:
    ext = name.rsplit(".",1)[-1]
    open("resume_src."+ext,"wb").write(raw)         # 路 B
print("saved", d["name"], len(raw), "bytes")
PY
```

- **路 A**：`file resume.pdf` 校验确是 PDF，再 `swift "$S/pdf2png.swift" resume.pdf resume.png`（多页纵向拼接 3x 长图）。若 `file` 显示不是 PDF（探针形态判错）→ 按路 B 处理。
- **路 B**：`sips -s format png resume_src.<ext> --out resume.png`（原图已是 png 也过一遍，统一成 `resume.png`），**跳过 pdf2png**。

**路 C（`resume=standard`，无附件只有标准简历）** — 无可下载文件，改**截图标准简历面板**：点开「标准简历」tab、滚到底确认全量，用 `screencapture -x` 截图（或分段截图后 `sips` 纵向拼接）存 `resume.png`。定位滚动容器可用 `chrome-eval ... -e '...'` 辅助。务必包含教育/工作/项目全段。

**三路统一收尾**：`sips -Z 800 resume.png --out resume_thumb.png` 生成缩略图并 `Read` 目检，确认教育经历、工作经历、项目、技术栈都清晰可读，不缺页不糊。清理中间文件（`att.json`、`resume_src.*`、`resume_thumb.png`、分段图）。

## 0.3 抽取面试文字记录 → asr.md（探针已确认 asr=ready 才做）

> 前置：0.15 探针为 `asr=not_ready` 时**根本不会走到这里**（已按短路规则返回 SKIPPED）。走到这里说明速记确实就绪。

跑 `page/extract-asr.js`：它内部**点开速记入口（文本锚点优先，class 辅助）→ 滚到底确认全量 → 遍历消息块**，返回 `{ok, count, speakers, items:[{speaker,time,text}]}`：

```bash
chrome-eval "hire/talent/<talent_id>" -f "$S/page/extract-asr.js" 40 > asr_raw.json
python3 - <<'PY'
import json,sys
d=json.load(open("asr_raw.json"))
if not d.get("ok"): sys.exit("ASR not ready: "+d.get("reason",""))   # no_asr_entry/empty → 按 SKIPPED 处理
its=d["items"]
# 校验：条数、首末条、空内容、说话人集合（应恰好两人）
assert its and all(i["text"] for i in its), "有空内容条"
print("count=%d speakers=%s first=%r last=%r" % (d["count"], d["speakers"], its[0], its[-1]))
PY
```

- `ok:false`（`no_asr_entry`/`empty_after_extract`）→ 探针漏判，**按短路规则返回 `SKIPPED: 速记未就绪`，不写 asr.md**。
- 说话人集合应恰好是面试官+候选人两人；出现第三人或只有一人 → 警示并人工确认。
- `extract-asr.js` 已做滚动到底 + hash class 失效时按"说话人+HH:MM时间戳+文本"结构兜底；若有多段录制/分段 tab，逐段跑后合并。

生成 `asr.md`：头部写候选人/面试官/岗位/时间/条数元信息，正文按 `**说话人 HH:MM**` + 内容逐条排列，**不重不漏、保持原始顺序、不改写原文**。

## 0.4 抓取「代码考核」记录（探针 coding=yes 时必做）→ candidate-code.<ext>

> 前置：只有 0.15 探针判 `coding=yes`（「代码考核」卡片存在）才进入本步；`coding=no` 则跳过，并在评估时按"本轮未考编程题"处理。

⚠️ **血泪教训（真实误判）**：某候选人的代码写在飞书招聘「代码考核」里，初版评估误以为"代码不可得"（依据是 `meeting_coding_status` 接口返回 `is_coding_enabled:false`），据此按速记推断给了偏高分；事后从「代码考核」详情捞到真实代码、跑了一遍发现是错的，**下修了整整一档**。所以：**卡片在就必须去详情捞原始记录，不能只靠 asr 转写推断编码结果。**

采集路径（页面内点击，非 API）：候选人页 →「继续评价」按钮 →「代码考核」卡片 →「详情」链接。详情页含四样东西，全部采集：

1. **题目原文**（题干 + 全部示例用例）→ 记录到 `coding-analysis.md`。
2. **候选人代码全文** → 存 `candidate-code.<ext>`（按考核语言定后缀，如 `.ts`/`.py`/`.go`）。取法：聚焦 Monaco 编辑器 `document.querySelector('.monaco-editor textarea')` → 激活 Chrome 窗口 → `Cmd+A` 全选 `Cmd+C` 复制 → `pbpaste` 落盘（编辑器懒渲染，直接读 DOM 只能拿到可视区，必须走真实全选复制）。
3. **候选人运行记录** → 关键信号：跑了几次 / 有没有跑 / 跑的什么用例。**运行记录为空 = 平台可运行却零自测**，是编码习惯的强负向信号。
4. **页面切换记录**（进入/离开代码页的时间与离开时长）→ 判作答独立性：中途长时间离开可能查资料/问 AI，短暂离开（几秒）说明作答干净。

若探针判 `coding=yes` 但详情里题目走屏幕共享、白板或纯口述、无持久化代码：在 `coding-analysis.md` 写明"代码无持久化记录，仅口述/屏幕共享"，据 asr 转写还原题目与思路即可，**不脑补代码**。

## 0.5 采集完成检查

按 0.15 探针的形态核对产物：

- 简历：三路任一都应产出 `resume.png`（路 A 另有 `resume.pdf`）。目检缩略图确认完整清晰。
- 速记：`asr=ready` → 有 `asr.md` 且校验通过；`asr=not_ready` → 不应有 asr.md，且已返回 SKIPPED（不进入评估）。
- 编程题：`coding=yes` → 有 `candidate-code.<ext>` 与 `coding-analysis.md`；`coding=no` → 无编码产物，评估按"本轮未考"处理。

逐项确认后进入正式评估流程（SKILL.md「执行流程」）。清理中间文件（`att.json`、`asr_raw.json`、`resume_src.*`、分段图、缩略图）。

## 0.6 并发提示（Dynamic Workflow）

进入评估时，**并行**发起两个 general-purpose 子代理：①候选人五维证据提取（读 asr.md + resume.png/resume.pdf，产出证据密集的结构化清单）；②面试官复盘证据分析（问题全列表/时间分配/追问精准度/纪律/表达效率）。主对话同时亲自 Read asr.md 与 resume（视觉），交叉校验子代理结论后裁决打分并写报告。子代理只做证据提取，**打分裁决必须由主对话完成**。
