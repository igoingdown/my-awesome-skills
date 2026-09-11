# patrol — 飞书招聘未评价面试每日巡检

`hire-patrol` 定时任务的编排层。**运行副本在 `~/hire_patrol/`，改动后两边要同步。**

| 文件 | 用途 |
|---|---|
| `check.sh` | launchd 入口：防重入锁 → 调 `claude -p` 跑巡检 → verify 收尾校验 → multi-review 发布门禁 → 飞书告警 |
| `prompt.md` | 交给 `claude -p` 的编排指令：扫未评价列表 → 逐个判断是否需生成 → 调 interview-comment skill → 发飞书汇总 |

## 为什么纳入版本控制

这两个文件承载了多次事故的防护逻辑（陈旧锁自动接管、patrol 失败独立告警、空清单不等于没活干、同名不同人校验），但此前只有 `~/hire_patrol` 一份副本，不在任何 git 仓库里——丢一次就全没了。`verify.sh` 与 `multi-review.sh` 已经在 `scripts/` 下版本化，这两个补齐一致性。

## 运行时布局

```
~/hire_patrol/
├── check.sh              # launchd 入口（本目录副本）
├── prompt.md             # 巡检指令（本目录副本）
├── verify.sh             # 收尾校验（scripts/verify.sh 的副本）
├── multi-review.sh       # 发布门禁（scripts/multi-review.sh 的副本）
├── last_run_targets.txt  # 本轮需生成评价的目录清单，每轮清空
├── .lock/                # 防重入锁，内含 pid
└── logs/run-<时间戳>.log # 保留最近 30 天
```

launchd 任务名 `com.user.hire-patrol`，每天 10:30 触发。查状态：

```bash
launchctl list | grep hire-patrol
tail -60 ~/hire_patrol/logs/$(ls -t ~/hire_patrol/logs | head -1)
```

## 四道防护各对应一次真实事故

| 防护 | 事故 |
|---|---|
| 陈旧锁自动接管 + 告警 | 原实现 `mkdir` 失败就静默 `exit 0`。上一轮被 kill -9 或 OOM 后锁目录永久残留，此后每轮静默跳过、退出码还是 0——任务等于死了但看起来一切正常 |
| patrol 失败独立告警 | 2026-09-07 `claude -p` 因 ConnectionRefused 崩溃（exit=1），清单自然为空，verify 把空清单判成"今日无未评价面试"正常退出——当天一场真实面试没被采集，失败被伪装成没活干 |
| 收尾校验报告完整性 | 2026-08-18 `claude -p` 在评估子代理跑完前就退出，采集完成但报告没写出来，无人发现 |
| multi-review 发布门禁 | AI 自查查不出自己的系统性偏差。三次事故都是外部 review 才发现（编造实测数据、自创"正负相抵"绕过决策表、连续三份用未定义档位） |

## 手工重跑

```bash
# 单个候选人重新评估：直接在交互式会话里调 skill，不要走 check.sh
# 只跑收尾校验
T=$(mktemp) && echo "$HOME/github/interviews/<人名>/<轮次>" > "$T" \
  && bash ~/hire_patrol/verify.sh "$T" 0; rm -f "$T"
# 只跑发布门禁（不要套 timeout，macOS 没这个命令，见 ../scripts/README.md）
bash ~/hire_patrol/multi-review.sh ~/github/interviews/<人名>/<轮次>
```
