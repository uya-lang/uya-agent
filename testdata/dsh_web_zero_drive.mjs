#!/usr/bin/env node
// testdata/dsh_web_zero_drive.mjs — 零事件源那一路的**端到端**判据。
//
// 为什么单开一个驱动（不与 wire_probe_drive.mjs 合并）：那个的判据是
// 「某条消息**渲染出来了**」（正判据，要一个 needle）；这一条恰恰相反 ——
// 它要证的是「页面**没有**坏掉」，而坏掉时**没有 needle 可断言**：
// 用户现场（零参数跑 `--dsh-web`）的页面表现是 header 那一行红字
// 「加载会话历史失败」+ 控制台一串 `connection lost, retry`，正文本来就该是空的。
// 所以正判据只能是「合成器活着 + 那条红字不在 + 连接不重连」。
//
// 根因（实测）：快照 `records[]` 的逗号。零事件源时 seed 段自带收尾逗号、
// `session/end-seed` 又补一个 ⇒ `},,{` = 非法 JSON ⇒ 客户端
// `parseRemoteStreamServerMessage` 拒帧、`close(4002, 'invalid Remote stream
// frame')` ⇒ 每 3 秒重连一次。这一帧的**结构**由 `selftest[web-snapshot]` 离线判
// （拿本仓 JSON 解析器当 oracle）；本脚本判的是「用户真看到的那一屏」。
//
// 用法：WIRE_PROBE_URL=http://127.0.0.1:PORT/ node dsh_web_zero_drive.mjs <CDP_WS_URL>
// 退出码：0 = 三条都成立；1 = 有断言不成立（打印看到的东西）。

import WebSocket from '/home/winger/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/ws/index.js';

const wsUrl = process.argv[2];
if (!wsUrl) {
  console.error('用法：WIRE_PROBE_URL=… node dsh_web_zero_drive.mjs <CDP_WS_URL>');
  process.exit(2);
}

// 页面上出现这条 = 快照被客户端拒了（`chat.loadError` 的渲染，见 dsh-client-ui-chat）。
const BAD = 'Failed to load history';
// 合成器活着 = 会话真的被选中、对话区挂上了（零事件源时正文为空是**对的**）。
const ALIVE = 'Message or run a task';

let id = 0;
const pending = new Map();
const consoleLines = [];
const ws = new WebSocket(wsUrl, { perMessageDeflate: false });

function send(method, params = {}) {
  const mid = ++id;
  ws.send(JSON.stringify({ id: mid, method, params }));
  return new Promise((resolve, reject) => {
    pending.set(mid, { resolve, reject });
    setTimeout(() => {
      if (pending.has(mid)) {
        pending.delete(mid);
        reject(new Error('cdp timeout: ' + method));
      }
    }, 30000);
  });
}

async function evalJs(expr) {
  const r = await send('Runtime.evaluate', {
    expression: expr, returnByValue: true, awaitPromise: true,
  });
  if (r.exceptionDetails) {
    throw new Error('eval threw: ' + JSON.stringify(r.exceptionDetails).slice(0, 300));
  }
  return r.result?.value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

ws.on('message', (buf) => {
  let msg;
  try { msg = JSON.parse(buf.toString()); } catch { return; }
  const p = msg.params || {};
  if (msg.method === 'Runtime.consoleAPICalled') {
    consoleLines.push(p.args.map((a) => String(a.value ?? a.description ?? '')).join(' '));
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    consoleLines.push('EXCEPTION ' + String((p.exceptionDetails || {}).text || ''));
  }
  if (msg.id && pending.has(msg.id)) {
    const q = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) q.reject(new Error(JSON.stringify(msg.error)));
    else q.resolve(msg.result);
  }
});

ws.on('error', (e) => { console.error('ws error:', e.message); process.exit(1); });

ws.on('open', async () => {
  try {
    await send('Runtime.enable');
    await send('Page.enable');
    await send('Page.navigate', { url: process.env.WIRE_PROBE_URL });

    // ① 等 shell 挂载（最多 30s）：这一步保证「页面起得来」不是本脚本的判据，
    //    而是后面两条的前提。
    let mounted = false;
    for (let i = 0; i < 120; i++) {
      mounted = await evalJs(`!!document.querySelector('[data-slot="root"]')`);
      if (mounted) break;
      await sleep(250);
    }
    if (!mounted) { console.error('FAIL: shell 没挂载'); process.exit(1); }
    console.log('PASS shell 挂载');

    // ② 等合成器出现（会话被选中 + 对话区建起来）。**轮询**：DSH 选会话是异步的。
    let text = '';
    let alive = false;
    for (let i = 0; i < 120; i++) {
      text = (await evalJs('document.body.innerText')) || '';
      if (text.includes(ALIVE)) { alive = true; break; }
      await sleep(250);
    }
    console.log('合成器可见：' + alive);
    if (!alive) {
      console.error('--- 页面文本（前 900 字）---');
      console.error(text.slice(0, 900));
      console.error('FAIL: 合成器没出现（会话可能没选中）');
      process.exit(1);
    }

    // ③ 那条红字**不许在**。宽限 6 秒再读一次：客户端是「先渲染、拿到坏帧后
    //    再替换成错误行」的顺序，读早了会假绿（实测：T+4s 干净、T+8s 才红）。
    let badSeen = text.includes(BAD);
    for (let i = 0; i < 24 && !badSeen; i++) {
      await sleep(250);
      const again = (await evalJs('document.body.innerText')) || '';
      if (again.includes(BAD)) { badSeen = true; text = again; }
    }
    console.log('加载历史报错：' + badSeen);
    if (badSeen) {
      console.error('--- 页面文本（前 900 字）---');
      console.error(text.slice(0, 900));
      console.error('FAIL: 零事件源时页面报了「加载历史失败」');
      process.exit(1);
    }

    // ④ 连接不许反复重连（坏帧的症状是每 3 秒一轮 `connection lost`）。
    //    读**整段** console：重连发生在早期，晚读也还在。
    const lost = consoleLines.filter((l) => /connection lost/.test(l)).length;
    console.log('connection lost 次数：' + lost);
    if (lost > 0) {
      console.error('--- 控制台（前 20 行）---');
      for (const l of consoleLines.slice(0, 20)) console.error(l);
      console.error('FAIL: 连接反复重连（快照帧被拒的典型症状）');
      process.exit(1);
    }

    console.log('PASS 零事件源的页面');
    process.exit(0);
  } catch (e) {
    console.error('FAIL: ' + (e && e.message ? e.message : String(e)));
    process.exit(1);
  }
});
