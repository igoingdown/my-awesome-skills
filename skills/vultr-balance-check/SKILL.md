---
name: vultr-balance-check
description: 查询 Vultr 账户余额和当月待扣费用。使用时：用户询问 Vultr 账户余额、待扣费用或账户信息时触发。
---

# Vultr 账户余额检查

## 快速开始

1. 安装依赖：`bash install.sh`
2. 配置密钥：把 Vultr API Key 加进 `~/github/my_dot_files/secrets.sh`（参考 `secrets.example.sh`）
3. 测试运行：`bash vultr_balance_check.sh`

## 功能

- 使用 Vultr API 查询账户余额和当月待扣费用
- 显示格式化结果
- 记录到日志文件（`~/.openclaw/workspace/vultr_balance.log`）
- 可选：通过飞书发送消息

## 环境变量（统一放 secrets.sh，敏感信息不进仓库）

脚本启动时若环境变量未设置，会 source `~/github/my_dot_files/secrets.sh`（可用 `SECRETS_FILE` 改路径）。需包含：

| 变量 | 必填 | 说明 |
|------|------|------|
| `VULTR_API_KEY` | 是 | Vultr API Key |
| `VULTR_WORKSPACE_PATH` | 否 | 日志输出路径，默认 `~/.openclaw/workspace` |
| `FEISHU_RECEIVER_ID` | 否 | 飞书接收者 ID |

完整配置参考 `secrets.example.sh`。

## 获取 API Key

1. 访问：https://my.vultr.com/settings/#settingsapi
2. 点击 "Enable API" 或复制现有 API Key

## 使用示例

```bash
bash vultr_balance_check.sh
```
