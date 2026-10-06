#!/bin/sh
# examples/mcp-plugins/echo.sh — 用 POSIX shell 写一个 MCP 插件（P70 示例）
#
# 三种示例里最「无依赖」的一个：只有 /bin/sh 与 sed，任何 Linux 都能跑。
# 它证明插件不需要 SDK、不需要解释器、不需要构建 —— 只要进程能在 stdio 上
# 一问一答地读写 JSON 行。
#
# 配置：
#   uya-agent --mcp-server "echo=/bin/sh $PWD/examples/mcp-plugins/echo.sh"
# （用 `/bin/sh <脚本>` 起就不需要可执行位；直接 `./echo.sh` 则需要 chmod +x）
#
# ⚠ 静态常量走**双引号**（`printf '...'` 里的单引号在 sh 里不展开变量），
#   下面凡是要插变量（%s / $id）的地方都用双引号，且 JSON 里需要的 `"` 写成 `\"`。

while IFS= read -r line; do
    # 取 id（整数）；通知没有 id，此时 $id 为空
    id=$(printf '%s' "$line" | sed -n 's/.*"id"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p')
    # 取 method 的值
    method=$(printf '%s' "$line" | sed -n 's/.*"method"[ ]*:[ ]*"\([^"]*\)".*/\1/p')

    case "$method" in
        initialize)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"echo","version":"1.0"}}}\n' "$id"
            ;;
        notifications/initialized)
            : ;;   # 通知：不回响应
        tools/list)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo back the text you pass.","inputSchema":{"type":"object","properties":{"text":{"type":"string","description":"Text to echo"}},"required":["text"]}}]}}\n' "$id"
            ;;
        tools/call)
            # 从 arguments 里取 text（够用即可：示例的重点是协议形状，不是通用 JSON 解析）
            text=$(printf '%s' "$line" | sed -n 's/.*"text"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
            if [ -z "$text" ]; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"missing required argument \\"text\\""}],"isError":true}}\n' "$id"
            else
                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"echo: %s"}],"isError":false}}\n' "$id" "$text"
            fi
            ;;
        *)
            # 不认的方法（含宿主试的钩子）：-32601 ⇒ 宿主放行
            if [ -n "$id" ]; then
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
            fi
            ;;
    esac
done
