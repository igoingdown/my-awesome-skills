# my-awesome-skills

A collection of awesome skills built for Claude Code.

## Installation

Clone the repository and install dependencies:

```bash
git clone https://github.com/igoingdown/my-awesome-skills.git
cd my-awesome-skills
npm install
```

## Usage

Each skill lives under `skills/`. Install a skill by placing its directory into your Claude Code skills folder.

## Skills

### OpenRouter Balance

Query OpenRouter account balance and send Feishu notification.

使用说明：[skills/openrouter-balance/README.md](skills/openrouter-balance/README.md)

### Interview Comment

面向**后端/算法/大数据研发**岗位的严格面试评价生成器：
- 固定目录结构：`<人名>/001 002 003 .../`，每轮一个子目录
- 固定文件命名：`resume.png`（简历）/ `asr.md`（语音转文字）/ `review-res.md`（其他面试官评价文本）
- 五维定性判断（业务理解/技术支撑/技术广度/技术深度/软素质），每维 `+`/`=`/`-` 标注
- 七档综合评分（2.5 / 2.75 / 3 / 3.25 / 3.5 / 3.75 / 4），**3+ = ≥3.25 通过**
- 跨轮交叉参考：自动读取其他轮次 `review-res.md`，对本轮独立判断做**补充 + 校正**（先独立再参考、分歧时证据驱动 + 严格优先）
- 证据驱动：每个标注、优点、风险都引用 `asr.md` 原话或简历原文
- 严格机制：borderline 一律按低档打（3 和 3.25 之间犹豫 → 打 3 不通过）
- 输出：`<人名>/<目标轮>/evaluation.md`（按团队模板结构化）

使用示例：在 Claude Code 里说
> "评估 `~/interviews/zhang-san`，我做的是 2 面"

使用说明：[skills/interview-comment/SKILL.md](skills/interview-comment/SKILL.md)

### Family Travel Planner

带宠物家庭自驾旅行规划工具，支持：
- 避峰日期推荐（基于 GaoDe API + 拥堵系数）
- 自驾方案（路线规划 + 充电计划 + 区域住宿推荐 + 景点推荐）
- 火车方案（宠物乘车/托运政策调研）
- 方案对比（6维度对比表：耗时/成本/宠物压力/灵活度/政策风险/避峰难度）
- 避峰评估（拥堵降低 X% ±15%）

使用示例：
```bash
cd skills/family-travel-planner
npm install && npm run build
cp .env.example .env
# 编辑 .env，填入 GaoDe API Key
npm start -- --origin 北京 --destination 大连 --days 5 --holiday 五一
```

集成 OpenClaw 后，可在飞书上直接说：
> "帮我规划五一北京到大连的旅行，带狗，开 Model Y"

技术栈：TypeScript + GaoDe Map API + OpenClaw

使用说明：[skills/family-travel-planner/README.md](skills/family-travel-planner/README.md)

## License

MIT
