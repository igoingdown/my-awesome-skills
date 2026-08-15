# 阶段 0：材料采集（用户只贴飞书招聘链接时执行）

用户只给一个飞书招聘链接时，先自动完成简历与文字记录采集，产出标准目录结构后再进入评估流程。材料目录根为 `~/github/interviews/`。

## 0.1 打开页面

优先用 Claude Code 的 Chrome 集成（`claude --chrome` 启动 / `/chrome` 连接，需 Claude in Chrome 扩展）操作浏览器；若不可用，回退 AppleScript 方案（需 Chrome 菜单开启 查看→开发者→"允许 Apple 事件中的 JavaScript"）：

```bash
open -a "Google Chrome" "<链接>"   # 等待 5-6 秒加载
osascript -e 'tell application "Google Chrome" to get {URL, title} of active tab of front window'
# 页面 title 即候选人姓名，如 "郜忠明 - 招聘"
```

姓名转拼音得到目录名（如 郜忠明→gaozhongming），`mkdir -p ~/github/interviews/<拼音>/00N`（本轮为第几面就用几，1 面=001）。

## 0.2 下载简历 PDF → 渲染 resume.png

飞书招聘的简历接口（浏览器内带 cookie fetch，不要在终端直接 curl）：

```
GET /atsx/api/application/get_default_resume/?talent_id=<talent_id>&application_id=<application_id>
→ data.default_attachment.url 为 PDF blob 下载地址（带签名 token）
```

用 AppleScript 在页面内执行 JS：fetch 该 API 拿 url → fetch url 取 blob → FileReader 转 base64 存 `window.__pdfB64`。然后分块导出（AppleScript 单次返回有长度限制，按 10 万字符/块切片拼接）：

```bash
for i in 0 1 2; do osascript -e "tell application \"Google Chrome\" to execute active tab of front window javascript \"window.__pdfB64.slice($i * 200000, ($i + 1) * 200000)\"" >> pdf_b64.txt; done
tr -d '\n' < pdf_b64.txt | base64 -d > resume.pdf && file resume.pdf   # 校验是 PDF
```

渲染高清长图（多页纵向拼接，3x 缩放）：

```bash
swift ~/.claude/skills/interview-comment/scripts/pdf2png.swift resume.pdf resume.png
```

用 `sips -Z 800` 生成缩略图并 Read 目检，确认内容完整清晰。

## 0.3 抽取面试文字记录 → asr.md

1. 在页面右侧找到「面试速记」入口并点击（元素：`[class*=minutes]` 且文本为"面试速记"）：
   ```js
   Array.from(document.querySelectorAll('[class*=minutes]')).find(e => e.textContent.trim() === '面试速记').click()
   ```
2. 速记面板出现在 `[class*=tertiaryContainer]` 容器，消息块结构：`[class*=section__]` 内含 `[class*=name__]`（说话人）、`[class*=subInfo__]`（说话人+时间）、`[class*=content__]`（内容）。
3. **先滚动到底确认全量**（`tc.scrollTop = tc.scrollHeight`，等 2-3 秒后比对 section 数是否变化——目前观察为全量渲染非懒加载，但必须验证），检查是否有多段录制/分段 tab。
4. 页面内 JS 遍历全部 section 组装 JSON 存 `window.__asrJson`，按 1 万字符/块分片导出到本地，Python 校验：条数、首末条、空内容数、说话人集合（应恰好为面试官+候选人两人）。
5. 生成 `asr.md`：头部写候选人/面试官/岗位/时间/条数元信息，正文按 `**说话人 HH:MM**` + 内容逐条排列，**不重不漏、保持原始顺序、不改写原文**。

## 0.4 抓取「代码考核」记录（本轮有编程题时必做）→ candidate-code.<ext>

⚠️ **血泪教训（真实误判）**：某候选人的代码写在飞书招聘「代码考核」里，初版评估误以为"代码不可得"（依据是 `meeting_coding_status` 接口返回 `is_coding_enabled:false`），据此按速记推断给了偏高分；事后从「代码考核」详情捞到真实代码、跑了一遍发现是错的，**下修了整整一档**。所以：**只要本轮有编程题，就必须主动去「代码考核」详情捞原始记录，不能只靠 asr 转写推断编码结果。**

采集路径（页面内点击，非 API）：候选人页 →「继续评价」按钮 →「代码考核」卡片 →「详情」链接。详情页含四样东西，全部采集：

1. **题目原文**（题干 + 全部示例用例）→ 记录到 `coding-analysis.md`。
2. **候选人代码全文** → 存 `candidate-code.<ext>`（按考核语言定后缀，如 `.ts`/`.py`/`.go`）。取法：聚焦 Monaco 编辑器 `document.querySelector('.monaco-editor textarea')` → 激活 Chrome 窗口 → `Cmd+A` 全选 `Cmd+C` 复制 → `pbpaste` 落盘（编辑器懒渲染，直接读 DOM 只能拿到可视区，必须走真实全选复制）。
3. **候选人运行记录** → 关键信号：跑了几次 / 有没有跑 / 跑的什么用例。**运行记录为空 = 平台可运行却零自测**，是编码习惯的强负向信号。
4. **页面切换记录**（进入/离开代码页的时间与离开时长）→ 判作答独立性：中途长时间离开可能查资料/问 AI，短暂离开（几秒）说明作答干净。

⚠️ **不要被 `meeting_coding_status` 之类"会中状态"接口误导**——它在会后返回 false 不代表没有编程记录。真实记录入口永远是「代码考核」卡片的「详情」链接。

若本轮**没有**「代码考核」卡片（题目走屏幕共享、白板或纯口述，无持久化）：在 `coding-analysis.md` 写明"代码无持久化记录，仅口述/屏幕共享"，并据 asr 转写还原题目与思路即可，**不脑补代码**。

## 0.5 采集完成检查

目录内应有：`resume.pdf`、`resume.png`、`asr.md` 三个文件；若本轮有编程题且有「代码考核」记录，另有 `candidate-code.<ext>` 与 `coding-analysis.md`。逐项确认后进入正式评估流程（SKILL.md「执行流程」）。清理中间文件（`pdf_b64.txt`、`asr_raw.json`）。

## 0.6 并发提示（Dynamic Workflow）

进入评估时，**并行**发起两个 general-purpose 子代理：①候选人五维证据提取（读 asr.md + resume.pdf，产出证据密集的结构化清单）；②面试官复盘证据分析（问题全列表/时间分配/追问精准度/纪律/表达效率）。主对话同时亲自 Read asr.md 与 resume（视觉），交叉校验子代理结论后裁决打分并写报告。子代理只做证据提取，**打分裁决必须由主对话完成**。
