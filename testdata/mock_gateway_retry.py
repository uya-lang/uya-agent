#!/usr/bin/env python3
"""P82 假网关 —— 验收「传输层失败 → 退避重发」。

模拟上游抖动：**头 N 次**请求回一个可重试的失败，之后正常回 SSE 答案。用来验：

  ① 默认（不限次数）：503→503→200 ⇒ 退出码 0，转录里两条 `[retry]`，
     会话日志两条 `llm/retry`，且**三次请求的请求体逐字节相同**（同一步重发、历史没动）；
  ② `--api-retry-max 0`：503 之后**立刻**退出 2，网关只收到 1 次请求（闸门真的关得掉）；
  ③ `--api-retry-max 1`：503 之后不重发（已经发满 1 次），退出 2，网关只收到 1 次请求；
  ④ `--api-retry-max 2`：503→200 ⇒ 退出 0、一条 `[retry]`（上限被尊重，不多发）。

为什么判据落在「网关侧收到的请求体」上而不是只看退出码：重发路径最容易出的错是
「请求体悄悄变了」（往历史里压了条消息、step 推进了一格、header 跟丢了密钥）——
那样退出码照样是 0，而**逐字节比对**会当场抓住它。

这不是产品的一部分（产品是纯 Uya，只依赖 Uya 标准库）；它只是本地验收用的假端点。

用法：
    python3 testdata/mock_gateway_retry.py [port] [fail_times] [status]
        port       0 = 随机端口（首行打印 PORT）
        fail_times 前多少次回失败（默认 2）
        status     失败用哪个状态码（默认 503；给 429 可以顺带验限流那一档）

输出（stdout，供 Makefile 断言）：
    PORT <n>
    REQ <i> bytes=<n> sha=<hex8> same=<0|1>     每次请求一行（same=1 表示与首次逐字节相同）
"""
import hashlib
import json
import socket
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
FAIL_TIMES = int(sys.argv[2]) if len(sys.argv) > 2 else 2
STATUS = int(sys.argv[3]) if len(sys.argv) > 3 else 503

STATE = {"n": 0, "first": None}
LOCK = threading.Lock()

ANSWER = "SELFTEST-NETRETRY-OK"


def read_request(conn):
    """读满一个请求（头 + Content-Length 指定的体），返回原文。"""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return data
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    clen = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            clen = int(line.split(b":", 1)[1].strip())
    while len(body) < clen:
        chunk = conn.recv(65536)
        if not chunk:
            break
        body += chunk
    return head + b"\r\n\r\n" + body


def sse_body():
    """一帧正常的 chat SSE（正文 + finish_reason=stop + [DONE]）。"""
    frame = {
        "choices": [{"index": 0, "delta": {"role": "assistant",
                                           "content": ANSWER}}],
    }
    done = {"choices": [{"index": 0, "delta": {},
                         "finish_reason": "stop"}]}
    out = b""
    for obj in (frame, done):
        out += b"data: " + json.dumps(obj).encode() + b"\n\n"
    out += b"data: [DONE]\n\n"
    return out


def send(conn, status, body, ctype):
    head = (
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Connection: close\r\n"
        "Content-Length: %d\r\n\r\n"
        % (status, "Service Unavailable" if status == 503 else "Error",
           ctype, len(body))
    )
    conn.sendall(head.encode() + body)


def json_body():
    """非流式（`--no-stream`）的整段 JSON 响应。"""
    return json.dumps({
        "choices": [{"index": 0, "message": {"role": "assistant",
                                             "content": ANSWER},
                     "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 11, "completion_tokens": 5,
                  "total_tokens": 16},
    }).encode()


def handle(conn):
    raw = read_request(conn)
    with LOCK:
        STATE["n"] += 1
        i = STATE["n"]
        if STATE["first"] is None:
            STATE["first"] = raw
        first = STATE["first"]
    same = 1 if raw == first else 0
    print("REQ %d bytes=%d sha=%s same=%d"
          % (i, len(raw), hashlib.sha256(raw).hexdigest()[:8], same), flush=True)
    if i <= FAIL_TIMES:
        body = json.dumps({"error": {"code": "server_error",
                                     "message": "mock transient %d" % i}}).encode()
        send(conn, STATUS, body, "application/json")
    else:
        # 双形态：请求里带 `"stream":true` 就回 SSE，否则回整段 JSON
        # （`--no-stream` 那条路也要能验收 —— 它有自己的 http_request 分支）
        want_stream = b'"stream":true' in raw or b'"stream": true' in raw
        if want_stream:
            send(conn, 200, sse_body(), "text/event-stream")
        else:
            send(conn, 200, json_body(), "application/json")
    conn.close()


def main():
    global PORT
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(16)
    PORT = srv.getsockname()[1]
    print("PORT %d" % PORT, flush=True)
    print("FAIL_TIMES %d STATUS %d" % (FAIL_TIMES, STATUS), flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


main()
