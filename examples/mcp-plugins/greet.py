#!/usr/bin/env python3
"""examples/mcp-plugins/greet.py — 用 Python 写一个 MCP 插件（P70 示例）

与 `wordcount.ush` 是同一个协议、同一件事，只是换语言 —— 这就是「任意语言写插件」
的意思：宿主只认 stdio 上的 JSON-RPC，不关心对面是 Uya、Python 还是别的什么。

配置：
    uya-agent --mcp-server "greet=$PWD/examples/mcp-plugins/greet.py"

记得 `chmod +x greet.py`（shebang 要可执行位）。

MCP 的最小契约（本文件演示的就是全部）：
    1. `initialize`      → 回 protocolVersion / capabilities / serverInfo
    2. `notifications/initialized` → 通知，**不回响应**
    3. `tools/list`      → 报工具（name / description / inputSchema）
    4. `tools/call`      → 执行，回 content（`isError` 表示失败）
不认的方法回 `-32601 Method not found` —— 宿主据此判「这个 server 不认这个钩子」并放行。
"""
import json
import sys


def handle(req):
    """一条请求 → 一条响应（None = 这条不该回，例如通知）。"""
    method = req.get("method")
    rid = req.get("id")

    # 通知（没有 id）：MCP 规定不回响应
    if rid is None:
        return None

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "greet", "version": "1.0"},
            },
        }

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "tools": [
                    {
                        "name": "greet",
                        "description": "Say hello to someone.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "name": {
                                    "type": "string",
                                    "description": "Who to greet",
                                }
                            },
                            "required": ["name"],
                        },
                    }
                ]
            },
        }

    if method == "tools/call":
        args = (req.get("params") or {}).get("arguments") or {}
        who = args.get("name")
        if not isinstance(who, str) or not who:
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": 'missing required argument "name"',
                        }
                    ],
                    "isError": True,
                },
            }
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "content": [{"type": "text", "text": f"Hello, {who}!"}],
                "isError": False,
            },
        }

    # 不认的方法（含宿主试的钩子）：规范要求的 -32601，宿主会放行
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "error": {"code": -32601, "message": "Method not found"},
    }


def main():
    # 一行一条 JSON（`\\n` 分隔）—— MCP 的 stdio 帧格式。
    # 必须 `flush`：管道有缓冲，不 flush 宿主会一直等。
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            # 坏行：回一条解析错误（带 id 才回；拿不到 id 就丢弃这一行）
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": "Parse error"},
                    }
                ),
                flush=True,
            )
            continue
        resp = handle(req)
        if resp is not None:
            print(json.dumps(resp, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
