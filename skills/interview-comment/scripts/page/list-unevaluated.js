// page/list-unevaluated.js — 拉取飞书招聘「我的任务 → 面试 → 未评价」列表。
// 供 hire-patrol 巡检使用（列表扫描），与候选人评估共用 chrome-eval 引擎。
// 需在飞书招聘任意已登录页执行（浏览器自动带 cookie）。
// 返回 JSON：{ ok:true, total, list:[{name, talent_id, application_id, round}] }  或
//           { ok:false, reason:"not_json" }（登录态失效，接口回退 HTML）
//
// activity_status: 1=未开始 2=未评价 3=已评价。POST 必须带全字段，空 body 会返回 HTML。
const out = [];
let offset = 0;
const limit = 20;
let total = 0;
while (true) {
  const r = await fetch("/atsx/api/interview/list_v2/", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ q: "", filters: "{}", activity_status: 2, offset, limit, time_zone: "Asia/Shanghai" }),
  });
  const txt = await r.text();
  let j;
  try { j = JSON.parse(txt); } catch (e) { return { ok: false, reason: "not_json" }; } // 登录态失效
  const arr = (j.data && j.data.interview_list) || [];
  total = (j.data && j.data.total_count) || total;
  for (const it of arr) {
    out.push({
      name: (it.talent && it.talent.name) || null,
      talent_id: it.talent_id || (it.talent && it.talent.id) || null,
      application_id: it.application_id || null,
      round: it.round != null ? it.round : null,
    });
  }
  if (arr.length < limit) break; // 取完
  offset += limit;
}
return { ok: true, total, list: out };
