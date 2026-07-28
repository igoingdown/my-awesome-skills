---
name: lindorm-chat-history
description: 按 UID 查用户在 Lindorm(LindormSearch/ES 兼容) 里的聊天原文。使用时：用户想查某个 UID(或反转 UID)在 chat history 索引里的聊天记录、会话原文、消息内容时触发。
---

# Lindorm 用户聊天原文查询

按 UID 从 Lindorm 的聊天记录索引里拉用户聊天原文。索引名、字段名都通过环境变量注入，适配不同部署。

## 快速开始

```bash
# 按原始 UID 查（脚本自动反转后匹配用户字段）
bash query_chat_history.sh 100000000000000001

# 手上已经是反转后的值（或索引直接存原始 UID），加 --reversed 跳过反转
bash query_chat_history.sh 100000000000000009 --reversed

# 只数命中条数
bash query_chat_history.sh <uid> --count

# 只看某个会话
bash query_chat_history.sh <uid> --conversation <conversation_id>

# 覆盖索引名（否则取 env LINDORM_CHAT_INDEX）
bash query_chat_history.sh <uid> --index my_chat_index

# 导出该用户全部消息到 JSONL（search_after 翻页）
bash query_chat_history.sh <uid> --export /tmp/chat.jsonl
```

## 关键背景（务必先读，都是踩过的坑）

- **端点通常是 LindormSearch 搜索引擎**（ES 兼容，`proxy-search` 端口默认 30070），**不是 LindormTable SQL**。必须走 ES REST 接口；`lindorm-cli` 对这个地址无效，会报 `parse url failed`。
- **UID 可能是反转存储的**：有些部署把用户 ID 十进制字符串整体按字符倒序后再入库（打散分片、避免写热点），存进 `rev_user_id` 之类字段。脚本默认把传入 UID 反转后再匹配。
  - 若你手上已是反转值 → 加 `--reversed`。
  - 若索引直接存原始 UID → 设 `LINDORM_USER_FIELD` 指向原始字段并加 `--reversed`（等于不反转、按你给的值查）。
- **有的索引 `_source` 被关闭**（`enabled:false`），默认命中不返回文档，必须用 `docvalue_fields` 显式点名字段。脚本已按 docvalue 取值。
- **若 `content` 是 `keyword` 且设了 `ignore_above`**：超过该长度的单条消息不会进该字段索引，可能取不到。
- **"这个字段不存在"必须先核 mapping 再下结论**：`_source` 关闭时，没在 `docvalue_fields` 里点名的字段一律不返回，看起来和"表里压根没这列"一模一样。判断字段有无只认 `GET <index>/_mapping`（再对照存储侧的建表定义），不认"查了一次没返回"。踩过：据此宣布索引缺 sender 字段，被用户当场纠正"这个表有该字段，你的结论明显是错的"。
- **缺发送方/角色字段时，禁止用序号奇偶推断角色**：会话内序号未必从固定一方起步，也可能有系统消息、重发、异步补写打乱奇偶——按奇偶分 user/assistant 的标注会成片错，且错得看不出来（用户第一反应就是"按奇数偶数分角色可能不准呀"）。正确做法是多源交叉补齐这一列：① 先核 mapping / 建表定义确认索引或存储里是否本就有该字段（多数情况是有的，只是没取）；② 存储侧按主键点查同一条消息，拿它的发送方枚举值；③ 仍缺就用日志侧的请求/落库原文按消息 ID 对齐反查。三条都不通时，标注只能标 unknown，不许用奇偶顶上。

## 配置（索引名/字段名放 env，真实内部命名不进仓库）

| 变量 | 必填 | 默认 | 说明 |
|------|------|------|------|
| `LINDORM_ENDPOINT_URL` | 是 | — | LindormSearch 接入地址，如 `http://ld-xxx-proxy-search-public.lindorm.rds.aliyuncs.com:30070` |
| `LINDORM_USER` | 是 | — | 用户名 |
| `LINDORM_PASSWORD` | 是 | — | 密码 |
| `LINDORM_CHAT_INDEX` | 是 | — | 聊天记录索引名（也可用 `--index` 传） |
| `LINDORM_USER_FIELD` | 否 | `rev_user_id` | 用户 ID 字段（term 匹配用） |
| `LINDORM_CONV_FIELD` | 否 | `conversation_id` | 会话 ID 字段（排序/过滤用） |
| `LINDORM_SEQ_FIELD` | 否 | `sequence` | 会话内序号字段（排序用） |
| `LINDORM_CONTENT_FIELD` | 否 | `content` | 消息原文字段 |
| `LINDORM_EXTRA_FIELDS` | 否 | — | 额外要取的字段，逗号分隔 |

凭据/配置统一放 `~/github/my_dot_files/secrets.sh`（可用 `SECRETS_FILE` 或 `--secrets` 改路径），脚本启动时若 env 未设置会自动 `source`。完整示例见 `secrets.example.sh`。密码通过 curl `-K` 从 stdin 传入，不会进 `ps` 或命令历史。

结果按会话字段再按序号字段排序，即每段对话的自然顺序。

## 拉完之后：怎么组织成可 review 的取证材料

聊天原文常常只是链路的一环。要复盘"用户这一轮到底经历了什么"，需要把原文和日志侧的中间产物按消息 ID / 时间对齐拼起来，而不是只贴聊天记录。踩过的返工点：

- **先在本地整理成表格（CSV / JSONL）跑通一遍，再同步到协作文档**。直接边查边往云文档里写，字段缺漏和顺序错乱要到用户 review 时才暴露，返工一次成本很高。本地那一版就是自查用的：每行一轮，列齐"输入 / 中间产物 / 输出"，自己从头到尾读一遍再上传。
- **组织维度是"每个用户一章 → 章内按对话轮次顺序"**，不是按数据源或按字段分块。用户要看的是时间线，不是"这是 A 源的数据、那是 B 源的数据"。
- **非中文内容逐条给中文译文，一条都不能漏**。用户明确要求原文 + 译文对照，包括摘要类、要点类等衍生字段——只译对话正文、漏译衍生字段会被打回。
- 单个用户几十上百轮时原文体量很大：一律先落盘（`--export`）再用脚本统计，上下文里只留结论与少量示例，别把整段原文读进对话。

## 依赖

`curl`（必需）、`jq`（美化/导出模式需要，缺失时降级为原始 JSON 输出）。
