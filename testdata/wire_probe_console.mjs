// testdata/wire_probe_console.mjs — 连上 CDP，把页面的 console 与未捕获异常打出来。
//
// 为什么需要它：**「页面只是空」这类故障在页面文本里没有线索**（`--dump-dom` 也是），
// 唯一的地方是浏览器控制台与异常。本仓在 P80 上两次靠它定位（少了 session.create、
// WS 丢连接后 shell 卡住）。
// 用法：WIRE_PROBE_URL=http://... node wire_probe_console.mjs <CDP_WS_URL>
import WebSocket from '/home/winger/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/ws/index.js';

const wsUrl = process.argv[2];
let id = 0;
const pending = new Map();
const lines = [];
const ws = new WebSocket(wsUrl, { perMessageDeflate: false });
const send = (m, p = {}) => {
  const i = ++id;
  ws.send(JSON.stringify({ id: i, method: m, params: p }));
  return new Promise((res, rej) => {
    pending.set(i, { res, rej });
    setTimeout(() => { if (pending.has(i)) { pending.delete(i); rej(new Error('timeout ' + m)); } }, 20000);
  });
};
ws.on('message', (b) => {
  let m; try { m = JSON.parse(b.toString()); } catch { return; }
  const p = m.params || {};
  if (m.method === 'Runtime.consoleAPICalled') {
    lines.push(p.type + ': ' + p.args.map((a) => String(a.value ?? a.description ?? '')).join(' '));
  }
  if (m.method === 'Runtime.exceptionThrown') {
    lines.push('EXCEPTION: ' + String((p.exceptionDetails || {}).text || '').slice(0, 200));
  }
  if (m.id && pending.has(m.id)) {
    const q = pending.get(m.id); pending.delete(m.id);
    m.error ? q.rej(new Error(JSON.stringify(m.error))) : q.res(m.result);
  }
});
ws.on('open', async () => {
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Page.navigate', { url: process.env.WIRE_PROBE_URL });
  await new Promise((r) => setTimeout(r, 9000));
  console.log('--- console ---');
  for (const l of lines.slice(0, 15)) console.log(l);
  console.log('--- total: ' + lines.length);
  process.exit(0);
});
ws.on('error', (e) => { console.error('ws ' + e.message); process.exit(1); });
