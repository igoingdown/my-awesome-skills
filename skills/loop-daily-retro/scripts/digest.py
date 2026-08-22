#!/usr/bin/env python3
"""每日复盘取数：切出指定日期(默认昨天)的真实工作素材，供 daily-retro.sh 归纳。
用法: digest.py [YYYY-MM-DD]
输出两部分到 stdout:
  PART 1 = 当天有真实活动的 Claude session（只切当天轮次，非整 session 首尾），
           按当天轮次数排序，前 3 个标 [TOP]，并给出 transcript 绝对路径供精读。
  PART 2 = 可选的 IM 素材：若配置了 $IM_DIGEST_CMD，调它抓当天即时通讯素材追加于此。
IM 取数失败不致命，只在该段打印一行错误，session 部分照常输出。
"""
import json, glob, os, sys, subprocess, datetime

DAY = sys.argv[1] if len(sys.argv) > 1 else \
    (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
NEXT = (datetime.date.fromisoformat(DAY) + datetime.timedelta(days=1)).isoformat()

# ---------- PART 1: session 切片 ----------
def get_text(msg):
    c = msg.get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return '\n'.join(b.get('text', '') for b in c
                         if isinstance(b, dict) and b.get('type') == 'text')
    return ''

def is_real_user(txt):
    if not txt:
        return False
    if txt.startswith('<') or txt.startswith('Caveat') or txt.startswith('[{'):
        return False
    if 'system-reminder' in txt[:80]:
        return False
    return True

files = []
for d in glob.glob(os.path.expanduser('~/.claude/projects/*/')):
    files.extend(glob.glob(d + '*.jsonl'))

rows = []
for f in files:
    users, assists = [], []
    try:
        with open(f, errors='replace') as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if not rec.get('timestamp', '').startswith(DAY):
                    continue
                t = rec.get('type')
                if t == 'user':
                    txt = get_text(rec.get('message', {})).strip()
                    if is_real_user(txt):
                        users.append(txt)
                elif t == 'assistant':
                    txt = get_text(rec.get('message', {})).strip()
                    if txt:
                        assists.append(txt)
    except Exception:
        continue
    if not users and not assists:
        continue
    proj = f.split('/projects/')[1].split('/')[0]
    rows.append({'turns': len(users) + len(assists), 'proj': proj,
                 'path': f, 'users': users, 'assists': assists})

rows.sort(key=lambda r: r['turns'], reverse=True)
print(f"# 每日复盘素材  日期={DAY}")
print(f"\n## PART 1 — Claude session（当天有真实活动的共 {len(rows)} 个）")
print("说明：前 3 个标 [TOP]，已内联当天较完整的对话正文（用户提问全文 + 助手每轮首段），无需再去读原始 transcript；"
      "其余 session 只给用户提问摘要 + 末条结论。所有正文已剔除工具调用/工具输出噪声。\n")
for i, r in enumerate(rows):
    is_top = i < 3
    print("=" * 90)
    print(f"{'[TOP] ' if is_top else ''}[{r['proj']}]  turns={r['turns']}")
    if is_top:
        # 内联当天对话：用户提问给足(800字)，助手每轮给首段(400字)，让模型能判"最难/如何优化"
        for j, u in enumerate(r['users'][:12]):
            print(f"  U{j}: {u[:800].replace(chr(10), ' ')}")
        for k, a in enumerate(r['assists'][:12]):
            print(f"  A{k}: {a[:400].replace(chr(10), ' ')}")
        if len(r['assists']) > 12:
            print(f"  A_last: {r['assists'][-1][:400].replace(chr(10), ' ')}")
    else:
        for j, u in enumerate(r['users'][:6]):
            print(f"  U{j}: {u[:260].replace(chr(10), ' ')}")
        if r['assists']:
            print(f"  A_last: {r['assists'][-1][:300].replace(chr(10), ' ')}")

# ---------- PART 2: 可选 IM 素材（通过外部命令插件化） ----------
# 自我笔记、私聊、群里 @我 这类即时通讯素材，往往藏着当天的想法与被交办的事，
# 是很好的复盘补充。但 IM 平台各异，这里不绑定具体平台：
# 若你在 config 里设置了 $IM_DIGEST_CMD，脚本调它抓当天素材（签名: <cmd> <DAY>，输出纯文本）。
print(f"\n\n## PART 2 — IM 素材（{DAY}）\n")
im_cmd = os.environ.get("IM_DIGEST_CMD", "").strip()
if not im_cmd:
    print("（未配置 IM_DIGEST_CMD，本节留空——复盘将只基于 Claude session。）")
    print("如需接入你的 IM（抓「发给自己的笔记 / 私聊 / 群里@我」），在 config 里设置")
    print("IM_DIGEST_CMD 指向一个命令：接收日期参数、输出当天素材纯文本、过滤掉自动推送。")
else:
    try:
        out = subprocess.run(im_cmd.split() + [DAY], capture_output=True,
                             text=True, timeout=180)
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip()[:200] or "IM_DIGEST_CMD non-zero exit")
        sys.stdout.write(out.stdout)
    except Exception as e:
        print(f"IM 素材取数失败 — {e}")
