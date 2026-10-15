#!/usr/bin/env node
// testdata/dsh_web_chat_drive.mjs — 用 CDP 驱动真 chromium：在 DSH 的界面里**打字**，
// 断言假网关的答复真的渲染进了对话区（`--dsh-web` 活会话那一腿的判据）。
//
// 为什么必须真按键盘：`session/prompt` 是宿主唯一**认识请求体**的那一面，而它由
// 浏览器在「用户提交 composer」时发出（`dsh-client-ui-conversation` 的 `send`）。
// 拿 curl 直接打那条 API 只验了宿主自己（`dshweb_*` 的裸探针就是这么做的），
// **验不到「页面上的输入框到底把什么发出去了」** —— 而那正是用户报的那件事。
//
// 做法：① 等 shell 挂载；② 找到 composer 的 textarea（DSH 的输入框）并聚焦；
// ③ 用 CDP 的 `Input.insertText` 打进一句**只可能来自假网关**的话（模型名当暗号）；
// ④ 按回车；⑤ 轮询对话区直到那句话出现。
//
// 用法：node testdata/dsh_web_chat_drive.mjs <CDP_WS_URL> <QUESTION> <ANSWER> [TOKEN]
//        QUESTION = 要打进去的那句（判「我打的字进了 composer」）
//        ANSWER   = 假网关会答的那句（判「答复经整条链回来并渲染出来」）
//        TOKEN   给了就先进一次 `/?token=<tok>` 种 cookie（绑非回环时的形态）
// 退出码：0 = 打字 → 提交 → 答复渲染出来了；1 = 有断言不成立（打印看到的文本）。

import WebSocket from '/home/winger/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/ws/index.js';

const [wsUrl, question, answer, token] = process.argv.slice(2);
if (!wsUrl || !question || !answer) {
  console.error('用法：node dsh_web_chat_drive.mjs <CDP_WS_URL> <QUESTION> <ANSWER> [TOKEN]');
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

// composer 的输入框：DSH 的 composer 是一个 contenteditable 或 textarea。
// 判据取「页面里最像输入框的那个」而不是写死选择器：DSH 的 class 名是构建期哈希
// （`EvIC1a_*` 这种），钉死它等于把判据绑在一次构建上 —— 换个版本就假红。
const FIND_INPUT = `(() => {
  const cands = [...document.querySelectorAll('textarea, [contenteditable="true"]')]
    .filter(e => e.offsetParent !== null);
  if (!cands.length) return null;
  const el = cands[0];
  el.setAttribute('data-uya-probe-input', '1');
  return true;
})()`;

const IS_FOCUSED = `(() => {
  const el = document.querySelector('[data-uya-probe-input]');
  return !!el && (document.activeElement === el || el.contains(document.activeElement));
})()`;

// 控制台消息（诊断用：失败时打印，帮定位「帧到了但没折出来」那类问题）。
const consoleMsgs = [];
const wsFrames = [];
function onConsole(m) {
  try {
    if (m.method === 'Runtime.consoleAPICalled') {
      const args = (m.params.args || []).map((a) => a.value ?? a.description ?? '').join(' ');
      consoleMsgs.push('[' + m.params.type + '] ' + args);
    } else if (m.method === 'Runtime.exceptionThrown') {
      const d = m.params.exceptionDetails || {};
      consoleMsgs.push('[exception] ' + (d.text || '') + ' '
        + ((d.exception && d.exception.description) || ''));
    } else if (m.method === 'Log.entryAdded') {
      const e = m.params.entry || {};
      consoleMsgs.push('[' + (e.level || '') + '] ' + (e.text || ''));
    }
  } catch { /* 诊断用，永不抛 */ }
}

ws.on('open', async () => {
  try {
    await send('Runtime.enable');
    await send('Page.enable');
    ws.on('message', (buf) => {
      try { onConsole(JSON.parse(buf.toString())); } catch { /* ignore */ }
    });
    // 收 WebSocket 的原始帧（诊断「帧到了但客户端判非法」用）：
    // `Network.webSocketFrameReceived` 会把服务端发出去的**原文**带回来。
    await send('Network.enable');
    ws.on('message', (buf) => {
      try {
        const m = JSON.parse(buf.toString());
        if (m.method === 'Network.webSocketFrameReceived') {
          const pl = (m.params && m.params.response && m.params.response.payloadData) || '';
          wsFrames.push(pl);
        }
      } catch { /* ignore */ }
    });
    const url = process.env.WIRE_PROBE_URL;
    // 带令牌时先进一次 `?token=`（宿主会 303 + 种 cookie），再回正常路径 ——
    // 这正是用户「把 URL 发给同事」的那条路。
    if (url && token) {
      await send('Page.navigate', { url: url + '?token=' + encodeURIComponent(token) });
      await sleep(1200);
    }
    if (url) {
      await send('Page.navigate', { url });
      await sleep(1500);
    }

    // ① 等 shell 挂载
    let mounted = false;
    for (let i = 0; i < 120; i++) {
      mounted = await evalJs(`!!document.querySelector('[data-slot="root"]')`);
      if (mounted) break;
      await sleep(250);
    }
    if (!mounted) { console.error('FAIL: shell 没挂载'); process.exit(1); }
    console.log('PASS shell 挂载');

    // ② 等输入框出现（会话选中之后 composer 才画出来）
    let found = null;
    for (let i = 0; i < 80; i++) {
      found = await evalJs(FIND_INPUT);
      if (found) break;
      await sleep(250);
    }
    if (!found) {
      console.error('FAIL: 找不到 composer 的输入框');
      console.error(await evalJs('document.body.innerText.slice(0,800)'));
      process.exit(1);
    }
    console.log('PASS composer 输入框在');

    // ③ 聚焦并打字（CDP 的 Input.insertText 走的是浏览器的输入事件 —— 与
    //    真人打字同一条路，所以 `input` / `beforeinput` 都照发）。
    await evalJs(`(() => {
      const el = document.querySelector('[data-uya-probe-input]');
      el.focus();
      return true;
    })()`);
    await sleep(300);
    const focused = await evalJs(IS_FOCUSED);
    if (!focused) {
      // 有些构建把焦点放在包裹元素上：再点一次拿焦点
      await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: 200, y: 200, button: 'left', clickCount: 1 });
      await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: 200, y: 200, button: 'left', clickCount: 1 });
      await sleep(200);
      await evalJs(`(() => {
        const el = document.querySelector('[data-uya-probe-input]');
        if (el) el.focus();
        return true;
      })()`);
      await sleep(200);
    }
    await send('Input.insertText', { text: question });
    await sleep(400);

    // ④ 回车提交。`Input.dispatchKeyEvent` 的两条（keyDown + char）都要发：
    //    只发 keyDown 时某些构建的 composer 不认（它等 `keypress`）。
    const keyOpts = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 };
    await send('Input.dispatchKeyEvent', { type: 'keyDown', ...keyOpts });
    await send('Input.dispatchKeyEvent', { type: 'char', text: '\r', ...keyOpts });
    await send('Input.dispatchKeyEvent', { type: 'keyUp', ...keyOpts });

    // ⑤ 等答复渲染出来（活会话要真跑一轮：网关是假的，但进程、日志、tail、
    //    推送都是真的 —— 所以给足时间）。
    // 判据两条，缺一不可：
    //   ① **我打的那句**出现在页面上 ⇒ 键盘输入真的进了 composer 并提交了；
    //   ② **假网关答的那句**出现在页面上 ⇒ 答复经「子进程 → 会话日志 → tail →
    //      活事件 → 页面」整条链回来了。
    // 只判 ② 会漏掉「输入根本没进去」；只判 ① 会漏掉「打进去没人接」——
    // 而后者正是用户报的那件事，也是这一腿存在的理由。
    // 读整页而不是某个 slot：实测 `[data-slot="conversation"]` 在真 chromium 里
    // 读到的是空串（消息挂在别的容器里），拿它当唯一判据会把「渲染对了」判成失败。
    let text = '';
    let haveQ = false;
    let haveA = false;
    let stableQ = 0;
    let stableA = 0;
    for (let k = 0; k < 200; k++) {
      text = (await evalJs('document.body.innerText')) || '';
      haveQ = text.includes(question);
      haveA = text.includes(answer);
      stableQ = haveQ ? stableQ + 1 : 0;
      stableA = haveA ? stableA + 1 : 0;
      if (stableQ >= 2 && stableA >= 2) break;   // 两条都连续两次读到 = 稳了
      await sleep(250);
    }

    console.log('我打的那句在页面上：' + haveQ);
    console.log('假网关的答复在页面上：' + haveA);
    if (!haveQ || !haveA) {
      console.error('--- 整页文本（前 1200 字）---');
      console.error((text || '').slice(0, 1200));
      console.error('--- 浏览器控制台（后 20 条）---');
      console.error(consoleMsgs.slice(-20).join('\n'));
      // 事件帧的 streamId 分布：与「客户端认的那条」比对（判「推给了死流」用）。
      const evSids = {};
      for (const f of wsFrames) {
        if (!f.includes('"type":"event"')) continue;
        const m = /"streamId":"([^"]+)"/.exec(f);
        if (m) evSids[m[1]] = (evSids[m[1]] || 0) + 1;
      }
      console.error('事件帧的 streamId 分布：' + JSON.stringify(evSids));
      const snapSids = {};
      for (const f of wsFrames) {
        if (!f.includes('"type":"snapshot"')) continue;
        const m = /"streamId":"([^"]+)"/.exec(f);
        if (m) snapSids[m[1]] = (snapSids[m[1]] || 0) + 1;
      }
      console.error('快照帧的 streamId 分布：' + JSON.stringify(snapSids));
      // 分类计数（比「后 8 条」有信息量：能一眼看出「服务端到底推没推 event 帧」）。
      const kinds = {};
      for (const f of wsFrames) {
        let k = 'other';
        if (f.includes('"type":"event"')) k = 'event';
        else if (f.includes('"type":"snapshot"')) k = 'snapshot';
        else if (f.includes('"type":"baseline"')) k = 'baseline';
        else if (f.includes('"type":"ready"')) k = 'ready';
        else if (f.includes('"type":"error"')) k = 'error';
        kinds[k] = (kinds[k] || 0) + 1;
      }
      console.error('WS 帧总数：' + wsFrames.length + ' 分类：' + JSON.stringify(kinds));
      console.error('--- 事件帧（前 4 条，各 200 字）---');
      console.error(wsFrames.filter((f) => f.includes('"type":"event"'))
        .slice(0, 4).map((f) => f.slice(0, 200)).join('\n'));
      console.error('FAIL: ' + (haveQ ? '答复没渲染出来' : '打的字没有进 composer'));
      process.exit(1);
    }
    console.log('PASS 打字 → 提交 → 答复渲染进了页面');
    process.exit(0);
  } catch (e) {
    console.error('FAIL: ' + (e && e.message ? e.message : String(e)));
    process.exit(1);
  }
});
