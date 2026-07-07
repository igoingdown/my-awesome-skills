---
name: volcengine-balance-check
description: 查询火山引擎账户消费信息。使用时：用户询问火山引擎账户消费、余额或账单信息时触发。
---

# 火山引擎账户查询

## 快速开始

1. 安装依赖：`bash install.sh`
2. 配置密钥：把火山引擎 AK/SK 加进 `~/github/my_dot_files/secrets.sh`（参考 `secrets.example.sh`）
3. 测试运行：`source venv/bin/activate && python volcengine_balance_check.py`

## 功能

- 使用火山引擎官方 SDK 查询账单信息
- 提取本月消费总金额、已支付和待支付金额
- 显示消费明细（按产品分类）
- 记录到日志文件（`~/.openclaw/workspace/volcengine_balance.log`）
- 可选：通过飞书发送消息

## 环境变量（统一放 secrets.sh，敏感信息不进仓库）

脚本启动时若环境变量未设置，会 source `~/github/my_dot_files/secrets.sh`（可用 `SECRETS_FILE` 改路径）。需包含：

| 变量 | 必填 | 说明 |
|------|------|------|
| `VOLC_ACCESS_KEY` | 是 | 火山引擎 Access Key |
| `VOLC_SECRET_KEY` | 是 | 火山引擎 Secret Key |
| `VOLC_REGION` | 否 | 区域，默认 `cn-beijing` |
| `FEISHU_RECEIVER_ID` | 否 | 飞书接收者 ID |

完整配置参考 `secrets.example.sh`。

## 使用示例

```bash
source venv/bin/activate
python volcengine_balance_check.py
```
