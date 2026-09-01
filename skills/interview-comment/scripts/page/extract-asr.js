// page/extract-asr.js — 抽取「面试速记」全量文字记录，返回结构化 JSON（chrome-eval 分片取回）。
// 前置：探针已判 asr=ready。本文件先点开速记入口、滚到底确认全量，再遍历消息块。
// 选择器策略：文本/结构锚点优先，哈希化 class 仅作辅助（class 会随飞书版本失效）。
// 返回 JSON：{ ok:true, count, speakers:[...], items:[{speaker, time, text}] }  或  { ok:false, reason }

// 1) 定位速记面板：旧 class 优先，失效则找"含最多消息块的滚动容器"
function findPanel() {
  let p = document.querySelector("[class*=tertiaryContainer]");
  if (p) return p;
  // 兜底：挑一个 scrollHeight 明显大于自身、且含多个"说话人+时间戳"块的容器
  const cands = Array.from(document.querySelectorAll("div"))
    .filter(d => d.scrollHeight > d.clientHeight + 100);
  cands.sort((a, b) => b.scrollHeight - a.scrollHeight);
  return cands[0] || document.body;
}
function sectionsIn(p) {
  return p ? Array.from(p.querySelectorAll("[class*=section__]")) : [];
}

// 2) 面板已渲染出内容就不要再点入口——入口是 toggle，重复点会把已展开的面板关掉
if (sectionsIn(findPanel()).length === 0) {
  let entry = Array.from(document.querySelectorAll("*"))
    .find(e => e.children.length === 0 && (e.textContent || "").trim() === "面试速记");
  if (!entry) entry = Array.from(document.querySelectorAll("[class*=minutes]"))
    .find(e => (e.textContent || "").trim() === "面试速记");
  if (!entry) return { ok: false, reason: "no_asr_entry" }; // 二次兜底：探针可能漏判
  entry.click();
}

// 3) 轮询等到条数出现并连续稳定 3 次。固定 sleep 不够：面板渲染慢时 findPanel 会
//    在 tertiaryContainer 还没挂上时兜底选中别的滚动容器，抽出 0 条误报 not_ready。
let panel = null, secs = [], prev = -1, stable = 0;
for (let i = 0; i < 40; i++) {
  await new Promise(r => setTimeout(r, 500));
  panel = findPanel();
  secs = sectionsIn(panel);
  if (secs.length > 0 && secs.length === prev) { if (++stable >= 3) break; } else stable = 0;
  prev = secs.length;
}
if (!secs.length) return { ok: false, reason: "empty_after_wait" };

// 4) 滚到底确认全量（观察为全量渲染，但必须验证条数稳定）
function sections() {
  let s = panel.querySelectorAll("[class*=section__]");
  if (s.length) return Array.from(s);
  // 兜底：找同时含"时间戳 + 文本"的重复块
  return Array.from(panel.querySelectorAll("div"))
    .filter(d => d.children.length && /\d{1,2}:\d{2}/.test(d.textContent || ""));
}
let last = -1;
for (let i = 0; i < 12; i++) {
  panel.scrollTop = panel.scrollHeight;
  await new Promise(r => setTimeout(r, 500));
  const n = sections().length;
  if (n === last) break;
  last = n;
}

// 5) 遍历消息块，抽 speaker / time / text
function pick(el, hints) {
  for (const h of hints) { const x = el.querySelector(h); if (x && (x.textContent || "").trim()) return x.textContent.trim(); }
  return "";
}
const items = [];
for (const sec of sections()) {
  const nameRaw = pick(sec, ["[class*=name__]", "[class*=employee-label]"]);
  const sub = pick(sec, ["[class*=subInfo__]"]);
  const time = ((sub || sec.textContent || "").match(/(\d{1,2}:\d{2})/) || [])[1] || "";
  let text = pick(sec, ["[class*=content__]"]);
  if (!text) {
    // 兜底：去掉说话人和时间戳后的剩余文本
    text = (sec.textContent || "").replace(nameRaw, "").replace(/\d{1,2}:\d{2}/, "").trim();
  }
  const speaker = nameRaw || (sub || "").replace(/\d{1,2}:\d{2}.*$/, "").trim();
  if (text) items.push({ speaker, time, text });
}
if (!items.length) return { ok: false, reason: "empty_after_extract" };
const speakers = [...new Set(items.map(i => i.speaker).filter(Boolean))];
return { ok: true, count: items.length, speakers, items };
