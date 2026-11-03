# Drama Plugin P0 核验结论

- 文档编号：DRAMA-P0-001
- 对应设计：DRAMA-DESIGN-001 v1.3
- 对应任务：DRAMA-TODO-001 v1.3 §2.2（仍需实测）
- 状态：进行中（B1/B2/B3/B5-前半/目录枚举/队列契约/Worker 恢复 已过验收；B4 已定案；B6/B7 部分）

每条结论只写三样东西：**怎么验的、验出什么、对设计的影响**。
没有跑过的项标「待实测」，不用推测填。

---

## 1. 已验收（有脚本、可重跑）

### 1.1 B1：Uya 写 stdio MCP Server 的最小闭环 —— 已验收

**怎么验的**：`drama_plugin/proto/mcp_stdio.ush` + `proto/selftest.sh`。
脚本喂 11 条请求（含 1 条通知、1 条 >1 MiB），对 stdout 逐条断言。

```bash
sh drama_plugin/proto/selftest.sh
# run: exit=0 stdout=9 行 stderr=0 字节
# PASS: B1 闭环（4 方法 + 3 工具）/ B2 帧格式（单行紧凑、≤1 MiB、stderr 干净）
```

**验出什么**：

- 四个基础方法全部可手写实现：`initialize`（回 `2024-11-05`）、
  `notifications/initialized`（不回响应）、`tools/list`、`tools/call`；
- 未知方法回 `-32601`，服务端不退出；
- EOF 后返回 0，不留半条消息；
- 三个工具的 raw 名就是 `list` / `describe` / `call`（不带点），
  `inputSchema` 是普通 JSON Schema；
- 业务失败用 `{"success":false,...}` + `isError:false`，
  协议失败用 JSON-RPC `error`——两种信封可以共存，模型侧可区分。

### 1.2 B2：帧格式硬约束 —— 已验收

**验出什么**：

- 单行紧凑输出可判定：脚本断言「响应原文除行尾外不含 `\n`」；
- 超 1 MiB 的请求可以被**整行丢弃且不中断服务**（原型里 `read_line`
  读到上限后继续读到行尾再丢，后续请求照常响应）；
- stderr 干净：编译告警修掉后，正常一轮会话 stderr 为 0 字节。

### 1.3 B7（部分）：宿主真的能连上 —— 已验收（工具发现部分）

```bash
./build/uya-agent --list-plugins \
  --mcp-server "drama=/abs/uya run /abs/mcp_stdio.ush UYA_ROOT=/abs/uya/stdlib"
# MCP servers: 1
# drama: 3 tool(s)
# MCP tools: 3
# (stdio transport only; tools are named mcp__<server>__<tool>)
```

**验出什么**：`command` 走绝对路径、`env` 可以跟在命令后传、
`serverName` 合法（`drama`）、三个工具被宿主认出来。

**待补**：`tools/call` 经宿主 + 模型的端到端（需要一次真实模型回合），
以及 read-only / workspace-write 下的权限行为——这两条仍未实测。

### 1.4 B3：文件事务、锁、陈旧锁、崩溃窗口 —— 已验收

**怎么验的**：`drama_plugin/proto/txn.ush` + `proto/txn_selftest.sh`。

```bash
sh drama_plugin/proto/txn_selftest.sh
# PASS: B3（原子写 / 锁互斥 / 陈旧锁回收 / 崩溃不留半个文件）
```

**验出什么**（每条都是实测，不是推理）：

- **原子写**：`O_CREAT|O_EXCL` 建 `<path>.tmp`（0600）→ 写满 → `sys_rename`
  到目标；成功时目标大小正确、无残留 tmp；
- **锁互斥**：两个进程抢同一把锁，第二个拿到 `BUSY <pid>`；
- **陈旧锁**：`kill -9` 持有者后再抢，得到 `STALE-RECOVERED <pid>`
  ⇒ `pid + kill(pid,0)` 探活可行，不会把项目变永久只读；
- **崩溃窗口**：在「数据已写进 `.tmp`、rename 还没发生」处硬杀进程，
  目标文件**不存在**，`.tmp` 完整保留（1048576 字节）
  ⇒ **不会出现半个文件**，孤儿 tmp 可被后续清理回收；
- 崩溃后同名目标可由下一次事务写成功（重试路径可用）。

### 1.5 B6（部分）：非 ASCII JSON 往返 —— 已验收

**验出什么**：`request_id` 传中文，返回里中文**原样透传**（UTF-8 字节），
没有被转义成 `\uXXXX`。对设计的影响：不必担心「中文被转义后长度翻 6 倍」，
但仍要按**码点**而不是字节算文本长度（DESIGN §16.3 的口径不变）。

### 1.6 B5（前半）：HTTP 客户端 —— 已验收

**怎么验的**：`drama_plugin/proto/http_client.ush` + `proto/http_selftest.sh`，
自己起一个 `python3 -m http.server` 和一个「只 accept 不回包」的黑洞端口。

```bash
sh drama_plugin/proto/http_selftest.sh
# PASS: B5（HTTP GET / 状态行 / header 边界 / 404 / 拒绝 / 超时）
```

**验出什么**：

- `sys_socket` / `sys_connect` / `sys_send` / `sys_recv` 在 Uya 里可用，
  IPv4 字面量地址直接构 `sockaddr_in` 即可；
- 请求头自己拼（`HTTP/1.1` + `Connection: close`），响应按
  `\r\n\r\n` 切 header/body，状态行取第 9–11 字节；
- 404 如实返回状态码，不抛异常；
- 连接被拒 → `ERR connect`，不挂死；
- **超时预算真的生效**：客户端自报 `ELAPSED 3002`（预算 3000 ms），
  而不是靠外层 `timeout` 收尸。

**仍未做（同一项的后半）**：TLS（`lib/tls/https.uya` 只有握手原语，
证书校验/SNI 要自己接）、域名解析（现在只接受 IP）、重定向、
分块传输、SSE/流式、连接复用。这些是 P5 之前必须补的，别被"能 GET 了"骗过去。

### 1.7 目录枚举与文件摘要 —— 已验收

**怎么验的**：`drama_plugin/proto/scan.ush` + `proto/scan_selftest.sh`
（自己造目录、造 1000 个空文件、造空文件与一字之差的文件）。

```bash
sh drama_plugin/proto/scan_selftest.sh
# PASS: 目录枚举 + 摘要（百集索引前置能力）
```

**验出什么**：

- `sys_getdents64` 在 Uya 里可用；Linux 记录布局是
  `d_ino(8) d_off(8) d_reclen(2) d_type(1) name…`，按 `d_reclen` 逐条走，
  跳过 `.`/`..`，空目录返回 `COUNT 0` 不报错；
- 文件摘要可复现：同内容同摘要、一字之差不同摘要、空文件等于
  FNV-1a 64 的偏移基值 `cbf29ce484222325`（实现正确的硬证据）；
- **1000 个文件一轮枚举，整轮墙钟 3 s（含 uya 编译）**
  ⇒ DESIGN §8.7 担心的"扫全树会慢"在 1000 量级上不成立，
  索引的价值主要在"避免每次提交都全量扫"，而不是"扫不动"。

**对设计的影响**：§8.7 的索引仍是必要的（4500–6000 文件 × 每次提交），
但判据可以更硬：单次 `list`/`continuity.inspect` < 200 ms 靠索引，
而不是靠"文件少"。

### 1.8 本地生成队列契约 —— 已采集（读侧）

**怎么采的**：本机队列正在跑真实任务时，直接读
`/system_stats`、`/prompt`、`/queue`、`/history`、`/view`。
写侧（`POST /prompt`）**故意没提交**——会占 GPU，留到 P8 的真实链路里测。

**结论**：见 `proto/LOCAL_QUEUE_CONTRACT.md`，五个关键事实：

1. 视频产物出现在 `outputs.<node>.images[]`，靠 `animated: [true]` 识别，
   找 `videos` 键会颗粒无收；
2. `client_id` 由调用方给，落在 `extra_data` 里 ⇒ **这是幂等键的落点**：
   提交后崩溃时按 `client_id` 扫最近历史找回来，不盲目重发；
3. 未知 `prompt_id` 返回 `{}` 而不是 404 ⇒ 轮询必须把空 dict 当"未完成"；
4. 单卡单槽（`queue_running` 长度实测 1）⇒ 并发上限 1，产能基线成立；
5. 取消分两种：排队中 `DELETE /queue`、执行中 `POST /interrupt`。

**对设计的影响**：DESIGN §10.3 的 `submit/poll/fetch/cancel/depth`
可以直接按这张表实现；`GET /prompt` 的 `queue_remaining` 用来派发前限流。

### 1.9 Worker 中断/重启 —— 已验收

**怎么验的**：`drama_plugin/proto/worker.ush` + `proto/worker_selftest.sh`。
每步完成后向 journal **追加**一行 `done <n>` 并 close；启动时读 journal
取最大已完成步，从下一步继续。测试在第 4 步执行中硬杀，再重启。

```bash
sh drama_plugin/proto/worker_selftest.sh
# 被杀时已完成: 3 步
# 重启 -> RESUME 4 / FINAL 10
# PASS: Worker 中断/重启（检查点续跑、不重复执行）
```

**验出什么**：

- 首次运行 `RESUME 1`（无历史）；中途硬杀后重启 `RESUME 4`，
  **没有从 1 重跑**，也没有跳步；
- 跑完后 journal 恰好 10 条 `done`、10 个不同步骤 ⇒ **每步恰好执行一次**；
- 这条断言正是 DESIGN §9.3「只恢复未完成步骤，不重复执行已完成步骤」
  的可判定版本。

**配套注意**：杀进程必须按进程组杀（见 §3 第 5 条），否则测出来的是
"假崩溃"——脚本里 `kill -9 -$pid` + `pgrep` 轮询到进程真的消失才算数。

---

## 2. 已出结论、不必再试

### 2.1 B4：没有 `fsync`，接受已知限制 —— 定案

```bash
grep -rn 'fsync\|fdatasync' uya/stdlib/lib --include=*.uya   # 无输出
```

**结论**：提交只保证「rename 原子 + 崩溃后可重建」，**掉电可能丢最后一次
提交**。这条写进 DESIGN §8.2 与部署文档；selftest 用「杀进程」验证恢复，
不假装能验证掉电。若将来不能接受，再单独做 syscall 包装原型（不改架构）。

### 2.2 宿主的 env 与权限事实（源码级复核，1.3 修正了一条错判）

**env 白名单**（`src/plugin/mcprun.uya:159-180`）：子进程只继承
`HOME LOGNAME PATH SHELL TERM USER` 六个变量，再叠加配置里的 `env`
（同名后者胜）。⇒ 代理、API Key、`DSH_*` 一律看不见，必须写进配置。

**MCP 工具批准**（`src/plugin/mcp.uya:1019-1049`，判定在
`src/tools/perm.uya:124-136`）：

| 模式 | 行为 |
|---|---|
| read-only | 每次都要用户批准 |
| workspace-write | 每次都要用户批准 |
| danger-full-access | 直接放行 |
| 无回答渠道（非交互/子代理） | fail closed（等于拒绝） |

⚠ **DESIGN 1.2 原来写"read-only 下 MCP 工具一律拒绝"是错的**：
`perm_requires_approval()` 只在 read-only 为真，`perm_confine()` 在
read-only 与 workspace-write 都为真，两者取或 ⇒ 这两种模式都是"逐次批准"。
1.3 已按源码改正（DESIGN §14.2）。

**推论**：百集无人值守不能靠 Agent 循环调 `call`（会 fail closed），
必须由 Worker 自己推进——这正好与"Worker 独立进程"的架构决策一致。

### 2.3 宿主协议事实 —— 与 DESIGN §4.2 一致

`--list-plugins` 的输出直接印证：仅 stdio、工具名 `mcp__<server>__<tool>`、
`serverName` 参与命名。没有发现与文档不一致之处。

---

## 3. Uya 写法的实证坑（P1 之前必须知道）

这几条都是这次原型里**编译或运行失败过**的，不是抄来的注意事项：

1. **`--strict-overflow` 卡普通算术**：`v = v * 10 + d` 直接编译失败
   （`i64 溢出无法证明`）。要么加区间守卫，要么用饱和/包装运算符。
   解析 JSON-RPC 的 `id`、把数字转字节都会踩到。
   ⚠ 仓里 `examples/mcp-plugins/wordcount.ush` 现在就是因此**编译不过**
   （第 237 行），照抄它会直接卡住。
2. **`&const byte` 直接下标会被 DEBUG 检查拒绝**
   （`DEBUG_BYTE_PTR_SUBSCRIPT_ERROR`）：从行缓冲里截路径要写成带边界检查的
   拷贝函数，先把长度证明出来。
3. **`&"literal"[0: n]` 强转成字节指针会出 codegen 警告**
   （slice 描述符被当指针）：静态字符表用 C 串形式
   （`"0123456789abcdef" as &const byte`），别用切片再强转。
4. **`sys_*` 收的是 C 串**：把 `&line[i]` 直接传给 `sys_open`/`sys_rename`，
   路径后缀会带上行缓冲里的残留字节——原型第一版就因此「写成功但文件找不到」。
   路径必须先拷进 NUL 结尾的缓冲。
5. **`uya run` 会再起一个子进程**：只 `kill -9` 包装进程时子进程还活着，
   于是「崩溃测试」测的是假崩溃（.tmp 照样被提交）。测试必须按**进程组**杀
   （`setsid` + `kill -9 -<pid>`，再等进程真的消失）。
   这条对 P4 的「事务与恢复测试」同样适用。

---

## 4. 待实测（P0 剩下的活）

| 项 | 卡住谁 | 备注 |
|---|---|---|
| HTTP 后半：TLS / DNS / 重定向 / 分块 / SSE / 复用 | P5 | 明文 GET 已通（§1.6） |
| JSON 嵌套 256 上限 | P3/P5 | 大 Bible/大纲是否触顶未知 |
| 目录扫描与摘要读回 | P3/P13 | 已验收（§1.7）；正式实现用 sha256 |
| Worker 中断/重启 | P4 | 已验收（§1.9）；真实 Worker 还要接任务锁与 Provider 轮询 |
| env/密钥注入、权限模式 | P11 | 需一次真实 `uya-agent` 会话 |
| 资产共享目录可见性 | P3/P10 | 数据根目录必须显式配置 |

---

## 5. 原型文件

| 文件 | 作用 | 验收脚本 |
|---|---|---|
| `proto/mcp_stdio.ush` | 三工具 stdio MCP server | `proto/selftest.sh` |
| `proto/txn.ush` | 原子写 + 锁 + 陈旧锁 + 崩溃注入 | `proto/txn_selftest.sh` |
| `proto/http_client.ush` | 明文 HTTP GET + 超时 | `proto/http_selftest.sh` |
| `proto/scan.ush` | 目录枚举 + 摘要 | `proto/scan_selftest.sh` |
| `proto/worker.ush` | Worker 检查点续跑（journal 追加写） | `proto/worker_selftest.sh` |
| `proto/LOCAL_QUEUE_CONTRACT.md` | 本地队列实测契约（读侧） | 现场采集，样本在文档里 |

两个脚本都是**可重跑**的：`sh drama_plugin/proto/selftest.sh`、
`sh drama_plugin/proto/txn_selftest.sh`，失败即 exit 1。
