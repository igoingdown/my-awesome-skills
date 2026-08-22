#!/usr/bin/env bash
# 把一条周报链接归档进「汇总索引文档」的锚点段落之后（最新在最上）。
#
# 这是一个参考实现骨架：真实逻辑依赖你所用云文档平台的 CLI（$DOC_CLI）能力——
# 读文档结构拿到段落 block-id、按 block-id 在其后插入一段内容。不同平台 API 不同，
# 下面用伪代码 + 注释描述算法，你需要用自己文档平台的命令把 TODO 段落补齐。
#
# 用法: archive-to-index.sh <doc_url> <week_label>
set -uo pipefail

CONFIG="${LOOP_WEEKLY_REPORT_CONFIG:-$HOME/.config/loop-weekly-report.sh}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

INDEX_DOC="${WEEKLY_INDEX_DOC:-}"
INDEX_ANCHOR_KW="${WEEKLY_INDEX_ANCHOR_KW:-[[ANCHOR:weekly-index]]}"
DOC_CLI="${DOC_CLI:-doc-cli}"
REPORT_OWNER="${REPORT_OWNER:-Me}"

URL="$1"; LABEL="$2"
TODAY=$(date +%F)

if [ -z "$INDEX_DOC" ]; then
  echo "archive-to-index: 未配置 WEEKLY_INDEX_DOC，跳过归档（非致命）"
  exit 0
fi

# 算法（与具体文档平台无关，实现时替换成你 $DOC_CLI 的等价命令）：
#  1. 拉取索引文档全文（带每个 block 的 id）。
#  2. 在正文里找到含锚点关键词 $INDEX_ANCHOR_KW 的段落，取它的 block-id。
#     —— 用「关键词定位」而不是硬编码 block-id，避免文档结构变动后失效。
#  3. 构造一行内容：<粗体 LABEL> · <指向 URL 的链接「周报 LABEL（REPORT_OWNER）」> · 归档 TODAY
#     —— URL 里的 & < > 记得做 XML 转义，避免破坏文档结构。
#  4. 调 $DOC_CLI 的「在指定 block 之后插入」命令，把这行插到锚点段落后面（=列表最上）。
#
# 下面是需要你按自己平台补齐的 TODO：

echo "archive-to-index: doc=$INDEX_DOC anchor='$INDEX_ANCHOR_KW' label='$LABEL' url='$URL'"
echo "TODO: 用 $DOC_CLI 实现上面 4 步。参考实现依赖私有云文档 CLI，未随仓库分发。"
# 例：
#   anchor_id=$("$DOC_CLI" fetch --doc "$INDEX_DOC" --with-ids | locate_paragraph "$INDEX_ANCHOR_KW")
#   content="<p><b>${LABEL}</b> · <a href=\"$(xml_escape "$URL")\">周报 ${LABEL}（${REPORT_OWNER}）</a> · 归档 ${TODAY}</p>"
#   "$DOC_CLI" update --doc "$INDEX_DOC" --insert-after "$anchor_id" --content "$content"
exit 0
