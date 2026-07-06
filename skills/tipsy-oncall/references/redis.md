# Redis 只读查询

这份文档解决 tipsy-backend 值班时"要查一条 Redis 里的实时状态"这类需求 —— 比如某个 session 的 pending 队列长度、某个用户的限流窗口、某个热角色的缓存 TTL。写在这里的两条通道都不需要在跳板机上落 Redis 密码,也不需要开 6379 白名单,直接从本地打通。什么时候读这份文档:排障看板显示某后端接口"卡在 Redis"、要验证某个缓存 key 是否被正确写入、线上限流 / 冷启动异常需要看具体 key 值、或某个异步队列疑似积压。

## 方案 A(首选):阿里云 R-KVStore RunCommand OpenAPI

阿里云 Redis 提供了 `RunCommand` 这个 OpenAPI,直接从公网网关把命令下发到实例,**不走 6379,不需要 Redis AUTH 密码**,只吃 AK/SK。

- 命名空间:`R-KVStore`,version `2015-01-01`
- 端点:`r-kvstore.aliyuncs.com`(公网)
- 认证:`$ALIYUN_ACCESS_KEY_ID` / `$ALIYUN_ACCESS_KEY_SECRET`,region 用 `$ALIYUN_REGION_ID`
- 必填参数:
  - `InstanceId`:线上 `$ALIYUN_REDIS_INSTANCE_ID_PROD`,测试 `$ALIYUN_REDIS_INSTANCE_ID_TEST` —— 严格按 SKILL.md §1 环境铁律,不要串环境
  - `Command`:单条大写命令,如 `HGETALL`
  - `Args`:JSON 数组字符串,如 `["session:abc123"]`

### 只读白名单

只发这些命令,别的不要碰,以免误触发写入或阻塞:

- 取值:`GET` / `HGETALL` / `HGET` / `HKEYS` / `LRANGE`(必须带上下界)
- 元数据:`TYPE` / `TTL` / `EXISTS` / `OBJECT ENCODING` / `STRLEN` / `LLEN`
- 扫描:`SCAN` / `HSCAN` / `SSCAN`(必须带 `MATCH` 和 `COUNT`,别裸扫)

### 硬禁用

`FLUSHALL` / `FLUSHDB` / `CONFIG` / `DEBUG` / `SHUTDOWN` —— 阿里云网关侧直接 reject,别浪费调用。`KEYS *` 在集群版会 cross-slot 报错,单实例也会长阻塞,一律用 `SCAN 0 MATCH pattern COUNT 100` 替代。任何 `SET` / `DEL` / `EXPIRE` 只读默认铁律下禁止,即便测试环境也走 propose 流程。

### 大 hash / 大 list

单次 RunCommand 有返回大小上限(约 2 MB),大 hash 用 `HSCAN key 0 COUNT 200` 分页,不要 `HGETALL`;大 list 先用 `LLEN` 探长度,再 `LRANGE key 0 99` 抽头样本,超过 1000 条直接止步、改走日志。

### RAM 授权

`AliyunKvstoreReadOnlyAccess` 不够 —— 它只覆盖 Describe*,不覆盖 RunCommand。需要额外授权 `kvstore:RunCommand` 这个 action。如果调用报 `NoPermission`,先去 RAM 控制台确认策略,不要以为是签名错。

### 集群版陷阱

tipsy 线上 Redis 是集群版,跨 slot 的多 key 命令(如 `MGET k1 k2` 但两个 key 不在同一 slot)会失败;单 key、同一 hash tag 内的操作是安全的。要批量查多个 key,分多次调用,别偷懒 pipeline。

## 方案 B(兜底):阿里云 DMS Web + nimbalyst-browser

OpenAPI 报鉴权错、实例未开通白名单、或者返回被截断时,回退 DMS Redis 控制台:

1. 打开 `$ALIYUN_DMS_REDIS_URL_PROD`(测试用 `$ALIYUN_DMS_REDIS_URL_TEST`),让浏览器自动登录会话
2. 用 nimbalyst-browser 定位到"命令窗口" tab,把只读命令 type 进去
3. 通过 `browser_evaluate` hook fetch 抓 XHR 请求的响应 JSON —— 这样拿到结构化结果,不靠 OCR 截图文本

这个通道慢、会话易超时、不适合脚本化循环,但兜底稳。任何 Redis 查询都不要在 DMS 里手打 `FLUSH` / `SET` / `DEL`,遵守 SKILL.md §1 只读铁律。

## 常用查询封装

高频查询(pending 长度、session TTL、rate limit 计数)统一走 `scripts/redis-cmd.sh`,内部封装了 OpenAPI 签名、环境切换、结果解包,不用自己拼签名:

```
scripts/redis-cmd.sh prod HGETALL "session:$sid"
scripts/redis-cmd.sh test TTL     "rate_limit:$uid"
scripts/redis-cmd.sh prod HSCAN   "hot_character:index" 0 COUNT 200
```

第一个参数固定 `prod` / `test`,脚本内部按环境铁律选实例、走对应的 AK/SK 别串环境。

## tipsy 常见 key 前缀

只列高频,**实际前缀请参考 tipsy-backend 仓库里 pkg/cache 的命名常量**,避免猜错前缀导致 miss:

- `session:*` —— 会话状态、上下文摘要
- `pending:*` —— 异步任务队列(mempoint / 打电话总结 / 记忆 ingest 常用)
- `rate_limit:*` —— 用户 / 接口维度限流窗口
- `hot_character:*` —— 热角色缓存索引

## 案例:查 pending 队列长度

**现象**:线上某用户反馈"消息已发但迟迟没回复",怀疑 mempoint 队列积压。
**通道**:方案 A,先 `scripts/redis-cmd.sh prod TYPE pending:mempoint:$uid` 确认是 `list`。
**查询**:再 `scripts/redis-cmd.sh prod LLEN pending:mempoint:$uid`,返回 12。
**结论**:确实积压,顺着 uid 去 SLS 拉 memory 服务日志,看 ingest worker 是否卡在 dedup key 或下游超时,再决定是否需要重启 worker。

## 下一步 / 相关

- 数据库查询走 [references/db.md](mysql-postgres.md)(MySQL / PG / Lindorm 的 bytebase 通道)
- 日志查询走 [references/logs.md](sls-logs.md)(SLS 静默陷阱 + SigNoz memory 服务)
- 直接 curl memory 服务见 [references/memory-service.md](memory-direct.md)
- 只读默认、环境隔离、AK/SK 不落盘的铁律见 SKILL.md §1