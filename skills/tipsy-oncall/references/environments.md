# 环境隔离与预览环境定位

这份文档解决"你现在到底在查哪个环境"这个最容易翻车的问题。tipsy-backend 有 prod / test / preview 三套环境,每套都有独立的 MySQL、Redis、ES、Lindorm、memory service、SLS 日志,数据完全隔离,连命名都不一样(线上库叫 tipsy,测试库叫 fantasy,Lindorm 线上叫 tipsy 而测试叫 fantacy——注意是 fantacy 不是 fantasy,拼错了查半天没数据)。**开工前先锁死环境,再谈查询。** 环境判错等于把用户线上问题当测试 bug 去回,或者反过来把测试脏数据当线上事故上报,两种翻车都极其昂贵。任何排障动作前必读本节。

## 三环境全景表

| 维度 | prod(线上) | test(测试/dev/staging) | preview(PR 预览) |
| --- | --- | --- | --- |
| MySQL 实例 | tipsy-backend-prod-mysql-sj6z | tipsy-backend-test-mysql-v8kd | 复用 test |
| MySQL 库名 | tipsy | fantasy | fantasy |
| Postgres(memory) | tipsy-memory / tipsy_memory 库 | tipsy-memory / tipsy_memory 库(逻辑隔离) | 复用 test |
| Lindorm 库 | tipsy | fantacy(注意拼写) | fantacy |
| memory service | `$TIPSY_MEMORY_URL_PROD` | `$TIPSY_MEMORY_URL_TEST` | 复用 test |
| SLS project | `$SLS_PROJECT_PROD` | `$SLS_PROJECT_TEST` | 复用 test project |
| SLS logStore | tipsy-chat | lightspeed-hk | lightspeed-hk |
| SLS region | us-east-1 | cn-hongkong | cn-hongkong |
| Redis | R-KVStore 生产实例 | R-KVStore 测试实例 | 复用 test |
| API 域名 | 生产域名(勿手写) | dev/staging 域名 | https://{commit_id}-{build_number}.api.dev.fantacy.live |
| DMS URL | `$DMS_URL_PROD` | `$DMS_URL_TEST` | 复用 test |

所有真实实例 ID、URL、token 都在 `secrets.sh` 里,以 `_PROD` / `_TEST` 后缀区分。**永远从 env 变量取,不要在命令、报告、聊天里粘真实值**(见 §1 铁律"token 不落盘")。

## 预览环境(preview)

tipsy-backend 独有,每次 PR 打包会部署一个短命 pod,URL 结构固定:

```
https://{commit_id}-{build_number}.api.dev.fantacy.live
```

例:`https://3e695923-588.api.dev.fantacy.live`——`3e695923` 是 commit short id,`588` 是流水线 build number,拼接后就是 preview 的 tag。tag 通常从飞书流水线通知直接拿到;拿不到就跑 `scripts/env-detect.sh` 让脚本按域名反查(脚本在仓库根目录下,做了 curl 探测 + 反查流水线的封装)。

预览环境**不是独立环境**:数据库、Redis、ES、Lindorm、memory 全部复用 test 实例。这意味着:

- 数据查询:一律用 `$*_TEST` 变量走 bytebase / 直连,别为 preview 单独找连接串。
- pod 日志:走 SLS **测试 project**(`$SLS_PROJECT_TEST` / logStore=lightspeed-hk / region=cn-hongkong),用 `__tag__:_image_name_` 精确过滤 `{commit_id}-{build_number}`(不加 tag 会把整个测试集群的日志都捞出来,信噪比爆炸)。
- 复现问题:preview 之间会互相污染(共用 test DB),排查数据类问题前先看数据是不是别的 PR 造成的。

## 环境识别 checklist

顺序不能乱,少一步都可能查错环境:

1. 用户说"线上 / 生产 / prod / 用户报障"→ 一律走 `_PROD` 变量。
2. 用户说"测试 / test / dev / staging / 联调"→ 一律走 `_TEST` 变量。
3. 用户贴了 preview URL(`{commit_id}-{build_number}.api.dev.fantacy.live`)→ 抽出 tag,**数据走 `_TEST` 变量,日志走 SLS 测试 project + `__tag__:_image_name_` 过滤**。
4. 用户啥都没说 → **反问**(哪个环境?贴一下报障 URL 或日志截图),不要默认 prod。默认 prod 的代价:一份写在报告里的错误结论。

## API 认证与时序对齐

- **认证 header**:`token: <jwt>`,**不是 `Authorization: Bearer <jwt>`**。给 backend 打 curl / hook fetch(preview 或 test)都走这个头。JWT 从 `$TIPSY_BACKEND_JWT_PROD` / `$TIPSY_BACKEND_JWT_TEST` 取。memory service `/v1/memory/*` 是内网无鉴权,直接 curl。
- **时序**:所有查询、告警、报告一律用 UTC(见 §1 铁律)。用户口述的时间通常是 UTC+8,先当场换算(减 8 小时)成 UTC 再喂给 SLS / SigNoz / PromQL。报告里回引用户时间时,同时给 UTC 和 UTC+8 两栏,便于双向核对。

## 下一步 / 相关

- references/mcp-usage.md(SKILL.md §2 前置):具体到 bytebase / signoz / aliyun-sls 各自怎么按环境切实例。
- [references/direct-connect.md](memory-direct.md):Redis / ES / memory service 直连姿势与环境变量。
- [references/reporting.md](report-format.md):五段报告里如何声明环境、贴 UTC 时间戳。

## 排障案例

**预览环境 API 500 定位 pod 日志**:PM 贴 `https://3e695923-588.api.dev.fantacy.live/api/x` 报 500 → 抽 tag `3e695923-588` → 走 SLS 测试 project(`$SLS_PROJECT_TEST` / logStore=lightspeed-hk / region=cn-hongkong),query `__tag__:_image_name_: *3e695923-588* and level: ERROR`,时间窗按用户报障时刻的 UTC±10 分钟 → 命中一条 nil pointer,数据类字段来自 test DB 脏数据(另一 PR 写入),结论:非本 PR 引入,建议清库位。