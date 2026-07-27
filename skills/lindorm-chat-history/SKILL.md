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

## 依赖

`curl`（必需）、`jq`（美化/导出模式需要，缺失时降级为原始 JSON 输出）。
