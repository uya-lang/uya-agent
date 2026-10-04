#!/usr/bin/env python3
"""编排假网关（P42 验收用，不属于产品）：造一个「先思考、再跑慢 bash」的子代理。

用途：给真终端下的 uya-agent 喂受控 SSE，用来验收 `/watch` 的实时性 ——
父代理派一个子代理，子代理跑一条 `sleep N` 的 bash；这段时间里 `/watch sub-1`
必须已经能从它的会话日志里读到 `[step …]` / `▸ bash …` 这类事件。

与 testdata/mock_gateway_sse.py 同一路子（本地验收用的假端点，不进产品、不进 SRC）。
bash 工具要求 `description`，参数里必须带上（否则工具会当场拒掉，看不到追踪）。

用法（首行打印 PORT）：
    python3 testdata/mock_gateway_watch.py 0 [SLEEP_SECS] > /tmp/gw.log 2>&1 &
    PORT=$(awk '/^PORT/{print $2}' /tmp/gw.log)
"""
import json
import socket
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
SLEEP_SECS = int(sys.argv[2]) if len(sys.argv) > 2 else 8
WATCH_MARK = "WATCH_CHILD_MARK_5b7e"
REQS = []


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
    try:
        head, body = read_request(conn)
        REQS.append(body)
        is_child = WATCH_MARK.encode() in body
        has_tool = b'"role":"tool"' in body
        # 四类请求（顺序重要：子代理的收尾请求也带 tool，必须先判 is_child）：
        #   * 子代理 + 有工具结果 → 收尾
        #   * 子代理 + 没有工具结果 → 发慢 bash
        #   * 父代理 + 有工具结果 → 收尾（否则会无限重派子代理）
        #   * 父代理 + 没有工具结果 → 派子代理
        if is_child:
            kind = "child-final" if has_tool else "child-toolcall"
        else:
            kind = "parent-final" if has_tool else "parent-spawn"
        sys.stderr.write("REQ #%d kind=%s (%d bytes)\n" % (len(REQS), kind, len(body)))
        sys.stderr.flush()

        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                     b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")

        def chunk(payload):
            if payload:
                conn.sendall(("%x\r\n" % len(payload)).encode() + payload + b"\r\n")

        base = {"id": "chatcmpl-watch", "object": "chat.completion.chunk",
                "created": 0, "model": "watch-mock"}

        if kind == "parent-spawn":
            # 父代理首轮：派一个后台子代理
            tc = [{"index": 0, "id": "call_sub", "type": "function",
                   "function": {"name": "subagent", "arguments": json.dumps({
                       "prompt": WATCH_MARK + " 请先跑一条慢命令，再总结。",
                       "description": "watch 实时性验收",
                       "run_in_background": True}, ensure_ascii=False)}}]
            chunk(sse(dict(base, choices=[{"index": 0, "delta": {"role": "assistant",
                                                                "tool_calls": tc}}])))
            chunk(sse(dict(base, choices=[{"index": 0, "delta": {},
                                          "finish_reason": "tool_calls"}])))
            chunk(sse(dict(base, choices=[], usage={"prompt_tokens": 1, "completion_tokens": 1,
                                                  "total_tokens": 2})))
            chunk(b"data: [DONE]\n\n")
            conn.sendall(b"0\r\n\r\n")
            return

        if kind == "child-toolcall":
            # 子代理：先流几段思考（会落成 assistant/reasoning），再要一条慢 bash
            for i in range(3):
                chunk(sse(dict(base, choices=[{"index": 0,
                                               "delta": ({"role": "assistant"} if i == 0 else {}),
                                               "reasoning_content":
                                                   "子代理思考第 %d 段：准备跑慢命令" % (i + 1)}])))
                time.sleep(0.8)
            tc = [{"index": 0, "id": "call_bash_1", "type": "function",
                   "function": {"name": "bash", "arguments": json.dumps({
                       "command": "sleep %d && echo CHILD_TOOL_DONE" % SLEEP_SECS,
                       "description": "跑一条慢命令"})}}]
            chunk(sse(dict(base, choices=[{"index": 0, "delta": {"tool_calls": tc}}])))
            chunk(sse(dict(base, choices=[{"index": 0, "delta": {},
                                          "finish_reason": "tool_calls"}])))
            chunk(sse(dict(base, choices=[], usage={"prompt_tokens": 1, "completion_tokens": 1,
                                                  "total_tokens": 2})))
            chunk(b"data: [DONE]\n\n")
            conn.sendall(b"0\r\n\r\n")
            return

        # child-final / 兜底
        chunk(sse(dict(base, choices=[{"index": 0, "delta": {"role": "assistant",
                                                            "content": "子代理做完了：CHILD-DONE-OK"}}])))
        chunk(sse(dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": "stop"}])))
        chunk(sse(dict(base, choices=[], usage={"prompt_tokens": 1, "completion_tokens": 1,
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
