#!/bin/bash
# verify.sh — 巡检收尾校验：确认每个"本应生成评价"的候选人目录都产出了完整报告。
#
# 背景（真实教训 2026-08-18）：claude -p 进程在评估子代理还没跑完时就退出了，
# 采集完成（resume.png + asr.md 都在）但 evaluation.md / interviewer-review.md 没写出来，
# 而 check.sh 只记 exit=$?（还是 0），没人发现报告缺失，靠人肉才补跑。
# 这个脚本把"报告完整性"做成确定性的 shell 校验，不依赖 LLM 是否记得自查。
#
# 输入：$1 = targets 清单文件，每行一个候选人的目标目录（绝对路径），如
#   ~/github/interviews/liuyuan/001
#        $2 = patrol 进程退出码（可选）。非 0 时"空清单"不代表无未评价面试，而是采集失败，
#             不能报"本次无候选人需生成评价"——那会把失败伪装成没活干（事故 2026-09-07）。
# 调度脚本在评估阶段负责把每个"决定生成评价"的候选人目录写进这个文件（SKIPPED 的不写）。
#
# 输出：stdout 打印校验结果；退出码 0=全部完整或无目标，1=有缺失（调度脚本据此告警）。
# 完整定义：目录下 evaluation.md 与 interviewer-review.md 同时存在且非空。
#
# 用法：
#   ./verify.sh <targets 清单文件> [patrol 退出码]
#   INTERVIEWS_ROOT=/path/to/interviews ./verify.sh targets.txt
set -u

TARGETS="${1:-}"
PATROL_EXIT="${2:-0}"
# 面试材料根目录，可用环境变量覆盖。作用是限定 targets 清单只能指向这个目录下的路径，
# 防止清单被污染后读写到别处。
INTERVIEWS_ROOT="${INTERVIEWS_ROOT:-$HOME/github/interviews}"

if [[ -z "$TARGETS" || ! -f "$TARGETS" ]]; then
  echo "VERIFY: 无 targets 清单文件（本次可能无未评价候选人，或 prompt 未写清单）—— 跳过校验"
  exit 0
fi

# 去重、忽略空行(兼容 bash 3.2,不用 mapfile)
DIRS_CLEAN="$(grep -v '^[[:space:]]*$' "$TARGETS" | sort -u)"

if [[ -z "$DIRS_CLEAN" ]]; then
  if [[ "$PATROL_EXIT" -ne 0 ]]; then
    echo "VERIFY: targets 清单为空，但 patrol 异常退出(exit=$PATROL_EXIT) —— 判为采集失败，非「今日无未评价面试」"
    exit 1
  fi
  echo "VERIFY: targets 清单为空 —— 本次无候选人需生成评价"
  exit 0
fi

total=0
missing=0
report=""
while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  total=$((total+1))
  # 只允许 INTERVIEWS_ROOT 下的路径，防止清单被污染指向别处。
  # ⚠️ 非法路径必须计入 missing：早先只打 [SKIP] 就 continue，退出码仍是 0，
  # 调度脚本据此判定"一切正常"——这正是这套门禁要防的「失败伪装成没活干」，
  # 清单里出现非法路径本身就说明上游写错了，必须告警。
  case "$d" in
    "$INTERVIEWS_ROOT"/*) : ;;
    *) report+="  [MISS] 非法路径(不在 $INTERVIEWS_ROOT 下，疑似上游写错清单): $d"$'\n'
       missing=$((missing+1)); continue ;;
  esac
  ev="$d/evaluation.md"
  rv="$d/interviewer-review.md"
  ok_ev=0; ok_rv=0
  [[ -s "$ev" ]] && ok_ev=1
  [[ -s "$rv" ]] && ok_rv=1

  # ---- 内容门禁：文件非空不等于内容合格（事故 2026-09-08）----
  # 历史问题：verify 只查 -s，结果放行了(a)非法分数档位 (b)非法面试官档位
  # (c)对外交付物混入内部术语与断链文件引用 (d)"正负相抵"这类规则外自创算法。
  gate=""
  if [[ $ok_ev -eq 1 ]]; then
    # 分数必须是 6 个合法档位之一：2 / 2.5 / 3 / 3+ / 3.5 / 4
    # 先抓出"综合评分："后面紧跟的那个数字串，再白名单比对
    score="$(grep -oE '综合评分[:：][^0-9]*[0-9]+(\.[0-9]+)?\+?' "$ev" | head -1 \
             | grep -oE '[0-9]+(\.[0-9]+)?\+?$')"
    if [[ -z "$score" ]]; then
      gate+="未找到综合评分 "
    else
      case "$score" in
        2|2.5|3|3+|3.5|4) : ;;
        *) gate+="非法分数档位($score) " ;;
      esac
    fi
    # 规则外自创算法
    grep -qE '正负相抵|两者抵消|相互折抵|净额' "$ev" && gate+="含规则外抵消表述 "
    # 对外交付物不得含内部术语/断链引用
    # 2026-09-11 扩充：判分依据/取样缺口/未取样/补测/决策表 也是内部评分机制术语。
    # 外部 review 指出：读者(HR、下一轮面试官)要的是"这个候选人怎么样",
    # "本轮未取样,不作判分依据"这种写法把内部评分流程暴露给了他们;而且
    # "取样缺口"读起来像候选人的缺陷,实际是面试安排没覆盖到——归属都错了。
    # 改法：换成客观事实的说法（"本轮没有考察到""不作为对他的能力判断"
    # "本轮没有聊到""建议下一轮把 X 考察完整"）。
    grep -qE 'coding-analysis\.md|review-log\.md|review-(sol|terra|luna)|取样单元|压分项|前置门|SKILL\.md|判分依据|取样缺口|未取样|补测|决策表' "$ev" \
      && gate+="含内部术语或断链引用 "
    # 维度表必须是六维：2026-09-08 规则把「编码与算法」从技术深度里拆成独立核心维度，
    # 就是因为一个符号承载不了同一维度内并存的正负证据。实测三份报告都仍用五维表头，
    # 把编码结果塞回技术深度，而旧门禁只校验分数档位，全部放行。
    grep -q '编码与算法' "$ev" || gate+="维度表缺「编码与算法」(仍为旧五维) "

    # ---- 结构与冗余：防自造标题、防复述简历（事故 2026-09-09）----
    # 用户原话："这种内容不需要留在面评里,简历都有,面评只需要保留简历没有的内容"。
    # 自造标题是塞冗余的入口：按模板写就没地方放「资格信息」这类表格。
    grep -qE '^#{2,3} (资格信息|关键优势|主要风险|证据边界|二面建议|下一轮建议)' "$ev" \
      && gate+="含模板外自造标题 "
    # 简历已有的客观字段不该在面评里复述
    grep -qE '^\| *(学历|本科|届次|应聘岗位|面试轮次|工作年限) *\|' "$ev" \
      && gate+="复述简历信息(学历/届次/岗位等) "
    # 模板必需标题缺失
    for h in '## 信息汇总' '### 概览' '### 优点' '### 待提升点' '### 风险点' '### 后续面试重点关注' '## 面试记录'; do
      grep -qF "$h" "$ev" || gate+="缺模板标题[${h}] "
    done

    # ---- C0（编码未考完）时不得声称"实测"（事故 2026-09-11，两份报告同时踩）----
    # C0 的定义是「未形成可验收主体」——缺的是核心控制流(return、目标值计算、调用关系)
    # 而非环境性缺失(import、main 入口)。补齐核心控制流等于替候选人定义了算法主体，
    # 跑出来的不是他提交物的结果。两份报告都写成"忠实移植后实跑"+「实测结果」小节，
    # 一份还给出"195 组中 12 组判错"，读者会误读成"候选人代码跑失败了"，
    # 而真实情况是"他没写完、我们没测到"。三路独立 review 一致指出才发现。
    # 判定：维度表里编码与算法标注为「未考完/未取样」时，正文不得出现实测类措辞。
    # 只拦两类"肯定式声称"，放过"不是候选人代码的实测""无实测结果"这类正确的否定说明——
    # 后者恰恰是本次要求的写法，全词匹配会把正确写法也拦掉（实测误报 3/3）。
    if grep -qE '^\| *编码与算法 *\| *（?(本轮)?未(考完|取样)' "$ev"; then
      for f in "$ev" "$d/coding-analysis.md"; do
        [[ -s "$f" ]] || continue
        bad=""
        # (a) 标题式：把「实测结果」当小节标题，等于宣告这是提交物的运行记录
        grep -qE '^#{2,4} *实(测|跑)' "$f" && bad="标题「实测结果」"
        # (b) 肯定式动作：移植/补齐之后"实跑/对跑/实测"，且同句没有否定词
        grep -E '(移植|补齐|补全|重建).{0,40}(实测|实跑|对跑)' "$f" \
          | grep -qvE '不(是|能|算|构成)|并非|无实测|没有实测' && bad="${bad}移植后称实跑"
        [[ -n "$bad" ]] && gate+="编码判未考完(C0)但$(basename "$f")有${bad} "
      done
    fi

    # ---- 核心维度 - 与综合分必须自洽（事故 2026-09-11）----
    # 决策表第 3 条：恰好 1 个核心维度(技术支撑/技术深度/编码与算法)为 - → 综合 2.5，
    # 且不得因其他维度有 + 而上浮；第 2 条：≥2 个核心 - → 2。
    # 这条能机械判：数维度表里核心维度那三行有几个 -，再跟综合分对。
    # 事故形态：编码判 - 后综合给了 2.5 是对的，但改判后核心 - 换成了技术支撑，
    # 若只改表格符号忘了改分数，或反过来分数改了表格没改，都会漂出决策表。
    core_neg=0
    while IFS= read -r line; do
      case "$line" in
        *"技术支撑"*|*"技术深度"*|*"编码与算法"*)
          # 只认单独成格的 -，排除「（本轮未考完）」这类留空写法
          printf '%s' "$line" | grep -qE '\| *- *\|' && core_neg=$((core_neg+1)) ;;
      esac
    done < <(grep -E '^\| *(技术支撑|技术深度|编码与算法) *\|' "$ev")
    if [[ -n "$score" ]]; then
      if [[ $core_neg -ge 2 && "$score" != "2" ]]; then
        gate+="${core_neg}个核心维度判-但综合分是${score}(决策表第2条应为2) "
      elif [[ $core_neg -eq 1 && "$score" != "2.5" && "$score" != "2" ]]; then
        gate+="1个核心维度判-但综合分是${score}(决策表第3条应为2.5) "
      fi
    fi

    # ---- 有 - 的维度必须在概览交代是哪条硬负向（模板硬规则）----
    # 模板要求：出现 - 时在概览对应维度那段写明硬负向类型或依据。
    # 只查"报告里出现了 - 但概览通篇没有任何 - 的说明"这种明显漏写。
    if [[ $core_neg -ge 1 ]]; then
      overview="$(sed -n '/^### 概览/,/^### 优点/p' "$ev")"
      printf '%s' "$overview" | grep -qE '`-`|判 *-|为 *-' \
        || gate+="有核心维度判-但概览未交代依据 "
    fi

    # ---- 引语溯源：防跨候选人证据污染（事故 2026-09-09）----
    # 真实事故：范思远那份的软素质依据写着「3 万多条」，而这是同批次另一位候选人
    # 韩旭的项目数据，范思远全程没说过。并行评估多人时上下文同时装着多份材料，
    # 串台是系统性风险。外部 review 三路才发现，自查完全没看出来。
    # 做法：抽出报告里中文引号内含数字的短语（最易串台），逐个回本人 asr.md 找。
    # 比对前两侧都去掉空白：报告排版会给中英文数字加空格（"100 多个"），
    # 而 ASR 原文是"100多个"，直接 grep 会全量误报。
    # 兜底：找不到时再去简历文本里找一次（简历引语是合法来源）。
    asr="$d/asr.md"
    if [[ -s "$asr" ]]; then
      asr_flat="$(tr -d '[:space:]' < "$asr")"
      resume_flat=""
      [[ -s "$d/resume.txt" ]] && resume_flat="$(tr -d '[:space:]' < "$d/resume.txt")"
      orphan=""
      while IFS= read -r q; do
        [[ -z "$q" ]] && continue
        # 只查含数字的引语：清洗类改写会让合法引语找不到，纯文字引语误报率过高
        [[ "$q" =~ [0-9] ]] || continue
        qf="$(printf '%s' "$q" | tr -d '[:space:]')"
        [[ -z "$qf" ]] && continue
        case "$asr_flat" in *"$qf"*) continue ;; esac
        [[ -n "$resume_flat" ]] && case "$resume_flat" in *"$qf"*) continue ;; esac
        # 简历引语是合法来源，但 resume 多为 pdf/png 无法 grep：
        # 若该引语所在行显式标注了「简历」，视为已交代来源，放行。
        grep -F "$q" "$ev" | grep -q '简历' && continue
        orphan+="$q; "
      done < <(grep -oE '"[^"]{4,20}"' "$ev" | tr -d '""' | sort -u)
      [[ -n "$orphan" ]] && gate+="引语在本人材料中找不到[$orphan] "
    fi
  fi
  if [[ $ok_rv -eq 1 ]]; then
    # 面试官档位只能 A/B/C/D，禁止子档
    grep -qE '综合评分[:：][^A-D]*[ABCD][+-]' "$rv" && gate+="面试官档位含非法子档 "

    # ---- 旁听场不得给用户打档（事故 2026-09-10）----
    # 复盘的用途是让用户改进自己的面试技巧。用户是 shadow 陪面时，提问行为全是别人的，
    # 给用户打 A/B/C/D 等于评错了人——用户翻历史复盘做趋势对比会把别人的成绩当自己的。
    # chenzhenran/002 就踩了：开篇正确交代"复盘对象是涂鹏"，却仍在评分栏写了 C。
    # 判定：复盘正文自述本场为 shadow/陪面/旁听 → 评分栏必须是"不评档"，不许出现 A/B/C/D。
    if grep -qE 'shadow|陪面|旁听' "$rv"; then
      grep -qE '综合评分[:：][^A-D]*[ABCD]([^A-Za-z+-]|$)' "$rv" \
        && gate+="旁听场却给用户打了档位(应写「不评档」) "
    fi
  fi

  if [[ $ok_ev -eq 1 && $ok_rv -eq 1 && -z "$gate" ]]; then
    report+="  [OK]   $d"$'\n'
  elif [[ $ok_ev -eq 1 && $ok_rv -eq 1 ]]; then
    report+="  [GATE] $d 内容门禁未过: ${gate}"$'\n'
    missing=$((missing+1))
  else
    miss=""
    [[ $ok_ev -eq 0 ]] && miss+="evaluation.md "
    [[ $ok_rv -eq 0 ]] && miss+="interviewer-review.md "
    # 区分：采集是否完成（有 asr.md/resume.png 却缺报告 = 评估中断，最需要告警）
    collected=""
    [[ -s "$d/asr.md" ]] && collected+="asr.md "
    [[ -s "$d/resume.png" ]] && collected+="resume.png "
    report+="  [MISS] $d 缺: ${miss}(已采集: ${collected:-无})"$'\n'
    missing=$((missing+1))
  fi
done <<EOF
$DIRS_CLEAN
EOF

echo "VERIFY: 目标 ${total} 个，缺失 ${missing} 个"
printf '%s' "$report"

if [[ $missing -gt 0 ]]; then
  exit 1
fi
exit 0
