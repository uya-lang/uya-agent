#!/usr/bin/env python3
"""双路线假网关（P37 验收用，不属于产品）：把「请求到底打到哪个提供方」变成可断言的事实。

用途：验收「切模型要连端点与凭据一起跟随」。这里起**两个**假网关，各自扮演一个提供方，
并把收到的每一个请求记下来 —— 模型名与 `Authorization` 都记账，于是「切完还在打旧提供方」
「切完带了旧提供方的密钥」这类静默故障都能当场判出来。

与 testdata/mock_gateway_sse.py 同一路子（本地验收用的假端点，不进产品、不进 SRC）。

用法（首行按提供方各打印一行 PORT）：
    python3 testdata/mock_gateway_route.py [SLOW_SECS] > /tmp/gw.log 2>&1 &
    PORT_A=$(awk '/^PORT-A/{print $2}' /tmp/gw.log)
    PORT_B=$(awk '/^PORT-B/{print $2}' /tmp/gw.log)

行为（够验收用，不模拟更多）：
  * 第一条请求：回一条 tool_calls，要 `bash` 跑 `sleep SLOW_SECS` —— 用来撑出一个
    「回合正在跑」的确定窗口，好在里面敲 /model；
  * 之后每条请求：直接回一个最终答案 `<NAME>-ANSWER`（A/B 两个网关的文本不同，
    于是「这一轮是谁答的」在屏幕上就是可读的事实）；
  * 每条请求都往 stderr 打一行 `GW-<NAME> #N model=<...> auth=<...> path=<...>`。

退出：收到 SIGTERM 就收工（Makefile 用 trap kill）。
"""
import json
import socket
import sys
import threading
import time

REQ_LOG = {}
SRV = {}
NAME_A = "PROV-A"
NAME_B = "PROV-B"
# 撑出「回合正在跑」的窗口：第一条请求要一条慢 bash
SLOW_SECS = int(sys.argv[1]) if len(sys.argv) > 1 else 10


def read_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        c = conn.recv(65536)
        if not c:
            break
        data += c
    head, _, rest = data.partition(b"\r\n\r\n")
    clen = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            clen = int(line.split(b":", 1)[1].strip())
    while len(rest) < clen:
        c = conn.recv(65536)
        if not c:
            break
        rest += c
    return head, rest


def sse(obj):
    return ("data: " + json.dumps(obj, ensure_ascii=False) + "\n\n").encode("utf-8")


def handler_for(name):
    def handle(conn):
        try:
            head, body = read_request(conn)
            recs = REQ_LOG[name]
            recs.append(body)
            auth = ""
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"authorization:"):
                    auth = line.split(b":", 1)[1].strip().decode("utf-8", "replace")
            try:
                model = json.loads(body).get("model", "")
            except Exception:  # noqa: BLE001
                model = ""
            sys.stderr.write("GW-%s #%d model=%s auth=%s path=%s\n"
                             % (name, len(recs), model, auth,
                                head.split(b" ")[1].decode("utf-8", "replace")
                                if b" " in head else "?"))
            sys.stderr.flush()

            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                         b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")

            def chunk(payload):
                if payload:
                    conn.sendall(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")

            base = {"id": "chatcmpl-route", "object": "chat.completion.chunk",
                    "created": 0, "model": "route-mock"}

            if len(recs) == 1:
                # 首轮：撑住回合（跑一条慢 bash），好让验收脚本在里面敲 /model
                tc = [{"index": 0, "id": "call_slow", "type": "function",
                       "function": {"name": "bash", "arguments": json.dumps({
                           "command": "sleep %d && echo SLOW-DONE" % SLOW_SECS,
                           "description": "撑住回合的慢命令"}, ensure_ascii=False)}}]
                chunk(sse(dict(base, choices=[{"index": 0, "delta": {"role": "assistant",
                                                                    "tool_calls": tc}}])))
                chunk(sse(dict(base, choices=[{"index": 0, "delta": {},
                                              "finish_reason": "tool_calls"}])))
            else:
                chunk(sse(dict(base, choices=[{"index": 0, "delta": {
                    "role": "assistant", "content": name + "-ANSWER"}}])))
                chunk(sse(dict(base, choices=[{"index": 0, "delta": {},
                                              "finish_reason": "stop"}])))
            chunk(sse(dict(base, choices=[], usage={"prompt_tokens": 1,
                                                   "completion_tokens": 1,
                                                   "total_tokens": 2})))
            chunk(b"data: [DONE]\n\n")
            conn.sendall(b"0\r\n\r\n")
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write("ERR %r\n" % (exc,))
            sys.stderr.flush()
        finally:
            try:
                conn.close()
            except OSError:
                pass
    return handle


def spawn(name):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    REQ_LOG[name] = []
    SRV[name] = srv
    print("PORT-%s %d" % (name.split("-")[1], srv.getsockname()[1]), flush=True)

    def loop():
        h = handler_for(name)
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=h, args=(conn,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()
    return srv


def main():
    spawn(NAME_A)
    spawn(NAME_B)
    # 主线程只是陪着（两个 accept 循环都在后台线程里）：等 SIGTERM
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
