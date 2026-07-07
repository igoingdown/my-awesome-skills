#!/usr/bin/env python3
"""
火山引擎账户余额检查脚本
使用火山引擎官方 SDK 查询账户余额和消费信息

依赖安装：
    bash install.sh

凭证配置（统一走 secrets.sh，不进任何版本库）：
    在 ~/github/my_dot_files/secrets.sh 中 export VOLC_ACCESS_KEY / VOLC_SECRET_KEY
    可用环境变量 SECRETS_FILE 改路径
"""

import sys
import os
import json
import subprocess
from datetime import datetime

# ==================== 凭证：统一走 secrets.sh ====================
def load_secrets():
    """环境变量已设置则直接用；否则用 bash source secrets.sh 后取回所需变量"""
    if os.environ.get('VOLC_ACCESS_KEY') and os.environ.get('VOLC_SECRET_KEY'):
        return
    secrets = os.environ.get('SECRETS_FILE') or os.path.expanduser(
        '~/github/my_dot_files/secrets.sh')
    if not os.path.exists(secrets):
        return
    wanted = ['VOLC_ACCESS_KEY', 'VOLC_SECRET_KEY', 'VOLC_REGION',
              'VOLC_WORKSPACE_PATH', 'FEISHU_RECEIVER_ID']
    printer = ''.join(f'printf "%s\\0" "${{{k}:-}}"; ' for k in wanted)
    result = subprocess.run(
        ['bash', '-c', f'source "$1" >/dev/null 2>&1; {printer}', '_', secrets],
        capture_output=True, text=True)
    if result.returncode != 0:
        return
    values = result.stdout.split('\0')
    for key, value in zip(wanted, values):
        if value and not os.environ.get(key):
            os.environ[key] = value

load_secrets()
# =================================================================

# 检查环境变量
VOLC_ACCESS_KEY = os.environ.get('VOLC_ACCESS_KEY')
VOLC_SECRET_KEY = os.environ.get('VOLC_SECRET_KEY')
VOLC_REGION = os.environ.get('VOLC_REGION', 'cn-beijing')
WORKSPACE = os.path.expanduser(os.environ.get('VOLC_WORKSPACE_PATH', '~/.openclaw/workspace'))
FEISHU_RECEIVER_ID = os.environ.get('FEISHU_RECEIVER_ID')

if not VOLC_ACCESS_KEY or not VOLC_SECRET_KEY:
    secrets = os.environ.get('SECRETS_FILE') or os.path.expanduser(
        '~/github/my_dot_files/secrets.sh')
    print("❌ Error: VOLC_ACCESS_KEY and VOLC_SECRET_KEY must be set")
    print(f"请在 {secrets} 中加入：export VOLC_ACCESS_KEY=... / export VOLC_SECRET_KEY=...")
    sys.exit(1)

# 添加 venv 中的包路径
script_dir = os.path.dirname(os.path.abspath(__file__))
venv_site_packages = os.path.join(script_dir, 'venv', 'lib', 'python*', 'site-packages')

# 通配符匹配 Python 版本
import glob
matching_paths = glob.glob(venv_site_packages)
if matching_paths:
    sys.path.insert(0, matching_paths[0])
else:
    # 备用：检查系统安装的包
    sys.path.insert(0, os.path.expanduser("~/Library/Python/3.14/lib/python/site-packages"))

try:
    from volcengine.billing.BillingService import BillingService
except ImportError as e:
    print(f"❌ Error: 无法导入火山引擎 SDK: {e}")
    print("请运行: bash install.sh")
    sys.exit(1)


def get_account_info():
    """获取火山引擎账户信息"""
    client = BillingService()
    client.set_ak(VOLC_ACCESS_KEY)
    client.set_sk(VOLC_SECRET_KEY)

    now = datetime.now()
    period = f"{now.year}-{now.month:02d}"

    params = {
        "BillPeriod": period,
        "Limit": 100,
        "Offset": 0,
    }
    body = {}

    try:
        resp = client.list_bill_overview_by_prod(params, body)
        return resp
    except Exception as e:
        print(f"API 调用失败: {e}")
        import traceback
        traceback.print_exc()
        return None


def parse_response(resp):
    """解析 API 响应，提取关键信息"""
    if not resp:
        return {
            "monthly_cost": "获取失败",
            "total_paid": "获取失败",
            "total_unpaid": "获取失败",
            "bill_details": [],
            "raw_response": "无响应"
        }

    result = resp.get("Result", {})
    bill_list = result.get("List", [])

    total_payable = 0.0
    total_paid = 0.0
    total_unpaid = 0.0
    bill_details = []

    for bill in bill_list:
        product = bill.get("ProductZh", bill.get("Product", "未知"))
        payable = float(bill.get("PayableAmount", 0))
        paid = float(bill.get("PaidAmount", 0))
        unpaid = float(bill.get("UnpaidAmount", 0))

        total_payable += payable
        total_paid += paid
        total_unpaid += unpaid

        bill_details.append({
            "product": product,
            "payable": payable,
            "paid": paid,
            "unpaid": unpaid
        })

    return {
        "monthly_cost": f"{total_payable:.2f}",
        "total_paid": f"{total_paid:.2f}",
        "total_unpaid": f"{total_unpaid:.2f}",
        "bill_details": bill_details,
        "raw_response": json.dumps(resp, indent=2, ensure_ascii=False)
    }


def get_openclaw_path():
    """动态获取 openclaw 命令路径"""
    result = subprocess.run(['which', 'openclaw'], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip()
    return None


def get_lark_cli_path():
    """动态获取 lark-cli 命令路径（可用环境变量 LARK_CLI 覆盖）"""
    lark = os.environ.get('LARK_CLI')
    if lark and os.path.exists(lark):
        return lark
    result = subprocess.run(['which', 'lark-cli'], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip()
    return None


def main():
    """主函数"""
    print("=" * 80)
    print("火山引擎账户余额检查")
    print("=" * 80)

    print(f"\n📡 正在查询火山引擎账户信息（区域: {VOLC_REGION}）...")
    resp = get_account_info()

    data = parse_response(resp)

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # 构建账单明细
    details_text = ""
    for bill in data['bill_details']:
        details_text += f"  • {bill['product']}\n"
        details_text += f"    应付: {bill['payable']:.2f} 元 | 已付: {bill['paid']:.2f} 元 | 未付: {bill['unpaid']:.2f} 元\n"

    message = f"""⏰ 火山引擎账户状态更新（{now}）

📊 本月消费汇总:
  • 总应付: {data['monthly_cost']} 元
  • 已支付: {data['total_paid']} 元
  • 待支付: {data['total_unpaid']} 元

📋 消费明细:
{details_text}
---
⚠️  说明：此 API 返回账单明细，不包含账户余额信息。
"""

    print("\n" + message)

    # 记录到日志文件
    os.makedirs(WORKSPACE, exist_ok=True)
    log_file = os.path.join(WORKSPACE, "volcengine_balance.log")
    try:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(message + "\n" + "=" * 80 + "\n")
        print(f"\n✅ 已记录到日志: {log_file}")
    except Exception as e:
        print(f"\n⚠️  记录日志失败: {e}")

    # 通过飞书发送消息：优先 openclaw，缺失则回退 lark-cli
    openclaw_path = get_openclaw_path()
    lark_path = get_lark_cli_path()
    if openclaw_path and FEISHU_RECEIVER_ID:
        print("\n📤 正在通过飞书发送消息（openclaw）...")
        try:
            result = subprocess.run([
                openclaw_path,
                "message", "send",
                "--channel", "feishu",
                "--target", FEISHU_RECEIVER_ID,
                "--message", message
            ], capture_output=True, text=True, timeout=30)

            if result.returncode == 0:
                print("✅ 飞书消息发送成功！")
            else:
                print(f"⚠️  飞书消息发送失败: {result.stderr}")
        except Exception as e:
            print(f"⚠️  发送飞书消息时出错: {e}")
    elif lark_path and FEISHU_RECEIVER_ID:
        print("\n📤 正在通过飞书发送消息（lark-cli）...")
        try:
            result = subprocess.run([
                lark_path,
                "im", "+messages-send",
                "--user-id", FEISHU_RECEIVER_ID,
                "--as", "user",
                "--text", message
            ], capture_output=True, text=True, timeout=30)

            if result.returncode == 0:
                print("✅ 飞书消息发送成功！")
            else:
                print(f"⚠️  飞书消息发送失败（lark-cli token 可能需重新授权：lark-cli auth login）: {result.stderr}")
        except Exception as e:
            print(f"⚠️  发送飞书消息时出错: {e}")
    elif not FEISHU_RECEIVER_ID:
        print("\n⚠️  FEISHU_RECEIVER_ID 未配置，跳过飞书消息发送")
    else:
        print("\n⚠️  未找到 openclaw / lark-cli 命令，跳过飞书消息发送")

    return 0


if __name__ == "__main__":
    sys.exit(main())
