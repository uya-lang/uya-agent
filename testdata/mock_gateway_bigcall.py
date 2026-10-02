#!/usr/bin/env python3
"""大参数假网关 —— 只用于验收「tool_calls 容量」（README 踩坑 35）。

它让 agent 的第一步就拿到一发**参数超过 8 KiB** 的 `write` 调用：正文是
`CAP-HEAD|` + 600×16 字节 + `|CAP-TAIL`（≈9.6 KiB），序列化后的 tool_calls 原文 ≈9.9 KiB。
旧实现把它按固定 8192 的缓冲序列化，于是这一步直接以
`error: out of memory serializing tool_calls` 中止整轮（用户截图那一幕）。

之后每一次请求，脚本都会把「头尾标记是否一字不差地回来了」写进**给模型看的最终答案**里，
所以修前/修后不用翻日志：直接看 agent 打印的回答与脚本 stdout 上的每个请求形状。

这不是产品的一部分（产品是纯 Uya，只依赖 Uya 标准库）；它只是本地验收用的假端点。

用法：
    python3 testdata/mock_gateway_bigcall.py [port] [file]     # port=0 → 随机端口，首行 PORT n

配 uya-agent 跑（`--api=chat` 钉住 chat 协议；`--no-dsh-config` 不读真机设置）：
    python3 testdata/mock_gateway_bigcall.py 0 > /tmp/bigcall.log 2>&1 &
    PORT=$(awk '/^PORT/{print $2}' /tmp/bigcall.log)
    UYA_AGENT_API_KEY=k ./build/uya-agent --no-dsh-config \
        --base-url "http://127.0.0.1:$PORT/v1" --api=chat --model mock-model \
        --workspace /tmp/ws --agent-home /tmp/ah --tls-verify=none --max-steps 2 \
        "把 big.txt 写出来"

对照（修前 / 修后）：
    修前：exit 3 + stderr 出现 `error: out of memory serializing tool_calls`，
          脚本只看到 1 个请求（没有第二步），文件没写出来；
    修后：exit 0 + 回答 `BIGCALL-OK …`，脚本看到 2 个请求，
          第二个请求里 head/tail 都是 True，落盘文件与正文逐字节相同。
"""
import json
import socketserver
import sys
from http.server import BaseHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
TARGET = sys.argv[2] if len(sys.argv) > 2 else "big.txt"

HEAD = "CAP-HEAD|"
TAIL = "|CAP-TAIL"
BODY = HEAD + ("0123456789abcdef" * 600) + TAIL
ARGS = json.dumps({"file_path": TARGET, "content": BODY}, ensure_ascii=False)

STATE = {"n": 0}


def completion(stream):
    """第一发：大参数 write 调用；之后：把标记判定写进最终答案。"""
    STATE["n"] += 1
    n = STATE["n"]
    if n == 1:
        message = {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_big",
                    "type": "function",
                    "function": {"name": "write", "arguments": ARGS},
                }
            ],
        }
        finish = "tool_calls"
    else:
        message = {
            "role": "assistant",
            "content": "BIGCALL-OK 请求数=%d 头=%s 尾=%s" % (n, STATE["head"], STATE["tail"]),
        }
        finish = "stop"
    choice = {"index": 0, "finish_reason": finish}
    choice["delta" if stream else "message"] = message
    return {"id": "chatcmpl-bigcall", "object": "chat.completion", "choices": [choice]}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):   # 别把访问日志混进对照输出
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n)
        text = raw.decode("utf-8", "replace")
        stream = '"stream":true' in text
        # 第二个请求起，才可能带着上一轮的 assistant(tool_calls) 原文回来
        if STATE["n"] >= 1:
            STATE["head"] = HEAD in text
            STATE["tail"] = TAIL in text
        print(
            "REQ %d path=%s stream=%s bytes=%d head=%s tail=%s"
            % (STATE["n"] + 1, self.path, stream, len(raw),
               STATE.get("head"), STATE.get("tail")),
            flush=True,
        )
        body = json.dumps(completion(stream), ensure_ascii=False).encode("utf-8")
        if stream:
            body = b"data: " + body + b"\n\ndata: [DONE]\n\n"
            ctype = "text/event-stream"
        else:
            ctype = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("127.0.0.1", PORT), Handler) as httpd:
    print("PORT", httpd.server_address[1], flush=True)
    print("BODY bytes", len(BODY), "ARGS bytes", len(ARGS), flush=True)
    httpd.serve_forever()
