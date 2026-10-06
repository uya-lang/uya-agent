# MCP 插件示例（P70）

这三个文件是**同一个插件的三种语言实现** —— 宿主只认 stdio 上的 JSON-RPC，
不关心对面是 Uya、Python 还是 POSIX shell。它们证明「任意语言写插件」不是口号：

| 文件 | 语言 | 依赖 | 配置 |
|---|---|---|---|
| `wordcount.ush` | Uya（`uya run`） | 本仓编译器（需 `UYA_ROOT`） | `--mcp-server "wc=/abs/path/uya run …/wordcount.ush UYA_ROOT=/abs/lib/"` |
| `greet.py` | Python 3 | 无（标准库） | `--mcp-server "greet=/abs/path/greet.py"` |
| `echo.sh` | POSIX shell | `/bin/sh` + `sed` | `--mcp-server "echo=/bin/sh /abs/path/echo.sh"` |

试一下（在仓库根）：

```bash
# 看插件被认出来了没有：每个 server 一行结论
./build/uya-agent --list-plugins \
    --mcp-server "echo=$PWD/examples/mcp-plugins/echo.sh"

# 只拿一个 server 对一下协议（手发两行请求，看它回什么）
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n' \
     | ./examples/mcp-plugins/echo.sh
```

## MCP 的最小契约

插件要实现的就四件事（`echo.sh` 是最短的完整例子）：

1. `initialize` → 回 `{protocolVersion, capabilities, serverInfo}`；
2. `notifications/initialized` → 通知，**不要回响应**（回了会让宿主把响应配错 id）；
3. `tools/list` → 回 `{tools:[{name, description, inputSchema}]}`；
4. `tools/call` → 回 `{content:[{type:"text",text:"…"}], isError:false}`。

帧格式：**一行一条 JSON**（`\n` 分隔）。stdin 是管道，一次 `read` 可能拿到半行或好几行 ——
所以按 `\n` 切，别假设「一次读 = 一条消息」。

不认的方法回 `-32601 Method not found`：宿主拿它判「这个 server 不认那个方法（例如某个钩子）」
并**放行** —— 所以纯工具插件不需要实现任何钩子。

## 三条从示例里学到的实务

* **`env` 要显式给**。宿主只把安全白名单（`HOME LOGNAME PATH SHELL TERM USER`）加上
  你在配置里显式写的 `K=V` 交给子进程 —— 它是第三方进程，不该看到宿主自己的
  `DSH_*` 与凭据类变量。所以 `wordcount.ush` 的例子里 `UYA_ROOT` 是显式写的：
  `--mcp-server "wc=/abs/uya run …/wordcount.ush UYA_ROOT=/abs/lib/"`。
* **`command` 不做 PATH 查找**（`execve` 只吃路径）。写 `uya` 时用的是**子进程 PATH** 里的
  那个 `uya` —— 它可能不是你刚编的那个版本。示例里一律写绝对路径，省一次「为什么工具数
  是 0」的排查。
* **`.ush` 插件的环境很窄**：`uya run` 的脚本里只有 `libc` + `std.json`，本仓的
  `Buf` / `bufx_*` 都用不了（那些要参与编译整个仓库才有）。`wordcount.ush` 顶部的注释
  记了另外两个坑：整数转字节的 `as!` 必须带 `catch`，以及
  `&"literal"[0: n]` 传给 `*const byte` 形参会让输出乱码（`Makefile` 的
  `codegen-audit` 专门扫这个形状）—— 收 `&[byte]` 形参就没这个问题。

## 想让模型真的调用它

`--list-plugins` 只证明**装载**成功。要跑一次真实工具调用：

```bash
./build/uya-agent --workspace /tmp/scratch \
    --mcp-server "wc=/usr/local/bin/uya run $PWD/examples/mcp-plugins/wordcount.ush UYA_ROOT=/usr/local/lib/" \
    "用 word_count 数一下 README.md 的前 20 行"
```

模型侧看到的名字是 `mcp__<serverName>__<rawName>`（上例里是 `mcp__wc__word_count`）——
名字里的非法字符会换成 `_`，太长会截断并补 12 位 sha256 后缀（与 DSH 同一套规则）。
