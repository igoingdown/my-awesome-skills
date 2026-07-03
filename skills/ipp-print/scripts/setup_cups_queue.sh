#!/bin/bash
# setup_cups_queue.sh — 在 macOS 上为 IPP 网络打印机创建常驻 CUPS 队列（IPP Everywhere）
#
# 用法:
#   setup_cups_queue.sh <printer-ip> [queue-name]
#
#   printer-ip  打印机 IP 地址（必填），也可通过环境变量 PRINTER_IP 提供
#   queue-name  CUPS 队列名（可选，默认 Office_IPP_Printer）
#
# 示例:
#   setup_cups_queue.sh 192.168.1.100
#   setup_cups_queue.sh 192.168.1.100 Office_IPP_Printer
#   PRINTER_IP=192.168.1.100 setup_cups_queue.sh
#
# 说明:
#   - 队列基于 IPP Everywhere（lpadmin -m everywhere）创建，无需厂商驱动。
#   - 若已存在同名队列会先删除再重建，保证 URI 指向最新 IP。
#   - 兼容 macOS 自带 bash 3.2。

set -euo pipefail

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

PRINTER_IP="${1:-${PRINTER_IP:-}}"
QUEUE_NAME="${2:-Office_IPP_Printer}"

if [ -z "$PRINTER_IP" ]; then
    usage
    exit 1
fi

if ! echo "$PRINTER_IP" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "错误: IP 格式不对: \"$PRINTER_IP\"（应形如 192.168.1.100）" >&2
    exit 1
fi

PRINTER_URI="ipp://${PRINTER_IP}/ipp/print"

echo "==> 目标打印机: $PRINTER_URI"
echo "==> 队列名:     $QUEUE_NAME"

# 1. 预检: 631 端口可达性（nc -G 为 macOS 的连接超时秒数; 无 timeout 命令可用）
echo "==> [1/4] 检查打印机 IPP 端口 (631) 可达性 ..."
if ! nc -z -G 3 "$PRINTER_IP" 631 >/dev/null 2>&1; then
    echo "错误: 无法连接 ${PRINTER_IP}:631。" >&2
    echo "  可能原因: 打印机 IP 已变化(DHCP)、打印机关机、或本机没连到打印机所在 Wi-Fi。" >&2
    echo "  排查方法见 references/troubleshooting.md（IP 重发现 / Wi-Fi 切换）。" >&2
    exit 1
fi
echo "    端口 631 可达。"

# 2. 已存在同名队列则先删除
echo "==> [2/4] 清理同名旧队列（如存在）..."
if lpstat -p "$QUEUE_NAME" >/dev/null 2>&1; then
    echo "    发现已存在队列 ${QUEUE_NAME}，删除重建。"
    lpadmin -x "$QUEUE_NAME"
else
    echo "    无同名队列，跳过。"
fi

# 3. 创建 IPP Everywhere 队列
echo "==> [3/4] 创建 CUPS 队列 ..."
lpadmin -p "$QUEUE_NAME" -E -v "$PRINTER_URI" -m everywhere
# 确保队列处于启用/接收任务状态（个别系统上 -E 未完全生效，失败可忽略）
cupsenable "$QUEUE_NAME" 2>/dev/null || true
cupsaccept "$QUEUE_NAME" 2>/dev/null || true

# 4. 验证队列
echo "==> [4/4] 验证队列状态 ..."
if ! lpstat -p "$QUEUE_NAME"; then
    echo "错误: 队列 $QUEUE_NAME 创建后未能通过 lpstat 验证，请检查 CUPS 服务状态。" >&2
    exit 1
fi

echo ""
echo "队列创建成功。打印用法:"
echo "    lp -d $QUEUE_NAME /path/to/file.pdf"
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! 警告: CUPS 本地显示 completed 不代表纸真的打出来了!             !!"
echo "!! 实测: 加密 PDF 经 CUPS 队列打印, 本机报 completed, 打印机侧     !!"
echo "!! 任务实际 aborted、0 页出纸。                                    !!"
echo "!! 重要文件请用 print_pdf.sh 打印(自带打印机侧验证), 或手动用      !!"
echo "!! IPP Get-Job-Attributes 查打印机侧 job-state 与                  !!"
echo "!! job-media-sheets-completed, 方法见 references/troubleshooting.md !!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
