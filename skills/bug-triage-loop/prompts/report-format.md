# prompts/report-format.md

## Review markdown 输出格式

按此模板生成给用户 review 的 markdown。**保持简洁**,重点信息在前 100 字。用户目标是 30 秒内决定 approve/reject/defer。

**规范**:遵循团队 code review comment 约定 —— 长内容(证据链、日志片段、代码引用、验证步骤)用 `<details>` 折叠,顶部只留判定结论 + 根因假设 + review 按钮。

## 标准模板(verdict = real_bug + confidence = likely/needs-more-signal)

```markdown
## Bug review: <title>

**AI 判定**:real_bug | **实锤等级**:likely (score: 0.72) | **严重度**:high | **模块**:`<domain>`
**上报人**:<@name via ou_xxx> | **上报时间**:`<YYYY-MM-DD HH:MM>` +08:00 | **message_id**:`om_xxx`

### 根因假设

前端切换实体时携带**新 primary_key**,但历史数据按**旧 primary_key** 索引存储,`<domain>_service.go:L221` 用请求里的新 key 过滤,导致 `matched_count=0`。

### 建议:先加打点验证(rubric=likely 不 100% 确定)

- **位置**:`<domain>_service.go:L221`(`<HandlerFunc>`)
- **加 span**:`<domain>_list_query`,字段 uid / requested_key / matched_count / filter_applied
- **加告警**:`<domain>_list_empty_when_history_exists`,matched_count=0 但 `<main_table>` 有历史 → 5min > 20 次触发
- **观察窗口**:3 天

<details>
<summary>点开查看:我做了什么定位</summary>

1. **[SLS]** 查 uid=A123 最近 30 分钟 `GET /<domain>` → 命中 12 条,全部返回空数组
2. **[bytebase]** SELECT count(*) FROM `<main_table>` WHERE uid='A123' → 47 条(数据未丢)
3. **[memory]** curl /debug?uid=A123 → 相关记忆数据完整
4. **[代码]** grep `<HandlerFunc>` → `<domain>_service.go:L221` 用 primary_key 过滤

</details>

<details>
<summary>点开查看:证据链</summary>

**每条证据必须标 tag** (`ground_truth` / `strong_signal` / `absence_signal` / `inference` / `hypothesis`; 定义见 rubric.md §证据分级)。

| 证据 | Tag | 内容 | 来源 |
|---|---|---|---|
| SLS 日志 | strong_signal | `GET /<domain>?primary_key=X ... status=200 count=0` | project=`<你的 SLS project>`, logstore=`<domain>` |
| DB 记录 | ground_truth | 47 条 `<main_table>`,primary_key 分布:{"key_A": 40, "key_B": 7} | bytebase prod-`<你的库>` |
| 代码 | ground_truth | `<domain>_service.go:221` 用 `req.PrimaryKey` 过滤 (**完整函数已读**) | worktree: `<github_root>/bug-triage-worktrees/<short>/<backend>` |
| memory | absence_signal (**已排除参数错**: 同 uid 换个 <次键> 对照证实账号可拉非空) | 记忆数据完整,数据未丢 | memory 服务 /debug |

</details>

<details>
<summary>点开查看:对抗式自检 (**mandatory, 缺此段视为不合格报告**)</summary>

**规则来自一次真实事故复盘**: 主 agent 多次翻案都是先给结论后被用户手动打脸。这一段是**给结论前的自我打脸**。不许省略, 不许敷衍。

### 1. 现有证据里最弱的 3 条是什么?

列 3 条, 每条写清"弱在哪"(参数没验、时区没对齐、只 grep 未读完整函数、单一 absence signal, 等)。若不满 3 条 = 证据不够, 不该到 likely 及以上。

### 2. 如果 verdict 反过来, 现有数据能不能解释?

给出至少 1 个反命题, 用现有数据尝试建立它。反命题能被同样数据支持 = 当前 verdict 至少降 1 档。

### 3. 什么样的新数据会 falsify 当前结论?

明确写: 什么 SQL / 什么 SLS 查询 / 什么 curl / 什么代码路径, 结果如何将证伪。**这一条也是 T4/后续追问的清单来源**。

### 4. 时间窗对齐 sanity check

- 投诉时间戳 (UTC+8, 精确到分)?
- SLS 查询窗口是不是 T-2h ~ T+2h?
- 用户操作时间戳跟 DB 时间戳时区一致吗 (unix / UTC / 展示时间)?

任一未对齐 → verdict 强制降到 needs-more-signal。

### 5. 关键代码是否读了完整函数体?

列出所有引用的 file:line, 每一处必须**已读该函数 signature 到 return** (不许只 grep 到函数头)。有 X 处未读 = X 条 inference 证据降为 hypothesis。

### 6. 现状回验 + 用户画像 (来自一次"AI 替用户说话"真实事故复盘)

- 问题**现在**还在吗? 查了该实体的最新状态吗 (最新一条数据的时间戳 + 内容)?
- 用户投诉后的行为曲线拉了吗 (按天使用量 / 订单)? 有没有流失信号?
- 报告里若出现"重度/付费/VIP"字样, order/subscription/wallet 三表查了吗?
- 给用户的每条操作建议, 过了"存在/有权限/机制有效"三验吗 (SKILL.md Step 9)?

任一未做 → 对应结论标注"未回验", 处置建议降级为"待验证"。

</details>

<details>
<summary>点开查看:用户原文 + 附件 OCR</summary>

> <消息内容,不改写,原样引用>

**附件 OCR** (来自 triage.md 的 input_integrity):

- img1.png 提取内容 (verbatim): ...
- img2.png 提取内容 (verbatim): ...

</details>

---

### 你的 review

在对话里回复:
- **`approve`** = 认可分析,归档,推进下一条
- **`reject: <理由>`** = 分析有误,告诉我为什么(用于 prompt 迭代)
- **`defer`** = 稍后再看,本条不推进
```

## 输出规则

1. **必须严格用上面的一级/二级标题**,便于 grep/正则匹配
2. **不要用 emoji**
3. **代码引用必须给 `file:line`**,不要模糊指向
4. **打点方案必须是可执行的**(能直接抄进 grafana-as-code)
5. **不要输出思考过程**,只输出最终 markdown
6. **长内容(证据链/日志片段/用户原文)全部走 `<details>`**,顶部只留决策相关信息
7. **打点或修复方案放顶部**,不要藏在 details 里(用户点开 details 才看到就等于隐藏)

## 4 种 verdict 的模板差异

### 差异 1:verdict=real_bug + confidence=confirmed

把"建议:先加打点验证"换成"修复建议",**并新增必填 `### 修复与存量状态` 段**(P0 规则,来自一次支付相关真实事故复盘)。

```markdown
### 修复建议

- **修复位置**:`<domain>_service.go:L221`
- **修复思路**:改用 `<main_table>` 里 uid 的所有 primary_key 做 OR 过滤,而不是仅用 `req.PrimaryKey`
- **影响面**:受影响用户估算 ~500 <端>用户/天
- **回归风险**:低(只放宽过滤条件,不改数据结构)

### 修复与存量状态 (**mandatory, 缺此段视为不合格 confirmed 报告**)

**规则来自一次支付相关真实事故复盘**:代码 fix 已合入不代表用户已被补发。confirmed 报告必须回验以下 4 项:

1. **修复代码**:
   - Commit hash: `<hash>`
   - Author: `<name> <email>`
   - Commit date (UTC): `YYYY-MM-DD HH:MM`
   - PR: `#XXX`
   - 已部署 prod?**用 SLS 镜像 tag / trace 变化时刻直接印证**(如 image tag 从 `A-xx` 变为 `B-yy` 的第一条日志时间)
2. **存量补救状态**:
   - fix 部署至今是否有 `<Recover/Backfill/Retry>` / 手动补救等 API 的调用日志?(SLS grep 关键字精确统计次数)
   - 若 0 次:说明**没做过存量补**,verdict 保持 confirmed 但必须列全量存量清单
3. **本 uid 现网数据**(报告主 subject uid):
   - 再查一次 bytebase 主表,确认现在还是命中/仍缺失
4. **存量全量清单**:
   - 用 SLS pre-fix 期间 bug 触发日志 grep 出所有独立实体键(uid / <交易键> / order_id 等)
   - 逐个 bytebase 反查 → 输出 "已恢复 N / 未恢复 M" 表,附具体 uid 列表(未恢复的必须列出)
   - 交叉可能有"命中键但归属其他 uid" 的误报,要显式排除

<details>
<summary>点开查看:验证方式</summary>

- 修复后观察 `<domain>_list_empty_when_history_exists` 告警消失
- 抽样 10 个受影响 uid 手动验证结果恢复
- Logfire 上看 `<HandlerFunc>` 返回空数组的比例应该降到 <1%

</details>
```

### 差异 2:verdict=real_bug + confidence=insufficient

打点方案换成"信息补充清单",简化整个 markdown:

```markdown
## Bug review: <title>

**AI 判定**:real_bug | **实锤等级**:insufficient (score: 0.25) | **严重度**:medium | **模块**:unknown
**message_id**:`om_xxx`

### 需要用户补充

- [ ] 受影响的用户 uid
- [ ] 出现问题的时间点(精确到分)
- [ ] 端(iOS/Android/Web)
- [ ] 操作步骤(点了什么按钮之后?)

<details>
<summary>点开查看:我尝试的定位路径</summary>

- 查 SLS 全量搜"<用户口述关键词>" → 命中数万条,无法收敛
- 查代码 `<HandlerFunc>` → 找到但无法对应到具体请求
- 尝试从消息内容抽 uid 关键词 → 无匹配

</details>

<details>
<summary>点开查看:用户原文</summary>

> <消息内容>

</details>

---

### 你的 review

- **`approve`** = 我去追反馈人补细节,先归档
- **`defer`** = 我先看看,可能有额外线索
```

### 差异 3:verdict=not-bug-after-analysis

```markdown
## Bug review: <title>

**AI 判定**:not-bug-after-analysis(初判 real_bug,定位后改判)
**message_id**:`om_xxx`

### 为什么定位后判非 bug

分析后发现是产品预期行为:用户在测试环境做了主动清空缓存的操作,导致本地缓存和服务端不一致。这是正常的缓存刷新流程。

### 建议回复用户

> "感谢反馈。这个是缓存刷新导致的正常现象,重新拉取即可恢复。如果生产环境也有类似问题请再告知。"

<details>
<summary>点开查看:定位过程</summary>

<定位细节>

</details>

<details>
<summary>点开查看:用户原文</summary>

> <消息内容>

</details>

---

### 你的 review

- **`approve`** = 认可,归档
- **`reject: <理由>`** = 你认为它是 bug,告诉我原因(会写入 rubric 反例库)
```

### 差异 4:verdict=not_bug 或 duplicate

**不生成 review markdown**,直接写 processed.jsonl 退出。用户在 state/loop.log 里可以看到跳过原因。
