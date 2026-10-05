#!/usr/bin/env python3
"""收工提醒假网关 —— 只用于验收「验收类命令跑绿后注入一行 [acceptance] 提醒」（§19 的 P55）。

三轮脚本（模式由请求体里的关键字选）：
  第 1 轮：`touch nudge_changed.txt` —— **改动类**命令（提醒判据要求「改动之后」）
  第 2 轮：按模式给第二发 bash：
     `ACCEPT-CONTROL`  → `ls -la`（非验收类，提醒不该出现）
     `ACCEPT-FALSEPOS`  → `grep -n "make build" Makefile && echo ok`（文本里有 make，
                          但没有哪一段以验收命令开头 —— 这正是第一版误报的形状）
     否则               → `make build`（验收类，跑绿之后应当出现提醒）
  第 3 轮：最终答案 `ACCEPT-DONE 模式=…`。

这不是产品的一部分（产品是纯 Uya，只依赖 Uya 标准库）；它只是本地验收用的假端点。

用法：
    python3 testdata/mock_gateway_accept.py [port]      # port=0 → 随机端口，首行 PORT n

配 uya-agent 跑（验收命令见 Makefile 的 e2e-accept-nudge）：
    UYA_AGENT_API_KEY=k ./build/uya-agent --no-dsh-config --no-stream \
        --base-url "http://127.0.0.1:$PORT/v1" --api=chat --model mock-model \
        --workspace <ws> --agent-home <home> --tls-verify=none "任务 ACCEPT-NUDGE"
"""
import json
import socketserver
import sys
from http.server import BaseHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0

STATE = {"n": 0, "cmds": [], "users": 0, "round": 0}


def args_for(cmd):
    return json.dumps({"command": cmd, "description": "acceptance probe"}, ensure_ascii=False)


def completion(stream):
    STATE["n"] += 1
    STATE["round"] += 1
    if STATE["round"] <= 2:
        cmd = STATE["cmds"][STATE["round"] - 1]
        message = {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_accept_%d" % STATE["n"],
                    "type": "function",
                    "function": {"name": "bash", "arguments": args_for(cmd)},
                }
            ],
        }
        finish = "tool_calls"
    else:
        message = {"role": "assistant", "content": "ACCEPT-DONE 命令=%s" % STATE["cmds"][1]}
        finish = "stop"
    choice = {"index": 0, "finish_reason": finish}
    choice["delta" if stream else "message"] = message
    return {"id": "chatcmpl-accept", "object": "chat.completion", "choices": [choice]}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n)
        text = raw.decode("utf-8", "replace")
        stream = '"stream":true' in text
        # 多回合：每来一条新的 user 消息就把脚本从头放一遍（P55 的「回合结束还原档位」验收要用）
        users = text.count('"role":"user"') + text.count('"role": "user"')
        if users > STATE["users"]:
            STATE["users"] = users
            STATE["round"] = 0
            STATE["cmds"] = []
            STATE["cmds"] = ["touch nudge_changed.txt"]
            if "ACCEPT-CONTROL" in text:
                STATE["cmds"].append("ls -la")
            elif "ACCEPT-FALSEPOS" in text:
                STATE["cmds"].append('grep -n "make build" Makefile && echo ok')
            else:
                STATE["cmds"].append("make build")
        if not STATE["cmds"]:
            if "ACCEPT-CONTROL" in text:
                second = "ls -la"
            elif "ACCEPT-FALSEPOS" in text:
                second = 'grep -n "make build" Makefile && echo ok'
            else:
                second = "make build"
            STATE["cmds"] = ["touch nudge_changed.txt", second]
        print("REQ %d path=%s stream=%s bytes=%d cmds=%s"
              % (STATE["n"] + 1, self.path, stream, len(raw), STATE["cmds"]), flush=True)
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
    httpd.serve_forever()
