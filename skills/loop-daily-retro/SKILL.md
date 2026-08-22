---
name: loop-daily-retro
description: 一个每日自我复盘的定时 loop 的设计与参考实现。每天读昨天所有 Claude Code session（可选叠加 IM 素材），用 headless claude 生成「日记 + 自我改进项」云文档，并维护一篇持续累积的自我改进计划。适合想用「定时 + headless AI 做每日复盘、沉淀改进项、追踪自我成长」的人参考。触发词：每日复盘、自动日记、自我改进闭环、headless 定时复盘、session 复盘、cron + claude -p 写日记。
metadata:
  kind: loop
  schedule: "7 10 * * *  (每天上午，错峰)"
  surface: cron + headless-claude + cloud-doc + IM-notify
  desensitized: true
---

# loop-daily-retro

> 这是一个 **loop skill**（自动化循环），沉淀的是「怎么用定时 + headless AI 每天给自己写复盘日记、并累积自我改进计划」的设计与去敏参考实现。真实运行需按 `config.example.sh` 填本地配置，并把文档/通知/IM 层换成你自己的工具。

一句话：**每天早上自动读我昨天和 Claude 的所有对话，写成一篇复盘日记（最耗时/最难/怎么优化的/能沉淀什么），并把改进项追加进一篇持续累积的自我改进计划。** 逼自己每天回看、持续变好。

## 为什么值得自动化

复盘的价值在坚持，但人很难天天手写。把昨天的工作痕迹自动提取、让 AI 按固定的复盘框架归纳，门槛降到零，就能天天做。更关键的是**累积**：单日日记之外维护一篇「自我改进计划」，让改进项跨天沉淀、可回看，而不是写完就忘。

## 架构：提取 → 归纳 → 累积

1. **提取（digest.py）**：只切**昨天当天**的 session 轮次（不是整个 session 的首尾），按当天轮次数排序，前 3 个标 `[TOP]` 并内联较完整对话正文（用户提问给足、助手每轮给首段），让模型能判断「最难的事、怎么优化的」；其余只给摘要。可选叠加 IM 素材（见下）。
2. **归纳（headless claude）**：围绕固定五问写 ≤1000 字第一人称日记 + 「今日自我改进项」（≤3 条，具体可执行），建成云文档。
3. **累积（同一次调用内）**：维护一篇「自我改进计划」文档——首次运行新建并回传 token，之后每天把新改进项**追加到顶部、保留历史**。token 存本地状态文件，跨天复用同一篇。

## 关键设计决策与踩过的坑

- **切当天轮次，不切整 session 首尾**：一个长 session 可能跨好几天，只取首尾会串味。按 `timestamp` 前缀精确切出「昨天这一天」在每个 session 里的轮次，才是当天真实工作量。
- **[TOP] 分层内联，控制素材体积**：只有当天最活跃的前 3 个 session 内联完整对话（够模型判断难点），其余给摘要。既让模型抓住重点，又不让素材爆掉 headless 的上下文。
- **别让 headless 去读原始 transcript**：transcript 动辄十几 MB，模型一 Read 就超时。digest 把该看的都提取进一个纯文本文件，prompt 里明确要求「只读这个文件，不要 Read 原始 transcript」。这是**喂 headless AI 大体量素材的通用要点**：预提取成小文件，禁止它自己去啃大文件。
- **累积文档靠 token 复用**：首次运行让模型把新建文档的 token 用固定格式 `PLAN_TOKEN=<token>` 回传，脚本抓下来存盘；之后传给模型让它追加而非重写。这是**让每日 loop 维护同一篇长期文档的通用手法**。
- **判空要静默但留痕**：当天没有 session 活动时不生成空日记，但仍推一行提示，避免「今天怎么没日记」的疑惑。
- **数字不许编造**：prompt 强约束所有数字/结论/PR 号来自素材文件；测试性 session 和纯生活类内容忽略。

## IM 素材是可选插件（不绑定平台）

自我笔记、私聊、群里 @我 这类即时通讯素材，常藏着当天的想法和被交办的事，是很好的复盘补充。但 IM 平台各异，本 skill **不绑定任何具体 IM**：

- 在 config 里设 `IM_DIGEST_CMD` 指向一个命令（签名 `<cmd> <YYYY-MM-DD>`，输出当天素材纯文本、自己负责过滤自动推送），digest 就会把它的输出追加进 PART 2。
- 不设则复盘只基于 Claude session，PART 2 留空。

## 脱敏红线

- **署名** 外置到 config。
- **IM 层完全插件化**：参考实现里没有任何具体 IM 平台的命令、字段、群名、联系人——那些属于你的私有环境，通过 `IM_DIGEST_CMD` 在本地注入。
- 日记与改进计划由 AI 从你的私有素材生成、写到你自己的云文档，**不经过这个公开仓库**。

## 需要你自备/替换的东西

- **云文档 CLI（`$DOC_CLI`）**、**通知渠道（`$NOTIFY_CMD`）**：同 `loop-weekly-report`。
- **IM 素材命令（`$IM_DIGEST_CMD`）**：可选，接入你的 IM 抓当天素材。

## 安装与自检

```bash
./install.sh init-config     # 生成 ~/.config/loop-daily-retro.sh
$EDITOR ~/.config/loop-daily-retro.sh
./install.sh doctor          # 自检依赖与配置
./install.sh install-cron    # 装 crontab（每天 10:07，错峰）
```

手动补跑某天：`daily-retro.sh 2026-08-06`。

## 错峰：为什么是 10:07 不是 10:00

这台机器上跑着一批定时任务，整点（尤其 :00 / :30）容易撞车——多个 loop 同时起 headless claude、同时抢 IO，会互相拖慢甚至打爆资源。所以复盘挂在 **10:07** 这种非整点上。**给任何定时 loop 选时间点时，主动避开整点和别的任务的时刻**，是共享机器上的基本礼貌，也能让每个 loop 拿到更稳的资源。

## 与其他 skill 的边界

- 本 skill 管「每天复盘 + 累积改进」。要按周归纳工作成果，见 `loop-weekly-report`；要让 skill 库自己进化，见 `loop-skill-optimizer`。三者共享同一套「cron + headless claude + digest 预提取 + 去敏配置外置」范式。
