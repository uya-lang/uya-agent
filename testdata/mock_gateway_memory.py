#!/usr/bin/env python3
"""项目记忆假网关 —— 只用于 `make e2e-memory-live`（钉「记忆真的写得进盘」）。

为什么需要它：`src/selftest/st_pm2.uya` 的 `pm-e2e` 轮**直接调**摄取函数并手写正确的
参数（`res.ptr` / `res.len`），所以它证明的是「摄取函数本身对」，**不是接线对**。
生产代码里那两处坏调用点（把字段地址当值传、把绑定排在身份之前）因此长期没被发现 ——
表现为「记忆一直不失效」，实际是**从来没写进去过**。这一轮跑**真二进制**补上这条腿。

脚本（每次请求往后推一步，第 3 步给最终答案）：
  第 1 步：`read <file>`（默认 `README.md`）—— 摄取应记一条带 stat 锚点的 `layout` 事实
  第 2 步：`bash` 跑一条命令（默认 `make -n`）—— 摄取应记一条 `commands`
  第 3 步：最终答案 `MEMDONE`

这不是产品的一部分（产品是纯 Uya，只依赖 Uya 标准库）；它只是本地验收用的假端点。

用法：
    python3 testdata/mock_gateway_memory.py [port] [read_path] [bash_cmd]
        port=0 → 随机端口，首行 `PORT n`

    UYA_AGENT_API_KEY=k ./build/uya-agent --no-dsh-config --no-stream --no-tui \
        --base-url "http://127.0.0.1:$PORT/v1" --api=chat --model mock-model \
        --workspace <ws> --agent-home <home> --tls-verify=none "任务"
"""
import json
import os
import socketserver
import sys
from http.server import BaseHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
READ_PATH = sys.argv[2] if len(sys.argv) > 2 else "README.md"
BASH_CMD = sys.argv[3] if len(sys.argv) > 3 else "make -n"
# 请求体落盘（可选）：验收要断言**注入进请求**的那段 `<pm-memory>`，而不只是盘上产物。
# 没有它就只能看 `/memory` 报告 —— 那是报告，不是模型真正看到的东西。
DUMP = os.environ.get("UYA_MEM_DUMP", "")

STATE = {"n": 0}


def tool_call(idx, name, args):
    return {
        "role": "assistant",
        "content": None,
        "tool_calls": [
            {
                "id": "call_mem_%d" % idx,
                "type": "function",
                "function": {"name": name, "arguments": json.dumps(args)},
            }
        ],
    }


def reply(idx):
    """第 idx 次请求的应答（0 基）。"""
    if idx == 0:
        return tool_call(0, "read", {"file_path": READ_PATH}), "tool_calls"
    if idx == 1:
        # `description` 必填：少了它 bash 工具直接回 `Error: invalid description`
        # （那样的结果里没有 `[exit code: N]` ⇒ 按设计**什么都不记**，这一腿就白测了）
        return (
            tool_call(1, "bash",
                      {"command": BASH_CMD, "description": "memory live probe"}),
            "tool_calls",
        )
    return {"role": "assistant", "content": "MEMDONE"}, "stop"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n)
        text = raw.decode("utf-8", "replace")
        stream = '"stream":true' in text
        if DUMP:
            with open(DUMP, "a", encoding="utf-8") as fh:
                fh.write(text + "\n---UYA-REQ-END---\n")
        idx = STATE["n"]
        STATE["n"] += 1
        message, finish = reply(idx)
        choice = {"index": 0, "finish_reason": finish}
        choice["delta" if stream else "message"] = message
        body = json.dumps(
            {"id": "chatcmpl-mem", "object": "chat.completion", "choices": [choice]}
        ).encode("utf-8")
        if stream:
            body = b"data: " + body + b"\n\ndata: [DONE]\n\n"
            ctype = "text/event-stream"
        else:
            ctype = "application/json"
        print("REQ %d step=%d stream=%s bytes=%d"
              % (STATE["n"], idx, stream, len(raw)), flush=True)
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
    httpd.serve_forever()
