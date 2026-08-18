// page/probe.js — 阶段 0.15 前置探针。在候选人页里跑，一次判定本轮材料形态。
// 由 chrome-eval.sh 注入执行，返回 JSON。调用方据此决定 0.2/0.3/0.4 走哪条分支。
//
// 输出字段：
//   talent_id, application_id
//   resume:  "pdf" | "image" | "standard" | "other:<name>" | "fetch_err:<msg>"
//   att_name: 附件文件名（无附件为 null）
//   asr:     "ready" | "not_ready"      面试速记入口是否存在
//   coding:  "yes" | "no"               是否有「代码考核」卡片
const tid = (location.pathname.match(/talent\/(\d+)/) || [])[1] || null;
const aid = new URLSearchParams(location.search).get("application_id");

let resume = "unknown", att = null;
try {
  const r = await fetch(
    "/atsx/api/application/get_default_resume/?talent_id=" + tid + "&application_id=" + aid,
    { headers: { "content-type": "application/json" } }
  );
  const j = await r.json();
  att = (j.data && j.data.default_attachment) || null;
  if (att && att.name) {
    const n = att.name.toLowerCase();
    if (n.endsWith(".pdf")) resume = "pdf";
    else if (/\.(png|jpe?g|webp)$/.test(n)) resume = "image";
    else resume = "other:" + att.name;
  } else {
    resume = "standard";
  }
} catch (e) {
  resume = "fetch_err:" + e;
}

// 速记：文本锚点优先（飞书 class 是哈希化的，不可靠）
const asrEntry = Array.from(document.querySelectorAll("*"))
  .some(e => e.children.length === 0 && (e.textContent || "").trim() === "面试速记");

// 代码考核卡片：正向信号（不要用 meeting_coding_status 会中状态接口）
const coding = (document.body.innerText || "").includes("代码考核");

return {
  talent_id: tid,
  application_id: aid,
  resume,
  att_name: att && att.name,
  asr: asrEntry ? "ready" : "not_ready",
  coding: coding ? "yes" : "no",
};
