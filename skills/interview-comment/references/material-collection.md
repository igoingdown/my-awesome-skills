# 阶段 0：材料采集（用户只贴飞书招聘链接时执行）

用户只给一个飞书招聘链接时，先自动完成简历与文字记录采集，产出标准目录结构后再进入评估流程。材料目录根为 `~/github/interviews/`。

**采集顺序**：0.1 打开页面 → **0.15 前置探针（判定本轮材料形态，决定后面各步怎么走）** → 0.2 简历 → 0.3 速记 → 0.4 代码考核（探针说有才做） → 0.5 完成检查。不要跳过 0.15，它决定后面所有分支。

## 0.1 打开页面并**按 URL 精确定位标签页**

运行环境决定用哪套浏览器控制方式，**不要混用**：

- **交互式会话**（用户在场）：可用 Claude Code 的 Chrome 集成（`claude --chrome` / `/chrome`，需 Claude in Chrome 扩展）。
- **无人值守 / launchd 定时任务**（如 hire-patrol）：**固定走 AppleScript，不要用 `/chrome` 集成**（launchd 环境没有交互式扩展，用集成会挂）。AppleScript 需 Chrome 菜单开启 查看→开发者→"允许 Apple 事件中的 JavaScript"。

打开页面：

```bash
open -a "Google Chrome" "<链接>"   # 等待 5-6 秒加载
```

⚠️ **不要用 `active tab of front window` 拿页面**。`open -a` 经常把 URL 开在后台标签，或前窗口停在别的文档——实测多次栽在这里（patrol 日志两次记录"落到别的窗口的飞书文档页"）。**必须遍历所有窗口/标签，按 URL 里的 `talent_id` 精确匹配**，拿到目标 tab 的引用后续所有 JS 都在这个 tab 上执行：

```bash
osascript -l JavaScript -e '
const c = Application("Google Chrome");
const TID = "<talent_id>";           // 从链接里取
const wins = c.windows();
for (let i = 0; i < wins.length; i++) {
  const tabs = wins[i].tabs();
  for (let j = 0; j < tabs.length; j++) {
    if ((tabs[j].url() || "").includes("hire/talent/" + TID)) {
      // 命中：可用 c.windows[i].tabs[j] 引用它执行 JS
      c.windows[i].visible = true; c.windows[i].index = 1; wins[i].activeTabIndex = j + 1;
      return JSON.stringify({win: i, tab: j, title: tabs[j].title()});
    }
  }
}
return "NOT_FOUND";
'
```

title 含候选人姓名（如 "王芳平 - 招聘"）。姓名转拼音全拼得到目录名（王芳平→wangfangping），`mkdir -p ~/github/interviews/<拼音>/00N`（本轮第几面就用几，1 面=001）。

若 osascript 报 "Not authorized to send Apple events" → launchd 缺自动化权限，直接判采集失败并按调用方约定通知，不要继续。

## 0.15 采集前置探针（决定后面各步怎么走）

在目标 tab 内跑**一段探测 JS**，一次性判定三件事，产出"采集清单"后再进入 0.2/0.3/0.4。这是把线性脚本改成"先探测再分支"的关键步骤——避免对不存在的速记、非 PDF 的简历硬套流程。

探测内容与判定：

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

简历接口（浏览器内带 cookie fetch，**不要**在终端直接 curl）：

```
GET /atsx/api/application/get_default_resume/?talent_id=<talent_id>&application_id=<application_id>
→ data.default_attachment.{url, name}   # url 为 blob 下载地址（带签名 token），name 判后缀
```

**路 A：`resume=pdf`** — 页面内 JS fetch 该 url 取 blob → FileReader 转 base64 存 `window.__b64`，分块导出（AppleScript 单次返回有长度限制，按 20 万字符/块）：

```bash
for i in 0 1 2; do osascript -e "tell application \"Google Chrome\" to execute (tab T of window W) javascript \"window.__b64.slice($i*200000,($i+1)*200000)\"" >> b64.txt; done
tr -d '\n' < b64.txt | base64 -d > resume.pdf && file resume.pdf   # 必须校验确是 PDF
swift ~/.claude/skills/interview-comment/scripts/pdf2png.swift resume.pdf resume.png   # 多页纵向拼接 3x 长图
```

若 `file resume.pdf` 显示不是 PDF（说明探针把形态判错、实际是图片）→ 转路 B。

**路 B：`resume=image`**（附件是图片，如 `1786416646302.png`）— 同样 fetch blob → base64 分块导出，但**直接按原扩展名落盘为 `resume.png`**（若原图非 png，落盘后用 `sips -s format png in.<ext> --out resume.png` 转一次），**跳过 pdf2png**。

**路 C：`resume=standard`**（无附件，只有「标准简历」结构化页）— 无可下载文件，改**截图标准简历面板**：在目标 tab 点开「标准简历」tab，定位简历滚动容器，`scrollTop=scrollHeight` 滚到底确认全量，用 `screencapture -x` 截目标区域（或分段截图后 `sips` 纵向拼接）存 `resume.png`。截不全就分段拼接，务必包含教育/工作/项目全段。

**三路统一收尾**：`sips -Z 800 resume.png --out resume_thumb.png` 生成缩略图并 `Read` 目检，确认教育经历、工作经历、项目、技术栈都清晰可读，不缺页不糊。清理中间文件（`b64.txt`、`resume_thumb.png`、分段图）。

## 0.3 抽取面试文字记录 → asr.md（探针已确认 asr=ready 才做）

> 前置：0.15 探针为 `asr=not_ready` 时**根本不会走到这里**（已按短路规则返回 SKIPPED）。走到这里说明速记确实就绪。

1. **找并点开「面试速记」入口——优先文本锚点，class 选择器只作辅助**。飞书 classname 是哈希化的，`[class*=minutes]` 这类前缀猜测**会随版本失效**（实测在当前页面结构上匹配为空）。用文本锚点兜底：

   ```js
   // 优先：任意叶子元素文本恰为"面试速记"
   let el = Array.from(document.querySelectorAll('*')).find(e => e.children.length===0 && (e.textContent||'').trim()==='面试速记');
   // 辅助：旧版 class 前缀
   if (!el) el = Array.from(document.querySelectorAll('[class*=minutes]')).find(e => (e.textContent||'').trim()==='面试速记');
   if (el) el.click();
   ```
   若两种都找不到入口 → 视同 `asr=not_ready`，按短路规则返回 SKIPPED（探针可能漏判，这里二次兜底）。

2. **定位速记面板与消息块，同样文本/结构锚点优先**。旧结构：面板在 `[class*=tertiaryContainer]`，消息块 `[class*=section__]` 内含 `[class*=name__]`（说话人）、`[class*=subInfo__]`（说话人+时间）、`[class*=content__]`（内容）。若这些 hash class 失效，改按**结构特征**兜底：找同时包含"说话人名 + HH:MM 时间戳 + 一段文本"的重复块。

3. **先滚动到底确认全量**（`容器.scrollTop = 容器.scrollHeight`，等 2-3 秒比对 section 数是否变化——目前观察为全量渲染非懒加载，但必须验证），检查是否有多段录制/分段 tab，有就逐段采齐。

4. 页面内 JS 遍历全部 section 组装 JSON 存 `window.__asrJson`，按 1 万字符/块分片导出到本地，Python 校验：条数、首末条、空内容数、说话人集合（应恰好为面试官+候选人两人；若出现第三人或只有一人，警示并人工确认）。

5. 生成 `asr.md`：头部写候选人/面试官/岗位/时间/条数元信息，正文按 `**说话人 HH:MM**` + 内容逐条排列，**不重不漏、保持原始顺序、不改写原文**。

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

逐项确认后进入正式评估流程（SKILL.md「执行流程」）。清理中间文件（`b64.txt`、`asr_raw.json`、分段图、缩略图）。

## 0.6 并发提示（Dynamic Workflow）

进入评估时，**并行**发起两个 general-purpose 子代理：①候选人五维证据提取（读 asr.md + resume.png/resume.pdf，产出证据密集的结构化清单）；②面试官复盘证据分析（问题全列表/时间分配/追问精准度/纪律/表达效率）。主对话同时亲自 Read asr.md 与 resume（视觉），交叉校验子代理结论后裁决打分并写报告。子代理只做证据提取，**打分裁决必须由主对话完成**。
