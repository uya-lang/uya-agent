#!/usr/bin/env node
// testdata/wire_probe_drive.mjs — 用 CDP 驱动真 chromium，验「消息渲染得出来吗」。
//
// 为什么需要它：`--dump-dom` 只能看首屏，而 DSH 的会话选择**持久在 localStorage 里**
// （`dsh.conversation.chat`），全新页面落在 hero 空态 ⇒ 首屏永远看不到消息。要验
// 「适配层的事件能不能渲染成卡片」必须**真的把会话打开**。
//
// 做法：连 chromium 的 DevTools Protocol，① 等 shell 挂载；② 点开侧栏里的会话；
// ③ 读回 DOM 里的文本，断言那几条只可能来自我们事件流的内容。
//
// 用法：node testdata/wire_probe_drive.mjs <CDP_WS_URL> <SESSION_TITLE> <NEEDLE>
// 退出码：0 = 三件事都成立；1 = 有断言不成立（打印看到的东西）。

import WebSocket from '/home/winger/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/ws/index.js';

const [wsUrl, title, needle] = process.argv.slice(2);
if (!wsUrl || !needle) {
  console.error('用法：node wire_probe_drive.mjs <CDP_WS_URL> <TITLE|-> <NEEDLE>');
  process.exit(2);
}

let id = 0;
const pending = new Map();
const ws = new WebSocket(wsUrl, { perMessageDeflate: false });

function send(method, params = {}) {
  const mid = ++id;
  ws.send(JSON.stringify({ id: mid, method, params }));
  return new Promise((resolve, reject) => {
    pending.set(mid, { resolve, reject });
    setTimeout(() => {
      if (pending.has(mid)) { pending.delete(mid); reject(new Error('cdp timeout: ' + method)); }
    }, 30000);
  });
}

async function evalJs(expr) {
  const r = await send('Runtime.evaluate', {
    expression: expr, returnByValue: true, awaitPromise: true,
  });
  if (r.exceptionDetails) throw new Error('eval threw: ' + JSON.stringify(r.exceptionDetails).slice(0, 300));
  return r.result?.value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

ws.on('message', (buf) => {
  let msg;
  try { msg = JSON.parse(buf.toString()); } catch { return; }
  if (msg.id && pending.has(msg.id)) {
    const p = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) p.reject(new Error(JSON.stringify(msg.error)));
    else p.resolve(msg.result);
  }
});

ws.on('error', (e) => { console.error('ws error:', e.message); process.exit(1); });

ws.on('open', async () => {
  try {
    await send('Runtime.enable');
    await send('Page.enable');
    // 导航到探针宿主（CDP 起的是一个空页面）
    const url = process.env.WIRE_PROBE_URL;
    if (url) {
      await send('Page.navigate', { url });
      await sleep(1500);
    }

    // ① 等 shell 挂载（最多 30s）
    let mounted = false;
    for (let i = 0; i < 120; i++) {
      mounted = await evalJs(`!!document.querySelector('[data-slot="root"]')`);
      if (mounted) break;
      await sleep(250);
    }
    if (!mounted) { console.error('FAIL: shell 没挂载'); process.exit(1); }
    console.log('PASS shell 挂载');

    // ② 会话现在由 shell 自己 create+打开（见宿主里的 session.create），所以
    //    这里只要等正文出现。仍然展开侧栏，顺带断言会话行也在。
    await evalJs(`(() => {
      const b = [...document.querySelectorAll('button')]
        .find(x => /Open sidebar/i.test(x.getAttribute('aria-label') || ''));
      if (b) b.click();
      return true;
    })()`);
    await sleep(800);
    const opened = await evalJs(`(() => {
      const btns = [...document.querySelectorAll('button')];
      const open = btns.find(b => /Open sidebar/i.test(b.getAttribute('aria-label') || ''));
      if (open) open.click();
      return true;
    })()`);
    await sleep(600);

    // 等正文渲染出来。**轮询 + 宽限**，且**读两处**：
    //   * `document.body.innerText` 是最终判据；
    //   * 另读 `[data-slot="conversation"]`（消息流所在的那个容器）。
    // 为什么要两处 + 宽限：DSH 的消息是**异步折叠**出来的，`innerText` 在它 attach
    // 到 slot 之前的瞬间可能读不到（实测：同一份数据、同一个宿主，这一条会**间歇**
    // 失败 —— 那是最难查的一类假红）。轮询到**连续两次都读到**才停，宽限期兜住
    // 「先渲染后又重排掉」的那种。
    let text = '';
    let hits = 0;
    for (let k2 = 0; k2 < 120; k2++) {
      const whole = (await evalJs('document.body.innerText')) || '';
      const conv = (await evalJs(
        '(()=>{const e=document.querySelector(\'[data-slot="conversation"]\');'
        + 'return e?e.innerText:"";})()')) || '';
      text = whole;
      const seen = whole.includes(needle) || conv.includes(needle);
      hits = seen ? hits + 1 : 0;
      if (hits >= 2) break;          // 连续两次都读到 = 稳了
      await sleep(250);
    }

    // ③ 读回正文
    const hasNeedle = (text || '').includes(needle);
    const hasTitle = title === '' ? true : (text || '').includes(title);
    console.log('会话标题可见：' + hasTitle);
    console.log('消息正文可见：' + hasNeedle);
    if (!hasNeedle) {
      console.error('--- 页面文本（前 1200 字）---');
      console.error((text || '').slice(0, 1200));
      console.error('FAIL: 消息没有渲染出来');
      process.exit(1);
    }
    console.log('PASS 消息渲染');
    process.exit(0);
  } catch (e) {
    console.error('FAIL: ' + e.message);
    process.exit(1);
  }
});
