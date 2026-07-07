# 火山引擎账户检查 - 配置指南

## 快速开始

1. **安装依赖**
   ```bash
   bash install.sh
   ```

2. **配置密钥**（统一放 secrets.sh，不进仓库）
   ```bash
   # 在 ~/github/my_dot_files/secrets.sh 中加入（参考 secrets.example.sh）：
   export VOLC_ACCESS_KEY="..."
   export VOLC_SECRET_KEY="..."
   ```

3. **获取密钥**
   - 访问：https://console.volcengine.com/iam/keymanage
   - 创建 Access Key（推荐使用主账号密钥）

4. **测试运行**
   ```bash
   source venv/bin/activate
   python volcengine_balance_check.py
   ```

## 环境变量说明

脚本启动时若环境变量未设置，会 source `~/github/my_dot_files/secrets.sh`（可用 `SECRETS_FILE` 改路径）。

| 变量名 | 必填 | 说明 |
|--------|------|------|
| `VOLC_ACCESS_KEY` | 是 | 火山引擎 Access Key |
| `VOLC_SECRET_KEY` | 是 | 火山引擎 Secret Key |
| `VOLC_REGION` | 否 | 区域，默认 `cn-beijing` |
| `VOLC_WORKSPACE_PATH` | 否 | 日志输出路径，默认 `~/.openclaw/workspace` |
| `FEISHU_RECEIVER_ID` | 否 | 飞书接收者 ID，不填则不发送飞书消息 |

## 故障排除

### SDK 导入失败
```bash
source venv/bin/activate
pip install volcengine
```

### API 调用失败
检查 `~/github/my_dot_files/secrets.sh` 中的 Access Key 和 Secret Key 是否正确。
