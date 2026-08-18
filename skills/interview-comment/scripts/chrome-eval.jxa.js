// chrome-eval.jxa.js — 在指定 Chrome 标签页里执行一段（可能是 async 的）页面 JS，取回结果。
//
// 这是本 skill 所有浏览器自动化的唯一底层原语：定位标签页 + 注入 async JS + 轮询 + 分片取回。
// 用 base64 传页面 JS，规避 osascript 的引号/换行/UTF-8 转义地狱（页面 JS 可自由含中文与引号）。
//
// 调用（一般由 chrome-eval.sh 包装，不直接手调）：
//   osascript -l JavaScript chrome-eval.jxa.js <url-substring> <base64-of-page-js> [timeoutSec]
//
// 页面 JS 约定：可用顶层 await、可 return 值。返回字符串原样取回；返回对象自动 JSON.stringify。
// 退出码/输出：命中并成功 → stdout 为结果字符串；否则 stdout 为 NOT_FOUND / ERR:<stack> / TIMEOUT。
function run(argv) {
  const urlSub = argv[0];
  const b64 = argv[1];
  const timeoutSec = argv[2] ? parseFloat(argv[2]) : 30;

  const chrome = Application("Google Chrome");
  if (!chrome.running()) return "ERR:Chrome not running";

  // 1) 遍历所有窗口/标签，按 URL 子串精确定位（不用 active tab of front window）
  const wins = chrome.windows;
  let W = -1, T = -1;
  for (let i = 0; i < wins.length && W < 0; i++) {
    const tabs = wins[i].tabs;
    for (let j = 0; j < tabs.length; j++) {
      let u = "";
      try { u = tabs[j].url() || ""; } catch (e) {}
      if (u.indexOf(urlSub) !== -1) { W = i; T = j; break; }
    }
  }
  if (W < 0) return "NOT_FOUND";

  // 命中的标签置前，方便需要焦点的操作（如 Monaco 全选复制）
  try { chrome.windows[W].visible = true; chrome.windows[W].index = 1; wins[W].activeTabIndex = T + 1; } catch (e) {}
  const tab = chrome.windows[W].tabs[T];

  // 2) 把页面 JS 包进 async IIFE，结果/错误挂到 window，供轮询读取
  const inject =
    '(function(){' +
    'var by=Uint8Array.from(atob("' + b64 + '"),c=>c.charCodeAt(0));' +
    'var src=new TextDecoder("utf-8").decode(by);' +
    'window.__CHDONE=false;window.__CHERR=null;window.__CHOUT="";' +
    'Promise.resolve((new Function("return (async ()=>{"+src+"})()"))())' +
    '.then(function(v){window.__CHOUT=(typeof v==="string")?v:JSON.stringify(v);window.__CHDONE=true;})' +
    '.catch(function(e){window.__CHERR=String((e&&e.stack)||e);window.__CHDONE=true;});' +
    'return "started";})()';
  try { tab.execute({ javascript: inject }); } catch (e) { return "ERR:inject failed: " + e; }

  // 3) 轮询完成，分片取回（osascript 单次返回有长度限制，按 5 万字符/片）
  const steps = Math.ceil(timeoutSec / 0.3);
  for (let k = 0; k < steps; k++) {
    delay(0.3);
    let st = "";
    try {
      st = tab.execute({ javascript: 'window.__CHDONE?(window.__CHERR?"E":"D:"+window.__CHOUT.length):"P"' });
    } catch (e) { st = "P"; } // 页面导航中读不到，继续等
    if (st.charAt(0) === "D") {
      const len = parseInt(st.slice(2), 10);
      let out = "";
      for (let s = 0; s < len; s += 50000) {
        out += tab.execute({ javascript: 'window.__CHOUT.slice(' + s + ',' + (s + 50000) + ')' });
      }
      return out;
    }
    if (st.charAt(0) === "E") {
      return "ERR:" + tab.execute({ javascript: 'window.__CHERR' });
    }
  }
  return "TIMEOUT";
}
