# ES（Elasticsearch）只读查询

这份文档解决 tipsy-oncall 值班时直连 Elasticsearch 查数据的操作路径，配合角色可见性 / 搜索 / trending 类问题使用。当你需要确认某角色或内容是否已同步到 ES、是否被过滤字段命中、别名当前指向哪个物理索引时读它。ES 没有 bytebase 那层拦截，本文所有命令按 §1 铁律默认只读，禁止手写 POST/PUT/DELETE。

## ES 实例基本信息

阿里云 ES 是原生 Elasticsearch（7.x / 8.x 依实例版本），数据面就是标准 ES REST，不走 DMS/Bytebase，curl 打 9200 就能查。

- endpoint 变量：`$ALIYUN_ES_ENDPOINT_PROD` / `$ALIYUN_ES_ENDPOINT_TEST`，形如 `https://xxx.public.elasticsearch.aliyuncs.com:9200`
- 认证：basic auth，`$ALIYUN_ES_USERNAME`（通常是 elastic） + `$ALIYUN_ES_PASSWORD`
- 环境隔离：线上 prod 与测试 test 完全独立，值班查线上必显式指定 PROD 变量，切勿串环境。

## 前置准备

阿里云 ES 默认关闭公网访问，首次值班必须先做：

1. 阿里云控制台 → Elasticsearch 实例 → 网络与安全 → 公网地址：确认已开启。
2. 公网白名单：把你当前出口 IP（`curl ifconfig.me`）加进去。
3. 用 `_cluster/health` 验证连通性：

```
curl -sS -u "$ALIYUN_ES_USERNAME:$ALIYUN_ES_PASSWORD" \
  "$ALIYUN_ES_ENDPOINT_PROD/_cluster/health?pretty"
```

连不通九成是白名单没配对或公网没开，不是密码错。

## 常用只读查询

**列索引 / 别名**：排障第一步先看真实索引名和别名映射，reindex 期间名字会跳。

```
curl -sS -u "$ALIYUN_ES_USERNAME:$ALIYUN_ES_PASSWORD" \
  "$ALIYUN_ES_ENDPOINT_PROD/_cat/indices?v&s=index"

curl -sS -u "$ALIYUN_ES_USERNAME:$ALIYUN_ES_PASSWORD" \
  "$ALIYUN_ES_ENDPOINT_PROD/_cat/aliases?v"
```

**按 id 查文档**：最快确认"到底有没有这条记录"。

```
curl -sS -u "$ALIYUN_ES_USERNAME:$ALIYUN_ES_PASSWORD" \
  "$ALIYUN_ES_ENDPOINT_PROD/<index_or_alias>/_doc/<id>?pretty"
```

**body 搜索**：字段过滤 + 精确匹配，注意 keyword 后缀。

```
curl -sS -u "$ALIYUN_ES_USERNAME:$ALIYUN_ES_PASSWORD" \
  -H "Content-Type: application/json" \
  "$ALIYUN_ES_ENDPOINT_PROD/<alias>/_search?pretty" \
  -d '{
    "size": 5,
    "query": {
      "bool": {
        "filter": [
          { "term": { "creator_id.keyword": "<uid>" } },
          { "term": { "status.keyword": "published" } }
        ]
      }
    }
  }'
```

**计数**：

```
curl -sS -u "$ALIYUN_ES_USERNAME:$ALIYUN_ES_PASSWORD" \
  -H "Content-Type: application/json" \
  "$ALIYUN_ES_ENDPOINT_PROD/<alias>/_count" \
  -d '{ "query": { "term": { "field.keyword": "<value>" } } }'
```

**分词器验证**：排查中文关键词误命中时看真实切词。

```
curl -sS -u "$ALIYUN_ES_USERNAME:$ALIYUN_ES_PASSWORD" \
  -H "Content-Type: application/json" \
  "$ALIYUN_ES_ENDPOINT_PROD/<index>/_analyze" \
  -d '{ "field": "name", "text": "<待测文本>" }'
```

## Tipsy 关键索引

具体索引名以 `pkg/es` 下命名和运行时别名为准，**不要照抄记忆里的名字**。常见有 character 相关（trending / latest / hot 各自对应一个别名或独立索引）、search 相关。必须先 `_cat/aliases` 确认当前别名指向哪个物理索引，尤其在 reindex 窗口期，查错索引会误判"没同步"。

## 常见坑

1. **keyword vs text**：字符串字段默认同时存 `text`（分词）和 `<field>.keyword`（精确）。精确 filter / term 一律加 `.keyword`，不加会走分词导致命中不了或误命中。
2. **深分页 10000 天花板**：`from + size ≤ 10000`，超过必须换 `search_after` + `pit`，否则直接报 `search_phase_execution_exception`。排障基本用不到深分页，遇到就先 narrow query。
3. **reindex 期间别名跳变**：tipsy 会做 reindex 切别名，查前不 `_cat/aliases` 看清指向，可能查到旧索引数据，得出"数据没写进来"的错误结论。
4. **只读默认**：ES 没有 bytebase 拦截层，任何 `POST/PUT/DELETE` 都会真的写生产。真需要改数据走后端接口或 reindex 流程，不在本 skill 范围。

## Chrome 兜底：DMS / Kibana Dev Tools

如果公网没开、白名单加不了、或者要跑复杂 DSL，走阿里云 DMS：`$ALIYUN_DMS_ES_URL_PROD`，用 `nimbalyst-browser` MCP 打开（登录态命中后进 Kibana → Dev Tools），把上面的 body 复制进去直接执行。适合一次性排查，不适合脚本化 / 重复调用。

## 案例：角色在 trending 页消失，查 ES 是否同步

- 现象：创作者反馈自己角色几分钟前还在 trending，现在搜不到。
- 通道：ES REST（prod）+ `_cat/aliases`。
- 查询：先 `_cat/aliases` 看 trending 别名指向哪个物理索引（如 `character_v1_20260701`），再 `GET <alias>/_doc/<char_id>` 拿文档；发现 `visibility.keyword = "hidden"`、`nsfw_flag = true`，而 MySQL 里同一个 id 是 `published`。
- 结论：ES 侧字段被过滤规则命中导致隐藏，不是同步延迟。回到后端过滤逻辑排查 NSFW / Limitless 匹配，不是 ES 问题。参见项目记忆《角色可见性问题根因》里"精确匹配 bug"的历史教训，别把用户"消失了"直接翻译成"没同步"。

## 下一步 / 相关

- 主 SKILL：`../SKILL.md`（§0 决策树、§1 铁律的只读默认与环境隔离）
- MySQL / PG 查询走 `mysql-postgres.md`
- 记忆服务 API 走 `memory-direct.md`
- Redis 直连（R-KVStore OpenAPI）走 `redis.md`
- Chrome / DMS 兜底的通用形态见 nimbalyst-browser 兜底(SKILL.md §4)