#!/usr/bin/env python3
"""解析 tb_call.sh 对 mcp/meego 各工具的返回。

返回体三层嵌套（实测）：
  ```json 围栏 → JSON 字符串 → 字符串体是真 JSON，但尾部拼了 " log_id: xxx"
直接 json.loads 会报 "Extra data"。错误返回是 "id=..., code=..., message=..." 开头的纯文本。

用法（stdin = tb_call 原始输出）:
  parse_meego.py rows    # search_by_mql: 每行打印 标题|状态（自动识别 名称/缺陷名称 字段）
  parse_meego.py fields  # search_by_mql: 打印首行记录的字段名清单（探索字段 label 用）
  parse_meego.py json    # 任意工具: 打印剥壳后的完整 JSON（jq 友好）
"""
import sys, json, re


def unwrap(raw: str):
    """剥围栏 → loads 字符串 → 截尾 log_id → loads 对象。返回 (obj, err_text)。"""
    s = raw.strip()
    if s.startswith("```"):
        s = re.sub(r"^```[a-zA-Z]*\n?", "", s)
        s = re.sub(r"\n?```$", "", s.strip())
    try:
        inner = json.loads(s)
    except Exception as e:
        return None, f"OUTER_FAIL {e}: {s[:200]}"
    if not isinstance(inner, str):
        return inner, None
    if inner.lstrip().startswith("id=") or "message=" in inner[:80]:
        return None, f"API_ERR {inner[:300]}"
    end = inner.rfind("}")
    body = inner[: end + 1] if end >= 0 else inner
    try:
        return json.loads(body), None
    except Exception as e:
        return None, f"INNER_FAIL {e}: {body[:200]}"


def field_value(v):
    """moql_field_list 里 value 的三种形态取显示值。"""
    if not isinstance(v, dict):
        return v
    if "string_value" in v:
        return v["string_value"]
    if "key_label_value" in v:
        return (v["key_label_value"] or {}).get("label", "")
    kl = v.get("key_label_value_list")
    if kl:
        return kl[0].get("label", "")
    return v


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "rows"
    d, err = unwrap(sys.stdin.read())
    if err:
        print(err)
        sys.exit(1)
    if mode == "json":
        print(json.dumps(d, ensure_ascii=False, indent=1))
        return
    cnt = "?"
    if isinstance(d, dict) and d.get("list"):
        cnt = d["list"][0].get("count", "?")
    rows = (d or {}).get("data", {}).get("1", [])
    if mode == "fields":
        if rows:
            for f in rows[0].get("moql_field_list", []):
                print("  name=%s key=%s" % (f.get("name"), f.get("key")))
        else:
            print("(无返回行，无法列字段)")
        return
    print("命中总数:", cnt, " 本页:", len(rows))
    for r in rows:
        dd = {f.get("name"): field_value(f.get("value")) for f in r.get("moql_field_list", [])}
        # 标题字段因类型而异：需求=名称，缺陷=缺陷名称
        title = dd.get("名称") or dd.get("缺陷名称") or ""
        extras = "  ".join(
            "%s=%s" % (k, v) for k, v in dd.items() if k not in ("名称", "缺陷名称") and v
        )
        print("  - %s | %s" % (title, extras))


if __name__ == "__main__":
    main()
