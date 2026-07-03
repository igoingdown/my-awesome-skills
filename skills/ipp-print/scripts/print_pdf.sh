#!/bin/bash
#
# print_pdf.sh — 通过 IPP 协议向网络打印机打印 PDF，并在打印机侧做真实验证（确认实际出纸）。
#
# 用法：
#   print_pdf.sh <printer-ip> <pdf-file> [--force-rewrite]
#   PRINTER_IP=192.168.1.100 print_pdf.sh <pdf-file> [--force-rewrite]
#
# 流水线：
#   1. 参数与文件校验（file 命令确认是 PDF）
#   2. pdfinfo 预检加密；加密或 --force-rewrite 时用 pdftocairo -pdf 重写为干净的未加密 PDF
#   3. ipptool Print-Job 发送，解析 job-id
#   4. 轮询打印机侧 Get-Job-Attributes（每 5 秒一次，最多 24 轮）
#   5. 只有 job-state=completed 且 job-media-sheets-completed>0 才判定成功
#      （注意：本机 CUPS 报 completed 不可信，必须查打印机侧！）
#      若 aborted + document-format-error 且尚未重写过，自动重写后重试一次
#
# 实测于 macOS + Canon iR-ADV C5250；对支持 IPP Everywhere 的网络打印机通用。
# 依赖：ipptool（macOS 自带）；pdfinfo/pdftocairo 来自 Homebrew poppler（brew install poppler）。

set -euo pipefail

# 轮询间隔（秒）与最大轮数，可用同名环境变量覆盖（默认 5s x 24 轮 = 120s）
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_ROUNDS="${MAX_ROUNDS:-24}"

usage() {
    cat <<'USAGE'
用法：
  print_pdf.sh <printer-ip> <pdf-file> [--force-rewrite]

也可通过环境变量提供打印机 IP：
  PRINTER_IP=192.168.1.100 print_pdf.sh <pdf-file> [--force-rewrite]

参数：
  <printer-ip>      打印机 IP（IPP 端点固定为 ipp://<IP>/ipp/print）
  <pdf-file>        要打印的 PDF 文件路径
  --force-rewrite   跳过加密预检，强制先用 pdftocairo 重写 PDF 再发送
                    （适用于内容流不规范、打印机报 document-format-error 的 PDF）

示例：
  print_pdf.sh 192.168.1.100 /path/to/file.pdf
  print_pdf.sh 192.168.1.100 ~/Documents/example.pdf --force-rewrite

说明：
  - 脚本会轮询打印机侧任务状态，只有 job-state=completed 且实际出纸页数 > 0 才算成功。
  - 加密 PDF 会被打印机拒收（job-state=aborted / document-format-error），脚本会自动
    用 pdftocairo 解密重写后重试（依赖 Homebrew poppler：brew install poppler）。
  - 打印机整机状态（卡纸/缺纸/缺粉等）可用同目录的 check_printer.sh 查看。
USAGE
}

# ---------- 依赖检查 ----------
if ! command -v ipptool >/dev/null 2>&1; then
    echo "错误：找不到 ipptool（macOS 应自带，通常位于 /usr/bin/ipptool），无法继续。" >&2
    exit 1
fi

HAVE_PDFINFO=0
HAVE_PDFTOCAIRO=0
command -v pdfinfo >/dev/null 2>&1 && HAVE_PDFINFO=1
command -v pdftocairo >/dev/null 2>&1 && HAVE_PDFTOCAIRO=1

# ---------- 参数解析 ----------
FORCE_REWRITE=0
ARG1=""
ARG2=""
NPOS=0
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        --force-rewrite)
            FORCE_REWRITE=1
            ;;
        -*)
            echo "错误：未知选项 $arg" >&2
            usage >&2
            exit 1
            ;;
        *)
            NPOS=$((NPOS + 1))
            if [ "$NPOS" -eq 1 ]; then
                ARG1="$arg"
            elif [ "$NPOS" -eq 2 ]; then
                ARG2="$arg"
            else
                echo "错误：多余的位置参数 $arg" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

if [ "$NPOS" -eq 2 ]; then
    PRINTER_IP="$ARG1"
    PDF_FILE="$ARG2"
elif [ "$NPOS" -eq 1 ] && [ -n "${PRINTER_IP:-}" ]; then
    PDF_FILE="$ARG1"
else
    usage >&2
    exit 1
fi

PRINTER_URI="ipp://${PRINTER_IP}/ipp/print"

# ---------- 文件校验 ----------
if [ ! -f "$PDF_FILE" ]; then
    echo "错误：文件不存在：$PDF_FILE" >&2
    exit 1
fi
if ! file -b "$PDF_FILE" | grep -qi 'PDF'; then
    echo "错误：$PDF_FILE 不是 PDF 文件（file 识别为：$(file -b "$PDF_FILE")）" >&2
    exit 1
fi

# ---------- 临时目录与清理 ----------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ipp_print.XXXXXX")"
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

REWRITTEN_PDF="$WORKDIR/rewritten.pdf"
SEND_OUT="$WORKDIR/send_output.txt"
POLL_OUT="$WORKDIR/poll_output.txt"
POLL_TEST="$WORKDIR/get_job_attributes.test"

# 生成 Get-Job-Attributes 测试文件（$uri/$jobid 是 ipptool 变量，不能被 shell 展开）
cat > "$POLL_TEST" <<'EOF'
{
  NAME "Get job attributes"
  OPERATION Get-Job-Attributes
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR naturalLanguage attributes-natural-language en
  ATTR uri printer-uri $uri
  ATTR integer job-id $jobid
  DISPLAY job-state
  DISPLAY job-state-reasons
  DISPLAY job-impressions-completed
  DISPLAY job-media-sheets-completed
}
EOF

# ---------- 工具函数 ----------

# pdftocairo 重写：解密 + 规范化内容流，产物为干净的未加密 PDF 1.7
rewrite_pdf() {
    src="$1"
    if [ "$HAVE_PDFTOCAIRO" -ne 1 ]; then
        echo "错误：需要 pdftocairo 重写 PDF，但未安装。请先执行：brew install poppler" >&2
        exit 1
    fi
    echo "==> 正在用 pdftocairo 解密/重写 PDF：$src"
    echo "    （pdftocairo 的 stderr 出现若干 'Syntax Error' 行是正常的，只要退出码为 0 即可）"
    if ! pdftocairo -pdf "$src" "$REWRITTEN_PDF"; then
        echo "错误：pdftocairo 重写失败（退出码非 0），无法继续。" >&2
        exit 1
    fi
    if [ "$HAVE_PDFINFO" -eq 1 ]; then
        if ! pdfinfo "$REWRITTEN_PDF" >/dev/null 2>&1; then
            echo "错误：重写产物无法被 pdfinfo 读取，重写失败。" >&2
            exit 1
        fi
    fi
    echo "==> 重写完成，后续将发送重写后的文件。"
}

# 发送 Print-Job，成功时设置全局变量 JOB_ID
send_job() {
    send_file="$1"
    echo "==> 发送打印任务：$send_file -> $PRINTER_URI"
    # ipptool 测试失败时退出码非 0，先捕获输出再自行判断
    ipptool -tv -f "$send_file" "$PRINTER_URI" print-job.test >"$SEND_OUT" 2>&1 || true
    if ! grep -q 'status-code = successful-ok' "$SEND_OUT"; then
        echo "错误：Print-Job 未返回 successful-ok。ipptool 原始输出：" >&2
        cat "$SEND_OUT" >&2
        echo "" >&2
        echo "排查建议：" >&2
        echo "  - 确认 Mac 与打印机在同一局域网（连错 Wi-Fi 是最常见原因）" >&2
        echo "  - 用同目录 check_printer.sh $PRINTER_IP 查看打印机整机状态" >&2
        echo "  - 打印机 IP 可能因 DHCP 变化，可重新扫描网段确认" >&2
        exit 1
    fi
    JOB_ID="$(sed -n 's/.*job-id (integer) = \([0-9][0-9]*\).*/\1/p' "$SEND_OUT" | head -n 1)"
    if [ -z "$JOB_ID" ]; then
        echo "错误：Print-Job 返回成功但未解析到 job-id。ipptool 原始输出：" >&2
        cat "$SEND_OUT" >&2
        exit 1
    fi
    echo "==> 任务已提交，job-id = $JOB_ID"
}

# 把 ipptool 输出的 job-state（可能是枚举名或数字）归一化为状态名
normalize_state() {
    raw="$1"
    case "$raw" in
        *completed*|9)          echo "completed" ;;
        *aborted*|8)            echo "aborted" ;;
        *canceled*|7)           echo "canceled" ;;
        *processing-stopped*|6) echo "processing-stopped" ;;
        *processing*|5)         echo "processing" ;;
        *pending-held*|4)       echo "pending-held" ;;
        *pending*|3)            echo "pending" ;;
        *)                      echo "$raw" ;;
    esac
}

# 轮询打印机侧任务状态；结束后设置全局变量 JOB_STATE / JOB_REASONS / SHEETS / IMPRESSIONS
poll_job() {
    JOB_STATE=""
    JOB_REASONS=""
    SHEETS=""
    IMPRESSIONS=""
    LAST_JOB_STATE=""
    round=1
    echo "==> 轮询打印机侧任务状态（每 ${POLL_INTERVAL}s 一次，最多 ${MAX_ROUNDS} 轮）..."
    while [ "$round" -le "$MAX_ROUNDS" ]; do
        ipptool -tv -d "jobid=$JOB_ID" "$PRINTER_URI" "$POLL_TEST" >"$POLL_OUT" 2>&1 || true
        state_raw="$(sed -n 's/.*job-state (enum) = \(.*\)/\1/p' "$POLL_OUT" | head -n 1)"
        JOB_REASONS="$(sed -n 's/.*job-state-reasons ([^)]*keyword) = \(.*\)/\1/p' "$POLL_OUT" | head -n 1)"
        SHEETS="$(sed -n 's/.*job-media-sheets-completed (integer) = \([0-9][0-9]*\).*/\1/p' "$POLL_OUT" | head -n 1)"
        IMPRESSIONS="$(sed -n 's/.*job-impressions-completed (integer) = \([0-9][0-9]*\).*/\1/p' "$POLL_OUT" | head -n 1)"
        JOB_STATE="$(normalize_state "$state_raw")"
        echo "    [第 ${round}/${MAX_ROUNDS} 轮] job-state=${JOB_STATE:-未知} reasons=${JOB_REASONS:-无} sheets=${SHEETS:-?} impressions=${IMPRESSIONS:-?}"
        case "$JOB_STATE" in
            completed|aborted|canceled)
                return 0
                ;;
        esac
        round=$((round + 1))
        if [ "$round" -le "$MAX_ROUNDS" ]; then
            sleep "$POLL_INTERVAL"
        fi
    done
    LAST_JOB_STATE="$JOB_STATE"
    JOB_STATE="timeout"
    return 0
}

# 取消打印机侧任务（用于超时后清理卡住的任务，避免它占住打印队列）
cancel_job() {
    cat > "$WORKDIR/cancel_job.test" <<'EOF'
{
  NAME "Cancel job"
  OPERATION Cancel-Job
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR naturalLanguage attributes-natural-language en
  ATTR uri printer-uri $uri
  ATTR integer job-id $jobid
  ATTR name requesting-user-name admin
}
EOF
    if ipptool -tv -d "jobid=$JOB_ID" "$PRINTER_URI" "$WORKDIR/cancel_job.test" 2>&1 | grep -q 'status-code = successful-ok'; then
        echo "==> 已取消卡住的任务 job-id=${JOB_ID}（避免它阻塞打印机队列）。"
        return 0
    fi
    # Cancel-Job 返回 not-possible 通常表示任务已进入终态（如已被打印机自行取消），复查确认
    ipptool -tv -d "jobid=$JOB_ID" "$PRINTER_URI" "$POLL_TEST" >"$POLL_OUT" 2>&1 || true
    recheck_state="$(normalize_state "$(sed -n 's/.*job-state (enum) = \(.*\)/\1/p' "$POLL_OUT" | head -n 1)")"
    case "$recheck_state" in
        canceled|completed|aborted)
            echo "==> 任务 job-id=${JOB_ID} 已处于终态（${recheck_state}），无需取消。"
            ;;
        *)
            echo "警告：取消任务 job-id=${JOB_ID} 失败（当前状态：${recheck_state:-未知}），它可能仍占着打印机队列，" >&2
            echo "      必要时到打印机面板上手动删除该任务。" >&2
            ;;
    esac
}

fail_with_details() {
    echo "" >&2
    echo "❌ 打印失败。打印机侧任务终态：job-state=${JOB_STATE:-未知} job-state-reasons=${JOB_REASONS:-无}" >&2
    echo "" >&2
    echo "最后一次 Get-Job-Attributes 原始输出：" >&2
    cat "$POLL_OUT" >&2
    echo "" >&2
    echo "排查建议：" >&2
    echo "  - 用同目录 check_printer.sh $PRINTER_IP 查看整机状态" >&2
    echo "    （printer-state-reasons 出现 media-jam/toner-empty/media-empty 等即为硬件故障）" >&2
    echo "  - 若 reasons 为 document-format-error：PDF 加密或内容流不规范，" >&2
    echo "    可用 --force-rewrite 强制先重写（依赖 brew install poppler）" >&2
    echo "  - 若一直卡在 processing/job-transforming 直至超时：打印机可能正忙或已挂起" >&2
    echo "  - 若一直卡在 processing-stopped 且 reasons=none：实测常见原因是 PDF 纸张尺寸" >&2
    echo "    与打印机纸盒不匹配（如 Letter 尺寸发给只装了 A4 纸的打印机），打印机在面板上" >&2
    echo "    静默等待人工确认。用 --force-rewrite 配合 pdftocairo 之外，更直接的办法是" >&2
    echo "    重新生成 A4 尺寸的 PDF，或到打印机面板上确认换纸提示。" >&2
    echo "  - 注意：本机 CUPS 队列报 completed 不可信，必须以打印机侧状态为准" >&2
    exit 1
}

# ---------- 加密预检 ----------
SEND_FILE="$PDF_FILE"
HAS_REWRITTEN=0

if [ "$FORCE_REWRITE" -eq 1 ]; then
    echo "==> 用户指定 --force-rewrite，跳过预检直接重写。"
    rewrite_pdf "$PDF_FILE"
    SEND_FILE="$REWRITTEN_PDF"
    HAS_REWRITTEN=1
elif [ "$HAVE_PDFINFO" -eq 1 ]; then
    echo "==> 预检：pdfinfo 检查 PDF 是否加密..."
    ENCRYPTED_LINE="$(pdfinfo "$PDF_FILE" 2>/dev/null | grep '^Encrypted:' || true)"
    if echo "$ENCRYPTED_LINE" | grep -qi 'yes'; then
        echo "==> 检测到加密 PDF（打印机会拒收，即使加密策略允许打印），正在解密重写..."
        rewrite_pdf "$PDF_FILE"
        SEND_FILE="$REWRITTEN_PDF"
        HAS_REWRITTEN=1
    else
        echo "==> 预检通过：PDF 未加密。"
    fi
else
    echo "警告：未安装 pdfinfo，无法预检 PDF 是否加密，将直接发送原文件。" >&2
    echo "      若打印机拒收（document-format-error），需要 poppler 才能自动重写重试：" >&2
    echo "      brew install poppler" >&2
fi

# ---------- 发送 + 轮询 + 判定（document-format-error 时最多自动重写重试 1 次） ----------
while :; do
    send_job "$SEND_FILE"
    poll_job

    if [ "$JOB_STATE" = "completed" ] && [ -n "$SHEETS" ] && [ "$SHEETS" -gt 0 ]; then
        echo ""
        echo "✅ 打印成功，实际出纸 ${SHEETS} 页（job-id=${JOB_ID}, 打印机侧确认 job-state=completed）"
        exit 0
    fi

    if [ "$JOB_STATE" = "aborted" ] \
        && echo "${JOB_REASONS:-}" | grep -q 'document-format-error' \
        && [ "$HAS_REWRITTEN" -eq 0 ]; then
        echo ""
        echo "==> 打印机拒收（document-format-error），自动用 pdftocairo 重写后重试一次..."
        rewrite_pdf "$PDF_FILE"
        SEND_FILE="$REWRITTEN_PDF"
        HAS_REWRITTEN=1
        continue
    fi

    if [ "$JOB_STATE" = "completed" ]; then
        echo "" >&2
        echo "警告：job-state=completed 但实际出纸页数为 ${SHEETS:-0}（impressions=${IMPRESSIONS:-?}），不能判定为成功。" >&2
    fi
    if [ "$JOB_STATE" = "timeout" ]; then
        echo "" >&2
        echo "警告：轮询 ${MAX_ROUNDS} 轮（$((MAX_ROUNDS * POLL_INTERVAL)) 秒）后任务仍未到达终态（最后状态：${LAST_JOB_STATE:-未知}）。" >&2
        cancel_job
    fi
    fail_with_details
done
