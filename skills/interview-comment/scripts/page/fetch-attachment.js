// page/fetch-attachment.js — 拉取候选人默认简历附件，返回 base64（chrome-eval 会分片取回）。
// 用于 0.2 简历采集的 pdf / image 两路。standard（无附件）路不走这里，改截图。
// 返回 JSON：{ name, mime, b64 }  或  { error: "<msg>" }
const tid = (location.pathname.match(/talent\/(\d+)/) || [])[1] || null;
const aid = new URLSearchParams(location.search).get("application_id");
try {
  const meta = await (await fetch(
    "/atsx/api/application/get_default_resume/?talent_id=" + tid + "&application_id=" + aid,
    { headers: { "content-type": "application/json" } }
  )).json();
  const att = meta.data && meta.data.default_attachment;
  if (!att || !att.url) return { error: "no attachment (可能是 standard 简历，走截图路)" };
  const blob = await (await fetch(att.url)).blob();
  const b64 = await new Promise((res, rej) => {
    const fr = new FileReader();
    fr.onload = () => res(String(fr.result).split(",")[1]); // 去掉 data:...;base64, 前缀
    fr.onerror = rej;
    fr.readAsDataURL(blob);
  });
  return { name: att.name, mime: blob.type, b64 };
} catch (e) {
  return { error: String(e) };
}
