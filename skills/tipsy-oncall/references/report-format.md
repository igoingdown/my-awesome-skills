# 五段值班报告格式规范

这份文档定义 tipsy-oncall skill §3 那份「五段结构」值班排障报告的详细规范。**做完排障、准备把结论回给业务或研发前必读**——包括临时口头汇报、飞书群贴、issue 收尾评论、以及塞给下一位值班的交接文档。仅在自己脑内推理、还没对外输出时不用严格套。

## 一、为什么是硬约束

- **值班场景需求**：读的人（PM、上游研发、下一位值班）通常不会花超过 30 秒读你的报告。五段「现象 → 通道 → 查询 → 结论 → 后续」一眼扫下去能定位到自己要看的位置；合成一整段接的人得逐字读。
- **机器可再消费**：结构化五段将来能被检索、被 AI 复盘、被写入 llmdoc 长期记忆；散文式排障除了写它的人自己没人能维护。
- **历史误判教训**：曾出现「角色可见性消失」被复述成「翻译门控 bug」的事故，就是因为报告里把「用户说」当结论、没分离「现象」与「结论」两段。五段结构强制把用户话术转成客观现象，避免带偏。

## 二、五段详细规范

### 现象
- 一句话客观描述 + 时间窗（精确到分钟，UTC 与北京时间同时给一个）+ 环境（prod / test / preview）。
- 禁止「用户说……」。用户话术要翻译成客观事实,比如「用户反馈角色消失」写成「trending / latest / web 三列表 07-04 02:15~02:40 UTC 新角色曝光条数下降 70%,test 环境未复现」。
- 禁止无时间窗。「今天早上」不算,「07-04 02:15~02:40 UTC(北京 10:15~10:40)」才算。

### 通道
- 1~3 个通道 + **每个通道为什么选它**。通道即数据源(bytebase MySQL / PG、SLS、signoz、memory curl、ES REST、Redis RunCommand、Chrome fetch)。
- 禁止只写通道名不写理由。写「查 SLS」不合格;写「查 SLS 因为 trending 走搜索 API,应用日志会带 recommend_char_ids 采样」合格。
- 超过 3 个通道说明问题面没收敛,回去重新缩小假设。

### 查询
- 每个通道给出关键命令,一律用 secrets.sh 变量名占位,**不允许出现真实 URL、token、accesskey**。
- 每条命令后跟精简结果,3~5 行封顶。禁止粘一屏原始日志——把日志压成关键字段。
- 需要 PromQL / SQL / SPL 的,把语句本身保留,方便别人复用。

### 结论
- 一句话判定 + 根因指向具体文件 / 函数 / 表 / 字段。
- 禁止多结论并列。有两个不确定原因说明排障没做完,不该出报告。
- 禁止「可能是……」「疑似……」模糊表达。真不确定就写「无法判定,已排除 X / Y,待补 Z 通道数据」。

### 后续
- 1~3 条 actionable。每条含「动作 + 责任方(@who)+ deadline / 触发条件」。
- 禁止「关注一下」「注意监控」「后续排查」这类空话。要么「@张三 07-05 前给 hotfix PR」,要么「触发条件:同一告警再出现即回滚 dev@abc123」。

## 三、常见反模式

- 五段合并成一段散文,读者要通读才能拼出脉络。
- **结论段里写现象**(「trending 消失了」是现象;「NSFW 筛选精确匹配 bug 导致新角色被过滤」才是结论)。
- **后续段里写结论**(把根因塞进后续,读者会漏掉)。
- 查询命令没脱敏,粘了真 token / accesskey / 真 URL——直接违反 skill §1 铁律。
- 后续给不出 actionable,只是把「感觉要关注 X」当动作。

## 四、示范：三个真实场景

### 示范 A ｜ 角色可见性(MySQL + ES 双通道)

**现象**:trending / latest / web 三列表 07-04 02:15~02:40 UTC(prod) 新角色曝光下降 70%,test 环境未复现。
**通道**:①bytebase MySQL(核对可见字段 `is_public` / `is_deleted` / `limitless_level`);②ES REST(核对索引 doc count 是否同步)。选双路是因为可见性由 MySQL 权威 + ES 检索共同决定,必须两路对齐才能定位错位在哪一层。
**查询**:
- `bytebase.query_database "SELECT COUNT(*) FROM character WHERE created_at BETWEEN ... AND is_public=1"` → MySQL 新角色 1240 条,`is_public=1` 占 98%。
- `curl -s "$ES_ENDPOINT/character/_count" -u "$ES_USER:$ES_PASSWORD" -d '{...}'` → ES 同窗口 doc count 372 条,缺 868 条。

**结论**:根因在 ES 同步链路。`character/service/visibility.go:filterByRating` 的 NSFW 筛选精确匹配 bug 在 `limitless_level=NULL` 时把新角色误判为 NSFW,同步 worker 跳过写入。
**后续**:
1. @李四 07-05 前提 hotfix,把 `IS NULL` 视作 SFW。
2. @值班 加 Grafana 告警:MySQL 新角色数 - ES doc count 差值 >100 触发。

### 示范 B ｜ mempoint 没入库(PG + memory curl 双通道)

**现象**:test 环境 uid=xxx 用户 07-04 05:00~05:30 UTC 完成 6 轮对话,memory retrieve 未拿到任何 mempoint。
**通道**:①memory 直连 curl(memory 服务是否收到 ingest);②bytebase PG `tipsy_memory` 库(是否落表)。选这两路是因为 SLS 对 mempoint 静默(见 skill §1 铁律),必须绕开 SLS。
**查询**:
- `curl "$TIPSY_MEMORY_URL_TEST/v1/memory/retrieve?uid=xxx&..."` → mempoints=[],但 `debug_log` 显示 4 次 ingest 收到且 `dedup_hit=true`。
- `bytebase.query_database "SELECT COUNT(*), MAX(created_at) FROM mempoint WHERE uid='xxx'"` → 库里 0 条,最新记录停在 04:12 UTC。

**结论**:ingest 请求到达但被 dedup key 拦截。根因:客户端上一轮会话 `batchTurns=4` 缓存未清,新会话复用了旧 dedup key(`memory/dedup.go:makeKey`)。
**后续**:
1. @王五 07-05 前给 dedup key 加 sessionID 维度。
2. @赵六(客户端)排查 batchTurns 边界为什么跨会话复用。

### 示范 C ｜ 接口 500(SLS 单通道)

**现象**:prod `/v1/chat/send` 07-04 10:22~10:24 UTC 连续 500,error rate 从 0.02% 飙到 4.1%,2 分钟后恢复。
**通道**:SLS 线上 project(`k8s-log-cdabe95251a0843e983951d48046d1b21` / logStore `tipsy-chat`)。单通道即可,因为窗口极短且已恢复,直接拉时段 ERROR 级日志足以定位;拉 signoz 时序反而慢。
**查询**:
- `sls_execute_spl` 查询:`* AND level:ERROR AND path:/v1/chat/send AND time >= 10:22 AND time <= 10:24` → 5 条 stack 全部指向 `chat/service/send.go:142 nil pointer dereference on user.Profile`,伴随 upstream `profile-service` timeout 日志 12 条。

**结论**:profile-service 短暂抖动 → Profile 返回 nil → send handler 缺防御导致 panic。根因在 `chat/service/send.go:142` 缺 nil check;profile-service 抖动是触发条件。
**后续**:
1. @陈七 07-05 前加 nil check + 熔断兜底。
2. @值班 观察 profile-service p99,若 2 分钟内 timeout >10 次立即触发告警。

## 五、反模式对比

**坏例子(合并成一段)**:「trending 列表消失了,查了下 MySQL 和 ES,发现 ES 少了 800 多条,可能是 NSFW 筛选的问题,建议关注一下。」——现象 / 通道 / 查询 / 结论 / 后续全糊在一起,「可能」违反结论段禁令,「关注一下」不是 actionable。

**好例子**:严格按示范 A 五段格式,每段有明确边界,结论无歧义,后续可执行。

## 下一步 / 相关

- 想理解每个通道具体怎么查、返回什么字段:见 `references/mysql-postgres.md` / `references/sls-logs.md` / `references/memory-direct.md`。
- 「查询」段的命令模板与脱敏规范:见 `references/report-format.md`。
- 「后续」段对接 llmdoc 更新的接法:见 `references/report-format.md`。