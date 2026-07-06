# Memory 服务直连排障 recipe

这份文档解决"绕开后端 API、直接对 memory 服务发 curl 验证记忆行为"的场景。当值班收到"AI 忘了刚才说过的话""换了话题就漏词""reset OC 后还在提旧事"这类工单,或者通过 PG 直查已经确认某条记忆入库了但用户反馈完全没生效,读这份;如果只是想确认"是否落库",走 `references/mysql-postgres.md` 的 PG 章节即可,不必打搅 memory 服务。

## 服务位置与鉴权

memory 服务是内部服务,不走网关,没有 token 鉴权,直接 curl endpoint 即可。endpoint 一律走 env 变量,永远不要把明文 URL 粘进报告、脚本或提交里:

- 线上:`$TIPSY_MEMORY_URL_PROD`
- 测试:`$TIPSY_MEMORY_URL_TEST`

先 `source secrets.sh` 让这两个变量落到当前 shell,再执行下面所有命令。所有 curl 都用 `-sS -m 10 -H 'Content-Type: application/json'` 打底,避免长时间挂住终端。

## 四个核心 endpoint

### POST /v1/memory/retrieve(**只读**,首选)

按 (session_id, character_id) 做 embedding 检索,返回 top-k mempoints。这是排障最常用的入口,因为它反映的是**上游模型实际能拿到的记忆**,而不是数据库里躺着的记忆。

```bash
curl -sS -m 10 -X POST "$TIPSY_MEMORY_URL_PROD/v1/memory/retrieve" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"<sid>","character_id":"<cid>","k":10}'
```

`k` 不传时由服务侧决定,一般 5~10。返回体 mempoints 为空**不等于**"没入库",可能只是"这次 query 的向量距离打不进 top-k"。

### GET /v1/memory/summary(**只读**)

按 (session_id, character_id) 拿当前摘要,验证"AI 是否记住了长期主线"。

```bash
curl -sS -m 10 "$TIPSY_MEMORY_URL_PROD/v1/memory/summary?session_id=<sid>&character_id=<cid>"
```

打电话摘要 (`character_call_summary`) 不走这个 endpoint,那条链路见 `llmdoc/voice-call-memory-backtrack.md`。

### POST /v1/memory/ingest(**变更**,慎用)

手工回灌 mempoints,一般只在灰度重跑或修数据时用。body 里 `messages` 是原始对话数组,服务侧再切分 mempoint。

```bash
curl -sS -m 10 -X POST "$TIPSY_MEMORY_URL_PROD/v1/memory/ingest" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"<sid>","character_id":"<cid>","messages":[...]}'
```

只读默认下不主动调用;需要用户在工单里显式确认再执行,而且线上要先在测试环境用同一批 messages 复现一遍。

### DELETE /v1/memory/delete(**危险,变更**)

按 (session_id, character_id) 清空记忆,常见于"reset OC / 重置人设"的场景。这条**不属于** tipsy-oncall 的只读默认范畴,只在用户明确点名"我要清"、并给到 session_id 时才碰,而且必须先用 retrieve + summary 各拉一份存进报告作为证据。

```bash
curl -sS -m 10 -X DELETE "$TIPSY_MEMORY_URL_PROD/v1/memory/delete" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"<sid>","character_id":"<cid>"}'
```

## mempoint 语义与脚本封装

memory 服务对 mempoint 的处理有三条硬语义,看日志和对比 PG 时必须记住:

- **batchTurns=4**:每 4 轮对话切一个 mempoint,不足 4 轮不落。
- **相交区间即删**:新 mempoint 覆盖的对话区间和旧 mempoint 相交时,**旧的会被删除**,不是"追加"。
- **dedup key 拦重**:同一 dedup key 的 ingest 会被拦掉,防止上游重试造成重复 mempoint。

日常排障不必手撸 curl,直接用 `scripts/` 目录下的封装:

- `scripts/memory-retrieve.sh <env> <session_id> <character_id> [k]`:一键调用 retrieve,自动挑 PROD/TEST endpoint。
- `scripts/mempoint-timeline.sh <env> <session_id> <character_id>`:把 PG 里该 session 的所有 mempoint 按时间线打印出来,能一眼看出"相交即删"是否发生、有没有漏切。

两条脚本都是只读的,可以放心跑。

## 与 PG 直查的关系(交叉验证)

**永远不要单看一个信号下结论**。PG(`tipsy_memory` 库)直查回答的是"记忆有没有入库",curl retrieve 回答的是"记忆能不能被检索到",两条链路互不覆盖:

| 场景                     | PG 直查 | curl retrieve | 结论                                  |
| ------------------------ | ------- | ------------- | ------------------------------------- |
| 都有                     | 有      | 有            | 记忆链路正常,问题在上游 prompt 或裁剪 |
| 只 PG 有                 | 有      | 空            | embedding 检索 miss,查向量 / query    |
| 只 retrieve 有(极少)   | 无      | 有            | 缓存幻觉或 session_id 打错            |
| 都没                     | 无      | 空            | 没入库,查 ingest 链路                 |

PG 查询模板在 `references/mysql-postgres.md`,mempoint 表结构和字段语义在 `llmdoc/multi-role-memory-design.md`。

## 排障案例

**现象**:用户反馈"AI 完全忘了刚才聊的",带来 session_id 和 character_id。
**通道**:先 PG 直查 `mempoint` 表 → 再 `scripts/memory-retrieve.sh prod <sid> <cid> 10`。
**查询**:PG 显示该 session 有 3 条 mempoint,retrieve 返回空。
**结论**:入库正常,是 embedding 检索 miss。核对 mempoint 内容后发现被"相交即删"合并到了最新一条,而最新那条向量和用户当前 query 语义距离远,top-k 打不中。判为已知语义、回归 memory 服务侧的检索质量看板,而非丢库 bug。

## 下一步 / 相关

- `references/mysql-postgres.md`:PG `tipsy_memory` 库表结构与只读查询模板。
- `references/report-format.md`:五段报告如何把 PG + retrieve 两个信号交叉写清楚。
- `llmdoc/multi-role-memory-design.md`:三层记忆设计、群聊 vs 私聊 ingest 差异、`character_knowledge` 独立表。
- `llmdoc/voice-call-memory-backtrack.md`:打电话摘要的独立链路,不走本文档的 summary endpoint。