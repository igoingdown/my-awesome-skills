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
