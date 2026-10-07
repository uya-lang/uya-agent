#!/usr/bin/env python3
"""可搬运性验收用的假网关 —— 把收到的**请求体**落盘，再回一条最小合法答复。

为什么需要它：`e2e-portable` 要断言的「system prompt 里有没有那一节」只能在
**发出去的请求**里看。本仓已有的出口都不够用：

  * `--debug-dump` 只记**错误体 / 坏 payload**（`ag_config.uya` 的 `diag_dump`），
    正常 200 的那一发它不落盘（实测：跑完只有 275 B，且不含 system prompt）；
  * `mock_gateway_echo.py` 会把请求回显进 **400 错误体**里 —— 能拿到请求，但它
    故意回错误码，于是「一轮跑完」永远失败，没法用它验「整轮正常」。

所以这里单独一个：**正常答复 + 请求落盘**。

答复形状：`--api=chat` 走 chat/completions；`--api=responses` 走 responses。
两种都给（脚本按请求路径选），免得验收腿被协议牵着走。

用法（首行打印 PORT）：
    python3 testdata/mock_gateway_portable.py <port> <dump-path>
    PORT=$(awk '/^PORT/{print $2}' /tmp/gw.log)

这不是产品的一部分（产品是纯 Uya，只依赖 Uya 标准库）；它只是本地验收用的假端点。
"""
import json
import socket
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
DUMP = sys.argv[2] if len(sys.argv) > 2 else "/tmp/portable_req.json"
# 落盘用「追加 + 分隔」：一轮里可能有多次请求（工具轮），全部都留证据
LOCK = threading.Lock()


def read_request(conn):
    """读到整个请求（头 + Content-Length 指定的体）。返回 (head, body)。"""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return b"", b""
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
    return head, body


def reply_for(head):
    """按请求路径选协议 —— responses / chat 各给一份最小合法答复。"""
    if b"/responses" in head:
        return json.dumps({
            "id": "resp_portable", "object": "response", "status": "completed",
            "output": [{
                "type": "message", "role": "assistant", "id": "msg_portable",
                "content": [{"type": "output_text", "text": "PORTABLE-OK"}],
            }],
            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
        }).encode()
    return json.dumps({
        "id": "chatcmpl_portable", "object": "chat.completion", "created": 0,
        "model": "mock",
        "choices": [{"index": 0, "finish_reason": "stop",
                     "message": {"role": "assistant", "content": "PORTABLE-OK"}}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }).encode()


def handle(conn):
    head, body = read_request(conn)
    if body:
        with LOCK:
            with open(DUMP, "ab") as fh:
                fh.write(b"\n===REQUEST===\n")
                fh.write(body)
    payload = reply_for(head)
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                 b"Content-Length: " + str(len(payload)).encode()
                 + b"\r\nConnection: close\r\n\r\n" + payload)
    conn.close()


def main():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(8)
    print("PORT %d" % srv.getsockname()[1], flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
