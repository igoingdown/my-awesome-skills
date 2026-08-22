#!/usr/bin/env python3
"""提取指定日期窗口内所有 Claude session 的摘要清单，供周报生成使用。
用法: claude-session-digest.py <start-date> <end-date>   # 均为 YYYY-MM-DD，[start, end)
按最后活跃时间过滤，扫描顶层 session 文件（subagents 仅做关键词信号计数）。

采样口径（2026-08-17 修）：不再只取首条用户消息 + 末条助手回复。
- 全程真实用户消息去重后按位置采样（首/中/末），避免续接会话/长会话主线丢失；
- 助手正文按高信号关键词摘取兜底行，并抽取 PR/issue 号；
- 关联 subagents 目录做关键词命中计数，兜住话题漂移到子代理里的工作。
"""
import json, glob, os, sys, re

if len(sys.argv) != 3:
    print(__doc__, file=sys.stderr)
    sys.exit(1)
START, END = sys.argv[1], sys.argv[2]

MAX_USER = 8            # 每个 session 最多采样的用户消息条数
USER_CHARS = 160        # 每条用户消息截断
MAX_SIGNAL = 6          # 每个 session 最多摘取的信号行数
SIGNAL_CHARS = 140
SUBAGENT_BYTE_CAP = 8 * 1024 * 1024   # 每个 session 扫描 subagents 的字节上限

# 高信号关键词：里程碑/成果/事故类，命中的助手正文行会被摘出兜底。
# 这里放的是通用工程词，请按你自己的业务领域补充高价值关键词（越贴合越准）。
SIGNAL_KW = ['上线', '合入', '合码', 'MERGED', '终验', '压测', '灰度', '部署',
             '事故', '告警', 'runbook', 'DDL', '恰好一次', '验收', '决策树']
# subagents 目录只统计这批领域关键词命中次数（同样建议按你的业务补充）。
SUB_KW = ['事故', '告警', '上线', '合入', 'spec', '压测']

PR_RE = re.compile(r'(?:PR\s*)?#\d{2,5}')   # 有界 \d{2,5}，走 python re，安全

files = []
for d in glob.glob(os.path.expanduser('~/.claude/projects/*/')):
    files.extend(glob.glob(d + '*.jsonl'))


def norm(s):
    return ' '.join(s.split())


def get_text(msg):
    c = msg.get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return '\n'.join(b.get('text', '') for b in c
                         if isinstance(b, dict) and b.get('type') == 'text')
    return ''
def is_real_user(txt):
    """过滤工具结果/系统提醒/续接指令等非真实输入。"""
    if not txt:
        return False
    t = txt.lstrip()
    if t.startswith('<') or t.startswith('Caveat'):
        return False
    if 'system-reminder' in txt[:100]:
        return False
    if 'Base directory for this skill' in txt[:80]:
        return False
    # 续接会话开场白（读某个 .txt 并继续）本身无信息量，跳过
    if re.match(r'^\S+\.txt\s', t) or t.startswith('This session is being continued'):
        return False
    return True


def sample_positions(items, k):
    """从 items 里按首/中/末均匀取最多 k 条，保持原顺序。"""
    if len(items) <= k:
        return items
    idxs = sorted(set(round(i * (len(items) - 1) / (k - 1)) for i in range(k)))
    return [items[i] for i in idxs]


def scan_subagents(session_path):
    """统计该 session 关联 subagents 目录里的领域关键词命中，兜住话题漂移。"""
    base = session_path[:-6]  # 去掉 .jsonl
    subdir = os.path.join(base, 'subagents')
    if not os.path.isdir(subdir):
        return {}
    hits = {}
    budget = SUBAGENT_BYTE_CAP
    for root, _, fnames in os.walk(subdir):
        for fn in fnames:
            if not fn.endswith('.jsonl'):
                continue
            p = os.path.join(root, fn)
            try:
                with open(p, errors='replace') as fh:
                    for line in fh:
                        budget -= len(line)
                        if budget <= 0:
                            return hits
                        for kw in SUB_KW:
                            if kw in line:
                                hits[kw] = hits.get(kw, 0) + 1
            except Exception:
                continue
    return hits


rows = []
for f in files:
    try:
        first_ts = last_ts = None
        summaries = []
        user_msgs = []          # 去重后的真实用户消息（保序）
        seen_user = set()
        last_assistant = None
        signal_lines = []       # 助手正文里的高信号行
        seen_signal = set()
        pr_ids = []
        seen_pr = set()
        n_lines = 0
        with open(f, errors='replace') as fh:
            for line in fh:
                n_lines += 1
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                t = rec.get('type')
                ts = rec.get('timestamp')
                if ts:
                    if not first_ts:
                        first_ts = ts
                    last_ts = ts
                if t == 'summary':
                    s = rec.get('summary', '')
                    if s:
                        summaries.append(s)
                elif t == 'user':
                    txt = norm(get_text(rec.get('message', {})))
                    if is_real_user(txt):
                        key = txt[:60]
                        if key not in seen_user:
                            seen_user.add(key)
                            user_msgs.append(txt[:USER_CHARS])
                elif t == 'assistant':
                    raw = get_text(rec.get('message', {})).strip()
                    if not raw:
                        continue
                    last_assistant = norm(raw)
                    # 抽 PR/issue 号
                    for m in PR_RE.findall(raw):
                        mm = m.replace(' ', '')
                        if mm not in seen_pr:
                            seen_pr.add(mm)
                            pr_ids.append(mm)
                    # 摘高信号行
                    for ln in raw.splitlines():
                        ln = norm(ln)
                        if len(ln) < 6:
                            continue
                        if any(kw in ln for kw in SIGNAL_KW):
                            key = ln[:50]
                            if key not in seen_signal:
                                seen_signal.add(key)
                                signal_lines.append(ln[:SIGNAL_CHARS])
        if not first_ts:
            continue
        if last_ts[:10] < START or first_ts[:10] >= END:
            continue
        sub_hits = scan_subagents(f)
        rows.append({
            'proj': f.split('/projects/')[1].split('/')[0],
            'file': os.path.basename(f),
            'start': first_ts, 'end': last_ts, 'lines': n_lines,
            'summaries': summaries[:3],
            'users': sample_positions(user_msgs, MAX_USER),
            'n_users': len(user_msgs),
            'signals': signal_lines[:MAX_SIGNAL],
            'prs': pr_ids[:20],
            'last_assistant': (last_assistant or '')[:400],
            'sub_hits': sub_hits,
        })
    except Exception as e:
        print(f'ERR {f}: {e}', file=sys.stderr)

rows.sort(key=lambda r: r['start'])
for r in rows:
    print('=' * 100)
    print(f"[{r['proj']}] {r['file']}  {r['start'][:16]} ~ {r['end'][:16]}  ({r['lines']} lines)")
    if r['summaries']:
        print('SUMMARY:', ' | '.join(r['summaries']))
    if r['prs']:
        print('PR/ISSUE:', ' '.join(r['prs']))
    print(f"USER_MSGS (采样 {len(r['users'])}/{r['n_users']} 条去重):")
    for u in r['users']:
        print('  - ' + u)
    if r['signals']:
        print('SIGNAL_LINES:')
        for s in r['signals']:
            print('  * ' + s)
    if r['sub_hits']:
        kv = ', '.join(f'{k}×{v}' for k, v in sorted(r['sub_hits'].items(), key=lambda x: -x[1]))
        print('SUBAGENT_HITS:', kv)
    print('LAST_ASSIST:', r['last_assistant'].replace('\n', ' ⏎ '))
print(f'\nTOTAL SESSIONS: {len(rows)}', file=sys.stderr)

