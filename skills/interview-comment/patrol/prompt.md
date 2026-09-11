# 飞书招聘未评价面试巡检(每日 10:30 定时任务)

你是 launchd 定时触发的无人值守巡检任务。目标:检查飞书招聘「我的任务 → 面试 → 未评价」列表,对每个未评价的面试轮次,用 **interview-comment** skill 在本地生成面试评价报告。

**铁律:对飞书招聘只读,严禁任何写操作**——不点"提交评价"、不填写任何表单、不修改候选人状态。评价报告只写入本地 `~/github/interviews/`。

**所有浏览器自动化能力都在 interview-comment skill 里**(`~/.claude/skills/interview-comment/scripts/`),本 prompt 只负责编排:扫列表 → 逐个交给 skill → 汇总通知。不要在这里手写 osascript,一律调 `chrome-eval.sh`。

## 步骤

### 1. 打开面试列表页并扫未评价列表

```bash
S=~/.claude/skills/interview-comment/scripts
open -a "Google Chrome" "https://awaken-intelligence.feishu.cn/hire/application-biz/interview/list?activeStatus=2"
sleep 8
"$S/chrome-eval.sh" "awaken-intelligence.feishu.cn/hire" -f "$S/page/list-unevaluated.js" 30 > /tmp/patrol_list.json
echo "exit=$?"
```

- 退出码 2 且 stderr 提示 "Not authorized" → launchd 缺自动化权限,跳到第 4 步发失败通知。
- 退出码 3 (NOT_FOUND) → 页面没加载好,多等几秒重试一次;仍失败发失败通知。
- 结果 JSON `{ok:false, reason:"not_json"}` → 登录态失效,跳到第 4 步发"需要手动登录"通知。
- `{ok:true, list:[...]}` → `list` 每条含 `name / talent_id / application_id / round`;`list` 为空即今日无未评价。

### 2. 逐条判断是否需要生成评价

- 姓名转拼音全拼(刘世龙→liushilong),轮次目录 = round 补零 3 位(1→001)。
- 若 `~/github/interviews/<拼音>/<轮次>/` 下 **同时存在** `evaluation.md` 和 `interviewer-review.md` → 可能已评过,但**必须先做同名校验**(下条),校验通过才跳过。
- ⚠️ **同名不同人校验(事故 2026-09-07)**:不同汉字的姓名可能拼音相同(韩勖 / 韩旭 都是 hanxu)。目录已存在报告时,**不得仅凭拼音判定"已评过"**,必须核对是不是同一个人:
  - 打开该目录的 `asr.md`,读头部的候选人姓名字段与面试时间;
  - 姓名汉字一致且面试时间与本次 round 吻合 → 确认同一人,跳过;
  - **姓名汉字不同,或面试时间明显不是本次那场** → 是同名不同人,目录后缀数字区分(`hanxu` 已占用 → 本次用 `hanxu2`),按新候选人走第 3 步生成。
  - 无法从 `asr.md` 判定时,一律**按不同人处理**(宁可多生成一份也不能漏掉一场真实面试)。
- 否则进入第 3 步生成。

### 3. 调用 interview-comment skill 生成评价

对每个**决定要生成评价**的候选人(即第 2 步未跳过的),先把其目标目录追加写入收尾校验清单,再调 skill:

```bash
# 决定生成前就登记(check.sh 收尾会核对这些目录是否都产出了完整报告)
echo "/Users/zhaomingxing/github/interviews/<拼音>/<轮次>" >> ~/hire_patrol/last_run_targets.txt
```

然后用 Skill 工具调用 `interview-comment`,args 传候选人链接:

```
https://awaken-intelligence.feishu.cn/hire/talent/<talent_id>?application_id=<application_id>
```

采集/形态判定/健壮性**全部以 skill 的「阶段 0」为准**——skill 会用共享脚本 `chrome-eval.sh` 定位标签页、跑 `page/probe.js` 探针(简历 PDF/图片/标准、速记就绪与否、有无代码考核)、按分支采集,再评估输出 `evaluation.md` + `interviewer-review.md`(有编程题另出 `coding-analysis.md`)。本 prompt 不重复采集细节。

注意:
- **速记未就绪**:skill 探针判 `asr=not_ready` 会返回 `SKIPPED: 速记未就绪`(面试未进行/转写未生成/不完整),不写残缺评价。收到 SKIPPED 就跳过,通知里注明"速记未就绪,明天巡检再试"。**SKIPPED 的候选人不要写入 last_run_targets.txt**(它没打算生成报告,不该被收尾校验判为缺失)。若已提前登记又转为 SKIPPED,从清单里删掉该行。
- **评估务必跑到落盘**:确认 `evaluation.md` 和 `interviewer-review.md` 两个文件都已写出再处理下一个候选人。check.sh 会在你退出后做收尾校验,任何登记了却没产出完整报告的目录都会触发飞书告警。
- **主面 / 旁听要判开**(事故 2026-09-10):飞书 `interviewer_list` 只登记 shadow 者一人,**系统字段判不出谁是主面**。skill 会按 `asr.md` 说话人分布判角色——用户零发言就是 shadow 陪面,此时 `interviewer-review.md` 写成观摩笔记且**不给用户打 A/B/C/D 档**,候选人评价照常写满。两个文件仍然都要产出,收尾校验不变。汇总通知里注明该场是旁听,便于用户区分。
- 全程对飞书只读。

### 4. 发飞书汇总通知

```bash
export PATH=~/.nvm/versions/node/v24.15.0/bin:$PATH
lark-cli im +messages-send --user-id ou_c1ed0ed35fbeaef460c457906f8d31be --markdown $'...'
```

- 有未评价:汇总「未评价 N 个;已生成 X(姓名 + 本地路径);跳过 Y(原因);失败 Z(原因)」。
- 无未评价:发一句「✅ 招聘巡检:今日无未评价面试」。
- 巡检自身失败(登录态失效 / TCC 权限被拒等):发失败原因和需要用户做什么。
