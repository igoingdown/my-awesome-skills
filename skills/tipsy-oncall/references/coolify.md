# coolify CLI 用法与覆盖范围

这份文档给 tipsy-oncall 值班同学用来判断:面前这个服务到底该不该用 coolify 排查,以及在 coolify 里怎么最快看到"这个 app 到底部没部署上、日志说了什么"。开始查任何"部署问题"之前先读这份,避免把明明跑在阿里云 K8s 上的主链路当成 Coolify 副服务查错方向。

## 一、覆盖范围:先判断在不在 Coolify 上

Coolify **不覆盖** tipsy-backend / tipsy-memory 主链路。这两个跑在阿里云 K8s(参见 secrets.sh 里的 kubeconfig 相关变量与 SLS logstore),日志/滚动/回滚都不走 Coolify,任何"接口 500 / 请求慢 / mempoint 没入库"这类主链路问题都不要往这里查。

Coolify 承接的是**未来上 Coolify 的副服务**:内部工具、周边小服务、demo 站、临时 side-car。判断依据:如果这个服务的部署 pipeline 在 GitLab CI/CD + K8s Deployment,就不是 Coolify;如果它是通过 Coolify UI 或 CLI 触发的 app / service / database 资源,才是。

## 二、认证与配置

Coolify CLI(v1.6.2)默认从 `~/.config/coolify/config.json` 里的 context 读取当前实例地址与 token,无需每次传参。三种优先级:

1. `--context <name>`:显式指定当前调用用哪个 context(多实例、prod / staging 切换时必用)。
2. `--token <token>`:临时覆盖 context 里的 token,只对当次调用生效(不落盘,符合铁律"token 不落盘")。
3. 默认 context:兜底。

secrets.sh 里的 `$COOLIFY_URL` / `$COOLIFY_TOKEN` / `$COOLIFY_APP_UUID` 是**历史遗留**,只在极少数没配 context 的机器上兜底 curl,不是推荐路径。推荐把实例信息一次性写入 context,后续调用不再手动传 token。

## 三、顶层子命令速查(v1.6.2 真实)

- `app`:应用管理(list / get / logs / deployments / start / stop / restart 等)。
- `service`:预置模板服务(如数据库、监控等一键部署栈)。
- `deploy`:全局部署视角(跨 app 的部署列表与详情)。
- `server`:被 Coolify 纳管的宿主机。
- `resource`:通用资源查询。
- `database`:Coolify 托管的数据库实例(与业务 MySQL / PG 无关)。
- `project`:项目(app / service 的组织单元)。
- `teams`:成员与权限。
- `context`:CLI 侧的实例上下文(list / use / verify)。
- `config`:CLI 本地配置。
- `github`:GitHub 应用集成。
- `private-key`:SSH 私钥管理。

## 四、全局 flag

- `--context <name>`:切实例。
- `--debug`:打印 HTTP 请求细节,查"请求发出去了吗、返回什么"时开。
- `--format table|json|pretty`:输出格式,自动化必选 `json`,肉眼查用 `pretty` 或省略。
- `-s` / `--show-sensitive`:显示敏感字段(token、env),**默认不加**,只在必要时人工加,不入 shell history。
- `--token <token>`:临时 token 覆盖。

## 五、查部署状态常用命令

以下 `<UUID>` 用占位符,实际用 `app list` 拿真实 UUID。

```
coolify --format json app list
coolify --format json app get <APP_UUID>
coolify app logs <APP_UUID>
coolify app deployments <APP_UUID>
coolify --format json deploy list
coolify deploy get <DEPLOY_UUID>
coolify --format json service list
```

多实例切换:

```
coolify context list
coolify context use <CONTEXT_NAME>
coolify context verify
```

`context verify` 会实打实 ping 一次 API,是判断"CLI 配置对不对、token 有没有过期"的最快方式,比 `app list` 更纯净。

## 六、一键汇总:scripts/coolify-status.sh

仓库里已经放了 `scripts/coolify-status.sh`,内部按当前 context 顺序调用 `app list` / `service list` / `deploy list`,并把最近失败的部署高亮出来。日常巡检直接跑它,不必手敲多条命令;若脚本报鉴权错,先跑 `coolify context verify` 定位是 token 过期还是 URL 变了。

## 七、真实排障案例

**副服务部署失败:** 某内部工具在 Coolify UI 里显示 "Deployment failed",页面 log 被截断。切到 CLI 走 `coolify --context <ctx> app deployments <APP_UUID>` 拿最近一次 `deploy_uuid`,再 `coolify deploy get <DEPLOY_UUID>` 看完整 stderr,发现是构建阶段 `pnpm install` 撞到私有 registry 401;根因是 Coolify 侧的 registry token 过期,续期后 `coolify app restart <APP_UUID>` 恢复。

## 八、下一步 / 相关

- 需要看主链路(tipsy-backend / tipsy-memory)部署与滚动:去 `references/sls-logs.md` 与 K8s kubeconfig 相关文档,不走 Coolify。
- 需要看 Coolify 里托管的独立数据库:优先走 bytebase 只读通道(`references/mysql-postgres.md`),不用 `coolify database` 直连。
- Coolify 兜底 Chrome 抓 XHR:见 `references/chrome-fallback.md`(nimbalyst-browser + `browser_evaluate` hook fetch)。
- 铁律回顾:token 不落盘、只读默认、五段报告 —— 见 SKILL.md §1。