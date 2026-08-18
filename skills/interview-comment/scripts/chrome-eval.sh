#!/usr/bin/env bash
# chrome-eval.sh — 在匹配 URL 的 Chrome 标签页里跑一段页面 JS 并打印结果。
#
# 这是 skill 与 hire-patrol 共用的浏览器自动化入口。它把"定位标签页 + 注入 async JS +
# 轮询 + 分片取回 + UTF-8/引号转义"这件最容易写错的事收敛成一个命令，调用方不用再手写 osascript。
#
# 用法：
#   chrome-eval.sh <url-substring> -f <page-js-file> [timeoutSec]
#   chrome-eval.sh <url-substring> -e '<inline page js>'  [timeoutSec]
#   echo '<page js>' | chrome-eval.sh <url-substring> -    [timeoutSec]
#
# 页面 JS 里可用顶层 await、可 return（字符串原样返回；对象自动 JSON）。
#
# 退出码：
#   0  成功（结果在 stdout）
#   3  NOT_FOUND（没有标签页 URL 命中；页面可能没打开或还没加载）
#   4  TIMEOUT（页面 JS 超时未完成）
#   5  ERR（Chrome 未运行 / 注入失败 / 页面 JS 抛错，stderr 有详情）
#   2  参数错误（含缺少自动化权限时 osascript 的报错）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/chrome-eval.jxa.js"

if [[ $# -lt 2 ]]; then
  echo "usage: chrome-eval.sh <url-substring> {-f <file>|-e <inline>|-} [timeoutSec]" >&2
  exit 2
fi

URLSUB="$1"; MODE="$2"; shift 2

JS=""
case "$MODE" in
  -f) JS="$(cat "$1")"; shift ;;
  -e) JS="$1"; shift ;;
  -)  JS="$(cat)" ;;
  *)  echo "unknown mode: $MODE (want -f/-e/-)" >&2; exit 2 ;;
esac
TIMEOUT="${1:-30}"

B64="$(printf '%s' "$JS" | base64 | tr -d '\n')"

OUT="$(osascript -l JavaScript "$ENGINE" "$URLSUB" "$B64" "$TIMEOUT" 2>/tmp/chrome-eval.stderr || true)"
STDERR="$(cat /tmp/chrome-eval.stderr 2>/dev/null || true)"; rm -f /tmp/chrome-eval.stderr

# osascript 自身报错（最常见：launchd 环境缺自动化权限）
if [[ -n "$STDERR" && -z "$OUT" ]]; then
  echo "$STDERR" >&2
  case "$STDERR" in
    *"Not authorized"*|*"-1743"*) echo "HINT: 缺少 Apple 事件自动化权限（launchd 环境需授权）。" >&2 ;;
  esac
  exit 2
fi

case "$OUT" in
  NOT_FOUND) echo "NOT_FOUND: 没有标签页 URL 含 '$URLSUB'（页面没打开或未加载完）" >&2; exit 3 ;;
  TIMEOUT)   echo "TIMEOUT: 页面 JS ${TIMEOUT}s 内未完成" >&2; exit 4 ;;
  ERR:*)     echo "$OUT" >&2; exit 5 ;;
  *)         printf '%s' "$OUT"; echo; exit 0 ;;
esac
