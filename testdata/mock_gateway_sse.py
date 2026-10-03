#!/usr/bin/env python3
"""可编排的假 LLM 网关（P30 验收用，不属于产品）。

用途：给真终端下的 uya-agent 喂**受控的 SSE**，用来验收 P30 的两件事：
  1) 单步长流式期间敲 `/status`、`/tasks`、`/help`，浮层必须**当场**出现（不再等 step 边界）；
  2) 回合运行中敲 `/new`：必须立刻出现回执，并且当前回合被中断、随后真的开了新会话。

与 testdata/mock_gateway_echo.py 同一路子（本地验收用的假端点，不进产品、不进 SRC）。

用法（首行打印 PORT）：
    python3 testdata/mock_gateway_sse.py 0 [STEPS] [GAP_MS] > /tmp/gw.log 2>&1 &
    PORT=$(awk '/^PORT/{print $2}' /tmp/gw.log)

参数：
    STEPS   写进流里的回答段数（默认 1 —— 就是「整回合只有一步」那个现场）
    GAP_MS  每段 SSE 之间的停顿（毫秒，默认 3000）—— 造出「长单步」的窗口

行为：
  * 每次请求都是一段 chat/completions 的 SSE 流：先 reasoning_content（几帧，中间按
    GAP_MS 停），再 content「SELFTEST_OK」，最后 usage + [DONE]。
  * 任何请求都回同样的答案（没有 tool_calls），所以回合就是一步。
"""
import json
import socket
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
STEPS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
GAP_MS = int(sys.argv[3]) if len(sys.argv) > 3 else 3000

REQS = []


def read_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    clen = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            clen = int(line.split(b":", 1)[1].strip())
    while len(rest) < clen:
        chunk = conn.recv(65536)
        if not chunk:
            break
        rest += chunk
    return head, rest


def sse(obj):
    return ("data: " + json.dumps(obj, ensure_ascii=False) + "\n\n").encode("utf-8")


def handle(conn):
    try:
        head, body = read_request(conn)
        REQS.append(body)
        sys.stderr.write("REQ #%d (%d bytes)\n" % (len(REQS), len(body)))
        sys.stderr.flush()
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                     b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")

        def chunk(payload):
            if not payload:
                return
            conn.sendall(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")

        base = {"id": "chatcmpl-p30", "object": "chat.completion.chunk",
                "created": 0, "model": "p30-mock"}
        step = 0
        while step < STEPS:
            step += 1
            # 先流一段「思考」，中间按 GAP_MS 停 —— 这段停顿时长就是「长单步」的现场
            for i in range(3):
                delta = {"role": "assistant"} if i == 0 else {}
                delta["reasoning_content"] = "第 %d/%d 段思考…" % (step, STEPS)
                chunk(sse(dict(base, choices=[{"index": 0, "delta": delta}])))
                time.sleep(GAP_MS / 1000.0 / 3.0)
            if step < STEPS:
                # 中间几段只写 content 片段，最后一段再给完整答案
                chunk(sse(dict(base, choices=[{"index": 0, "delta": {"content": "…"}}])))
                chunk(sse(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}])))
                continue
        chunk(sse(dict(base, choices=[{"index": 0, "delta": {"content": "SELFTEST_OK"}}])))
        chunk(sse(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}])))
        chunk(sse(dict(base, choices=[], usage={"prompt_tokens": 11, "completion_tokens": 7,
                                              "total_tokens": 18})))
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
