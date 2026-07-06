---
name: openrouter-balance
description: 查询 OpenRouter 账户余额（总额度、已使用、剩余额度）并通过飞书私聊通知。支持定时执行和手动触发。
---

# OpenRouter Balance Checker

查询 OpenRouter 账户额度并通过飞书通知。

## 功能

- 查询总额度（total_credits）
- 查询已使用额度（total_usage）
- 计算剩余额度（total_credits - total_usage）
- 通过飞书私聊发送富文本卡片通知
- 支持重试机制和错误处理

## 环境变量

在调用此脚本前，需配置以下环境变量：

- `OPENROUTER_API_KEY`: 你的 OpenRouter API Key
- `FEISHU_APP_ID`: 飞书应用 App ID
- `FEISHU_APP_SECRET`: 飞书应用 App Secret
- `FEISHU_RECEIVER_OPEN_ID`: 接收消息用户的 OpenID

## 使用方法

### 通过 Claude Code Skill 调用

如果你使用 Claude Code，可以直接说：

> 帮我查询 OpenRouter 账户余额

或者说：

> 运行 openrouter-balance skill

### 手动执行脚本

```bash
node ~/.agents/skills/openrouter-balance/dist/check.js
```

## 定时执行示例

### 每小时执行（macOS - launchd）

创建 `~/Library/LaunchAgents/com.openrouter.balance.plist`（`__HOME__` 替换为你的实际 $HOME，launchd 不解析环境变量）：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openrouter.balance</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/node</string>
        <string>__HOME__/.agents/skills/openrouter-balance/dist/check.js</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

加载配置：
```bash
launchctl load ~/Library/LaunchAgents/com.openrouter.balance.plist
```

### 每天执行（Linux - cron）

编辑 crontab：`crontab -e`
```
0 9 * * * cd $HOME/.agents/skills/openrouter-balance && node dist/check.js
```

## 输出示例

飞书消息：
```
OpenRouter 账户报告
总额度: $10.00
已使用: $3.50
剩余额度: $6.50
```
