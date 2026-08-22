---
name: loop-weekly-report
description: 一个每周自动生成工作周报的定时 loop 的设计与参考实现。每周一读上周所有 Claude Code session，用 headless claude 归纳成分类周报云文档，链接自动归档进汇总索引，再推一条通知。适合想用「定时 + headless AI + 从自己的工作痕迹里自动写周报/月报/汇总」的人参考。触发词：自动周报、session 汇总、headless 定时生成文档、工作痕迹归纳、周报自动化、cron + claude -p 写文档。
metadata:
  kind: loop
  schedule: "0 11 * * 1  (每周一上午)"
  surface: cron + headless-claude + cloud-doc + IM-notify
  desensitized: true
---

# loop-weekly-report

> 这是一个 **loop skill**（自动化循环），沉淀的是「怎么用定时 + headless AI 把自己一周的工作痕迹自动写成周报」的设计与去敏参考实现。真实运行需按 `config.example.sh` 填本地配置，并把文档/通知层换成你自己的工具。

一句话：**每周一自动读我上周和 Claude 的所有对话，归纳成一篇分类周报，建成云文档、归档进索引、把链接发我手机。** 我不用再手写周报。

## 为什么值得自动化

周报的原始素材其实全在你一周的工作痕迹里（每个 session 干了什么、解决了什么、结论是什么），只是散、且回忆有偏差。让 AI 从结构化摘要里归纳，比人凭记忆写更全、更省时，还不容易漏掉长会话里真正的重头戏。

## 架构：三步流水线

1. **提取（digest.py）**：扫过去一周 `[上周一, 本周一)` 窗口内所有 session transcript，每个 session 压成一条结构化摘要——项目、时间、PR/issue 号、**按首/中/末采样的多条用户消息**、**助手正文里的高信号行**、**子代理关键词命中**、最终结论。
2. **归纳（headless claude）**：`claude -p` 通读摘要，按固定大类（需求承接 / 稳定性排查 / 用户反馈 / 架构设计 / 基础组件 / 研发效能）归纳成 1000~1500 字周报 + 「下周重点」，创建云文档，并把 URL 用固定格式 `WEEKLY_DOC_URL=<url>` 打到 stdout 供脚本捕获。
3. **归档（archive-to-index.sh）**：把这周的链接插到「汇总索引文档」锚点段落之后（最新在最上），再推通知。

## 关键设计决策与踩过的坑

- **采样别只取首条消息**：早期 digest 只取「首条用户请求 + 末条助手回复」，结果**续接会话和长会话的主线全丢**——一个 session 聊了 5 个话题，只看到第一个。改成对去重后的真实用户消息按位置（首/中/末）采样，才抓得住主线。
- **子代理命中兜底话题漂移**：真正的重活常常 fan-out 到 subagent 里做，主线程摘要看不到。所以额外扫每个 session 关联的 `subagents/` 目录，统计领域关键词命中次数——命中高的关键词往往才是这个 session 的重头戏。这些关键词要**按你自己的业务领域定制**（脚本里给的是通用工程词）。
- **高信号行摘取**：助手正文里含「上线/合入/事故/验收/压测…」这类里程碑词的行单独摘出，避免归纳时漏掉关键成果。同样建议按业务补词。
- **URL 用固定标记回传**：headless claude 建完文档后，约定用 `WEEKLY_DOC_URL=<url>` 单独一行输出，外层脚本用 `grep -oE` 抓，比让模型「告诉我链接」稳定得多。这是**让 headless AI 和外层脚本可靠交接结果的通用技巧**。
- **锚点按关键词定位，不硬编码 block-id**：归档时在索引文档里按锚点关键词找插入位置，而不是记死某个段落 id——文档结构一变，硬编码就失效。
- **数字必须来自素材、不许编造**：prompt 里明确要求所有数字/结论/PR 号来自摘要文件；元操作类 session（讨论周报本身）和测试 session 不计入工作量。

## 脱敏红线

- **署名、租户域名、文档 ID** 全部外置到 config，仓库里只有占位符。
- **业务领域关键词**（gems/coins/内部功能名之类）不进仓库——脚本里只放通用工程词，你在本地 config 化的 digest 里自己加。
- 周报正文由 AI 从你的私有 session 生成、发到你自己的云文档，**不经过这个公开仓库**；仓库里只有生成它的脚本骨架。

## 需要你自备/替换的东西

- **云文档 CLI（`$DOC_CLI`）**：创建/更新文档、按 block 插入内容。参考实现依赖一个私有 CLI，未随仓库分发——`archive-to-index.sh` 里用伪代码 + TODO 标出了你要补齐的 4 步。
- **通知渠道（`$NOTIFY_CMD`）**：把链接推到你的 IM/邮件。
- **索引文档**：一篇带锚点段落的「周报汇总」文档，新链接往锚点后插。

## 安装与自检

```bash
./install.sh init-config     # 生成 ~/.config/loop-weekly-report.sh
$EDITOR ~/.config/loop-weekly-report.sh
./install.sh doctor          # 自检依赖与配置
./install.sh install-cron    # 装 crontab（每周一 11:00）
```

## 与其他 skill 的边界

- 本 skill 管「每周归纳」。要按天做「日记 + 自我改进项」复盘，见 `loop-daily-retro`；要让 skill 库自己进化，见 `loop-skill-optimizer`。三者共享「cron + headless claude + digest 提取 + 去敏配置外置」的同一套范式，但产物和窗口不同。
