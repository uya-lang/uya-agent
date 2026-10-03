#!/usr/bin/env python3
"""可编排的假 LLM 网关（P30 验收用，不属于产品）。

用途：给真终端下的 uya-agent 喂**受控的 SSE**，用来验收 P30 的两件事：
  1) 单步长流式期间敲 `/status`、`/tasks`、`/help`，浮层必须**当场**出现（不再等 step 边界）；
  2) 回合运行中敲 `/new`：必须立刻出现回执，并且当前回合被中断、随后真的开了新会话。

与 testdata/mock_gateway_echo.py 同一路子（本地验收用的假端点，不进产品、不进 SRC）。

用法（首行打印 PORT）：
    python3 testdata/mock_gateway_sse.py 0 [STEPS] [GAP_MS] [HEAD_DELAY_MS] [TOOL_CMD] > /tmp/gw.log 2>&1 &
    PORT=$(awk '/^PORT/{print $2}' /tmp/gw.log)

参数：
    STEPS         写进流里的回答段数（默认 1 —— 就是「整回合只有一步」那个现场）
    GAP_MS        每段 SSE 之间的停顿（毫秒，默认 3000）—— 造出「长单步」的窗口
    HEAD_DELAY_MS 收到请求后先停这么久**再发响应头**（默认 0 = 立刻发）—— P31 用：
                  「请求已经发出去、响应头还没回来」是客户端唯一没有泵点的那段，
                  客户端会一直卡在 hc_open 的读头循环里
    TOOL_CMD      非空时：第一次请求回一个 bash 工具调用（命令就是它），第二次请求
                  才回普通答案（默认 "" = 从不发 tool_calls）。用来造「长时间 bash」
                  与「有工具结果的历史」（压缩需要 shadow > 0）

行为：
  * 每次请求都是一段 chat/completions 的 SSE 流：先 reasoning_content（几帧，中间按
    GAP_MS 停），再 content「SELFTEST_OK」，最后 usage + [DONE]。
  * 默认（TOOL_CMD 为空）任何请求都回同样的答案（没有 tool_calls），所以回合就是一步。
"""
import json
import socket
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
STEPS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
GAP_MS = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
HEAD_DELAY_MS = int(sys.argv[4]) if len(sys.argv) > 4 else 0
TOOL_CMD = sys.argv[5] if len(sys.argv) > 5 else ""

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
        if HEAD_DELAY_MS > 0:
            # P31：响应头也压住 —— 客户端这一段完全没有泵点（hc_open 的读头循环是阻塞读）
            time.sleep(HEAD_DELAY_MS / 1000.0)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                     b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")

        def chunk(payload):
            if not payload:
                return
            conn.sendall(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")

        base = {"id": "chatcmpl-p30", "object": "chat.completion.chunk",
                "created": 0, "model": "p30-mock"}
        if TOOL_CMD and b'"role":"tool"' not in body:
            # P31：第一次请求先要一个 bash 工具调用（用来造长 bash / 造出可压缩的历史）
            tc = [{"index": 0, "id": "call_1", "type": "function",
                   "function": {"name": "bash",
                                "arguments": json.dumps({"command": TOOL_CMD})}}]
            chunk(sse(dict(base, choices=[{"index": 0, "delta": {"role": "assistant",
                                                                "tool_calls": tc}}])))
            chunk(sse(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "tool_calls"}])))
            chunk(sse(dict(base, choices=[], usage={"prompt_tokens": 11, "completion_tokens": 7,
                                                  "total_tokens": 18})))
            chunk(b"data: [DONE]\n\n")
            conn.sendall(b"0\r\n\r\n")
            return
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
