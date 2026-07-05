---
name: newapi-usage
description: 查询 new-api / one-api 系 LLM 网关的当日用量（按模型的花费/tokens/调用次数 + 账户余额）并通过 lark-cli 飞书私聊推送。当用户询问"今天 LLM 用了多少"、"new-api 用量"、"模型花费"、"token 消耗"，或要求配置/排查每小时用量推送定时任务时使用。
---

# new-api 当日 LLM 用量报告

查询 new-api（one-api 系开源网关）`/api/data/self` 接口，聚合当日按模型的用量（美元花费、tokens、调用次数），附账户余额，通过 lark-cli 飞书私聊推送。支持 launchd（macOS）/ cron（Linux）每小时定时执行，自带推送降噪（用量无变化不重复推）。

## 手动执行

```bash
bash <skill目录>/scripts/report.sh
```

输出日志到 stdout；推送成功会在飞书私聊收到消息。当日无用量、或用量与上次推送无变化时跳过。

## 配置（统一放 secrets.sh，敏感信息不进仓库）

脚本启动时 source `~/github/my_dot_files/secrets.sh`（可用 `NEWAPI_SECRETS_FILE` 改路径）。该文件是个人凭证文件，**不进任何版本库**。需包含：

```bash
export NEW_API_BASE_URL="https://your-newapi.example.com"   # 实例地址（内网域名属敏感信息）
export NEW_API_ACCESS_TOKEN="xxxx"                          # 系统访问令牌
export NEW_API_USER_ID="1"                                  # 平台用户 id
export NEWAPI_REPORT_RECEIVER="ou_xxxx"                     # 飞书接收人 open_id
# 可选：
# export NEWAPI_QUOTA_PER_UNIT=500000   # quota→$1 换算率，默认 500000
# export LARK_CLI=/path/to/lark-cli     # lark-cli 不在常规路径时指定
```

获取各项的值：

- **NEW_API_ACCESS_TOKEN**：平台「个人设置」页生成系统访问令牌；或已登录会话调 `GET /api/user/token`。**重新生成会使旧令牌失效**
- **NEW_API_USER_ID**：`GET /api/user/self` 返回的 `data.id`
- **NEWAPI_QUOTA_PER_UNIT**：`GET /api/status` 返回的 `quota_per_unit`（各实例可能不同，算错钱先查这里）
- **NEWAPI_REPORT_RECEIVER**：lark-cli 查询（`lark-cli contact +search-user --query 姓名`）

## API 要点

- 所有请求须带两个头：`Authorization: Bearer $TOKEN` 和 `New-Api-User: $USER_ID`，缺后者报"未提供 New-Api-User"
- 用量：`GET /api/data/self?start_timestamp=&end_timestamp=&default_time=hour`，返回「模型 × 小时桶」数组，字段 `model_name` / `token_used` / `count` / `quota`
- 换算：`quota / quota_per_unit = 美元`
- 余额：`GET /api/user/self` 的 `data.quota`（同样换算）
- token 失效表现：`success: false` + Unauthorized 消息，脚本会推送 ⚠️ 告警提醒重新生成（同一错误只推一次）

## 推送降噪

指纹 = `当日:状态:总quota:总调用次数`，存于 `~/.local/state/newapi-usage/last_push`。每小时跑但只在有新用量时推送；跨天自动重置。想强制推一次：删掉该文件再跑。

## 定时任务

### macOS（launchd，每小时整点）

plist 模板在 `assets/com.newapi.usage.plist`，含 `__HOME__` / `__SKILL_DIR__` 两个占位符。安装：

```bash
SKILL_DIR="$HOME/github/my-awesome-skills/skills/newapi-usage"   # 按实际 clone 位置调整
sed -e "s|__HOME__|$HOME|g" -e "s|__SKILL_DIR__|$SKILL_DIR|g" \
  "$SKILL_DIR/assets/com.newapi.usage.plist" \
  > ~/Library/LaunchAgents/com.newapi.usage.plist
launchctl load ~/Library/LaunchAgents/com.newapi.usage.plist
```

排查：

```bash
launchctl list | grep com.newapi.usage      # 已加载？上次退出码？
tail -20 ~/Library/Logs/newapi-usage.log    # 运行日志
tail -20 ~/Library/Logs/newapi-usage.err.log
launchctl start com.newapi.usage            # 手动触发一次
```

### Linux（cron，每小时整点）

```bash
crontab -e
# 加一行（日志追加到用户目录）：
0 * * * * /bin/bash $HOME/github/my-awesome-skills/skills/newapi-usage/scripts/report.sh >> $HOME/.local/state/newapi-usage/cron.log 2>&1
```

脚本内取"今日 0 点"已兼容 BSD date（macOS）与 GNU date（Linux）。

## 已知问题

- lark-cli user token 过期时推送失败，日志会提示；重新授权：`lark-cli auth login`
- launchd/cron 以最小环境运行，脚本内已内置 nvm node 常用路径；lark-cli 装在别处时在 secrets.sh 里 `export LARK_CLI=...`
