#!/usr/bin/env python3
"""回显型假网关 —— 只用于验收「诊断出口」（§16 踩坑 33 / P19）。

它模拟那类中转网关的报错风格：**非 2xx 的错误体里把收到的整个请求原样回显**。
uya-agent 的旧实现会把这具身体按字节打给 fd 2，TUI 再把它渲染成一大块带 `· ` 前缀的
NOTICE 行（屏幕上就是「半个汉字 + 一屏 JSON」= 用户报的乱码）。

这不是产品的一部分（产品是纯 Uya，只依赖 Uya 标准库）；它只是本地验收用的假端点。

用法：
    python3 testdata/mock_gateway_echo.py [port]        # port=0 → 随机端口，首行打印 PORT

配 uya-agent 跑（验收记录见 §19「P19 的诊断出口验收」）：
    python3 testdata/mock_gateway_echo.py 0 > /tmp/gw.log 2>&1 &
    PORT=$(awk '/^PORT/{print $2}' /tmp/gw.log)
    UYA_AGENT_API_KEY=k ./build/uya-agent --no-dsh-config \
        --base-url "http://127.0.0.1:$PORT/v1" --api=chat --model mock-model \
        --workspace /tmp/ws --agent-home /tmp/ah --max-steps 1 --tls-verify=none \
        --debug-dump /tmp/diag.bin "写一个文件" 2> /tmp/diag.err

对照（修前 / 修后）：
    wc -c /tmp/diag.err            # 297 → 330 字节
    grep -c $'\\r' /tmp/diag.err   # 7（裸 CR，每个都会变成转录里的一行）→ 0
    head -3 /tmp/diag.err          # 最后一行是**一行**转义预览 + 「… N bytes total」
    grep -o '"kind":"[a-z-]*","bytes":[0-9]*' ~/.uya-agent/sessions/*/*/session.jsonl
"""
import json
import socket
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0

# 让回显体带上一点「多字节字符 + 控制字节」，把转义与字符边界一起验了
NOTE = "网关拒绝：invalid request body（这是一条很长的中文说明，用来触发预览截断）"


def read_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return data
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
    return head + b"\r\n\r\n" + body


def handle(conn):
    req = read_request(conn)
    # 关键：错误体里**原样**塞进收到的请求（含请求头的 CRLF 与组装好的 tools 数组）
    body = b'{"error":{"message":"' + NOTE.encode() + b'"},"request":' + req + b'}'
    head = (
        "HTTP/1.1 400 Bad Request\r\n"
        "Content-Type: application/json\r\n"
        "Connection: close\r\n"
        "Content-Length: %d\r\n\r\n" % len(body)
    )
    conn.sendall(head.encode() + body)
    conn.close()


def main():
    global PORT
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(8)
    PORT = srv.getsockname()[1]
    print("PORT %d" % PORT, flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


main()
