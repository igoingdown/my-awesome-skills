#!/bin/bash
#
# install.sh — ipp-print skill 依赖体检与安装引导
#
# 用法:
#   ./install.sh          # 检查所有依赖，缺什么提示怎么装
#   ./install.sh --fix    # 检查并自动安装缺失的可选依赖（需要 Homebrew）
#
# 说明:
#   核心工具全部为 macOS 自带，本脚本只做存在性验证；
#   唯一第三方依赖 poppler（pdfinfo/pdftocairo）是可选的——
#   只在需要预检/重写加密 PDF 时用到。

set -euo pipefail

FIX=0
if [ "${1:-}" = "--fix" ]; then
    FIX=1
elif [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
elif [ -n "${1:-}" ]; then
    echo "错误: 未知参数 $1（支持 --fix / --help）" >&2
    exit 1
fi

FAIL=0
WARN=0

check_required() {
    # $1: 命令名  $2: 用途说明
    if command -v "$1" >/dev/null 2>&1; then
        printf "  [OK]   %-14s %s\n" "$1" "$2"
    else
        printf "  [缺失] %-14s %s\n" "$1" "$2"
        FAIL=1
    fi
}

echo "==> 检查核心依赖（macOS 自带，缺失说明系统环境异常）..."
check_required ipptool   "IPP 打印与验证（print_pdf.sh 核心）"
check_required nc        "端口探测（discover/check）"
check_required dns-sd    "Bonjour 打印机发现"
check_required lpadmin   "CUPS 队列管理（setup_cups_queue.sh）"
check_required lpstat    "CUPS 队列状态查询"
check_required lp        "CUPS 打印提交"
check_required route     "默认路由/网段推导"
check_required ifconfig  "本机 IP 获取"

echo ""
echo "==> 检查可选依赖（poppler，用于加密 PDF 预检与重写）..."
if command -v pdfinfo >/dev/null 2>&1 && command -v pdftocairo >/dev/null 2>&1; then
    printf "  [OK]   %-14s %s\n" "poppler" "pdfinfo + pdftocairo 均可用"
else
    WARN=1
    printf "  [缺失] %-14s %s\n" "poppler" "pdfinfo/pdftocairo 不全"
    if [ "$FIX" -eq 1 ]; then
        if command -v brew >/dev/null 2>&1; then
            echo "         --fix 已指定，正在执行: brew install poppler ..."
            brew install poppler
            WARN=0
        else
            echo "         无法自动安装: 未检测到 Homebrew（https://brew.sh）。" >&2
        fi
    else
        echo "         安装命令: brew install poppler"
        echo "         （不装也能打印未加密 PDF，但加密 PDF 会被打印机拒收且无法自动重写）"
    fi
fi

echo ""
echo "==> 检查脚本可执行位 ..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)/scripts"
for f in "$SCRIPT_DIR"/*.sh; do
    if [ -x "$f" ]; then
        printf "  [OK]   %s\n" "$(basename "$f")"
    else
        printf "  [修复] %s 缺可执行位，已 chmod +x\n" "$(basename "$f")"
        chmod +x "$f"
    fi
done

echo ""
if [ "$FAIL" -eq 1 ]; then
    echo "结论: 核心依赖缺失（上方 [缺失] 项）。这些工具应为 macOS 自带，"
    echo "      请确认运行环境是 macOS；Linux 环境的改造点见 README.md 兼容性一节。"
    exit 1
elif [ "$WARN" -eq 1 ]; then
    echo "结论: 核心依赖齐全，可以打印。建议安装 poppler 以支持加密 PDF（brew install poppler）。"
    exit 0
fi
echo "结论: 全部依赖就绪。下一步: ./scripts/discover_printer.sh 发现打印机。"
exit 0
