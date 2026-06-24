# Grafana as Code (Tipsy)

把 Tipsy 后端的「告警即代码 / 看板推送 / 阈值校准」沉淀成一个可触发的操作 skill。
**薄编排**:不复制脚本逻辑,只负责加载凭证、定位仓库脚本、跑现成工具,并把历史踩坑
固化成护栏。真正干活的脚本在 tipsy-backend 仓库的 `deploy/grafana/`。

## 覆盖能力

- **告警**:`deploy/grafana/alerting/`(tipsy-backend)与 `alerting-recsys/`(recsys)的
  DRY `spec → make generate → validate → push` 工作流(走 Grafana Provisioning API)。
- **看板**:`scripts/push_dashboard.py` 导入/更新看板 JSON(走经典 `/api/dashboards/db`)。
- **阈值校准/诊断**:`scripts/diagnostics/*.py`(只读查 ARMS Prometheus),写阈值前先查真实
  series,杜绝凭假设设阈值。

## 前置条件

1. **仓库**:`deploy/grafana/` 须已提交进 tipsy-backend 仓库——skill 靠
   `git rev-parse --show-toplevel` 定位它,未提交则换 clone/worktree 会失效。
2. **凭证**:`~/github/my_dot_files/secrets.sh` 须导出 `GRAFANA_URL` / `GRAFANA_TOKEN`
   (见 [`secrets.example.sh`](secrets.example.sh))。skill 运行时 `source` 它注入 env,
   **token 绝不落盘**。
3. **依赖**:`python3` + `pyyaml>=6.0`(generate/push 脚本用)。

## 安装

```bash
# 方式一:套装自带安装器(含依赖与凭证体检)
./install.sh                # 安装 / 更新
./install.sh --dry-run      # 预览
./install.sh --uninstall    # 卸载

# 方式二:仓库根目录批量同步(会同步到 ~/.claude/skills 和 ~/.agents/skills)
cd ../.. && ./sync.sh
```

装完重启 Claude Code 会话,skill 列表应出现 `grafana-as-code`。

## 用法

在 Claude Code 里直接说,例如:

> "给 voice call 加一条 Agora 离会失败率告警"
> "tipsy-backend 的内存告警在误报,帮我校准阈值"
> "把 store-review 那个看板推上去"

详细流程与全部护栏见 [`SKILL.md`](SKILL.md)。
