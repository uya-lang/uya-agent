#!/usr/bin/env node
// testdata/dsh_web_model_drive.mjs — 「切模型之后请求真的打到另一家」那一腿的判据。
//
// 为什么判据是**假网关收到了什么**而不是页面上显示了什么：显示名是宿主自己画的，
// 而「界面变了、请求没变」正是这一族最典型的假绿（`dwhmodel.uya` 不变量③：
// 一次选择要落执行核与投影两处）。所以这里问两次、看两次答复：
//   ① 先在页面里打字问一句 ⇒ 答复必须是 `PROV-A-ANSWER`（初始路线是 A 家）；
//   ② 打 `session/selectModel` 切到 B 家的 `model-b`；
//   ③ 再问一句 ⇒ 答复必须是 `PROV-B-ANSWER`。
// 两句答复的文本不同（假网关按提供方给不同的话），所以「这一轮是谁答的」在
// 对话区里就是可读的事实。
//
// 用法：node dsh_web_model_drive.mjs <CDP_WS_URL> <BASE_URL> <GW_LOG>
// 退出码：0 = 三件事都成立；1 = 有断言不成立（打印看到的文本）。

import { readFileSync } from 'node:fs';
import WebSocket from '/home/winger/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/ws/index.js';

const [wsUrl, baseUrl, gwLog] = process.argv.slice(2);
if (!wsUrl || !baseUrl) {
  console.error('用法：node dsh_web_model_drive.mjs <CDP_WS_URL> <BASE_URL> [GW_LOG]');
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
  if (r.exceptionDetails) {
    throw new Error('eval threw: ' + JSON.stringify(r.exceptionDetails).slice(0, 300));
  }
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

// 会话 id：宿主只服务一条会话，id 是它自己的常量（`whost.uya` 的 DWH_SESSION_ID）。
const SESSION_ID = 'session-uya-0000-0000-0000-000000000001';

// 在页面里打字 + 回车（与 `dsh_web_chat_drive.mjs` 同一手法）。
async function typeAndSend(text) {
  await evalJs(`(() => {
    const cands = [...document.querySelectorAll('textarea, [contenteditable="true"]')]
      .filter(e => e.offsetParent !== null);
    if (!cands.length) return false;
    cands[0].setAttribute('data-uya-probe-input', '1');
    cands[0].focus();
    return true;
  })()`);
  await sleep(200);
  await send('Input.insertText', { text });
  await sleep(300);
  const keyOpts = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 };
  await send('Input.dispatchKeyEvent', { type: 'keyDown', ...keyOpts });
  await send('Input.dispatchKeyEvent', { type: 'char', text: '\r', ...keyOpts });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', ...keyOpts });
}

// 等整页文本里出现 `needle`（连续两次读到才算稳 —— 同 `wire_probe_drive.mjs`）。
// 读整页而不是某个 slot：实测 `[data-slot="conversation"]` 在真 chromium 里是
// 空串（消息挂在别的容器里），拿它当唯一判据会把「渲染对了」判成失败。
async function waitFor(needle) {
  let hits = 0;
  let txt = '';
  for (let k = 0; k < 160; k++) {
    txt = (await evalJs('document.body.innerText')) || '';
    if (txt.includes(needle)) hits += 1; else hits = 0;
    if (hits >= 2) return txt;
    await sleep(250);
  }
  return txt;
}

ws.on('open', async () => {
  try {
    await send('Runtime.enable');
    await send('Page.enable');
    const url = process.env.WIRE_PROBE_URL;
    if (url) {
      await send('Page.navigate', { url });
      await sleep(1500);
    }
    let mounted = false;
    for (let i = 0; i < 120; i++) {
      mounted = await evalJs(`!!document.querySelector('[data-slot="root"]')`);
      if (mounted) break;
      await sleep(250);
    }
    if (!mounted) { console.error('FAIL: shell 没挂载'); process.exit(1); }

    // ① A 家那一问
    await typeAndSend('PROV-A-QUESTION');
    let conv = await waitFor('PROV-A-ANSWER');
    if (!conv.includes('PROV-A-ANSWER')) {
      console.error('--- 页面文本（前 1000 字）---');
      console.error(conv.slice(0, 1000));
      console.error('FAIL: 第一问没有得到 PROV-A-ANSWER');
      process.exit(1);
    }
    console.log('PASS 第一问由 A 家答复');

    // ② 切到 B 家的 model-b（走宿主的 API：选择器那个浮层的 class 名是构建期
    //    哈希，钉死它就假红 —— 目录那一侧的渲染由第三腿与 web-models 轮保证）。
    const body = JSON.stringify({
      type: 'client-request', rpcId: 'model-drive-1', method: 'session/selectModel',
      payload: { args: { sessionId: SESSION_ID, provider: 'prov-b', model: 'model-b' } },
    });
    const resp = await evalJs(`fetch(${JSON.stringify(baseUrl + '/api/session/selectModel')}, {
      method: 'POST', headers: {'content-type': 'application/json'},
      body: ${JSON.stringify(body)},
    }).then(r => r.text())`);
    if (!resp || !resp.includes('"ok":true')) {
      console.error('FAIL: selectModel 没成功：' + String(resp).slice(0, 300));
      process.exit(1);
    }
    console.log('PASS selectModel 回 ok');

    // ③ B 家那一问
    await typeAndSend('PROV-B-QUESTION');
    conv = await waitFor('PROV-B-ANSWER');
    if (!conv.includes('PROV-B-ANSWER')) {
      console.error('--- 页面文本（前 1000 字）---');
      console.error(conv.slice(0, 1000));
      console.error('FAIL: 切过模型之后的那一问没由 B 家答复（请求还打在 A 家）');
      if (gwLog) {
        try {
          const lines = readFileSync(gwLog, 'utf8').split('\n').filter((l) => l.startsWith('GW-'));
          console.error('--- 假网关收到的（后 6 条）---');
          console.error(lines.slice(-6).join('\n'));
        } catch { /* 读不到就算了 */ }
      }
      process.exit(1);
    }
    console.log('PASS 切过模型之后由 B 家答复（请求真的换了一家）');
    process.exit(0);
  } catch (e) {
    console.error('FAIL: ' + (e && e.message ? e.message : String(e)));
    process.exit(1);
  }
});
