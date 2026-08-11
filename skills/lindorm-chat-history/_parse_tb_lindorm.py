#!/usr/bin/env python3
"""解析 tb_call.sh 对 tipsy lindorm_query 的返回。

返回形态：外层 ```json 围栏，内是一个 JSON 字符串，字符串体是带 markdown 表格的文本：
  "**Lindorm 查询结果:** `<回显的SQL>`\n\n返回 **N** 行 ...\n| col | col |\n| --- | --- |\n| v | v |..."

用法: _parse_tb_lindorm.py <sql> <out_jsonl>   (stdin = tb_call 原始输出)
  <sql>      本次发送的 SQL，用于防串台：回显里必须含它，否则判为串台返回 -1
  <out_jsonl> 追加写入的 JSONL 文件

约定 SELECT 列顺序：character_id, sequence, sender_type, timestamp, content
（与 query_chat_history.sh 里 TB export 的 SELECT 一致；少列时按表头名对齐）
stdout 打印本页解析出的行数；串台打印 -1；解析失败打印 0。
"""
import sys, json, re

def main():
    sql = sys.argv[1]
    out = sys.argv[2]
    raw = sys.stdin.read().strip()
    # 剥围栏 ```json ... ```
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-zA-Z]*\n?", "", raw)
        raw = re.sub(r"\n?```$", "", raw.strip())
    try:
        txt = json.loads(raw)
    except Exception:
        print(0); return
    if not isinstance(txt, str):
        print(0); return
    # 防串台：回显必须包含本次 SQL
    if sql and sql not in txt:
        print(-1); return
    lines = [l for l in txt.split("\n") if l.lstrip().startswith("|")]
    if not lines:
        print(0); return
    # 表头行确定列名与顺序
    header = [c.strip() for c in lines[0].strip().strip("|").split("|")]
    col_idx = {name: i for i, name in enumerate(header)}
    n = 0
    with open(out, "a") as f:
        for l in lines[1:]:
            if "---" in l and set(l.replace("|", "").strip()) <= {"-", " "}:
                continue
            cells = [c.strip() for c in l.strip().strip("|").split("|")]
            if len(cells) != len(header):
                # content 里可能含未转义的 | ，把多出的并回 content 列
                ci = col_idx.get("content")
                if ci is not None and len(cells) > len(header):
                    merged = cells[:ci] + ["|".join(cells[ci:ci + (len(cells) - len(header) + 1)])] \
                             + cells[ci + (len(cells) - len(header) + 1):]
                    cells = merged
                if len(cells) != len(header):
                    continue
            rec = {}
            for name, i in col_idx.items():
                rec[name] = cells[i]
            # 跳过表头误入 / 空行
            seqv = rec.get("sequence", "")
            if not seqv.lstrip("-").isdigit():
                continue
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            n += 1
    print(n)

if __name__ == "__main__":
    main()
