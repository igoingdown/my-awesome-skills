#!/bin/bash
#
# check_printer.sh — 检查一台网络打印机的端口开放性与 IPP 健康状态
#
# 动作：
#   1. nc 探测 631(IPP) / 9100(JetDirect) / 515(LPD) 端口；
#   2. 用 macOS 自带 ipptool 执行 Get-Printer-Attributes，友好展示
#      型号、状态、状态原因、支持的文档格式、默认纸张、PDF 版本支持；
#   3. printer-state-reasons 含 jam/empty 等故障关键字（或 stopped/不支持 PDF）
#      时告警，并以退出码 2 退出，供自动化流程判断能否打印。
#
# 兼容 macOS 自带 bash 3.2，依赖（nc/ipptool）均为系统自带。

set -euo pipefail

usage() {
    cat <<'EOF'
用法: check_printer.sh <printer-ip>
      PRINTER_IP=192.168.1.100 check_printer.sh

参数:
  printer-ip   打印机的 IPv4 地址，例如 192.168.1.100
               （也可通过环境变量 PRINTER_IP 提供）

示例:
  ./check_printer.sh 192.168.1.100
  PRINTER_IP=192.168.1.100 ./check_printer.sh

说明:
  IPP 端点固定为 ipp://<IP>/ipp/print（端口 631）。
  若不知道打印机 IP，先跑同目录下的 discover_printer.sh。

退出码:
  0  打印机可达且状态健康，可以发起打印
  1  参数错误 / 631 不通 / IPP 属性拉取失败
  2  打印机可达但存在告警（stopped/卡纸/缺粉/缺纸/不支持 PDF 等），打印前需先处理
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 1 ]; then
    echo "错误: 参数过多" >&2
    usage >&2
    exit 1
fi

IP="${1:-${PRINTER_IP:-}}"
if [ -z "$IP" ]; then
    usage >&2
    exit 1
fi
if ! echo "$IP" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "错误: IP 格式不对: \"$IP\"（应形如 192.168.1.100）" >&2
    exit 1
fi

URI="ipp://$IP/ipp/print"

# ---------- 1. 端口探测 ----------
echo "==> 探测 $IP 的常见打印端口（超时 2 秒/端口）..."
IPP_OPEN=no
port_label() {
    case "$1" in
        631)  echo "631 (IPP)" ;;
        9100) echo "9100 (JetDirect/RAW)" ;;
        515)  echo "515 (LPD)" ;;
    esac
}
for port in 631 9100 515; do
    if nc -z -G 2 "$IP" "$port" >/dev/null 2>&1; then
        printf "    %-22s 开放\n" "$(port_label "$port")"
        if [ "$port" = "631" ]; then
            IPP_OPEN=yes
        fi
    else
        printf "    %-22s 不通\n" "$(port_label "$port")"
    fi
done

if [ "$IPP_OPEN" != "yes" ]; then
    echo "" >&2
    echo "错误: 631 端口不通，无法走 IPP 打印。可能原因:" >&2
    echo "  1. Mac 和打印机不在同一局域网（最常见——检查是否连对了 Wi-Fi）；" >&2
    echo "  2. IP 已因 DHCP 变化失效（用 discover_printer.sh 重新发现）；" >&2
    echo "  3. 这台设备不支持 IPP（若仅 9100 开放，只能走 JetDirect/RAW，" >&2
    echo "     不在本 skill 的 IPP 流程覆盖范围内）。" >&2
    exit 1
fi

# ---------- 2. Get-Printer-Attributes ----------
echo ""
echo "==> 通过 IPP 拉取打印机属性: $URI ..."
ATTRS_OUT="$(mktemp /tmp/ipp_check.XXXXXX)"
trap 'rm -f "$ATTRS_OUT"' EXIT

# get-printer-attributes.test 是 ipptool 自带的标准测试文件
# （位于 /usr/share/cups/ipptool/，ipptool 会自动找到它）
if ! ipptool -tv "$URI" get-printer-attributes.test > "$ATTRS_OUT" 2>&1; then
    echo "错误: Get-Printer-Attributes 失败。ipptool 输出如下:" >&2
    cat "$ATTRS_OUT" >&2
    echo "" >&2
    echo "631 端口虽开放但 IPP 请求被拒，可能端点路径不是 /ipp/print，" >&2
    echo "或打印机的 IPP 服务异常。可尝试打开打印机 Web 管理页确认。" >&2
    exit 1
fi

# 从 ipptool -tv 的详细输出中提取指定属性行。
# 属性行形如: "        printer-state (enum) = idle"
get_attr() {
    # $1: 属性名; 输出 "= " 之后的值（找不到则输出空）
    grep -E "^ *$1 \(" "$ATTRS_OUT" | head -n 1 | sed 's/^[^=]*= //' || true
}

MAKE_MODEL="$(get_attr 'printer-make-and-model')"
STATE="$(get_attr 'printer-state')"
STATE_REASONS="$(get_attr 'printer-state-reasons')"
DOC_FORMATS="$(get_attr 'document-format-supported')"
MEDIA_DEFAULT="$(get_attr 'media-default')"
PDF_VERSIONS="$(get_attr 'pdf-versions-supported')"

echo ""
echo "================ 打印机信息 ================"
printf "  %-24s %s\n" "型号:" "${MAKE_MODEL:-<未上报>}"
printf "  %-24s %s\n" "状态 (printer-state):" "${STATE:-<未上报>}"
printf "  %-24s %s\n" "状态原因:" "${STATE_REASONS:-<未上报>}"
printf "  %-24s %s\n" "默认纸张:" "${MEDIA_DEFAULT:-<未上报>}"
printf "  %-24s %s\n" "PDF 版本支持:" "${PDF_VERSIONS:-<未上报，多数打印机不报此属性>}"
echo ""
echo "  支持的文档格式 (document-format-supported):"
if [ -n "$DOC_FORMATS" ]; then
    echo "$DOC_FORMATS" | tr ',' '\n' | sed 's/^ *//' | sed 's/^/    - /'
else
    echo "    <未上报>"
fi
echo "============================================"
echo ""

# ---------- 3. 健康判读 ----------
WARN=no

case "$STATE" in
    idle)
        echo "[OK] 打印机空闲 (idle)，可以接收任务。"
        ;;
    processing)
        echo "[提示] 打印机正在处理任务 (processing)，新任务会排队。"
        ;;
    stopped)
        echo "[告警] 打印机处于 stopped 状态，通常有故障（看状态原因）。"
        WARN=yes
        ;;
    *)
        echo "[提示] printer-state 值异常或未上报: \"${STATE:-空}\"。"
        ;;
esac

if [ -n "$STATE_REASONS" ] && [ "$STATE_REASONS" != "none" ]; then
    if echo "$STATE_REASONS" | grep -Eiq 'jam|empty|low|error|missing|failure'; then
        echo "[告警] printer-state-reasons 含故障关键字: $STATE_REASONS"
        echo "       常见含义: media-jam=卡纸  toner-empty=缺粉  media-empty=缺纸"
        WARN=yes
    else
        echo "[提示] printer-state-reasons 非 none: ${STATE_REASONS}（请留意）"
    fi
else
    echo "[OK] printer-state-reasons = none，打印机健康。"
fi

if echo "$DOC_FORMATS" | grep -q 'application/pdf'; then
    echo "[OK] 支持直接接收 application/pdf。"
    echo "     注意: 即便如此，加密 PDF 仍会被拒收（job-state=aborted），"
    echo "     发送前先用 pdfinfo 预检，必要时用 pdftocairo -pdf 重写。"
else
    echo "[告警] document-format-supported 里没有 application/pdf，"
    echo "       直接发 PDF 会失败，需要先转换格式。"
    WARN=yes
fi

echo ""
if [ "$WARN" = "yes" ]; then
    echo "结论: 打印机可达，但存在上述告警项，打印前请先处理。"
    exit 2
fi
echo "结论: 打印机可达且状态健康，可以发起打印。"
exit 0
