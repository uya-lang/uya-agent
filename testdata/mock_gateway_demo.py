#!/usr/bin/env python3
"""文档截图用的脚本化假网关（不属于产品；`make shot` 用它出图）。

为什么不复用 `mock_gateway_accept.py`：那个是**验收**夹具，判据盯着「提醒有没有
出现」，正文是 `ACCEPT-DONE …` 这种给断言看的字符串 —— 截进 README 里就是一行
天书。截图要的是**能自解释的一屏**：读文件 → 改一行 → 跑一遍 → 说结论。

脚本（按请求里的 `role":"user"` 条数推进，与 DSH 的回合边界同口径）：

    第 1 步  read    hello.uya
    第 2 步  edit    hello.uya（一处 replace，`--tool-lines` 打开时渲染成真 diff）
    第 3 步  bash    读回那一行，确认改的就是它
    第 4 步  正文    「已改成 Hello, uya! …」（finish_reason=stop）

确定性：没有时钟、没有随机、没有网络；同样的请求序列必给同样的响应。所以同一条
命令出的图**逐字节可复现**（`--tui-demo` 那条纪律的同款）。

用法：
    python3 testdata/mock_gateway_demo.py [port] > /tmp/demo-gw.log 2>&1 &
    PORT=$(awk '/^PORT/{print $2}' /tmp/demo-gw.log)
"""
import json
import socketserver
import sys
from http.server import BaseHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0

# 假工作区里那份文件的原文与改后文（两边都由脚本自己造，不读磁盘 ——
# 截图脚本会真的把 OLD 写进临时工作区，于是 read→edit→bash 三条腿都是真的）。
#
# 为什么最后一步是 `sed -n 2p` 而不是 `./hello`：这一屏要塞进 README 首屏，
# 每个字都会被截图里的人读到，而 `./hello` 要求工作区里先有一套能跑的 uya 工具链
# （`uya run` 一条实测 40 多秒，截图脚本等不起；失败时屏幕上只会留一行 `✗ Tool`）。
# 这里改成的是一条**确定、毫秒级、输出一行**的检查，屏幕上读起来也自解释。
OLD = 'export fn main() i32 {\n    @println("Hello, DSH!");\n    return 0;\n}\n'
NEW = 'export fn main() i32 {\n    @println("Hello, uya!");\n    return 0;\n}\n'

STEPS = [
    ("read", {"file_path": "hello.uya"}),
    ("edit", {"file_path": "hello.uya",
              "old_string": '@println("Hello, DSH!");',
              "new_string": '@println("Hello, uya!");'}),
    ("bash", {"command": 'printf "greeting: %s\\n" "$(sed -n 2p hello.uya)"',
              "description": "确认改的是那一行"}),
]

ANSWER = ("已把 hello.uya 的问候语改成 Hello, uya! —— 只动了一行，其余原样。"
          "要回滚就是把那一行改回去。")

STATE = {"step": 0, "users": 0}


def count_users(text):
    """数请求体里出现了几条 user 消息（`"role":"user"` 两种写法都算一次）。"""
    return text.count('"role":"user"') + text.count('"role": "user"')


def args_for(name, args):
    return json.dumps(args, ensure_ascii=False)


def completion(text, stream):
    """按**本回合**的步号给一条 chat.completion（stream 时由调用方包成 SSE 一帧）。

    步号必须跟着回合走：客户端每多一条 user 消息就是一个新回合。不重置的话，
    第二个任务会从脚本末尾接着跑 ⇒ 直接给最终答案，屏幕上一行工具都没有
    （实测：第一版就是这样，截出来的图和「改一行」完全不符）。
    """
    users = count_users(text)
    if users > STATE["users"]:
        STATE["users"] = users
        STATE["step"] = 0
    n = STATE["step"]
    STATE["step"] += 1
    if n < len(STEPS):
        name, args = STEPS[n]
        message = {
            "role": "assistant",
            "content": None,
            "tool_calls": [{
                "id": "call_demo_%d" % n,
                "type": "function",
                "function": {"name": name, "arguments": args_for(name, args)},
            }],
        }
        finish = "tool_calls"
    else:
        message = {"role": "assistant", "content": ANSWER}
        finish = "stop"
    choice = {"index": 0, "finish_reason": finish}
    choice["delta" if stream else "message"] = message
    return {"id": "chatcmpl-demo", "object": "chat.completion",
            "choices": [choice]}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        text = self.rfile.read(n).decode("utf-8", "replace")
        # 线协议两种形状都认：`--no-stream` 时客户端要一条 JSON，流式时要 SSE。
        stream = '"stream":true' in text or '"stream": true' in text
        body = json.dumps(completion(text, stream),
                          ensure_ascii=False).encode("utf-8")
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
