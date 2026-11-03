# Drama Plugin P0 核验结论

- 文档编号：DRAMA-P0-001
- 对应设计：DRAMA-DESIGN-001 v1.3
- 对应任务：DRAMA-TODO-001 v1.3 §2.2（仍需实测）
- 状态：进行中（B1/B2/B3 已过验收，B4 已出结论，B5/B6/B8 待做）

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

---

## 2. 已出结论、不必再试

### 2.1 B4：没有 `fsync`，接受已知限制 —— 定案

```bash
grep -rn 'fsync\|fdatasync' uya/stdlib/lib --include=*.uya   # 无输出
```

**结论**：提交只保证「rename 原子 + 崩溃后可重建」，**掉电可能丢最后一次
提交**。这条写进 DESIGN §8.2 与部署文档；selftest 用「杀进程」验证恢复，
不假装能验证掉电。若将来不能接受，再单独做 syscall 包装原型（不改架构）。

### 2.2 宿主协议事实 —— 与 DESIGN §4.2 一致

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
| HTTP/HTTPS 传输层 | P5 | stdlib 无客户端；先跑通一次 JSON 请求-响应 |
| JSON 嵌套 256 上限 | P3/P5 | 大 Bible/大纲是否触顶未知 |
| 目录扫描与摘要读回 | P3/P13 | 百集索引方案要用 |
| Worker 中断/重启 | P4 | 注意上面第 5 条 |
| env/密钥注入、权限模式 | P11 | 需一次真实 `uya-agent` 会话 |
| 资产共享目录可见性 | P3/P10 | 数据根目录必须显式配置 |

---

## 5. 原型文件

| 文件 | 作用 | 验收脚本 |
|---|---|---|
| `proto/mcp_stdio.ush` | 三工具 stdio MCP server（list/describe/call） | `proto/selftest.sh` |
| `proto/txn.ush` | 原子写 + 锁 + 陈旧锁 + 崩溃注入 | `proto/txn_selftest.sh` |

两个脚本都是**可重跑**的：`sh drama_plugin/proto/selftest.sh`、
`sh drama_plugin/proto/txn_selftest.sh`，失败即 exit 1。
