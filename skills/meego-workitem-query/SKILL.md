---
name: meego-workitem-query
description: 经 tool-bridge 网关的 mcp/meego 查询飞书项目(Meego)工作项——按人/按时间/按角色筛需求和缺陷、查工作项状态与详情、加评论。使用时：用户想查"我本周要关注的需求/bug"、"某人参与的工作项"、"这个 bug 什么状态"、按 MQL 搜工作项、给工作项加评论时触发。依赖 tool-bridge SK（secrets.sh 注入），空间配置见 secrets.example.sh。
---

# Meego 工作项查询（经 tool-bridge）

经团队 tool-bridge 网关的 `mcp/meego` 源查询飞书项目(Meego)的需求/缺陷，支持按参与人、时间窗、角色筛选，查状态详情，加评论。**全部知识来自逐条实测**，不是抄文档。

## 前置

- tool-bridge SK 已配（`TB_BASE_URL`/`TB_SK` 在 secrets.sh）。换取 SK 的步骤见 `secrets.example.sh`（浏览器登录 `$TB_BASE_URL/login`）。
- 本 skill 的空间配置在 secrets.sh（`MEEGO_PROJECT_KEY`/`MEEGO_PROJECT_SIMPLE_NAME`，见 `secrets.example.sh`）。
- 通用调用器 `tb_call.sh` 随本 skill 自带（纯 curl，无额外依赖），不依赖其它 skill 目录。

## 两个入口，身份模型完全不同（先搞清再用）

| 入口 | 身份 | 现状 |
|---|---|---|
| `mcp/meego`（本 skill 用这个） | **固定挂载身份**（某位同事，`search_user_info` 传 `["current_login_user()"]` 可查是谁） | 开箱可用，无需绑定 |
| `plugins/meego` | 调用方绑定身份（谁调用显示谁） | 需管理员在网关 `providerConfig.userKeys` 绑你的 SK↔user_key，未绑则连只读都 permission_denied |

**推论**：经 `mcp/meego` 的写操作（评论/建工作项）落地署名是**固定挂载身份，不是你**。要以本人身份操作 → 找管理员走 plugins/meego 绑定。`current_login_user()` 在 MQL 里恒等于固定挂载身份——**查"参与人里有我"必须先反查你自己的 user_key**（见下）。

## 核心流程

### 0. project_key 从哪来

本 MCP **没有列空间的工具**（官方 help 明说"不要猜"）。来源只有两个：
- Meego 网页 URL：`https://project.feishu.cn/<simple_name>/...` 路径里的 simple_name，或空间设置里的 project_key。
- 团队约定：常用空间的 key 记在 secrets.sh 的 `MEEGO_PROJECT_KEY`。

### 1. 反查任意人的 user_key

```bash
TB="bash tb_call.sh"
$TB call mcp/meego/search_user_info '{"project_key":"'$MEEGO_PROJECT_KEY'","user_keys":["<中文姓名>"]}'
# 返回 user_key / name_cn / lark_user_id。姓名、邮箱、user_key 都能当查询键。
```

### 2. MQL 查工作项（search_by_mql）

```sql
SELECT `名称`, `状态`, `更新时间` FROM `<project_key>`.`需求`
WHERE RELATIVE_DATETIME_BETWEEN(`更新时间`, 'past', '7d')
  AND array_contains(all_participate_persons(), '<id:USER_KEY>')
ORDER BY `更新时间` DESC LIMIT 30
```

**实测铁律（每条都踩过坑）：**

- **FROM 用 project_key 当空间名**。空间显示名（如 "XX 项目空间"）会报 `project label does not exist`。
- **字段 label 因工作项类型而异，禁止跨类型套用**：需求标题=`` `名称` ``，缺陷标题=`` `缺陷名称` ``（用`名称`报 attr label not found）。
- **本空间没有 `创建时间`，只有 `更新时间`**（key=updated_at）。"近一周"语义用更新时间反而更贴合"需要关注"。
- **`工作项ID`/`状态` 在缺陷类型的 MQL 里 label 不认**——拿 ID 和状态走 `get_workitem_brief`（见下），别在 MQL 里硬试。
- **userkey 匹配用 `<id:xxx>` 格式**：`array_contains(all_participate_persons(), '<id:7654...541>')`。
- **`all_participate_persons()` 是全部角色参与人的并集**，已覆盖研发/研发负责人/QA 等（实测：按角色单查的结果 ⊆ 参与人并集）。角色字段 `__角色名` 写法对部分角色报 label not found，优先用参与人并集。
- 字段名全部反引号包裹；字符串单引号；相对时间 `RELATIVE_DATETIME_BETWEEN(字段,'past','7d')`。

**探索未知空间的字段名**：先 `SELECT` 单个候选字段 `LIMIT 1` 试错（报错会说 attr label not found），或 `get_workitem_field_meta`（注意参数名是 `work_item_type` **不是** `work_item_type_key`，传错静默返回空；且它只返回自定义字段，不含状态/时间等系统字段）。

### 3. 拿工作项 ID / 状态 / 角色成员（get_workitem_brief）

```bash
$TB call mcp/meego/get_workitem_brief '{"project_key":"...","work_item_type_key":"issue","name":"<工作项标题>"}'
# 返回 work_item_id、work_item_status（{key:"IN PROGRESS",name:"进行中"}）、
# role_members（各角色成员及 user_key）、create/update_time。work_item_id 和 name 二选一传。
```

状态、ID、"这个 bug 压在谁手上"全从这里拿——这是比 MQL 更稳的权威源。

### 4. 加评论（add_comment，写操作）

```bash
$TB call mcp/meego/add_comment '{"project_key":"...","work_item_id":"<数字ID>","action":"create","content":"..."}'
```

- **work_item_id 必须传真实数字 ID**。schema 说"id或者名称"，实测传名称报 `biz not match workitem`——先用 get_workitem_brief 换 ID。
- 写操作署名是**固定挂载身份**。发前确认用户同意；测试用途注明"可忽略"字样。
- 验证评论已落：`list_workitem_comments`（**不是** `list_comments`，那是 plugins/meego 的工具名）。

### 5. 详情页链接（接口不返回，按格式拼）

接口全链路不返回 URL（brief/fields=_all 都没有）。格式（从真实链接确认）：

```
https://project.feishu.cn/<simple_name>/<issue|story>/detail/<work_item_id>
```

`?parentUrl=...&openScene=...` 是视图上下文参数，可省略。

## 返回体解析（必读，三层嵌套坑）

`mcp/meego` 经 tb_call.sh 的返回是：**```json 围栏 → JSON 字符串 → 字符串体是真 JSON 但尾部拼了 ` log_id: xxx`**。直接 `json.loads` 报 "Extra data"。正确解法（`scripts/parse_meego.py` 已封装）：

1. 剥 ``` 围栏；2. `json.loads` 得字符串；3. **截到最后一个 `}`** 再 loads；4. 错误返回是 `id=..., code=..., message=...` 开头的纯文本，先判再 parse。

```bash
$TB call mcp/meego/search_by_mql '<args>' | python3 scripts/parse_meego.py rows   # 摘要行
$TB call mcp/meego/search_by_mql '<args>' | python3 scripts/parse_meego.py fields # 列字段名
```

## 已验证的工具速查（实测过的）

| 工具 | read/write | 备注 |
|---|---|---|
| `search_user_info` | read | 姓名/邮箱/user_key 反查；`current_login_user()` = 固定挂载身份 |
| `search_by_mql` | read | 主查询入口，必传 project_key；分页走 session_id |
| `get_workitem_brief` | read | ID/状态/角色成员的权威源；参数 name 或 work_item_id |
| `get_workitem_field_meta` | read | 参数名 `work_item_type`；只返回自定义字段 |
| `list_workitem_types` | read | 类型 key：story=需求 issue=缺陷 |
| `list_workitem_role_config` | read | 角色清单（研发负责人/研发/QA负责人...） |
| `list_workitem_comments` | read | 验证评论；别和 plugins 侧 list_comments 混 |
| `add_comment` | **write** | 需数字 ID；署名=固定挂载身份；发前须用户确认 |

其余 30+ 工具（create_workitem/update_field/transition_state/WBS 系列）未实测，写操作调用前必读 `~help` 并让用户确认。

## 配置（敏感值全走 secrets，不进仓库）

| 变量 | 说明 |
|---|---|
| `TB_BASE_URL` / `TB_SK` | tool-bridge 网关凭据（已有） |
| `MEEGO_PROJECT_KEY` | 默认空间的 project_key |
| `MEEGO_PROJECT_SIMPLE_NAME` | 空间 simple_name（拼详情页 URL 用） |

参考 `secrets.example.sh`。真实 project_key、user_key、姓名、租户域名**绝不写进本仓库任何文件**。
