#!/usr/bin/env python3
"""wire_probe_host.py — 阶段 0 探针：用**不改动的 DSH dist** 起一个最小宿主。

目的是**证伪**（而不是证明）「DSH 的 webui 能当本仓的前端」这件事。它做四件事：
  ① 只读服务 DSH 自己装的那份 `dsh-web-frontend/dist`（一个字节都不改）；
  ② 复刻 DSH 的 `bootInjections()`：内联 queue 脚本 + 两个 parser-blocking preload
     + `window.__DSH_BOOT__` 全局，插在 `<head>` 开标签之后；
  ③ 服务最小 roster 的 `/plugins/<id>/client.js`（14 个包，从 DSH 的 node_modules 读）；
  ④ 把 `/api/*` 接到一份**离线**的会话数据上（本仓 `--selftest --wire-dump` 的译文 +
     合成出来的 session.list/history），两条下行用 WebSocket（**只发不收**）。

**它故意不实现**：真实的多会话执行、prompt 回路、附件、设置面 —— 那些是「接入」的
正题，而这一步只回答「界面能不能起来、消息能不能渲染出卡片」。

用法：
  python3 testdata/wire_probe_host.py [--port N] [--dump FILE]
  # 另开一个进程：chromium --headless --dump-dom http://127.0.0.1:PORT/

退出码：0 = 宿主起来了并且自检通过；1 = 起不来（缺 dist / 缺依赖）。
"""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import threading

# ---- DSH 安装位置（与 session/dshcfg.uya 的「常见 npm 全局路径」同一套口径）----
CANDIDATES = [
    os.environ.get("UYA_DSH_ROOT", ""),
    os.path.expanduser("~/.npm-global/lib/node_modules/@deepseek-ai/dsh"),
    "/usr/lib/node_modules/@deepseek-ai/dsh",
    "/usr/local/lib/node_modules/@deepseek-ai/dsh",
]

# ---- 最小可聊天 roster（14 个包，inject 闭包；见 DESIGN §11.9.6）----
# 少了任何一个，DSH 的 shell 都会「全有或全无」地整页 fail。
ROSTER = [
    "@deepseek-ai/dsh-api-gateway",
    "@deepseek-ai/dsh-api-remotes",
    "@deepseek-ai/dsh-client-connection",
    "@deepseek-ai/dsh-client-locale",
    "@deepseek-ai/dsh-client-modules",
    "@deepseek-ai/dsh-client-runtime",
    "@deepseek-ai/dsh-client-ui-conversation",
    "@deepseek-ai/dsh-client-ui-layout",
    "@deepseek-ai/dsh-client-ui-renderer",
    "@deepseek-ai/dsh-client-ui-settings",
    "@deepseek-ai/dsh-client-ui-sidebar",
    "@deepseek-ai/dsh-client-ui-theme",
    "@deepseek-ai/dsh-client-ui-workspace",
    "@deepseek-ai/dsh-typert-registry",
]

# 两个 bootstrap 包由 HTML 解析器在 shell 之前执行（顺序即数组顺序）。
PARSER_PRELOAD = [
    "@deepseek-ai/dsh-client-modules",
    "@deepseek-ai/dsh-client-runtime",
]

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# 驱动脚本要断言的**只可能来自我们事件流**的那两条（宿主与 drive 共用一份口径）。
PROBE_TITLE = "探针会话（本仓适配层）"
PROBE_NEEDLE = "PROBE-ASSISTANT-OK"

# 探针会话 id（session.list / workspace.list / mux 三处必须是同一个值）。
SESSION_ID = "session-probe-0000-0000-0000-000000000001"


def find_dsh():
    """找到装了 DSH 的根目录（要求 dist 与 client 包都在）。

    Returns:
        根目录字符串，或 None。
    """
    for root in CANDIDATES:
        if not root:
            continue
        nm = os.path.join(root, "node_modules", "@deepseek-ai")
        dist = os.path.join(nm, "dsh-web-frontend", "dist", "index.html")
        if os.path.exists(dist):
            return root
    return None


def pkg_client_path(root, pkg):
    """一个 client 包的 `lib/client.js` 绝对路径（`exports["./client"]` 的口径）。

    Returns:
        路径，或 None（包没装 / 没 client 半）。
    """
    nm = os.path.join(root, "node_modules")
    pj = os.path.join(nm, pkg, "package.json")
    if not os.path.exists(pj):
        return None
    try:
        with open(pj, encoding="utf-8") as f:
            meta = json.load(f)
    except (OSError, ValueError):
        return None
    exp = meta.get("exports", {})
    c = exp.get("./client") if isinstance(exp, dict) else None
    if isinstance(c, dict):
        c = c.get("default")
    if not isinstance(c, str):
        return None
    return os.path.join(nm, pkg, c)


def bundle_rev(path):
    """bundle 内容的 12 位 sha1（DSH 用它做 cache-busting 与图 rev）。"""
    with open(path, "rb") as f:
        return hashlib.sha1(f.read()).hexdigest()[:12]


def boot_injections(entries, graph_rev):
    """复刻 DSH 的 `bootInjections()`：queue 脚本 + 两个 preload + `__DSH_BOOT__`。

    Args:
        entries: `[{id,url,rev,immediately?}]`。
        graph_rev: 整图的 rev。

    Returns:
        head 段的 HTML 字符串（按执行顺序）。
    """
    queue = (
        "(()=>{\n"
        "const pendingQueue=[]\n"
        "window.__ModuleLoader__={\n"
        '  mode:"queue",\n'
        "  pendingQueue,\n"
        "  load(registration){pendingQueue.push(registration)},\n"
        "  create(options){\n"
        '    if(this.mode!=="queue")throw new Error("client-modules: '
        'window.__ModuleLoader__.create called after module-system boot")\n'
        "    const index=pendingQueue.findIndex(registration=>registration.id==="
        + json.dumps(PARSER_PRELOAD[0]) + ")\n"
        "    const registration=pendingQueue[index]\n"
        "    if(registration===undefined)throw new Error('client-modules: HTML did not preload "
        + PARSER_PRELOAD[0] + "/client.js')\n"
        "    pendingQueue.splice(index,1)\n"
        "    const exports=registration.factory(specifier=>{\n"
        "      throw new Error('client-modules: " + PARSER_PRELOAD[0]
        + "/client.js requested external \"'+specifier+'\" before the module system existed')\n"
        "    })\n"
        '    if(typeof exports!=="object"||exports===null||'
        'typeof exports.createClientModuleSystem!=="function"||'
        'typeof exports.apply!=="function"){\n'
        "      throw new Error(\"client-modules: " + PARSER_PRELOAD[0]
        + "/client.js did not export the bootstrap module face\")\n"
        "    }\n"
        "    return exports.createClientModuleSystem(this,{id:registration.id,exports},options)\n"
        "  }\n"
        "}\n"
        "})()"
    )
    by_id = {e["id"]: e for e in entries}
    parts = ["<script>" + queue + "</script>"]
    for pid in PARSER_PRELOAD:
        e = by_id.get(pid)
        if e is not None:
            parts.append('<script src="%s"></script>' % e["url"])
    graph = {"rev": graph_rev, "entries": entries}
    parts.append(
        "<script>globalThis[%s] = %s</script>"
        % (json.dumps("__DSH_BOOT__"),
           json.dumps(graph).replace("<", "\\u003c")))
    return "".join(parts)


def render_index(html, head_markup):
    """把注入片段插在 `<head>` 开标签之后（与 DSH 的 renderIndexInjections 同口径）。"""
    m = re.search(r"<head(?:\s[^>]*)?>", html, re.I)
    if m is None:
        return head_markup + html
    at = m.end()
    return html[:at] + head_markup + html[at:]


# ---- 离线会话数据：信封用本仓适配层的译文，外圈补 DSH 的 RPC 信封 ----

def adapt_real_log(log_path, out_path):
    """用**二进制的适配层**翻一份真日志（`UYA_SELFTEST_WIRE_FILE`），写到 out_path。

    为什么不在这里用 Python 抄一遍翻译：那等于把「适配」实现两份，而两份一定会分叉
    —— 要验的恰恰是**产品里那份**（`web/wsess.uya`）翻出来的东西 DSH 认不认。

    Returns:
        (ok, 行数)。ok=False = 二进制没跑成 / 没输出。
    """
    binary = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "build", "uya-agent")
    if not os.path.exists(binary):
        return False, 0
    env = dict(os.environ, UYA_SELFTEST_WIRE_FILE=log_path)
    try:
        r = subprocess.run([binary, "--selftest"], capture_output=True,
                           env=env, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return False, 0
    text = (r.stderr or b"").decode("utf-8", "replace")
    lines = [l for l in text.split("\n") if l.startswith("{")]
    if not lines:
        return False, 0
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return True, len(lines)


def load_dump(path):
    """读 `--wire-dump` 的译文行（每行一条 DSH SessionEvent）。

    Returns:
        事件字典列表。
    """
    if not path or not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def synth_events(seed):
    """没有 dump 时用一份最小的合成事件流（保证探针在任何机器上都能跑）。

    刻意**只用 DSH 认得的类型**，且形状与 `web/wsess.uya` 的译文一致。
    """
    if seed:
        return seed
    return [
        {"type": "user/message", "seq": 0, "time": 1,
         "data": {"role": "user", "id": "m-0",
                  "content": [{"type": "text", "text": "探针：一句话说明你能渲染我"}],
                  "source": {"kind": "user"}},
         "surfaceOp": "append"},
        {"type": "assistant/message", "seq": 1, "time": 2,
         "data": {"turn": 1, "step": 1,
                  "message": {"role": "assistant", "id": "m-1",
                              "content": [{"type": "text", "text": "PROBE-ASSISTANT-OK"}],
                              "source": {"kind": "model", "provider": "uya-agent",
                                         "model": "uya-agent"}},
                  "usage": {"inputTokens": 3, "outputTokens": 4}},
         "surfaceOp": "append"},
        {"type": "turn/end", "seq": 2, "time": 3,
         "data": {"turn": 1, "reason": {"kind": "completed"}}},
    ]


class Host:
    """最小宿主：静态资源 + `/api` unary + 两条 WebSocket 下行。"""

    def __init__(self, root, events, dump_path):
        self.root = root
        self.events = events
        self.dump_path = dump_path
        self.dist = os.path.join(root, "node_modules", "@deepseek-ai",
                                 "dsh-web-frontend", "dist")
        self.entries = self._entries()

    def _entries(self):
        """最小 roster 的 boot 图行（按 id 排序，rev 是 bundle 的 sha1）。"""
        rows = []
        for pid in ROSTER:
            p = pkg_client_path(self.root, pid)
            if p is None or not os.path.exists(p):
                continue
            rev = bundle_rev(p)
            row = {"id": pid, "url": "/plugins/%s/client.js?rev=%s" % (pid, rev),
                   "rev": rev}
            rows.append(row)
        return rows

    def graph_rev(self):
        """整图 rev（DSH 是 entries 的 sha1）。"""
        return hashlib.sha1(
            json.dumps(self.entries, sort_keys=True).encode()).hexdigest()[:12]

    def serve_index(self):
        """渲染 index.html（真 dist + 我们的注入）。"""
        with open(os.path.join(self.dist, "index.html"), encoding="utf-8") as f:
            html = f.read()
        return render_index(html, boot_injections(self.entries, self.graph_rev()))

    def static(self, pathname):
        """从真 dist 读一个静态资源（拒绝路径穿越）。

        Returns:
            (status, content_type, bytes) 或 None（没这个文件）。
        """
        rel = pathname.lstrip("/")
        if rel == "":
            rel = "index.html"
        full = os.path.normpath(os.path.join(self.dist, rel))
        if not full.startswith(self.dist):
            return 403, "text/plain", b"forbidden"
        if not os.path.isfile(full):
            return None
        ext = os.path.splitext(full)[1].lower()
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".js": "text/javascript; charset=utf-8",
            ".mjs": "text/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".json": "application/json",
            ".map": "application/json",
            ".svg": "image/svg+xml",
            ".webmanifest": "application/manifest+json",
            ".woff2": "font/woff2",
            ".woff": "font/woff",
            ".ttf": "font/ttf",
        }.get(ext, "application/octet-stream")
        with open(full, "rb") as f:
            return 200, ctype, f.read()

    def plugin(self, pathname):
        """`/plugins/<id>/client.js[.map]` → 该包的 lib/client.js（+ `.map`）。"""
        m = re.match(r"^/plugins/(.+?)/client\.js(\.map)?$", pathname)
        if m is None:
            return None
        p = pkg_client_path(self.root, m.group(1))
        if p is None:
            return None
        if m.group(2):      # 源映射：有就给，没有就当 404（浏览器能接受）
            p = p + ".map"
        if not os.path.isfile(p):
            return None
        with open(p, "rb") as f:
            return 200, "application/javascript; charset=utf-8", f.read()

    # ---- /api ----

    def unary(self, method, payload):
        """最小 `/api/<method>` 实现（只够让 shell 起来并渲染一份会话）。"""
        if method == "host.describe":
            return {"version": "0.0.1", "cwd": os.getcwd(),
                    "provider": "uya-agent", "model": "uya-agent",
                    "attachedSessions": 1, "home": os.path.expanduser("~"),
                    "canOpenPath": False}
        if method == "session.create":
            # ⚠ 这一步**不能少**：shell 起来的流程是「先 create 一个会话，再画它」，
            # 不是「列出来让我挑」。少了它，控制台只有一句
            # `initial workspace selection failed: session create failed`，
            # 而页面上**只是空**（hero 态）—— 这正是本探针最有价值的一条实测。
            return {"sessionId": SESSION_ID, "agentPreset": "standard"}
        if method == "session.list":
            return {"items": [{
                "sessionId": SESSION_ID,
                "updatedAt": 2, "running": False, "blank": False,
                "cwd": os.getcwd(),
                "projections": {"asOfSeq": 2, "values": {
                    "title": PROBE_TITLE}},
            }]}
        if method == "session.history":
            return {"events": [{"event": e} for e in self.events],
                    "hasMore": False,
                    "projections": {"asOfSeq": 2, "values": {
                        "title": PROBE_TITLE}}}
        if method == "session.models":
            return {"current": {"provider": "uya-agent", "model": "uya-agent"},
                    "routable": True, "groups": [], "failures": []}
        if method == "workspace.list":
            # 形状按**真 schema** 来（：workspaceId/path/title/
            # sessionIds/createdAt/updatedAt，两个时间都是 **ISO-8601 字符串**）。
            # ⚠ 侧栏是**按工作区分组**画会话行的：这里返回空 ⇒ 会话在 session.list
            # 里明明有、侧栏也**一行都不显示**（实测：页面只剩 "Ungrouped" 分组标题）。
            iso = "2026-01-01T00:00:00.000Z"
            return {"items": [{
                "workspaceId": "ws-probe",
                "path": os.getcwd(),
                "title": "探针工作区",
                "sessionIds": [SESSION_ID],
                "createdAt": iso, "updatedAt": iso,
            }], "archivedSessionIds": []}
        if method == "agentPreset.list":
            return {"items": []}
        if method == "skill.list":
            return {"items": []}
        if method == "subagent.list":
            return {"items": []}
        return None


def b64(b):
    """bytes → base64 字符串（WS 握手用）。"""
    return base64.b64encode(b).decode()


def ws_frame(payload):
    """服务端 → 客户端的一帧 text（**不掩码**：RFC 6455 规定服务端不许掩码）。"""
    data = payload.encode("utf-8")
    n = len(data)
    if n < 126:
        head = bytes([0x81, n])
    elif n < 65536:
        head = bytes([0x81, 126]) + n.to_bytes(2, "big")
    else:
        head = bytes([0x81, 127]) + n.to_bytes(8, "big")
    return head + data


def read_http_head(conn, buf):
    """读到 `\\r\\n\\r\\n` 为止，返回 (head_bytes, rest) 或 (None, buf)。"""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            return None, buf
        buf += chunk
    at = buf.index(b"\r\n\r\n") + 4
    return buf[:at], buf[at:]


def handle(conn, host):
    """一个连接的完整生命周期：HTTP 请求 → 响应（或升级成 WS 下行）。"""
    conn.settimeout(10)
    buf = b""
    try:
        head, rest = read_http_head(conn, buf)
    except (socket.timeout, OSError):
        conn.close()
        return
    if head is None:
        conn.close()
        return
    text = head.decode("latin-1")
    lines = text.split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) < 2:
        conn.close()
        return
    method, path = parts[0], parts[1]
    if os.environ.get("WIRE_PROBE_TRACE"):
        print("PROBE-REQ %s %s" % (method, path), flush=True)
    headers = {}
    for ln in lines[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip().lower()] = v.strip()

    # ---- WebSocket 升级（两条下行）----
    if headers.get("upgrade", "").lower() == "websocket":
        key = headers.get("sec-websocket-key", "")
        accept = b64(hashlib.sha1((key + WS_GUID).encode()).digest())
        conn.sendall((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        if path.startswith("/api/events.mux"):
            # 先发一条 session/subscribed，再把事件逐个推出去。
            sid = SESSION_ID
            frames = [{"type": "session/subscribed", "sessionId": sid,
                       "lastSeq": len(host.events) - 1}]
            for e in host.events:
                frames.append({"type": "session/event", "sessionId": sid,
                               "event": e})
            frames.append({"type": "session/projection", "sessionId": sid,
                           "key": "title",
                           "value": PROBE_TITLE,
                           "seq": 2})
        else:
            frames = [{"type": "host/session-added",
                       "sessionId": SESSION_ID,
                       "blank": False, "cwd": os.getcwd()}]
        try:
            for f in frames:
                envelope = {"type": "server-request",
                            "rpcId": "r-%d" % len(f),
                            "method": f["type"], "payload": f}
                conn.sendall(ws_frame(json.dumps(envelope)))
            # 保持连接开着（下行只发不收），让浏览器不把这一代判失败。
            while True:
                data = conn.recv(4096)
                if not data:
                    break
        except (socket.timeout, OSError):
            pass
        conn.close()
        return

    # ---- 普通 HTTP ----
    def reply(status, ctype, body):
        conn.sendall((
            "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
            "Connection: close\r\n\r\n" % (status, ctype, len(body))).encode()
            + body)

    if path == "/" or path.startswith("/index.html"):
        reply("200 OK", "text/html; charset=utf-8",
              host.serve_index().encode("utf-8"))
        conn.close()
        return

    if path.startswith("/plugins/"):
        r = host.plugin(path.split("?")[0])
        if r is None:
            reply("404 Not Found", "text/plain", b"no bundle")
        else:
            reply("200 OK", r[1], r[2])
        conn.close()
        return

    if path.startswith("/api/"):
        method = path[len("/api/"):].split("?")[0]
        if headers.get("content-type", "").split(";")[0].strip() != "application/json":
            reply("415 Unsupported Media Type", "text/plain", b"json only")
            conn.close()
            return
        body = rest
        want = int(headers.get("content-length", "0"))
        while len(body) < want:
            body += conn.recv(65536)
        try:
            env = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            reply("400 Bad Request", "text/plain", b"bad json")
            conn.close()
            return
        value = host.unary(method, env.get("payload"))
        if os.environ.get("WIRE_PROBE_TRACE"):
            print("PROBE-RESP %s -> %s" % (method, "none" if value is None else "ok"), flush=True)
        if value is None:
            # 未实现的方法：按 DSH 的口径回**业务错**（200 + RpcResult.error），
            # 而不是载体错 —— 客户端据此把那个面当「不支持」而不是「连接坏了」。
            out = {"type": "server-response", "rpcId": env.get("rpcId"),
                   "result": {"ok": False, "error": {
                       "code": "internal",
                       "message": "probe: %s not implemented" % method,
                       "details": {}}}}
        else:
            out = {"type": "server-response", "rpcId": env.get("rpcId"),
                   "result": {"ok": True, "value": value}}
        reply("200 OK", "application/json",
              json.dumps(out).encode("utf-8"))
        conn.close()
        return

    r = host.static(path.split("?")[0])
    if r is None:
        reply("404 Not Found", "text/plain", b"not found")
    else:
        reply("200 OK", r[1], r[2])
    conn.close()


def selftest_drive(real_log=""):
    """一条命令自证：起宿主 + 起 headless chromium + 用 CDP 驱动到「消息渲染出来」。

    这是**可证伪**的那一步：它回答「DSH 的 webui（一个字节都不改）能不能当本仓的前端」。
    做成一条命令是为了让它在别的机器上也能重跑（chromium 不在时**跳过**，不是失败）。

    Returns:
        0 = 通过或跳过；1 = 有断言不成立。
    """
    import shutil
    import subprocess
    import tempfile
    import time

    chrome = (shutil.which("chromium") or shutil.which("chromium-browser")
              or shutil.which("google-chrome"))
    if chrome is None:
        print("wire-probe: 跳过 —— 本机没有 chromium。")
        return 0
    root = find_dsh()
    if root is None:
        print("wire-probe: 跳过 —— 本机没装 DSH。")
        return 0

    # 有真日志就用真日志（`--real-log`）：那才是「本仓的会话」而不是合成样本。
    # 断言文本随之换成真日志里必然出现的两条（夹具里的 `PROBE-ASSISTANT-OK` 换掉）。
    needle = PROBE_NEEDLE
    if real_log:
        outp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "build", "wire_probe_real.jsonl")
        ok, n = adapt_real_log(real_log, outp)
        if not ok:
            print("wire-probe: 失败 —— 适配层没翻出任何事件。")
            return 1
        events = load_dump(outp)
        print("wire-probe: 真日志翻了 %d 条事件" % n)
        # 从译文里挑一条**用户消息**的正文当断言（它只可能来自那份日志）
        needle = ""
        for e in events:
            if e.get("type") == "user/message":
                for b in e["data"].get("content", []):
                    if b.get("type") == "text" and b.get("text"):
                        needle = b["text"]
                        break
            if needle:
                break
        if not needle:
            print("wire-probe: 失败 —— 那份日志里没有可断言的用户消息。")
            return 1
    else:
        events = synth_events([])
    host = Host(root, events, "")
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(32)
    port = srv.getsockname()[1]
    threading.Thread(target=_serve_forever, args=(srv, host), daemon=True).start()
    print("wire-probe: 宿主 http://127.0.0.1:%d/（roster=%d，事件=%d）"
          % (port, len(host.entries), len(events)))

    cdp_port = 9333
    prof = tempfile.mkdtemp(prefix="wire-probe-")
    proc = subprocess.Popen(
        [chrome, "--headless", "--no-sandbox", "--disable-gpu",
         "--remote-debugging-port=%d" % cdp_port,
         "--user-data-dir=" + prof, "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ws_url = None
        # chromium 打印 "DevTools listening" 之后的一小段时间里， 仍会
        # 拒连（实测：0.25s × 40 次全 refusal，而它在 standalone 下 6s 后就绪）。
        # 所以这里退避重试到 30s，而不是认定「CDP 没起来」。
        for _ in range(120):
            time.sleep(0.25)
            try:
                import urllib.request
                with urllib.request.urlopen(
                        # 用 `localhost`（不是 127.0.0.1）：本机 chromium 把 DevTools 端**只绑在 IPv6**
                        # 回环上，走 127.0.0.1 是 ECONNREFUSED（实测；这也是「standalone 能连、
                        # Popen 连不上」那个假象的真正原因）。
                        "http://localhost:%d/json/list" % cdp_port,
                        timeout=2) as r:
                    pages = json.loads(r.read().decode())
                if pages:
                    ws_url = pages[0]["webSocketDebuggerUrl"]
                    break
            except Exception:
                continue
        if ws_url is None:
            print("wire-probe: 失败 —— chromium 的 CDP 没起来。")
            return 1
        drive = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "wire_probe_drive.mjs")
        env = dict(os.environ, WIRE_PROBE_URL="http://127.0.0.1:%d/" % port)
        r = subprocess.run(["node", drive, ws_url, PROBE_TITLE, needle],
                           capture_output=True, env=env, timeout=180)
        out = (r.stdout or b"").decode("utf-8", "replace")
        err = (r.stderr or b"").decode("utf-8", "replace")
        sys.stdout.write(out)
        if err.strip():
            sys.stderr.write(err)
        return 0 if r.returncode == 0 else 1
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        srv.close()


def _serve_forever(srv, host):
    """后台线程：accept 循环（每条连接一个线程）。"""
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=handle, args=(conn, host), daemon=True).start()


def main():
    """入口：起监听、打印 URL、等 Ctrl-C。"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--dump", default="")
    ap.add_argument("--real-log", default="",
                    help="一份真的本仓 session.jsonl（用产品适配层翻它）")
    ap.add_argument("--dump-out", default="",
                    help="把翻好的译文写到这个文件（默认临时文件）")
    ap.add_argument("--once", action="store_true",
                    help="自检一次就退出（不长期驻留）")
    ap.add_argument("--selftest-drive", action="store_true",
                    help="起宿主 + chromium + CDP 驱动，验「消息渲染得出来吗」")
    args = ap.parse_args()

    if args.selftest_drive:
        return selftest_drive(args.real_log)

    root = find_dsh()
    if root is None:
        print("wire-probe: 跳过 —— 本机没装 DSH（找不到 dsh-web-frontend/dist）。")
        return 0
    if args.real_log:
        outp = args.dump_out or os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "build",
            "wire_probe_real.jsonl")
        ok, n = adapt_real_log(args.real_log, outp)
        if not ok:
            print("wire-probe: 失败 —— 适配层没翻出任何事件（%s）" % args.real_log)
            return 1
        print("wire-probe: 真日志翻了 %d 条事件（%s）" % (n, outp))
        events = load_dump(outp)
        if not events:
            print("wire-probe: 失败 —— 译文读不回来。")
            return 1
    else:
        events = synth_events(load_dump(args.dump))
    host = Host(root, events, args.dump)
    if not host.entries:
        print("wire-probe: 失败 —— 最小 roster 一个 client bundle 都没找到。")
        return 1

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen(32)
    port = srv.getsockname()[1]
    print("wire-probe: http://127.0.0.1:%d/" % port)
    print("wire-probe: roster=%d 个 client bundle，事件=%d 条"
          % (len(host.entries), len(events)))

    if args.once:
        srv.close()
        return 0

    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=handle, args=(conn, host),
                             daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
