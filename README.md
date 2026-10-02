# uya-agent — 纯 Uya 写的极简 CLI 编程 agent

一个**只用 Uya 源码**实现的命令行编程 agent：给它一句话任务，它自己看文件、改文件、跑命令，
多轮 loop 直到给出结论。全部代码 5 个 `.uya` 文件、约 3200 行，**不引入任何 C 代码、`@c_import`
或其它语言**，只依赖 Uya 语言与随编译器分发的标准库。

```
$ DEEPSEEK_API_KEY=sk-xxx ./build/uya-agent "在当前目录创建 hello.uya，编译并运行它"
[task] 在当前目录创建 hello.uya，编译并运行它
[step 1] tool: write_file
[step 2] tool: run_shell
Hello, Uya!
已创建并运行 hello.uya，输出为 Hello, Uya!。
```

---

## 1. 构建与运行

需要一个 Uya 编译器（默认用 `/home/winger/uya-0.10`，可在 Makefile 里改）：

```bash
make check        # 词法/语法/类型检查
make build        # 产出 build/uya-agent
make selftest     # 离线端到端自测（内置 mock LLM，不需要网络也不需要 key）
make probe        # 传输层探针：打真实 https 端点，期望 HTTP 401（不需要 key）
```

不带 make 的等价命令（关键点：**显式导出 `UYA_ROOT`**，并尽量用编译器的绝对路径）：

```bash
export UYA_ROOT=/home/winger/uya-0.10/lib/
export UYA_SPLIT_C_DIR=$PWD/build/uyacache      # 多文件 C 缓存别丢在仓库根目录
/home/winger/uya-0.10/bin/uya build src/agent.uya src/httpc.uya src/jsonx.uya src/tools.uya src/selftest.uya -o build/uya-agent
```

用法：

```bash
./build/uya-agent "任务..."          # 一次性执行
./build/uya-agent                    # REPL：逐行输入任务，空行/exit/Ctrl-D 退出
./build/uya-agent --selftest         # 离线自测
./build/uya-agent --probe            # 传输层探针
./build/uya-agent --help
```

| 选项 | 说明 |
|---|---|
| `--base-url URL` | 默认 `https://api.deepseek.com/v1`（也支持 `http://127.0.0.1:11434/v1` 这类本地明文端点） |
| `--model NAME` | 默认 `deepseek-chat` |
| `--workspace DIR` | 工具的活动目录，默认当前目录 |
| `--max-steps N` | 最多几轮工具调用，默认 12（熔断，防止模型绕圈） |
| `--max-response N` | 响应体上限，默认 256 KiB |
| `--timeout-ms N` | 单次 HTTP 超时，默认 120 s |
| `--no-shell` | 不提供 `run_shell`（tools schema 里也不会出现） |
| `--tls-verify=chain\|pin\|none` | TLS 信任策略，默认 `chain`，见第 5 节 |
| `--tls-pin HEX` | `pin` 模式要求的 leaf 证书 SHA-256（小写 hex） |
| `--quiet` | 不打印每步工具调用信息 |
| `--tls-debug` | 保留 `lib/tls` 的握手调试输出（默认静音，见第 3 节第 14 条） |
| `--http-debug` | 打印每轮响应的头与体首字节（排查网关怪异响应用） |

环境变量：`UYA_AGENT_BASE_URL`、`UYA_AGENT_MODEL`、`UYA_AGENT_WORKSPACE`、`UYA_AGENT_MAX_STEPS`、
以及 key（三选一）：`UYA_AGENT_API_KEY` / `DEEPSEEK_API_KEY` / `OPENAI_API_KEY`。

退出码：`0` 成功 · `1` 用法/配置错 · `2` 传输错（DNS/TCP/TLS/超时）· `3` 模型或协议错 · `4` 工具/工作区错。

---

## 2. 代码结构

```
src/httpc.uya     传输层：Buf、URL 解析、DNS+TCP、TLS 会话、请求构造、响应解析、leaf 指纹
src/jsonx.uya     JSON：JsonWriter 组装请求；JsonValue 导航取值；字符串反转义（关键，见下）
src/tools.uya     三个工具：read_file / write_file / run_shell
src/agent.uya     CLI、环境变量、对话历史、请求组装、主循环、工具分发、REPL
src/selftest.uya  --selftest 的内置 mock LLM + --probe
```

数据流（一轮）：

```
history ──build_request(JsonWriter)──▶ POST {base_url}/chat/completions ──http_request──▶ 响应体
   ▲                                                                                      │
   │                                                      std.json.parse → choices[0].message
   │                                                                                      │
   └── 追加一条 user 消息（工具结果文本） ◀── dispatch_tool ◀── tool_calls[0..n] ──────────┘
                                          （无 tool_calls 时：打印 content，结束）
```

### 对话协议是刻意「极简」的

模型返回 `tool_calls` 后，本地执行工具，把结果拼成**一条 `user` 消息**回灌，**不**回灌
assistant 的 `tool_calls` 原样 JSON。好处是彻底绕开 `tool_call_id` 配对要求，DeepSeek / ollama /
vLLM 等 OpenAI 兼容端点都一样稳。想升级成严格 `tool` 角色消息，只需把 `tool_calls` 的 `id`
存进历史并在回灌时用它（`agent.uya` 的 `has_calls` 分支就是改这一点）。

---

## 3. 用 Uya 写这类程序踩过的坑（都已在代码里修掉，值得单独记住）

1. **`std.json` 的字符串是零拷贝、未反转义的**。`JsonStrView` 指向原始缓冲区，`\"` `\\` `\n`
   这些转义序列**没有解码**。所以工具调用的 `arguments`（它本身是一段 JSON 文本）必须先
   反转义再 `parse`，否则永远得到“arguments are not valid JSON”。见 `jsonx.uya::sv_unescape`。
2. **`buf_append_cstr` 不补 `\0`**。凡是要把 `buf.ptr` 当 C 字符串传给 `sys_open`/`execve`
   的地方必须用 `buf_append_cstr_z`；否则系统调用会把缓冲区后面的残留字节当成路径的一部分，
   表现为莫名其妙的 `ENOENT`（这个坑让本项目的自测排查了好几轮）。
3. **错误值不能当参数传递**：`fn f(err: error)` 不是合法语法，错误只能在 `catch |err| {}` 内处理
   （`@error_name(err)` / `@error_id(err)`）。
4. **union 的构造是 `JsonValue.json_null()`**，不是结构体字面量 `JsonValue{ json_null: 0 }`。
5. **一行的 `catch` 要带分号**：`catch { 0 as usize; }`；写成 `{ 0 as usize }` 是语法错误。
6. **数组成员的下标安全证明只认「局部变量」**：`h.items[h.len]` 会被拒（“数组索引安全证明失败”），
   要先 `const idx: usize = h.len;` 再 `h.items[idx]`。
7. **模块级名字会全局合并**：`Conn`（撞 `std.http.types.Conn`）、`now_ms`（撞 `std.time.now_ms`）
   都导致过编译失败。私有辅助函数最好带项目前缀。
8. **`export fn main() i32`，不要 `!i32`**：多文件 split-C 构建时，`!i32` 生成的
   `main_main` 原型会和 `entry.uya` 的 `extern fn main_main() i32` 冲突（`conflicting types for 'main_main'`）。
9. **`&"text"[0:n] as &const byte` 是错的**：`&"text"[0:n]` 是**切片**，转成指针拿到的是切片的地址。
   要传 C 指针就传 `&buf[0]` 或 `slice.ptr`。同理 `sys_write(2, &"x"[0:1], 1)` 会编译失败，
   写成 `s.ptr, s.len`。
10. **`sys_fork` 是标准语义**（原进程拿到子进程 pid，`pid == 0` 是子进程）；子进程里用 `sys_exit(n)`。
11. **`ssl_write` 每次调用加密整段明文**，必须按 `RECORD_MAX_PLAIN = 16384` 分片；
    **`HandshakeCtx.server_flight_msg` 存的是握手消息流**（类型+3 字节长度+内容），不含 TLS record 头；
    **服务端响应后的 `close_notify` 是 record 类型 21（alert）**，要当 EOF 处理而不是当错误。
12. **`poll` 要处理 `POLLHUP`**：子进程“写完就退出”时只给 `POLLHUP` 不给 `POLLIN`，
    漏掉它就会“命令早就结束了却一直读到超时”。
13. **从已解析的 JSON 里取字段值，还要再反转义一次**（本项目最隐蔽的一个 bug）：
    `arguments` 那层反转义后 `parse` 出内层对象，但内层对象的 `content`/`path`/`command`
    仍然是 `std.json` 给的**未解码原始视图** —— 所以 `write_file` 会把模型写的 `\n`、`\"` 当成
    两个字符原样写进文件，生成一个“满屏字面量 `\n`”的源文件。规则是：**凡是 std.json 交出来的
    字符串，用它之前都要过一次 `sv_unescape`**。这个 bug 是真实模型跑 A5 时暴露的，现在自测的
    `tools` 轮用「带换行和引号的 content + 逐字节校验」把它钉住了。
15. **`std.json.parse` 是零拷贝的 —— 用完 JsonValue 树之前不能释放响应体**（本项目最严重的一个
    bug，表现为**偶发**失败）：`JsonValue` 里的字符串全是「指向输入缓冲区的视图」，而 agent 早期
    版本在 `parse` 之后立刻 `resp_free()`，随后再去查 `choices/message` 并派发工具 —— 内存一旦被
    堆复用，就报 `response has no choices[0].message`，或者工具拿到被覆盖的字符串。它时好时坏，
    很容易误判成“网关抽风”。正确做法：**先把响应体复制进 arena，再 parse，然后才释放响应体**
    （每轮一次 memcpy，代价可忽略）。同一个坑还教育了我：给这个报错加的“打印原始响应”诊断本身
    也在读已释放内存，所以第一版诊断打出来的是乱码 —— 诊断代码同样要守生命周期。
16. **`lib/tls` 会把握手全过程写到 fd 2**（`https_debug`/`hs_debug`）：CLI 里得在发请求期间把
    fd 2 临时指向 `/dev/null`（`dup(2)`→`open("/dev/null")`→`dup2`→请求→`dup2` 还原），
    否则用户会看到满屏 `[HS] ... [TLS] ...`；`--tls-debug` 保留原样便于排查。

---

## 4. 工具实现要点

| 工具 | 实现 | 限制 |
|---|---|---|
| `read_file` | `sys_open` + `sys_read` 循环读进堆缓冲 | 单次最多 64 KiB，超出附 `[truncated]` |
| `write_file` | `sys_open(O_WRONLY\|O_CREAT\|O_TRUNC, 0644)`；父目录缺失时 `mkdir` 一层后重试 | 整文件覆盖写 |
| `run_shell` | `pipe` → `fork` → 子进程 `dup2`+`chdir(workspace)`+`execve("/bin/sh", ["sh","-c",cmd], envp)` → 父进程 `poll` 读 stdout+stderr → 墙钟超时 `SIGKILL` → `waitpid` | 输出上限 64 KiB；默认超时 120 s；`--no-shell` 关闭 |

路径守卫（best-effort，**不是安全边界**）：所有 `path` 相对 `--workspace` 解析，拒绝绝对路径、
`~` 开头、以及含 `..` 段的路径。工具内部任何失败都不抛错，一律写成 `error: ...` 文本回给模型，
让它自己纠正；`run_shell` 本身当然能执行任意命令，所以别拿它当沙箱用。

---

## 5. TLS 信任策略（重要，和标准库现状有关）

`lib/tls` 是**真 TLS 1.2 客户端**（SNI、ECDHE-P256、PRF、Finished、系统信任库），实测对
`api.deepseek.com` 能完成握手并拿到 `HTTP/1.1 401`。但它的**链校验在真实站点上基本不可用**：

* `verify_chain_rsa` 要求「服务端发来的**链顶**证书公钥 == 某个信任锚」——真实站点不会把自己的
  根证书一并发来，所以这条路对 `api.deepseek.com` / `ping0.com` 都失败（`example.com` 恰好能过）；
* `cert_verify_signature` 只支持 SHA-256 + RSA PKCS#1 v1.5，SHA-384 的链过不去；
* `ssl_set_peer_identity` 把 `peer_san/peer_cn` 设成**我们自己传进去的期望域名**，
  所以标准库那一步“主机名校验”实际是拿期望值和期望值比，等于没校验。

因此本项目**不改标准库**，而是在 agent 侧提供三档策略：

| 模式 | 行为 |
|---|---|
| `--tls-verify=chain`（默认） | 握手后调用导出的 `verify_chain_rsa`，语义与标准库一致——安全，但真实站点通常会失败，失败时会打印精确原因 |
| `--tls-verify=pin` | 跳过链校验，直接校验**服务端 leaf 证书 DER 的 SHA-256** 是否等于 `--tls-pin`。指纹从 `HandshakeCtx.server_flight_msg` 自己解析出来（不依赖 `cert_parse` 的 RSA 前提），实测与 `openssl s_client | openssl x509 -outform DER | sha256sum` 完全一致 |
| `--tls-verify=none` | 不校验，仅打印观测到的 leaf SHA-256 与告警，方便你先 TOFU 再改成 `pin` |

推荐用法：先跑一次 `--probe --tls-verify=none` 拿到指纹，之后一律用 pin 模式：

```bash
./build/uya-agent --probe --tls-verify=none                 # 记下 leaf_sha256
DEEPSEEK_API_KEY=sk-xxx ./build/uya-agent \
  --tls-verify=pin --tls-pin 30d82529d19c5da6175a80db1c5522ac3ba5b42589212405cdc8783a1bf047fa \
  "创建 hello.uya，编译并运行它"
```

本地明文端点（ollama / llama.cpp 的 OpenAI 兼容接口）不走 TLS，直接 `--base-url http://127.0.0.1:11434/v1` 即可。

> 后续可做的（本项目**没做**）：给 `lib/tls` 补一条真正的链构建（用 issuer/签名关系从 leaf 走到
> 信任锚、支持 SHA-384）、并把 leaf 的 SAN 真正解析出来做主机名校验。做完之后 `chain` 模式就能
> 直接对云端可用、也不再需要 pin。

---

## 6. 自测与验收

`make selftest` 完全离线（在 `127.0.0.1:0` 上 fork 一个纯 Uya 写的 mock LLM），跑两轮真实
agent 循环并逐项断言：

| 轮次 | 覆盖点 |
|---|---|
| `shell` | tools schema 里有 `run_shell`；一轮里返回**两个** tool_calls（`write_file` + `run_shell`）；第二轮请求里必须出现 `wrote … note.txt`、`SELFTEST-SHELL-OK`、`exit=0`；落盘文件逐字节比对 |
| `no-shell` | `"name":"run_shell"` 不出现在请求里；其余同上 |
| `tools` | 一封 tool_calls 里塞 4 个调用：`write_file`（**content 带换行与引号**）、`read_file` 读回、`read_file ../escape.txt`（必须被路径守卫拒绝）、`run_shell sleep 5 timeout=300`（必须被 SIGKILL 并回 `(timeout, killed)`）；请求里内容必须只被转义一次；**末轮响应用 chunked 编码**；落盘 `esc.txt` 逐字节校验 |
| `http401` | mock 回 401 + 错误体：agent 必须打印状态与错误体并退出 3 |
| `max-steps` | mock 每轮都给 tool_calls：agent 必须在 `max_steps` 步后熔断退出 3 |

另外三条独立验收：

```bash
make check                                   # A1 类型检查通过
make build                                   # A2 产出 build/uya-agent
make probe BASE=https://api.deepseek.com/v1  # A4 期望 HTTP 401 + leaf 指纹（无需 key）
DEEPSEEK_API_KEY=... ./build/uya-agent --tls-verify=pin <sha256> "创建 hello.uya，编译并运行它"   # A5 真实端到端
```

**目前状态：A1–A6 全部通过。**

A5 用真实模型跑通的原话（`autodl-api` 网关，模型 `DeepSeek-V4.1-Flash`）：

```bash
UYA_AGENT_API_KEY=… ./build/uya-agent \
  --tls-verify=pin --tls-pin d0265eff44831df3d69b20bcb4ac05459ba59d73a03f8f819ee1f4f1f0e42538 \
  --base-url https://www.autodl.art/api/v1 --model DeepSeek-V4.1-Flash \
  --workspace build/e2e_real2 --max-steps 14 --timeout-ms 180000 \
  "在当前目录创建 hello.uya（打印 Hello, Uya! 的 Uya 程序），编译并运行它，然后告诉我运行输出。"
```

修掉下面第 15 条那个零拷贝 use-after-free 之后，这个任务**连跑两次都稳定通过**（每次 3–4 步工具调用后给出结论），
产物 `hello` 是真实 ELF，**独立运行输出 `Hello, Uya!`**。

关于 key：`~/.dsh/.credentials.yaml` 里那把 `DEEPSEEK_API_KEY` 是**有效但余额不足**的
（`api.deepseek.com` 返回 402 `Insufficient Balance`），所以 A5 换用了 harness 自己配置的
`autodl-api` 网关（同样是 OpenAI 兼容 `chat/completions`）。

---

## 7. 已知限制

* 只支持**非流式**（`stream:false`）；没做 SSE 增量输出。
* 上下文管理很朴素：整个历史每轮重新序列化，超过 24 条/单条 200 KiB 时丢最老的对话；
  没做 token 计数或智能摘要。
* `read_file` 一次最多 64 KiB；`write_file` 是整文件覆盖，没有 diff/patch 工具。
* 只做 IPv4（标准库 `dns_client_resolve_first_ipv4`），不做 IPv6、不走代理。
* 目标平台是 Linux x86-64（代码里的 syscall/常量按这个平台写）。
* 换到 `uya-0.11`：`tls/https.uya`、`std/json/*`、`x509/verify.uya` 与 0.10 逐字节相同，
  但 `libc/syscall.uya`、`std/runtime/runtime.uya`、`tls/ssl/context.uya` 有差异，需要重新验证
  （`make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...`）。
