#!/usr/bin/env python3
"""极简假 LLM 网关（`--dsh-web` 活会话那两腿用，不属于产品）。

与 `mock_gateway_route.py` 的分工：那一个会**先要一条慢 bash**（它是为「回合运行中
敲 /model」造的现场）；而活会话这两腿要的是「发一句、当场答一句」——
多出来的工具调用会把判据变成「等 10 秒 + 看两轮」，慢且间接（实测：那一轮里
`assistant/message` 分两条、第一条还是空的）。

行为：
  * `GET /health` → `OK`（启动探针用）；
  * 其余请求：回一段 chat/completions 的 SSE，正文就是 `--text` 给的那句；
  * 每条请求往 stderr 打一行 `GW-B #N model=<…> path=<…>`（判「请求打到了谁」）。

用法：
    python3 testdata/mock_gateway_answer.py 0 "PROV-B-ANSWER" > /tmp/gw.log 2>&1 &
    PORT=$(awk '/^PORT/{print $2}' /tmp/gw.log)
"""
import json
import socket
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
ANSWER = sys.argv[2] if len(sys.argv) > 2 else "MOCK-ANSWER"
N = 0
LOCK = threading.Lock()


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


def handle(conn):
    global N
    try:
        head, body = read_request(conn)
        path = head.split(b" ")[1].decode("utf-8", "replace") if b" " in head else ""
        if path.startswith("/health"):
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
            return
        with LOCK:
            N += 1
            n = N
        try:
            parsed = json.loads(body.decode("utf-8", "replace"))
        except ValueError:
            parsed = {}
        model = parsed.get("model", "?")
        sys.stderr.write("GW-B #%d model=%s path=%s\n" % (n, model, path))
        sys.stderr.flush()
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                     b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")

        def chunk(payload):
            if payload:
                conn.sendall(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")

        base = {"id": "chatcmpl-answer", "object": "chat.completion.chunk",
                "created": 0, "model": "answer-mock"}
        chunk(sse(dict(base, choices=[{"index": 0, "delta": {
            "role": "assistant", "content": ANSWER}}])))
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


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(16)
    print("PORT %d" % srv.getsockname()[1], flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
