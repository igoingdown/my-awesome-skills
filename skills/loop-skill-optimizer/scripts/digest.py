#!/usr/bin/env python3
"""提取日期窗口内所有 Claude session 的用户消息全集（批判/纠偏素材），供每日 skill 优化分析使用。
用法: claude-session-critique-digest.py <start-date> <end-date>   # 均为 YYYY-MM-DD，[start, end)
与 claude-session-digest.py（周报用，只取首条请求+最终结论）不同，本脚本输出每个 session
的全部用户文本消息——用户的批判、打断纠偏、重复强调都藏在这里面。
每组头部带 transcript 绝对路径，下游分析需要上下文时可直接回读原文件。
只扫顶层 session 文件（不含 subagents），跳过 skill-opt 流水线自身产生的项目目录。
"""
import json, glob, os, sys

if len(sys.argv) != 3:
    print(__doc__, file=sys.stderr)
    sys.exit(1)
START, END = sys.argv[1], sys.argv[2]

MAX_MSG = 300     # 每个 session 最多保留的用户消息条数（保首条 + 最近的）
MAX_LEN = 1000    # 单条消息截断长度

files = []
for d in glob.glob(os.path.expanduser('~/.claude/projects/*/')):
    if 'skill-opt' in os.path.basename(d.rstrip('/')):
        continue
    files.extend(glob.glob(d + '*.jsonl'))

def get_text(msg):
    c = msg.get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return '\n'.join(b.get('text', '') for b in c
                         if isinstance(b, dict) and b.get('type') == 'text')
    return ''

INTERRUPT_MARKS = ('[Request interrupted by user for tool use]',
                   '[Request interrupted by user]')

rows = []
for f in files:
    try:
        first_ts = last_ts = None
        msgs = []
        with open(f, errors='replace') as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                ts = rec.get('timestamp')
                if ts:
                    if not first_ts:
                        first_ts = ts
                    last_ts = ts
                if rec.get('type') != 'user' or rec.get('isMeta'):
                    continue
                txt = get_text(rec.get('message', {})).strip()
                # 打断标记本身丢弃，但保留其后用户补充的真实内容
                for m in INTERRUPT_MARKS:
                    if txt.startswith(m):
                        txt = txt[len(m):].strip()
                if not txt or txt.startswith('<') or txt.startswith('Caveat:') \
                        or 'system-reminder' in txt[:120]:
                    continue
                if len(txt) > MAX_LEN:
                    txt = txt[:MAX_LEN] + '…'
                msgs.append((ts or '', txt))
        if not first_ts or not msgs:
            continue
        if last_ts[:10] < START or first_ts[:10] >= END:
            continue
        rows.append({
            'proj': f.split('/projects/')[1].split('/')[0],
            'path': f,
            'start': first_ts, 'end': last_ts,
            'msgs': msgs,
        })
    except Exception as e:
        print(f'ERR {f}: {e}', file=sys.stderr)

rows.sort(key=lambda r: r['start'])
for r in rows:
    total = len(r['msgs'])
    msgs = r['msgs']
    omitted = 0
    if total > MAX_MSG:
        omitted = total - MAX_MSG
        msgs = [msgs[0]] + msgs[-(MAX_MSG - 1):]
    print('=' * 100)
    print(f"[{r['proj']}]  {r['start'][:16]} ~ {r['end'][:16]}  ({total} 条用户消息)")
    print(f"TRANSCRIPT: {r['path']}")
    for i, (ts, txt) in enumerate(msgs, 1):
        hhmm = ts[11:16] if len(ts) >= 16 else '??:??'
        print(f"U{i:02d} {hhmm} | {txt.replace(chr(10), ' ⏎ ')}")
        if omitted and i == 1:
            print(f"    …（中间省略 {omitted} 条）…")
