# docs/config.md

## 配置项

skill 会自动读这个文件,用 grep/正则从 markdown 里抽 `key: value`。

**首次使用**:把下面 3 个 `FILL_ME_*` 占位符替换为你的真实值。不填 skill 会直接退出并报错。

## 必填(替换占位符)

### bug_chat_id

飞书 Bug 反馈群的 chat_id(格式 `oc_xxx`)。用 `lark-cli im +chat-search --query "bug" --as user` 查到。

```
bug_chat_id: FILL_ME_OC_XXX
```

### my_open_id

你自己的 open_id(格式 `ou_xxx`),用于飞书私聊推送。用 `lark-cli contact +get-user --as user --json` 查到。

```
my_open_id: FILL_ME_OU_XXX
```

### github_root

你的 GitHub 工作目录根,skill 会在这里扫候选仓 + 开 worktree。

```
github_root: FILL_ME_ABSOLUTE_PATH
```

**注**:worktree 会开在 `<github_root>/bug-triage-worktrees/<message_id_short>/<repo_name>`。

## 可选(有默认值,不填也能跑)

### history_backfill_days

首次启动回拉多少天群历史。MVP 阶段先设 7 天,跑通稳定后再放大。

```
history_backfill_days: 7
```

### quiet_hours

静默时段(Asia/Shanghai)。静默期照常处理消息,但不发飞书推送。

```
quiet_hours: 22:00-08:00
```

### push_channel

推送方式。仅支持 lark 应用内私聊。

```
push_channel: lark_im_bot
```

### processed_verdict_scope

处理 review 时,是否把 not_bug 和 duplicate 也算作"已处理"(下次不再挑到)。

```
processed_verdict_scope: true
```

### workflow_min_evidence_sources

定位阶段何时切换到 dynamic workflow 并发模式。证据源估算 >= 此值时走 workflow。

```
workflow_min_evidence_sources: 3
```

## 涉及的仓库(bug-analyze / Step 7 参考)

Bug 可能跨多个仓。skill 在 Step 7 定位阶段会**先扫 `<github_root>/*` 拿到候选仓列表**,再按 module 字段决定开哪些仓的 worktree(见 SKILL.md Step 7)。

**你需要在下表里维护自己项目的仓库 → 模块 → 分支映射**。示例(替换成你的项目):

| 仓库 | 路径 | 主分支(worktree 用) | 模块归属 |
|---|---|---|---|
| example-backend | ~/github/example-backend | dev | 后端 / chat / memory / character / audit / pay 主战场 |
| example-app | ~/github/example-app | main | iOS/Android 客户端 |
| example-admin | ~/github/example-admin | main | 后台管理页面 |
| example-subscription | ~/github/example-subscription | main | 独立支付/订阅微服务(module=pay 时必须扫) |
| example-memory | ~/github/example-memory | main | 独立记忆微服务(module=memory 时必须扫) |

**注意**:很多项目会把 pay/memory 拆到独立微服务,不能默认 "chat/pay/memory 都归主后端"。**module 到候选仓的映射见 SKILL.md Step 7 §"module → 候选仓扫描"**。若你的项目全在一个 repo 里,只留一行即可。

**分支约定**:每行按你项目的真实主分支填(有的项目 main 有的项目 dev)。skill 不猜,以此表为准。

## 数据通路表(可选但强烈建议维护)

**规则来自一次"AI 替用户说话"真实事故复盘**:核心业务数据(如聊天消息正文)常存在 bytebase/DMS 覆盖不到的存储里(Lindorm / DynamoDB / 自建 KV)。每次排查现场摸通路极其费时。在下表维护"想看什么数据 → 走哪条通路",skill 在 Step 7/8 需要拉数据时**先查此表**:

| 想看的数据 | 首选通路 | 兜底通路 | 备注 |
|---|---|---|---|
| (示例)用户聊天原文 | 主库 feedback 表的上下文快照字段 | 会话表末条冗余字段;SLS ACCESS 日志 req body | 主存储 Lindorm 无直查权限 |
| (示例)用户实时设置 | SLS 里 setting/get 接口的 res body | 主库 user 表 | 接口响应含实时生效值 |
| (示例)用户付费画像 | order + subscription + wallet 三表 | 支付网关后台 | 涉及"重度付费"断言必查 |

**维护时机**:每次排查中发现新通路(或某通路失效),当场更新此表。

## 敏感数据脱敏

以下字段在写入 state/ 前必须打码:

- 手机号(11 位数字) → `1**********`
- 邮箱 → `xxx@***`
- 银行卡号 → `**** **** **** ****`
- access_token / api_key / bearer → `<REDACTED>`

skill 用 sed 自动处理,你不用管。

## 校验

```bash
grep -E "^(bug_chat_id|my_open_id|github_root):" docs/config.md | grep -v FILL_ME | wc -l
# 期望 = 3
```
