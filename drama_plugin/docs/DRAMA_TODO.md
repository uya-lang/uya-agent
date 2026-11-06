# Drama Plugin 开发任务清单

- 文档编号：DRAMA-TODO-001
- 版本：1.3
- 对应设计：DRAMA-DESIGN-001 v1.3
- 状态：待开发（P0 已有 3 条已知阻塞，见 §0.3）
- 验收终局：**100 集、四轴连续性机器可判定**（M1→M4，见 §1）

---

> 实现到哪一步、代码在哪、怎么复核：见 `docs/DRAMA_STATUS.md`
> （12 个可重跑验收脚本 + 22 个源文件的地图 + 已知限制）。

## 0. 开发约束

1. Drama 是独立 Uya 项目，不修改 `uya-agent` Agent Core。
2. MCP 固定只注册 `list`、`describe`、`call` 三个工具
   （公开名 `mcp__drama__list` 等；工具名不带点）。
3. 业务操作通过内部 Operation Registry 注册和分发。
4. Drama Plugin 自己实现 LLM Provider Adapter，不依赖宿主 Agent 代为创作。
5. MCP Server 与 Worker 分成两个运行模式/进程，共享同一数据根目录。
6. 多媒体文件不通过 MCP 传输；首版使用同机共享资产目录。
7. LLM 只能生成候选内容，不能直接写正式 Canon。
8. 剧本审核通过时提交剧情 Canon；成片验收只提交交付资产，不改变剧情 Canon。
9. 每个阶段必须有 selftest；不能以“代码已写”代替验收。
10. 所有依赖 Uya 文件、锁、进程和协议能力的实现，先由 P0 验证。
11. **协议帧硬约束**：stdio 一行一条紧凑 JSON、单条 ≤1 MiB、日志只走 stderr。
12. **`call` 必须 60 s 内返回**（宿主默认 `toolCallTimeoutMs=60000`），
    重活一律先落盘再返回 `queued`。
13. **工程边界（B 档）**：Uya 负责 Canon/Task/MCP/Registry/审批；
    分镜出图、QC、剪辑合成走既有产线（子进程适配），不一次性重写。
14. **视频 Provider 首版接本机本地队列**（GPU 串行、`prompt_id` 即幂等键），
    云 API 留作后续。
15. **连续性必须机器判定**：四轴不变量（DESIGN §6.11）全绿才允许提交；
    人工只看内容质量，不负责"记住"状态。
16. **验收终局是百集**：M1 三集 → M2 十集 → M3 三十集跨题材 → M4 百集，
    每个台阶都要过四轴不变量，缺一不升。
17. **大纲先批准**：100 集大纲未批准，不进入逐集细化。

## 0.1 版本 1.3 的修订摘要

1. 验收目标从「三集」改为「百集闭环」，总览表加四个台阶（M1–M4）。
2. 新增 P12「闭环引擎」：四本账、9 条不变量、提交门、历史重放、反例库。
3. 新增 P13「规模与产能」：派生索引、预算熔断、批量调度、抽样审批、
   10/30/100 集门槛。
4. P4 扩「四轴事件效果」任务组：事件效果必须能表达道具移动、知识授予、
   场景状态变更与时间推进。
5. P5/P6 增加系列层任务：`Series`/`Season`/`Arc`/`EpisodeOutline` 先批准。
6. P9 增加跨集审计任务组（外观锚帧、台词语料、笑点重复、承诺回收率）。
7. P11 增加抽样审批与异常优先队列。
8. §14 覆盖矩阵补 6 条操作；§15 风险登记补 GPU 超支、跨集漂移、
   审批注意力三条。
9. 阶段总览按 M1–M4 重排「对应版本」。

## 0.2 版本 1.2 的修订摘要（历史，保留）

1. 工具名去掉点号（`drama.list` → `list`），并写明公开名规则。
2. P0 拆成「已核验」与「仍需实测」两段（10 条里 6 条已有源码级答案）。
3. P0 新增：HTTP 传输层、单行紧凑输出自测、陈旧锁、fsync 缺失的替代方案、
   非 ASCII JSON 往返。
4. P2 的 `request_id` 改为可选，幂等键 = `(operation, input_hash)`。
5. P3 增加 `format_version` 与迁移任务；存储布局补 `locks/`、`idempotency/`。
6. P5 增加「LLM 传输层」任务组（stdlib 的 HTTPS 默认校验模式 1.5 起可用）。
7. P7 补接戏字段（`anchor_prev`/`cut_type`/`transition_line`/时间轴/片尾卡）
   与 provider 能力表校验。
8. P10 删「配音替换」，补编码/响度口径。
9. P11 补宿主配置样例（绝对路径 + `env` + 超时）。
10. 阶段总览加「对应版本」列；P6 的黄金 fixture 换成真实脚本。

## 0.3 已知阻塞（开工前必须认账的三条）

- `[!]` **没有 `fsync`**：stdlib 全树没有 `fsync`/`fdatasync` 包装。提交只能
  保证「不出现半个文件 + 崩溃后可重建」，**掉电可能丢最后一次提交**。
  替代方案写在 DESIGN §8.2；若不能接受，先做「自写 syscall 包装」的原型。
- `[x]` **HTTPS 默认校验模式已可用**（1.5 实测转绿）：`https_get("example.com",
  443, "/")` 握手完成、`S: 200`。1.3/1.4 记的"证书校验没做完"已被 6 个上游
  修复推翻（记录头错位、ECDSA SPKI、ECDSA 验签 r/s 错位、扩展 OID 缓冲与
  边界、keyUsage 未用比特、信任库截断 + MPI limb 上限），全部落在上游
  `~/uya/uya/lib/tls/`（commit `b578a7ed`）。
  ⇒ P5 可以直接用 `https_get`，不必绕本机网关；**不许**默认用 insecure 调
  带 API Key 的服务。边界：不做吊销/CT；反例（错主机名、过期）还没脚本化。
- `[!]` **没有随仓 sqlite 驱动**（`std/sql` 只有 Driver/Conn 接口）。
  存储只能走「不可变提交记录 + 原子 rename」的文件方案（DESIGN §8）。

任务标记：

- `[ ]` 未开始
- `[-]` 进行中
- `[x]` 已完成并通过验收
- `[!]` 阻塞/需设计决策

不得在未运行测试时勾选完成。

---

# 1. 阶段总览

| 阶段 | 内容 | 交付物 | 依赖 | 对应版本 |
|---|---|---|---|---|
| P0 | 仓库、Uya 和 MCP 技术核验 | P0_FINDINGS.md、原型 | 无 | — |
| P1 | 独立程序和 MCP 三工具骨架 | 可连接的 MCP Server | P0 | 0.1 |
| P2 | Operation Registry 和动态 Schema | list/describe/call 闭环 | P1 | 0.1 |
| P3 | Project、Bible、Asset 和基础存储 | 可持久化项目 | P2 | 0.2 |
| P4 | Canon、事件、快照和事务恢复 | 连续性状态引擎 | P3 | 0.3 |
| P5 | LLM 传输层、Adapter 和 Story Engine | 结构化剧本生成 | P4 | 0.4 |
| P6 | 连续三集剧本验收 | **M1 闭环最小版** | P5 | 0.5（M1） |
| P7 | Storyboard 和参考资产 | 可执行分镜 | P6 | 0.6 |
| P8 | Provider、Worker 和异步任务 | 视频任务闭环 | P7 | 0.7 |
| P9 | QA、重试和失败恢复 | 可自动质检 | P8 | 0.8 |
| P10 | Media/FFmpeg 合成 | 最终成片 | P9 | 0.8 |
| P11 | 端到端验收、文档和发布 | 独立可用版本 | P10 | 1.0（M2 之一） |
| P12 | 闭环引擎：四本账、不变量、提交门、重放 | 连续性机器可判定 | P4 | 0.5 起最小版 → 1.0 |
| P13 | 规模与产能：索引、预算、批量、台阶 | 百集可测算 | P12 | 1.0 → 1.1（M3）→ 2.0（M4） |

**四个台阶（验收门，缺一不升）：**

| 台阶 | 版本 | 判据 |
|---|---|---|
| M1 | 0.5 | 3 集连续、四轴不变量零红、重放 3 集复现率 100% |
| M2 | 1.0 | 10 集无人值守、一次崩溃恢复、一次闭环审计通过、查询 < 200 ms |
| M3 | 1.1 | 30 集跨 ≥2 个题材模板，换模板不改代码 |
| M4 | 2.0 | 100 集、Mock 压力零状态错误、抽 10 集重放全绿、成本误差 < 20% |

---

# 2. P0：技术核验与工程准备

## 目标

先验证后设计实现细节，不在未知 Uya 能力上写大量代码。

1.2 已把「未知」压缩到 4 条：其余能力在宿主源码与 stdlib 里已有确定答案，
直接照做即可（见 §2.1）。

## 任务排序（1.2）

先做能改架构决策的 8 项，其余排队：
帧格式 → 超时 → 锁（含陈旧锁）→ fsync 替代方案 → HTTP 传输层 →
JSON 上限/非 ASCII → env/密钥注入 → 资产可见性。

### 2.1 已核验（写结论，不必再做原型）

- [x] 宿主协议版本 `2024-11-05`、只 stdio、只 tools（+ 自定义钩子方法）。
- [x] stdout/stdin 是协议通道：一行一条**紧凑** JSON、单条 ≤1 MiB、超限整行丢；
      日志一律 stderr。
- [x] 工具公开名 = `mcp__<server>__<raw>`，非法字符换 `_`；`serverName`
      须匹配 `^[A-Za-z0-9_-]{1,32}$` ⇒ 工具 raw 名定为 `list`/`describe`/`call`。
- [x] `toolCallTimeoutMs` 默认 **60000 ms**（可配 1–3,600,000）。
- [x] 结果投影：text 段拼接；`isError:true` 前缀 `Error: `；
      `structuredContent` 已支持（可选）。
- [x] 临时文件 + 原子重命名：`os_rename` 可用；「O_EXCL 建 tmp(0600) →
      写 → rename」在宿主里已有三处实现可照抄。
- [x] 单写者：没有 `flock`，`O_CREAT|O_EXCL` 锁文件够用（须补陈旧锁探活）。
- [x] 子进程：`std/process` pipeline + `os_spawn`/`os_waitpid`/`os_kill`。
- [x] JSON：`std/json` 有 parser/encoder + `to_json<T>`/`from_json<T>`，
      嵌套上限 **256**。
- [x] FFmpeg 调用与产物检查：既有产线已在用。

### 2.2 仍需实测（P0 的全部工作量）

> 已经验过的项在下面直接勾选，证据在 `proto/P0_FINDINGS.md`
> 与 `proto/*_selftest.sh`（均可重跑）。

- [x] **Uya 写 stdio MCP Server 的最小闭环**：单行紧凑 JSON 读写、四个基础
      方法、未知方法回 `-32601`、EOF/断管退出、stdout 零污染。
      （`proto/mcp_stdio.ush`，`sh proto/selftest.sh` 全绿）
- [-] **HTTP 传输层**（阻塞 P5）：
      明文 HTTP 已跑通（建连/请求/响应/状态行/404/拒绝/3 s 预算，
      `proto/http_client.ush`）；HTTPS 侧 1.5 起**默认校验模式**即可用
      （`https_get` 拿 200，见 `proto/https_probe_selftest.sh`）；DNS 可用
      （`std/net/dns.uya`）。1.4 定位的 6 个根因（P0_FINDINGS §1.12）已全部
      在上游修完（commit `b578a7ed`）并同步进本仓 `uya/`（编译器 v0.11.0 +
      标准库）。仍缺：吊销（CRL/OCSP）、CT、反例回归、重定向、分块、SSE、
      连接复用。
- [x] **非 ASCII JSON 往返**：实测中文**原样透传**（UTF-8 字节，不转义）；
      缓冲边界仍按码点算长度。
- [-] **本地队列 Provider 契约**：读侧已实测（`/prompt` 队列深度、
      `/queue`、`/history`、`/view` 取 mp4；`client_id` 即幂等键落点，
      见 `proto/LOCAL_QUEUE_CONTRACT.md`）；单卡串行吞吐有真实日志
      （12.5 min/镜、重做 1.56×）。仍缺：`POST /prompt` 返回形状、
      队列满/重启清空行为、取消是否真停 GPU。
- [x] **fsync 替代方案确认**：`grep -rn 'fsync\|fdatasync' uya/stdlib/lib`
      无输出 ⇒ 接受「掉电可能丢最后一次提交」，写进部署文档与 §15 已知限制。
- [x] **陈旧锁处置**：`pid + kill(pid,0)` 探活实测可用，`kill -9` 后
      `STALE-RECOVERED`；锁文件损坏路径回 `LOCK_UNREADABLE`
      （`proto/txn_selftest.sh` 覆盖前两条）。
- [x] **目录扫描与文件校验**：`getdents64` 枚举 + 摘要读回实测通过；
      1000 文件枚举整轮 3 s（含编译）。正式实现用 sha256。
      （`proto/scan.ush`，`sh proto/scan_selftest.sh`）
- [x] **Worker 中断/重启行为**：检查点续跑已验收 —— 第 4 步硬杀后
      `RESUME 4`，跑完 journal 恰好 10 条 `done` / 10 个不同步骤（每步一次）。
      杀进程必须按**进程组**杀，否则测的是假崩溃（P0_FINDINGS §3 第 5 条）。
      孤儿 tmp 的宽限期清理仍待接进真实 Worker。
- [x] **env/密钥注入**（源码级已核验）：子进程只继承
      `HOME LOGNAME PATH SHELL TERM USER`，其余靠宿主配置 `env`
      （`src/plugin/mcprun.uya`）；`command` 走绝对路径。
- [x] **资产共享目录对宿主的可见性**（源码级已核验）：宿主 fork + execve
      启动 MCP 子进程，**不套沙箱**，`cwd` 由配置给 ⇒ 数据根目录必须在配置里
      显式写绝对路径，且权限由文件系统决定（不是宿主替你挡）。

### 2.3 工程准备

- [x] 确定 Drama 独立仓库位置和命名（决定：暂留本仓 `drama_plugin/`，见 `P0_FINDINGS.md` §1）。
- [x] 阅读 Uya 模块、包、构建和 selftest 规范（28 模块 → 单可执行；22 个 p 脚本）。
- [x] 阅读 `uya-agent` 的 `DESIGN.md`（尤其 §21 插件系统）、`CODING.md`（插件契约见 §1 表）。
- [x] 确认 Uya 可执行程序的构建和发布方式（单文件，仅依赖 libc；`build/drama`）。
- [x] 确认 Linux 首版目标平台（x86_64；系统调用只用 `libc.syscall` 子集）。

### 2.4 既有产线对接调研

- [ ] 盘清既有产线的入口与产物：分镜定义（唯一来源）、静态体检、出图、
      质检、成片、终检各自吃什么、吐什么。
- [ ] 确认「Uya 只做状态与调度、产线做生成与合成」的接口边界（B 档），
      列出需要新增的最小适配层。
- [ ] 记录产线的硬约束：画布 32 倍数 / 帧数 `17k+5`、单镜时长范围、
      编码与响度参数、能力表（哪些动作演不出来）。

## 交付物

- [x] `P0_FINDINGS.md`（每条标：已验证 / 不可用 / 替代方案 / 对应测试）。
- [x] 最小 MCP Server 原型（单行紧凑输出；p1/p2）。
- [x] 最小 HTTP 请求原型（`src/http.uya`，不引 libcurl；p5）。
- [x] 最小文件事务原型（tmp + rename + O_EXCL 锁 + 陈旧锁探活；p3/p4）。
- [x] 最小 Worker 中断/重启原型（p5d 断点续跑、p8 重试、p13c 抽样恢复）。
- [x] 产线适配接口草图（能力表 + `media.*`，`DRAMA_PROVIDER.md`；p8/p10）。

## 验收条件

P0 每项能力必须标记“已验证 / 不可用 / 替代方案”。未经验证的能力不得直接成为 P1–P11 的前提。

---

# 3. P1：独立程序和 MCP Server 骨架

## 目标

创建可独立构建、启动，并能被 `uya-agent` 连接的 Drama MCP Server。

> **状态（1.3）**：骨架已落地并通过 `sh drama_plugin/p1_selftest.sh`；
> 代码在 `drama_plugin/src/`（暂放本仓，独立仓落点见 §19 未定）。
> 未勾的项是"还没有"的：配置文件、正式 logger、标准错误分类。

## 工程结构

- [-] 创建独立 Drama 工程（现在在 `drama_plugin/src/`，6 个源文件能单独构建）。
- [x] 建立配置加载：`--config FILE` 读取 `data_dir`（显式 `--data-dir` 覆盖）；
      LLM 设置仍读数据根下 `llm.json`，其余配置暂未集中。
- [x] 建立 CLI 入口（`version`/`health`/`mcp serve`/`worker run`）。
- [x] 建立 `mcp serve` 运行模式。
- [x] 建立 `worker run` 空运行模式（先不执行任务）。
- [-] 建立日志模块（stderr）：`say_err` 已有；分级 logger 与脱敏待做。
- [-] 建立标准错误处理：退出码 0/2 已定；错误分类与错误码表待 P2。
- [x] 建立版本输出和健康检查。

## MCP 协议

- [x] 实现 JSON-RPC 请求解析（`json_min.uya` 的最小读取器）。
- [x] 实现 `initialize`（回 `2024-11-05`）。
- [x] 实现 `notifications/initialized`（不回响应）。
- [x] 实现 `tools/list`。
- [x] 实现 `tools/call`。
- [x] 注册 `list`（公开名 `mcp__drama__list`）。
- [x] 注册 `describe`（公开名 `mcp__drama__describe`）。
- [x] 注册 `call`（公开名 `mcp__drama__call`）。
- [x] 三个工具以外不注册其他 Tool。
- [x] 返回 JSON 文本内容，**单行紧凑**（无 pretty-print、无内嵌换行）。
- [x] 标准输出仅写协议消息；一切日志/诊断走 stderr。
- [x] 处理未知方法（回 `-32601`）、非法 JSON 和协议错误。
- [-] 单条消息 >1 MiB：**入站**整行丢弃已实测；**出站**超限改资产引用待做
      （现在最大文本 64 KiB 缓冲，超了就截断，P5 起换成资产引用）。
- [x] 正确处理 shutdown/EOF（断管不崩、不留半条消息）。

## 测试（都在 `p1_selftest.sh` 里，可重跑）

- [x] MCP initialize 测试。
- [x] tools/list 恰好三个工具测试（raw 名 = list/describe/call）。
- [x] 三个工具空实现调用测试。
- [x] 非法参数测试（缺 `operation` ⇒ `SCHEMA_INVALID`，`isError:false`）。
- [x] stderr/stdout 分离测试（正常一轮会话 stderr 为 0 字节）。
- [x] **单行紧凑判据**：逐行 `json.loads` 成功即证明没有内嵌换行。
- [x] **未知方法回 `-32601`**、server 不退出。
- [x] **`isError` 语义**：业务失败 `isError:false`，协议错误走 JSON-RPC error。
- [x] 与当前 `uya-agent` 的连接测试（`--list-plugins` 认出 3 个工具）。

## 验收

- `uya-agent` 能启动该独立进程。
- 工具列表只出现三个 Drama Tool。
- MCP 消息不被日志污染。
- 断开和重新连接后可以再次初始化。

---

# 4. P2：Operation Registry（**已完成**，验收见 `p2_selftest.sh`）

## 目标

建立稳定的动态业务操作发现、描述、校验和分发机制。

## 注册机制

- [x] 定义 OperationInfo。
- [x] 定义操作名与操作版本。
- [x] 定义 Input Schema。
- [x] 定义 Output Schema。
- [x] 定义 mutates/async/permission/cost/idempotency 属性。
- [x] 实现 register/find/list/describe。
- [x] 实现操作版本兼容检查。
- [x] 禁止重复注册和名称冲突。

## Schema 验证

- [x] 实现 object/string/integer/number/boolean/array 基础类型验证。
- [x] 实现 required。
- [x] 实现 enum。
- [x] 实现 minimum/maximum。
- [x] 实现 minLength/maxLength。
- [x] 实现 additionalProperties 策略。
- [x] 实现默认值填充（仅对声明可填充参数）。
- [x] 实现嵌套 object 和 array 验证。
- [x] 保证 describe 返回 Schema 与 call 实际校验使用同一个定义。

## 分发机制

- [x] 实现统一 Dispatcher。
- [x] `request_id` 改为**可选**：缺省生成并回显，只作 tracing。
- [x] 实现写操作幂等记录接口（键 = `operation` + `input_hash`）。
- [x] 同 `request_id` 但 `input_hash` 不同 ⇒ 报 `REQUEST_REUSED`。
- [x] 实现统一成功返回格式。
- [x] 实现统一错误格式。
- [x] 实现未知 operation 拒绝。
- [x] 实现权限和预算策略接口。
- [x] 实现操作审计记录。

## MCP 对接

- [x] `list` 从 Registry 读取目录。
- [x] `describe` 返回完整契约（含错误码与最小示例）。
- [x] `call` 使用 Registry 分发，并在 60 s 内返回。
- [x] 验证 list/describe 缓存所需的插件/操作版本信息。

## 验收（1.5 落地：`sh drama_plugin/p2_selftest.sh`，35 项全绿）

- [x] 注册一个 Mock Operation。
- [x] list 可发现该操作。
- [x] describe 可读取完整 Schema。
- [x] call 可执行。
- [x] 非法字段、缺失参数、类型错误均被拒绝。
- [x] 未注册操作不可执行。
- [x] 相同 `(operation, input_hash)` 不重复产生写入副作用。
- [x] 同 `request_id` + 不同 `input_hash` 被拒绝（`REQUEST_REUSED`）。

---

# 5. P3：Project、Bible、Asset 和基础存储

（**进行中**：存储 / Project / Bible 版本 / Asset 已落地；子模型字段与迁移器未做）

> 1.5 落地：`src/store.uya`（路径拼接/逐级 mkdir/原子写/读回）、
> `src/project.uya`（ID 规则、create/get/list、index.jsonl）、
> `src/ops.uya`（把 project.* 接到 Registry 上）。
> 验收：`sh drama_plugin/p3_selftest.sh`（22 项，含重启持久化与路径穿越拒绝）；
> `sh drama_plugin/p3b_selftest.sh`（21 项，Bible 版本/冻结文本 hash/资产元数据，
> 其中锁与资产的 SHA-256 用 Python 侧独立算一遍对数）。
> 仍未做：CharacterProfile / SceneDefinition / PropDefinition 的字段级约束、
> 迁移器、审计轮转、符号链接逃逸。

## 目标

建立项目及其稳定世界设定的持久化基础。

## Project

- [x] 定义 Project。
- [x] 定义 ProjectConfig。
- [x] 定义 ProjectBible（`bible.put/get/history`，版本不可变；p3b）。
- [x] 定义 BibleVersion（`version` / `format_version` / `content_hash`）。
- [x] 实现项目 ID 规则。
- [x] 实现 project.create。
- [x] 实现 project.get。
- [x] 实现 project.configure（改名/改集数，`config_version` 递增；p3）。
- [x] 实现项目列表/索引（如果首版确实需要）。
- [x] 实现项目版本管理（Bible 每版快照不可覆盖 + `config_version`；p3/p3b）。

## Bible 子模型（字段直接对齐既有资产包，1.2）

- [x] 定义 CharacterProfile：身份 / 外观冻结（脸、发型、服装、配饰）/
      声音与语言风格 / 表演口径 / 参考图口径（只取身份，不复制背景与棚灯；
      `DRAMA_DESIGN.md` §6.2）。
- [x] 定义 CharacterRelation（关系写进 `CharacterProfile`，事实带来源；§6.2）。
- [x] 定义 **CharacterLock**：冻结描述文本（连续性锁，逐字粘贴）+
      反向提示词（漂移排除项）。
- [x] 定义 SceneDefinition：叙事功能 + **一致性锚点 3–5 条** +
      冻结描述文本 + 反向提示词 + 参考图组 + 适用镜头清单（§6.3；
      layout/variant 已分家）。
- [x] 定义 SceneLayout（静态布局）与 SceneVariant（状态变体：时段/光/
      道具状态，**不进冻结文本**）。
- [x] 定义 PropDefinition（外观冻结 + 反向词；`prop_id` 全项目唯一，§6.4）。
- [x] 定义项目风格与创作规则（`rule.define` 只可扩展，改文本即 RULE_VIOLATION；p12b）。
- [x] 定义 `format` 规格块（每集 manifest 写默认画布 448×800、成片 440×800/24fps、编码/响度；强制校验待产线）。
- [x] 定义固定参考资产 ID（`asset.register` 的稳定 id + `sha256`；§6.2/§9）。
- [x] 冻结文本的**逐字粘贴**校验：写入后核对 hash，与产线脚本里那份一致。
- [x] 修改已被剧集引用的设定时创建新版本。

## 基础存储

- [x] 实现数据根目录配置（必须显式配置，不靠工作区变量推断）。
- [x] 实现项目目录创建（`projects/<id>/`；`locks/`、`idempotency/` 待 P4）。
- [x] 实现 JSON 读写封装。
- [x] 实现临时文件写入（O_EXCL、0600）。
- [x] 实现原子替换（tmp → rename），错误路径清理 tmp。
- [x] 每类 JSON 带 `format_version`；读到不认识的版本进只读故障态。
- [x] 实现版本迁移器（只做加法：缺 `format_version` 补 1，更高版本回 FORMAT_UNSUPPORTED；`project.migrate`，p3）。
- [x] 实现路径规范化。
- [x] 实现目录边界校验。
- [x] 实现基础文件完整性校验（审计核资产：缺失 / 大小不符 / ≤256 KiB 的 SHA-256；p12）。
- [x] 审计日志按大小轮转（8 MiB × 5），写失败只记 stderr 不影响业务。
      `dispatch.uya` 的 `oplog_note`：每次带 `project_id` 的 `call` 追加一行
      `{"ts":…,"op":…,"ok":…}`；写前看大小，满了把
      `audit/operations.jsonl` rename 成 `.1`（旧的逐级后移，只留 5 份），
      不重写历史文件。p13c 实测：10 集 33 行、轮转后 `.1` 恰好 9 MiB。

## Asset Store

- [x] 定义 AssetMetadata。
- [x] 实现 asset ID（项目内文件名即 ID，字符集白名单校验）。
- [x] 实现文件登记。
- [x] 实现 MIME、大小和 SHA-256 元数据。
- [x] 实现 asset.get（按 name 查单条 + 数据根相对路径；`asset.list` 仍回全部元数据）。
- [x] 实现 shared filesystem 访问模式（多个 MCP 进程共享同一 `--data-dir`，p3b 第二进程读同一 Bible/资产索引）。
- [x] 禁止任意绝对路径查询。
- [x] 防止路径穿越（名字白名单）；**符号链接逃逸待补**（要 lstat）。

## 验收

- [x] 创建两个项目并互不干扰。
- [x] 关闭重启后项目仍存在。
- [x] Bible 版本可追溯。
- [x] 资产元数据可查询。
- [x] 非授权路径无法读取。

---

# 6. P4：Continuity、Canon 和事务恢复（**第一段已落地**）

> 1.6 落地：`src/canon.uya`（状态槽 + 事件应用 + 不变量 + 提交记录 + 锁 + 恢复）、
> `canon.inspect` / `canon.commit` / `canon.recover` 三个操作。
> 验收：`sh drama_plugin/p4_selftest.sh`（19 项）：遥控器转移故事、四轴反例、
> base_revision 冲突、活锁拒绝、陈旧锁恢复、canon.json 丢失后从提交记录恢复。
> 仍未做：事件显式 ID 与去重、候选状态差异比较、`promise.jsonl` 双向一致、
> 锁文件的 host/acquired_at、把 `episode.approve` 接进事件校验（等 P5 的剧本模型）。

## 目标

实现短剧的权威剧情状态和可恢复提交机制。

## 动态状态

- [x] 定义 CharacterState（`CharSlot`：位置 + 在场校验；p4 状态槽断言）。
- [x] 定义 SceneState（`SceneSlot`：时段 + 变体；p4 断言 living_room 时段）。
- [x] 定义 PropState（`PropSlot`：所在场景 + 持有者；p4 断言 remote 在厨房冰箱手里）。
- [x] 定义 CharacterKnowledge（`CharSlot.knows` + `knowledge.grant` 在场校验；越界回 KNOWLEDGE_LEAK，p12b）。
- [x] 定义 AudienceKnowledge（事实 ID + 首次揭示集/镜 + 观众/角色分别记；§6.12）。
- [x] 定义 RunningGag（长期梗：ID/引入集/出现集数/回收；§6.6）。
- [x] 定义 Foreshadowing（ID/引入事件/计划回收/实际回收/可延期；§6.6）。
- [x] 定义 CanonSnapshot。

## 事件

- [x] 定义 StoryEvent。
- [x] 定义 EventPrecondition。
- [x] 定义 EventEffect。
- [x] 定义有限条件操作符枚举。
- [x] 实现事件唯一 ID（`r<revision>#<序号>`，canon.commit 返回 `event_ids`；p4）。
- [x] 实现事件顺序。
- [x] 实现事件来源追踪。
- [x] 实现事件前置条件检查。
- [x] 实现事件效果验证。
- [x] 实现冲突检测。
- [x] 禁止任意表达式执行。

## 四轴事件效果（1.3 新增）

事件效果必须能表达四类世界变化，否则闭环无从判定（DESIGN §6.10/§6.11）：

- [x] 道具效果：`prop.move(prop, to_scene|to_holder)`，前置条件是道具当前
      位置与操作者在场。
- [x] 知识效果：`knowledge.grant(character, fact)`，前置条件是角色在场；
      另需 `knowledge.misbelieve` 表达误信。
- [x] 环境效果：`scene.set(time_of_day|variant|furniture)`，变体必须在
      资产包允许集合内。
- [x] 时间效果：`timeline.advance(duration|day|night)`，只能前进不得回退。
- [x] 承诺效果：`promise.open/close/waive`，与 `promise.jsonl` 双向一致。
- [x] 每类效果都要有对应的**不变量谓词**（DESIGN §6.11 九条）。
- [x] 事件效果未覆盖的状态变化一律判为 `ORPHAN_CHANGE`（空事件提交直接拒）。

## Canon

- [x] 定义 Canon revision。
- [x] 实现当前状态读取。
- [x] 实现候选状态生成。
- [x] 实现候选状态差异比较（`canon.diff`：在内存副本上预演事件，返回
      from_revision/events/delta{characters,props,scenes,promises,rules,
      timeline_min}；非法事件与提交同样被拒；不落盘；p4）。
- [x] 实现不可变 Commit Record。
- [x] 实现单项目写入锁（O_EXCL 锁文件 + pid 探活）。
- [x] 锁文件写 `{pid, host, acquired_at, purpose}`；抢锁失败按
      「探活 → 超时报 LOCK_STALE → 损坏报 LOCK_UNREADABLE」处理（p4 三条用例）。
- [x] 验证陈旧锁（kill -9 之后）能恢复，不会把项目变成永久只读。
- [x] 实现 base_revision 检查。
- [x] 实现 commit_id 和幂等检查（`commit_id` = 提交记录 SHA-256，p4 从磁盘复算比对；操作级幂等见 p2）。
- [x] 实现快照生成。
- [x] 实现 current 指针更新。
- [x] 实现从 Commit Record 重建快照（记录里存全量 state，恢复不重放事件）。
- [x] 实现损坏/缺 revision 故障保护（缺 revision 被提交记录拉回；坏 JSON 报 IO_ERROR 且可 recover；p4）。

## 事务与恢复测试

- [x] 在发布 Commit Record 前模拟崩溃。
- [x] 在发布 Commit Record 后、更新快照前模拟崩溃。
- [x] 在快照写入中模拟崩溃。
- [x] 验证启动后可恢复到唯一正确 revision。
- [x] 验证重复提交不会重复应用事件（重放回 BASE_REVISION_CONFLICT，revision 不变；p4）。
- [x] 验证并发第二写者被拒绝。
- [x] 验证基础 revision 冲突。
- [x] 验证「提交中断后不留半个文件」（release 前杀进程）。
- [x] 记录持久化边界：rename 原子但无 fsync ⇒ 掉电可能丢最后一次提交
      （写进 P0_FINDINGS 与部署文档，selftest 用杀进程而不是断电验证）。

## 操作

- [x] 注册 continuity.inspect：`op_continuity_inspect` 复用 `audit_run`，
      返回账本、不变量与全历史重放结果（旧版只登记了名字，调用会报缺字段）。
- [x] 在 episode.approve(screenplay) 内部执行事件验证和 Canon 提交（`story_validate` → `canon_commit` → `approved.json`；p5b）。
- [x] 不提供绕过校验的外部状态写入入口（58 个操作里没有通用写文件/写状态；
      Canon 只能经 `canon.commit` 逐事件校验，剧本只能经 approve 提交）。

## 验收

用“遥控器由爸爸手中转移到冰箱”测试完整状态变更。未满足前置条件时必须拒绝提交；通过提交后可在进程重启后准确恢复。

四轴各来一个最小用例（1.3 新增）：

- [x] 故事：抛出的钩子在第 N+1 集被兑现，回收率计入 `promise` 账
      （批准时注入 `promise.close("hook_<N-1>")` + `promise.open("hook_<N>")`；
      p6 断言 3 集后 hook_1/hook_2 已关、只剩 hook_3 开着；审计
      `payoff_rate_pct` 用同一本账）。
      （P4 只做了 promise.open/close 的状态机，兑现统计留到 P12 的账本）
- [x] 人物：角色知道了不该知道的事 ⇒ `KNOWLEDGE_LEAK` 拒绝提交。
- [x] 环境：道具无事件地被挪动 ⇒ `PROP_TELEPORT` 拒绝提交。
- [x] 逻辑：状态变化找不到原因事件 ⇒ `ORPHAN_CHANGE` 拒绝提交。

---

# 7. P5：LLM Provider 和 Story Engine（**传输/Adapter/剧本/上下文/任务五段已落地**）

> 1.7 落地：`src/httpc.uya`（HTTP/HTTPS POST + 超时 + 状态码/错误分类）、
> `src/llm.uya`（配置来自 `<root>/llm.json`、mock 与 openai 兼容两种 Provider、
> choices[0].message.content 解析与反解转义、结构化校验、有限次重试）、
> `llm.ping` / `llm.complete` 两个操作。
> 验收：`sh drama_plugin/p5_selftest.sh`（10 项，用本机 Python HTTP 服务当上游）：
> mock 默认、正常解析、非 200 ⇒ UPSTREAM_ERROR、畸形响应 ⇒ BAD_RESPONSE、
> 模型输出非 JSON ⇒ MODEL_OUTPUT_NOT_JSON、超时 ⇒ TIMEOUT。
> 第二段（1.8）：`src/story.uya`（剧本结构校验、确定性时长口径、版本存储、
> 批准幂等）+ `episode.generate` / `episode.approve` 两个操作。
> 验收：`sh drama_plugin/p5b_selftest.sh`（12 项）：生成不改 Canon、时长确定性、
> 缺 hook 不能批准、不存在的版本 ⇒ NOT_FOUND、批准后候选事件进 Canon、
> 重复批准回放上次结果不重复应用事件。
> 第三段（1.9）：`src/context.uya`（Bible 版本 + Canon 快照 + 未回收承诺 +
> 最近摘要 + 来源 ID + 预算裁剪）、`context.inspect` 操作；批准后自动追加
> 一集摘要（episodes 以 canon revision 编号）。
> 验收：`sh drama_plugin/p5c_selftest.sh`（11 项）：来源 ID、Bible 版本号、
> 只给 open 承诺、批准后摘要进上下文、预算不足先丢摘要并标 truncated。
> 第四段（1.10）：`src/task.uya`（持久任务 + 断点续跑）、`episode.produce`
> 改成落盘建任务立刻回 queued、并把当次剧本版本写进任务记录（重试保留），
> `task.run` / `task.get` / `task.list`；
> 幂等重放不再重复执行操作（拿操作真实产出的 task_id 登记幂等槽）。
> 验收：`sh drama_plugin/p5d_selftest.sh`（9 项）：produce 只建任务、
> 跨进程可查、run 才干活、重复 run 回放、记录回退后能续跑。
> 第五段（1.19）：`src/series.uya` + `series.plan` / `outline.approve` /
> `series.get`——一次生成 100 集大纲（每集钩子/兑现上集/笑点节拍/主角倾斜），
> 未批准时逐集生成被拒（OUTLINE_NOT_APPROVED），重新规划作废旧批准。
> 验收：`sh drama_plugin/p5e_selftest.sh`（12 项）。
> 仍未做：重定向、分块/SSE、代理配置、Prompt 版本、格式修复重试、日志脱敏、
> 人物一致性审核、长期梗检索（只做了 promise 账）、独立 worker 进程。

## 目标

让 Drama Plugin 能独立完成结构化、可验证的连续剧本创作。

## 系列层规划（1.3 新增，百集前提）

- [x] 定义 `Series`：系列承诺、题材模板 ID、`format`、系列级冻结口径
      （`series.plan` 写 `series/outline.json` 的 `series` 块；p5e 断言）。
      （大纲已落地；题材模板与系列级冻结口径还没做）
- [x] 定义 `Season`/`Arc`：起止集、弧内冲突、兑现点、角色成长弧
      （10 集一季，弧兑现点 = 季末；p5e 断言 10 季与 1..10 / 91..100）。
- [x] 定义 `EpisodeOutline`：本集钩子、兑现上一集哪个 `promise_id`、
      笑点配额、场次、涉及角色/场景/道具。
- [x] `series.plan(total_episodes=100)` 一次生成完整大纲（100 集 5 ms）。
- [x] `outline.approve` 批准大纲；未批准则 `episode.generate` 拒绝执行。
- [ ] 剧本必须能追到 `EpisodeOutline`；大纲外新增承诺 ⇒ 审批时写回大纲升版本。
- [x] 大纲变更直接作废旧批准（要重新批才算数）；
      逐集 `needs_revalidation` 标记还没做。

## LLM 传输层（1.2 新增，P0 的 HTTP 原型的生产化）

- [x] 封装 HTTP 请求：方法/头/体/超时/重试（**重定向未做**）。
- [x] TLS：默认校验模式已验证通过（1.5）；SNI 与失败原因可诊断。
- [x] 响应解析：JSON 体、错误体、非 200 的错误映射。
- [ ] 若走流式（SSE/分块）：增量解析与中断恢复。
- [x] 代理与 `no_proxy`：配置只来自 `<data>/proxy.json`，请求行走
      absolute-form，`no_proxy` 命中即直连（p5f）。
- [x] 本地模型服务（如 Ollama/自建网关）作为一等 Provider 目标。

## LLM Adapter

- [x] 定义 LLMProvider 接口。
- [x] 定义模型配置。
- [x] 定义 Prompt/输入版本（`PROMPT_VERSION=1`，随 `llm_calls.jsonl` 落盘；p5）。
- [x] 实现结构化输出请求。
- [x] 实现响应解析和 Schema 校验。
- [x] 实现超时、限流和错误分类。
- [x] 实现有限次数的格式修复（输出非 JSON/结构不对时追加"只输出 JSON"重试一次；p5）。
- [x] 记录模型名称、参数和输出摘要（`llm_calls.jsonl`：模型/温度/超时/尝试次数/输出 hash；p5）。
      （P5 骨架只在响应里回 model/超时配置，落盘记录留到 Task 接入）
- [x] 日志和错误信息脱敏（审计/项目文件不含 API Key，密钥只在 llm.json；p5）。

## Story 模型

- [x] 定义 StoryConcept（`logline/theme/tone/hook_type`；§6.12）。
- [x] 定义 Conflict（`parties/stake/escalation[]`；§6.12）。
- [x] 定义 StoryBeat（`beat_no/function/action/turn`，与分镜 `beat` 对齐；§6.12）。
- [x] 定义 ComedyBeat（`kind/setup/punchline/callback_to`；§6.12）。
- [x] 定义 Dialogue（`who/line/subtext/gag_id?`，`line` 逐字；§6.12）。
- [x] 定义 Action（`text/visible/forbidden_check`；§6.12）。
- [x] 定义 Screenplay。
- [x] 定义 CandidateEventSet。
- [x] 定义 EpisodeSummary 并落盘（`episode` / `script_version` / `title` / `hook` / `scenes` /
      `duration_ms`；p6 断言）。

## 上下文组装

- [x] 读取项目 Bible 版本。
- [x] 读取当前 Canon Snapshot。
- [x] 读取最近 3–5 集摘要（`summaries.jsonl` 环形窗口只留最近 5 条；p5c）。
- [x] 检索本集相关人物/场景/道具（当前是全量 + 预算裁剪，向量检索留到 P13）。
- [x] 读取人物知识状态。
- [x] 读取未回收伏笔和长期梗。
- [x] 为检索结果保留来源 ID。
- [x] 设置上下文长度和材料优先级。

## 剧本生成

- [x] 生成主题和创意（剧本 `theme`；提示词模板与 mock 都产出，
      `story.review` 缺了报 `MISSING_THEME`）。
- [x] 生成冲突和喜剧结构（`conflict` + `comedy.{setup,payoff}`；
      大纲侧另有 `comedy_beat`；缺了报 `MISSING_CONFLICT`）。
- [x] 生成对白（`scenes[].dialogue[]`；p5b 断言非空，p7 断言分镜保留台词）。
- [x] 生成动作（`scenes[].action`；p5b 断言非空，分镜按动作出镜头）。
- [x] 生成结尾反转（`twist`；缺了报 `MISSING_TWIST`，p5b 四条一起断言）。
- [x] 生成候选剧情事件。
- [x] 结构化输出和校验。
- [x] 估算目标时长（对白 4 字/秒 + 标点 0.3 s，动作 8 字/秒）。
- [x] 生成剧集摘要（批准时写 summaries.jsonl：episode/script_version/title/hook）。

## 剧本审核

- [x] 确定性字段/格式检查（title / scenes / no / action / hook）。
- [ ] 人物性格一致性检查。
- [x] 角色知识状态检查（`knowledge.grant` 必须在场，否则 KNOWLEDGE_LEAK；p12b）。
- [x] 道具和场景状态检查（PROP_TELEPORT / SCENE_DRIFT；p12b）。
- [x] 事件前置条件检查（未定义的道具/角色、TIMELINE_CONFLICT 都被拒；p12b）。
- [ ] 喜剧结构和可理解性审查。
- [x] 生成问题清单和审核版本 ID（`story.review`：确定性检查清单 +
      `review_id` = 剧本内容 SHA-256 前 16 位；批准时写进
      `scripts/approved.json` 的 `review_id`，可回查是哪一版被批的；p5b）。
- [x] 支持创建新剧本版本，不覆盖旧版本（`scripts/v<N>.json` 只增不改；p5b 比对 v1 字节不变）。

## Task 接入

- [x] 让 `episode.produce(target=script)` 创建持久任务。
- [x] Worker 能执行 LLM 剧本步骤（`task.run` 走同一套 llm/story 代码；
      独立 worker 进程留到 P8）。
- [x] 保存输入 hash 与输出剧本版本（模型名称/参数落盘留到 P8 的日志）。
- [x] 中断后可从已完成步骤恢复。

## 验收

- [x] 可自动生成一集结构化剧本（mock Provider；p5b / p6）。
- [x] 返回候选事件，不修改 Canon。
- [x] 审核失败不能批准。
- [x] 审核通过后可批准并提交 Canon。
- [x] LLM 输出畸形或超时有明确错误，不污染项目状态（p5：MODEL_OUTPUT_NOT_JSON / TIMEOUT）。
- [x] 时长估算走确定性口径（对白 4 字/秒 + 标点 0.3 s；p7），与目标正片时长
      误差 ≤0.05 s；超差时给出可读的差距说明（差多少秒、哪几镜）。
- [x] 集尾钩子存在（缺 hook 的剧本不能批准，p5b）。

---

# 8. P6：连续三集剧本核心验收（**M1 最小版已跑通**）

> 1.11 落地：`drama_plugin/p6_selftest.sh` 用 mock Provider 跑完整链路——
> 建项目 + Bible v1 → 三集「生成 → 批准」，每集都重启进程（每次调用都是新
> 进程，等于天然的重启验证）。
> 验收点：canon revision 走到 3、时间轴累计推进、摘要三条且集号连续、
> 道具/角色都停在已知场景（四轴不变量零红）、Bible 版本没被剧本写坏、
> **换一个数据根用同样输入重跑，canon.json 逐字节一致（复现率 100%）**。
> 仍未做：真实模型（现在走 mock）、视频 Mock Production、冻结文本 hash 逐集
> 比对、人物情绪状态、长线梗。

## 目标

完成第一个可验证产品闭环：插件重启后仍能连续生成三集。

## 黄金 fixture（1.2 改为真实脚本）

**首选：已经产出过成片的真实短剧项目**（分镜、逐字台词、QC 清单齐备）。
它是"能对得上账"的外部事实：每集的分镜表、台词、镜号、时长都有实物可比对。

**补充样例**：虚构的最小项目仅用于单元测试（两三个人物、两个场景、
五个道具），不承担"连续性验收"职责。

固定脚本要提供的最小期望值：每集目标正片时长、片尾卡时长、镜号范围、
每镜台词逐字、场景/人物 ID。

## 测试流程

- [x] 创建项目和 Bible v1。
- [x] 生成第一集 script 候选。
- [x] 验证事件和连续性。
- [x] 审核第一集。
- [x] 批准第一集 screenplay，提交 Canon revision 1。
- [x] 停止 MCP Server 和 Worker。
- [x] 重启两个进程。
- [x] 生成第二集，确认加载 revision 1。
- [x] 审核并提交 revision 2。
- [x] 再次停止并重启进程。
- [x] 生成第三集，确认加载 revision 2。
- [x] 审核并提交 revision 3。
- [x] 验证人物 Profile 未漂移。
- [ ] 验证人物位置、服装和情绪状态合理。
- [x] 验证人物知识状态没有提前泄露（KNOWLEDGE_LEAK；p12b 反例 2）。
- [x] 验证道具位置连续。
- [x] 验证伏笔/长期梗状态连续（PROMISE_OVERDUE；p12b 反例 4）。
- [x] 验证事件因果成立。
- [x] 验证重复 `(operation, input_hash)` 不会创建重复任务（幂等重放）。
- [x] 验证视频失败不会改变 Canon（p9：失败/重试前后 canon.json md5 不变）。
- [ ] 逐集比对**冻结文本 hash 未变**、`CharacterState` 变体在允许集合内、
      知识事实无"提前知道"、道具位置变化都能追到事件。
- [x] 文本按码点计数（汉字算 1），时长按"念出来的字符数"折算（`cp_count`；p7）。

## 通过标准（M1 门槛）

三集全部基于前一集已提交的 Canon revision 生成；中间至少两次完整进程重启；
无状态丢失、重复提交或无法解释的连续性冲突。**并且四轴不变量零红**
（DESIGN §6.11 九条）、抽 3 集历史重放复现率 100%。

**该阶段通过前，不进入视频生产开发。**

## 反例库回归（1.3 新增）

- [x] DESIGN §13.5 的六条反例 fixture 全部落地（p12b 六条，逐条断言）。
- [x] 每条断言具体错误码，而不是"失败即可"（p12b 用 code_of 等值比较）。
- [x] 人为改动冻结文本、挪动道具、抹掉知识来源，各触发一次拒绝提交
      （p12b：冻结文本改字 ⇒ CHARACTER_DRIFT；道具瞬移 ⇒ PROP_TELEPORT；
      `knowledge.grant` 缺 `at_scene` ⇒ KNOWLEDGE_LEAK）。

---

# 9. P7：Storyboard 和参考资产（**第一段：确定分镜已落地**）

> 1.12 落地：`src/board.uya`（剧本 → 镜头序列，确定性规则）、
> `storyboard.build` / `storyboard.get` 两个操作，版本存 `boards/v<N>.json`。
> 规则：每 scene 的 action 出 1 个 medium 镜头、每条对白出 1 个 close 镜头；
> 时长沿用剧本口径（动作 8 字/秒、对白 4 字/秒、标点 0.3 s）；
> 首镜 anchor、其余 hard_cut；timeline 首尾相接；动作过能力表体检（禁用词）。
> 验收：`sh drama_plugin/p7_selftest.sh`（18 项）：确定性复用、字段齐全、
> 接戏枚举、timeline 连续、Σ时长 == 剧本时长、换版本出新分镜、
> 越界动作 ⇒ ACTION_UNSUPPORTED。
> 仍未做：机位/景别枚举的细表、参考图顺序与版本、ShotStateTransition、
> 道具/角色固定资产引用（现在只带 ID）、锚帧接戏差判据。

## 目标

将已批准剧本转成具有明确状态和素材引用的分镜。

## TODO

- [x] 定义 Storyboard（镜头序列 + 时间轴）。
- [x] 定义 Shot：`shot_id`/`sequence`/`beat`/`scene_id`/`framing`/`camera`/
      `action`/`line_text`/`timeline_in`/`timeline_out`/`source_duration`/
      `final_duration`/`ref_image_order`/`anchor_prev`/`cut_type`/
      `transition_line`/`state_in`/`state_out`/`render_tool`/`workflow_hash`。
- [x] 定义 CameraSpec（分镜输出 `camera.move=static`；真实运镜参数待产线）。
- [x] 定义 ShotAction（**必须过 provider 能力表校验**）。
- [x] 定义 ShotDialogue（台词逐字，供 ASR 核对与字幕定时）。
- [x] 定义 ShotAudio（`audio.has_dialogue` 由台词有无判定）。
- [ ] 定义 ShotStateTransition。
- [ ] 定义 ShotReference（参考图顺序 + 版本）。
- [x] 定义接戏枚举：`anchor`（上一镜末帧当本镜第 0 帧）/`hard_cut`
      （+ 接戏句）/`card`（片尾卡，不参与接戏校验）。
- [ ] 将镜头关联到剧本段落和事件。
- [x] 生成景别、机位、动作和镜头时长。
- [ ] 生成镜头起始状态和预期结束状态。
- [ ] 引用角色、场景和道具的固定资产版本（含冻结文本）。
- [ ] 检查镜头之间状态连续（含锚帧接戏差的判据定义）。
- [x] 检查总时长与目标时长（Σ镜头 = 正片，误差 ≤0.05 s；片尾卡单列）。
- [x] 将分镜保存为不可变版本。

## 验收

- [x] 一分钟剧本可生成可解析分镜。
- [x] 每个镜头有场景 ID 与对白人物 ID（道具引用留到接资产包）。
- [ ] 镜头可追溯到剧本事件。
- [x] 镜头时间轴衔接（anchor/hard_cut + timeline 首尾相接；
      接戏差判据与接戏句仍缺）。
- [x] 越出 provider 能力表的动作在静态体检阶段被拒绝（不是生成后才发现）。
- [x] 更改分镜产生新版本，不覆盖旧版。

---

# 10. P8：Provider、Worker 和异步视频任务（**第一段：mock Provider + Worker 已落地**）

> 1.13 落地：`src/provider.uya`（版本化能力表 + mock VideoProvider，确定性
> 产出占位 mp4）、任务表加 `target=video` 步骤（分镜 → 逐镜渲染 → 任务完成）、
> `drama worker run` 扫未完成任务并执行（状态以记录文件为准）。
> 验收：`sh drama_plugin/p8_selftest.sh`（13 项）：能力表版本化、
> produce 立刻回 queued、未批准剧本 ⇒ 任务 failed 且不产文件、
> 批准后 worker 跑完并产出 3 个镜头文件、视频不改 Canon、已完成的活不重做。
> 仍未做：真实本机队列 Adapter（submit/poll/cancel/取文件）、单 Worker 锁、
> 有限重试与取消、成本（GPU 分钟）记账、Cloud/HttpProvider。

## 目标

实现 Provider 可替换和视频任务可恢复。

## Provider 接口

- [x] 定义 Provider 基础配置。
- [x] 定义统一错误类型。
- [x] 定义超时和重试策略（LLM `timeout_ms`/`max_retries`，p5 超时路径；任务 `episode.retry`，p9）。
- [x] 定义模型、Provider 与**能力表**版本记录。
- [x] 定义 `video.capabilities()`：哪些动作能演、哪些不能（版本化）。
- [x] 定义 LLMProvider（`mock` / OpenAI 兼容 `openai`，`llm.uya`；p5）。
- [x] 定义 ImageProvider（`submit/poll/fetch` + 参考图顺序即绑定；`DRAMA_PROVIDER.md`）。
- [x] 定义 VideoProvider（mock；真实产线 Adapter 留到接本机队列）。
- [x] 定义 AudioProvider（只留方法名，调用回 PROVIDER_UNSUPPORTED；不做 TTS）。
- [x] 定义 MediaProvider（本机 FFmpeg：encode/mux/mix/loudnorm/probe）。
- [x] 定义 `PipelineProvider`：以子进程方式调用既有产线脚本
      （入参固化为 JSON、退出码与产物清单进检查点、只读 stdout 摘要）。

## 本地队列 Video Adapter（1.2 替换原「H3 Adapter」）

- [x] 确认本机生成服务契约：`queue/<task_id>.json`（提交 / 查状态 / 取结果），
      prompt_id 由 (task_id, board_version) 确定性算出（p8）。
- [x] 实现 submit（返回 `q_<8hex>` 的 prompt_id 作为 provider task id；p8）。
- [x] 实现 poll（`queue.get` 回 queued/running/done/failed/canceled；p8）。成/失败）。
- [ ] 实现 cancel（真把 job 停掉，而不是只停止 poll）。
- [ ] 实现结果取回（mp4 + 末帧图 + 元数据）。
- [ ] 实现参考素材参数转换（参考图顺序、帧索引引导）。
- [ ] 实现 Provider 错误映射。
- [x] 记录原始请求摘要与 `prompt_id`（记录含 task_id/board_version/时间戳，
      任务 done 时写回 `provider_prompt_id`；p8）。
- [x] 处理 submit 与保存 `prompt_id` 之间的崩溃窗口：prompt_id 确定性，
      重跑先查记录再决定重发（p8 断言记录未被改写）。查历史再决定重发。
- [x] 并发上限固定 1（单卡串行），排队顺序 = Worker 调度顺序。
- [x] 成本按 GPU 分钟记账（`production.report` 的 `gpu_ms`/`gpu_minutes`；p9）。
- [x] 云 API 版（`HttpProvider`）只留占位：`provider.capabilities` 里显式
      `http_provider:false`，不假装可用（p8）。

## Worker

- [x] 实现持久任务扫描。
- [x] 实现单 Worker 锁（`locks/worker.lock` + pid 探活，陈旧锁自动清）。
- [x] 实现任务状态迁移。
- [x] 实现步骤检查点（任务记录里的 `steps[]` 落盘；p5d / p8）。
- [ ] 实现 Provider 轮询。
- [x] 实现中断恢复（步骤状态在记录里；失败任务可重跑）。
- [x] 实现取消处理（`production.cancel`：未完成可取消，worker 不再捡起）。
- [x] 实现有限重试（`max_retries` + 预算熔断；p5/p8/p10）。
- [x] 实现任务状态查询。
- [x] 实现 Worker 不在线时的明确反馈（`production.status` 回 `worker=idle|busy`，按锁文件 pid 探活；p9）。

## 操作

- [x] episode.produce(target=video) 仅接受已批准剧本（p8：未批准 ⇒ script_not_approved）。
- [x] production.status（p9：查 queued/running/done/failed）。
- [x] production.cancel（p9：未完成可取消，worker 不再捡起）。
- [x] episode.retry（p9：失败任务重置 queued 且不动 Canon）。

## 验收

- [x] 可创建视频任务并返回 task_id（`call` 在 60 s 内返回）。
- [x] MCP 请求快速返回，不等待视频完成。
- [x] MCP Server 退出不丢失任务记录（p5d 断点续跑 / p8 任务记录持久化）。
- [x] Worker 重启后能恢复查询既有 job（p8 陈旧锁自动清 + 已完成任务不重复执行）。
- [x] 同一 `prompt_id` 不会重复执行、不会重复记账（p8 已完成任务不重复执行；p13c 资产账本无重复）。
- [x] 任务重复调用不会无条件重复创建（p5d 重复 `task.run` 回放，resumed=false）。

---

# 11. P9：Quality Engine 和局部重试（**第一段：确定性 QA 已落地**）

> 1.14 落地：`src/qa.uya`（剧本与分镜的确定性体检 + 不可变报告
> `qa/v<N>.json`）、`qa.run` / `production.status` / `episode.retry` 三个操作。
> 体检项：title/hook/scenes、对白说话人与文本、镜号连续、timeline 相接、
> 空镜头、Σ镜头时长 == 剧本时长。
> 验收：`sh drama_plugin/p9_selftest.sh`（9 项）：正常链路 QA 全绿、
> 缺 hook/无说话人对白被报出、production.status 可查、越界动作让任务 failed、
> retry 把任务重置为 queued、重试不改 Canon。
> 仍未做：ASR 对齐、锚帧像素差、成片终检、跨集审计、单镜头级重做、
> 重试次数与 GPU 分钟上限。

## TODO

### 剧情/镜头 QA

- [x] 检查生成视频对应的剧本版本（QA 比对分镜 `source_script_version`，不符报 `STALE_BOARD`；p9）。
- [x] 静态体检：字段完整、镜号连续、时长核算、能力表校验、规格合规。
- [x] ASR 对齐：逐镜台词相似度 ≥ 阈值（默认 0.85），产出字幕时间轴
      （`qa.align`：转录一行一条台词，编辑距离算每镜百分比，低于 85 列
      `mismatches`；字幕时间轴用 `media.subtitle` 的分镜时间；p7）。真实
      ASR 引擎仍未接，转录文本由调用方/外部工具给。
- [ ] 锚帧接戏差：`cut_type="anchor"` 的镜头与上一镜末帧做像素差比对。
- [ ] 成片终检：可解码、无空文件、无黑边、无长静音段、时长一致、片尾卡在（已做 manifest/文件存在/大小一致；其余待真实产线）。
- [ ] 检查人物外观和服装（对照冻结文本与锚点，模型辅助）。
      （P9 第一段只做确定性项；这条要模型辅助，等 P12 的审计）
- [ ] 检查场景和道具引用。
- [ ] 检查关键动作是否呈现。
- [x] 检查镜头时长和技术可播放性。
- [ ] 检查状态变化是否与批准事件相符。
- [x] 保存 QA 证据和结果版本。

### 跨集审计（1.3 新增，每 10 集）

- [x] 历史重放：抽 10 条提交（含第 1 与当前）＋全历史重放 hash 比对（p13c）。
- [x] 承诺回收率：`overdue` 必须为 0，`waived` 必须有原因与新到期集。
- [ ] 人物漂移：外观锚帧与首集基准比对；台词语料画像（人称、口头禅、
      句长、语速）比对。
- [ ] 笑点重复：连续 20 集内结构重复率超阈值即报告。
- [ ] 逻辑矛盾：全历史 `ORPHAN_CHANGE`/`TIMELINE_CONFLICT`/`RULE_VIOLATION`
      清零。
- [ ] 审计报告进资产；不通过不允许批量推进。

### 失败与重试

- [x] 定义错误类型和严重程度。
- [x] 定义可重试/不可重试分类。
- [x] 实现单镜头重试（`shot.retry`：按 sequence 只重渲一镜；p10）。
- [x] 实现失败步骤重试。
- [x] 实现重试次数与成本上限（`shot.retry` 计入预算，超限回 BUDGET_EXCEEDED；p10）。
- [x] 防止无限重试（失败任务写 state=failed + reason，不会留在 queued）。
- [x] 保留旧素材版本和审查结果。
- [x] 验证重试不改变 Canon。

## 验收

- [x] 能发现明显素材缺失/损坏。
- [x] 能记录人物/道具连续性问题（审计违规带 object；p12b）。
- [x] 能仅重做一个不合格镜头（p10：改写 shot_2 后 `shot.retry` 恢复 256 B）。
- [x] 达到重试上限会停止并说明原因（预算熔断回 BUDGET_EXCEEDED；p10）。
- [x] QA 失败的成片不能标记为 final approved（`final.approve`：无绿报告/无成片回 QA_FAILED；p11）。

---

# 12. P10：Media/FFmpeg 合成（**第一段：mock 拼接已落地**）

> 1.16 落地：`src/assemble.uya` + `media.assemble` 操作——按镜号顺序把镜头文件
> 拼成成片，写 manifest（`assemblies/v<N>.json`：镜头数、时长、大小、输出名、
> SHA-256）。真实转码的替换点就是 `concat_shots`（换成 PipelineProvider 调产线脚本）。
> 1.17 补：`media.probe` 用 ffprobe 读首条视频流宽高与容器时长，只接受数据根下
> 的相对路径，并记录 ffprobe/ffmpeg 版本首行与探测参数；合成出的成片同时登记进
> `assets.jsonl`（mime `video/mp4`）；失败不占版本，补回镜头重跑即可恢复；
> `media.probe` 还可带期望宽高/时长，不符回 `MEDIA_MISMATCH`；`media.encode`
> 按 format.encode 参数转码到 `encodes/<name>`。
> 验收：`sh drama_plugin/p10_selftest.sh`：manifest 字段齐全、
> 成片大小 == 各镜头字节数之和、合成不改 Canon、同样输入两次成片 hash 一致、
> 镜头缺失 ⇒ ASSEMBLY_MISSING_SHOT、媒体探测返回宽高/时长且越界路径被拒。

## TODO

- [x] 实现 FFmpeg 可执行文件探测（`/usr/bin`、`/usr/local/bin`、`/bin`；结果并入 `provider.capabilities.media` 的 `ffmpeg`/`ffprobe` 与路径）。
- [x] 实现媒体输入探测（`media.probe`：ffprobe 报宽高/时长；越界路径 ⇒ SCHEMA_INVALID）。
- [x] 实现视频拼接（按分镜时间轴顺序；mock 阶段是字节拼接，片尾卡待接）。
- [x] 实现现场声/音乐轨混音（`media.mix` 把音轨混入成片；不做配音替换）。
- [x] 实现 loudnorm 两遍（`media.loudnorm`：先测 input_i/TP/LRA/thresh，再带 measured_* 归一）。
- [ ] 实现字幕文件生成（以 ASR 对齐结果为定时依据；`media.subtitle` 已按分镜时间轴生成 SRT，ASR 待接）。
- [x] 实现字幕合成（`media.mux`：SRT 作为 mov_text 混进 MP4；ASR 定时待接）。
- [x] 实现输出编码配置（`media.encode`：libx264/crf20/yuv420p/aac 128k/32kHz/faststart；成片拼接接入待真实产线）。
- [ ] 实现输出时长/分辨率检查（`media.probe` 已支持 `expect_width`/`expect_height`/`expect_duration_ms`；成片与 `format` 绑定待真实产线）。
- [x] 实现输出文件完整性检查（大小与各镜头之和比对 + SHA-256 入 manifest）。
- [x] 记录 FFmpeg 版本和参数（`media.probe` 回 ffprobe/ffmpeg 版本首行与实际探测参数）。
- [x] 将最终成片登记为 Asset（合成后按 `episode_<N>.mp4` + `video/mp4` 入账）。
- [x] 支持失败后从合成步骤恢复（原子写 + 版本只在成功后递增；补回镜头重跑即恢复）。

## 验收

- [x] 镜头能按时间顺序拼接（片尾卡留到接真实产线）。
- [x] 音频轨道完整，响度达标（p10：混音后 aac 轨 + 两遍 loudnorm 测得 I≈-16 LUFS）。
- [ ] 字幕同步且可见（与 ASR 时间轴一致）。
- [ ] 输出文件可正常解码，编码参数与 `format` 一致。
- [x] 成片可以通过 asset.get 获取元数据和共享路径引用
      （路径为 `projects/<id>/assets/<name>`；合成时已登记 Asset）。

---

# 13. P11：端到端验收和发布

> **第一段（1.17）已落地**：`p11_selftest.sh` 从零跑到成片——建项目 → 写 Bible
> → 三集「生成 → 批准 → 视频任务 → worker → 分镜 → 合成 → QA → 审计」，
> 每步都断言状态与账本；末尾检查三份 manifest / 三个剧本版本 / 三个成片文件
> 都在盘上。
>
> **第二段（1.20）**：`sh drama_plugin/pack.sh [输出目录]` 打交付包——
> `bin/drama` + docs + src + 全部验收脚本 + README，顺带出 tar.gz 与 SHA-256。
> 独立构建入口：`sh drama_plugin/build.sh [输出路径]`；默认输出到当前目录
> 的 `build/drama`，可用 `UYA` / `UYA_ROOT` 指定工具链。

## 端到端测试

- [x] 新建短剧项目（`project.create`；p11）。
- [x] 自动生成并批准连续三集剧本（p11：三集 screenplay 逐版批准）。
- [x] 每集生成分镜（`board.build` v1–v3；p11）。
- [x] 调用本地队列生成镜头（mock 串行：任务队列 + Worker；p8/p13c）。
- [x] Worker 处理中途重启（p5d 断点续跑 + p8 陈旧锁自动清）。
- [x] Worker 恢复未完成任务（p5d：记录回退 pending 后能续跑）。
- [x] 执行 QA（确定性 QA + 九条不变量；`qa.run` 全绿，p11）。
- [x] 重做不合格镜头（`shot.retry` 按 sequence 只重渲一镜；p10）。
- [x] 合成成片（mock 拼接 `media.assemble`；p10/p11）。
- [x] 审批 final_cut（`final.approve`：QA 绿 + 有成片才放行；p11）。
- [x] 三集成片均可通过资产共享目录访问（`asset.get` 回 `projects/<id>/assets/<name>`；p11）。
- [x] Canon 只随 screenplay approval 变化，不随 final_cut approval 重复变化（p11：
      final.approve 后 Canon 仍 r3）。

## 发布

- [x] 独立构建脚本（`build.sh`；自测验证默认/自定义路径及启动）。
- [x] 定义当前版本号和兼容策略（0.1.0 / project format 1；不承诺 0.x
      跨版本数据兼容，迁移器未完成前要求先备份且不直接升级既有项目）。
- [x] 默认 Provider 配置模板（交付 `docs/DRAMA_PROVIDER.md`：无文件即 mock，
      本机无认证 OpenAI 兼容网关使用 `llm.json`）。
- [x] MCP Host 配置示例：CLI 已接受 `--config FILE`（读 `data_dir`），
      `llm.json` 支持 `api_key`；代理仍未实现，见下方限制。

      ```json
      {"mcpServers":{"drama":{
        "command":"/opt/drama/bin/drama",
        "args":["mcp","serve","--config","/etc/drama/config.json"],
        "cwd":"/var/lib/drama",
        "env":{},
        "toolCallTimeoutMs":60000}}}
      ```

      `/etc/drama/config.json` 只写 `{"data_dir":"/var/lib/drama"}`；密钥在
      数据根下 `llm.json`（0600，`api_key` 字段）。Host 侧不要注入
      `OPENAI_API_KEY`/`HTTP_PROXY`：Drama 不读这些环境变量。

- [x] 抽样审批策略：`production.report` 每 10 个完成任务抽 1 集进 `review_sample`，异常任务走 `failed_tasks` 优先队列（审批动作待接）
      （把百集约 300 次点击压到约 30 次）。
- [x] 权限模式说明（`DRAMA_OPERATIONS.md` 按源码记录）：read-only 与
      workspace-write 每次 MCP 调用都需批准，danger-full-access 放行，无回答
      渠道时 fail closed；无人值守走 Worker，不走 Agent 循环 `call`。
- [x] Worker 启动示例（交付 README：与 MCP 分进程、共享数据目录，单次扫描后退出）。
- [x] API Key：`llm.json` 可选 `api_key`，非空时请求带
      `Authorization: Bearer <key>`；p5 用本机 HTTP 服务抓头验证。环境变量
      与代理仍未接（见上一条），公网 Provider 需 `tls: 1`。
- [x] 数据目录备份/恢复说明（交付 README：停写后归档全数据根，解压新目录并校验）。
- [x] 已知限制说明（`DRAMA_OPERATIONS.md`）：无 fsync、单 Worker/模拟 GPU
      预算边界。真实 GPU 串行仍待产线接入。
- [x] Provider 配置文档（`DRAMA_PROVIDER.md`：`llm.json` 字段、错误边界、
      `mock-video-cap-1` 能力表及 P5/P8 回归入口）。
- [x] 支持平台说明（`DRAMA_PROVIDER.md`：当前仅 GNU/Linux x86-64；其他平台
      未验收，不作支持承诺）。
- [x] 完整 selftest 通过（发布包内 20 个阶段脚本及构建自测均通过）。

---

# 14. P12：闭环引擎（四轴连续性，1.3 新增）

> **第一段（1.15）已落地**：`src/audit.uya` + `canon.audit` 操作——
> 四本账计数（props/characters/scenes/promise/timeline）、重放完整性
> （逐条比对 commits 索引里的 state_hash 与提交记录里的全量 state）、
> 三类不变量（道具/角色必须停在已知场景、承诺逾期、canon 落后于提交）。
> 审计只读，不改任何状态。`canon.audit` 每次全量重检历史提交；重复审计后篡改旧提交仍会报错。
> 验收：`sh drama_plugin/p12_selftest.sh`（16 项）：干净状态全绿、
> 逾期承诺记 PROMISE_OVERDUE、篡改提交记录记 AUDIT_REPLAY_MISMATCH、
> 道具指向未知场景记 PROP_IN_UNKNOWN_SCENE、审计前后 canon.json 不变。
>
> **第二段（反例库六条）**：`sh drama_plugin/p12b_selftest.sh`（9 项）——
> 道具瞬移 PROP_TELEPORT、知识越界 KNOWLEDGE_LEAK、场景穿帮 SCENE_DRIFT、
> 伏笔落空 PROMISE_OVERDUE、时间悖论 TIMELINE_CONFLICT、外观漂移
> CHARACTER_DRIFT 各一条 fixture，外加漂移的显式豁免通道
> （`locks._allow_drift`）。

## 目标

把"连续性"从人工目检变成提交门：四本账 + 不变量检查器 + 提交门 + 历史重放。
这是"故事/人物/环境/逻辑闭环"的实现载体，不是可选项。

## 四本账

- [x] `promise`（承诺/伏笔/钩子）读写，随 Canon 版本化；
      `promise.report` 给回收率。
- [x] `prop`（道具位置）唯一位置不变式。
- [x] `knowledge`（谁知道什么）授予必须来自事件且角色在场。
- [ ] `space`（场景连通/陈设 hash/时段/变体）。
- [x] 账本重建：从 Commit Record 重算 state_hash 并逐条比对（审计里做）。
- [x] 账本只追加、只升版本，不可改写（p4 校验 1.json 在后续提交后 hash 不变）。

## 不变量检查器

- [x] 实现 DESIGN §6.11 的九条谓词与错误码（六条反例 + 规则/钩子/时序三类已覆盖）。
- [x] 每条错误带定位（对象 ID）：事件错误回 `object`，审计违规也带 `object`；
      集号/镜号的定位留到接真实产线（现在错误发生在对象层）。
- [ ] 增量检查：只查受影响实体，复杂度 O(集数)；不能复用未经校验的旧审计结论。
- [x] 全历史检查模式（`canon.audit` 每次逐条校验提交记录与索引 hash；可手动触发）。
- [x] 百集规模下单集提交检查 < 3 s（p13 实测每集数十 ms，断言阈值 3 s）。

## 提交门

- [x] `episode.approve` 内固定顺序：结构 → 前置 → 不变量 → 账本 → 提交 →
      快照 → 索引（`story_validate` → `canon_commit`（逐事件前置/不变量）→
      `approved.json` → `summaries.jsonl`；p5b/p5c）。
- [x] 任一步失败整体回滚到提交前 revision（p4：一批事件里有一条不合法 ⇒ revision 不变、状态无残留）。
- [x] 唯一豁免：承诺延期（`promise.waive` 需 `reason` + 新 `due_ep`，缺一即拒；p12b 验证 overdue 归零）。
- [x] 不提供任何绕过入口（不允许"直接写 Canon"）。

## 历史重放

- [x] 从 Commit Record 重放到任意 revision 的输入状态
      （`canon.recover` 用记录里的全量 state 直接重建）。
- [x] 抽 10 集与落盘提交记录做字段级比对（p13c：revision/state 一致）。
- [x] 重放不依赖网络与 GPU（纯本地可跑）。

## 反例库

- [x] 六条 fixture 落地（DESIGN §13.5），每条断言具体错误码。

## 验收

- [x] 人为构造六类违约全部被拦截且错误码正确（见 p12b 自测）。
- [x] 改动冻结文本/挪道具/抹知识来源 ⇒ 提交被拒（p12b 覆盖）。
- [x] 重放复现 100%（p6 三集逐字节一致；10 集抽检待 P13 规模数据）。

---

# 15. P13：规模与产能（1.3 新增）

> **第三段（1.18）**：`src/index.uya` + `index.rebuild` / `index.list`——
> 派生索引一行一集（revision/剧本/分镜/成片版本 + 成本），删掉后重建逐字节一致；
> 10 集重建 5 ms。验收脚本 `p13b_selftest.sh`（12 项）。
>
> **第一段（1.17）已落地**：`p13_selftest.sh` 默认连跑 10 集做测算，
> 也支持 `EPISODES=100` 做控制面压力；本轮百集实测提交与全量重放通过，
> 总耗时 4222 ms、审计 7 ms、canon.json 167 B（机器相关，不是产能承诺）。
> 这只量**插件自身开销**，不含模型、视频 Worker 与 GPU；真实产能仍以
> DESIGN §0.3 的产线基线为准。

## 目标

让"百集"成为可测算的产能，而不是口号（基线见 DESIGN §0.3）。

## 索引与分片

- [x] 派生索引（`index/episodes.jsonl`，一行一集），可从真相全量重建；
      shot/asset 级索引还没做。
- [x] 每集一个 `manifest.json`（视频任务完成时写 `episodes/<id>/manifest.json`：剧本/分镜版本、镜头数、时长、任务与成本；p8）。
- [x] `episode.get` / `index.list` 百集下 < 200 ms：`p13c_selftest.sh`
      100 集实测各 34 ms（机器相关，不是产能承诺）。
- [x] `continuity.inspect` 百集下 < 200 ms：p13c 100 集实测 34 ms。
- [x] 全量索引重建 < 60 s：100 集实测 36 ms。

## 预算与熔断

- [x] 任务级 cost：`renders` 与 `gpu_ms` 写进视频任务记录。
- [x] 项目级累计账本（`budget.report`：集数/任务/渲染/GPU 时长/每集渲染数）；
      三类配额与熔断还没做。
- [x] 超限熔断：超预算的任务直接判 failed(budget_exceeded)，不开工。
- [x] 重做率指标（`renders_per_episode`，百分之一为单位；告警阈值未接）。
- [x] `budget.report` 项目级汇总（按集会/阶段/provider 的细分留到接真实产线）。

## 批量调度与审批

- [x] 一次投 N 集、优先级、截止时间（`episode.batch`：逗号分隔集号 + `priority` + `deadline_s`；`production.report.tasks_overdue` 统计逾期，逾期的 src 任务由 worker 记 `failed/deadline_exceeded`；p9）。
- [x] 日终报告（`production.report`：完成集数、任务完成/失败、GPU 分钟、
      重做率、异常任务清单、不变量是否全绿；告警推送留到接真实产线）。
- [ ] 抽样审批 + 异常优先队列。

## 规模门槛

- [x] M2 的控制面部分：10 集连续提交 + 崩溃恢复（p4）+ 闭环审计（p12）；
      无人值守与真实产线仍待接。
- [x] 百集控制面压力：`EPISODES=100 sh drama_plugin/p13_selftest.sh` 已验证
      100 次提交、全量重放、审计和状态体积；不含视频 Worker/GPU。
- [ ] M3：30 集跨题材（题材模板参数化：Bible 模板 + 资产包模板 +
      能力表 + `format`，换模板不改代码）。
- [x] M4 的 Mock 部分：100 集 Mock 视频压力 + 抽 10 条提交历史重放。
      `EPISODES=100 sh drama_plugin/p13c_selftest.sh`：100 集先全部生成/
      批准/排队（每个任务固定建任务时的剧本版本），再一次 Worker 扫描消费
      全部任务——批量排队不会都去渲染"当前最新一集"；随后抽 10 条 commit
      校验 revision 与 state、断言 100 个分镜版本目录 / 300 个镜头文件、
      抽第 50 集按自己的目录合成、删 Canon 恢复、恢复后 Worker 重跑零重复
      任务。全部用 mock 占位文件，不含真实 GPU 与转码，见
      `docs/DRAMA_PROVIDER.md`。同一脚本还断言：300 条资产账本逐条重算
      SHA-256 与文件一致、`asset.list` 整份返回、`episode.get` /
      `index.rebuild` / `index.list` 百集耗时分别为 34 / 36 / 34 ms；
      `production.report` 汇总 100 集 / 零失败任务 / 不变量全绿。
- [ ] M4 的真实部分：接真实 VideoProvider 重跑同一套百集压力。
- [ ] 百集成本报告（GPU 小时、人工分钟、重做率、不变量红数）。
      `production.report` 已能给出 mock 口径的集数/GPU 分钟/重做率/红数；
      真实产线数字仍要等真实 Provider。
- [x] 镜头文件按分镜版本归档：mock 写
      `assets/v<board_version>/shot_<seq>.mp4`，不同集的分镜版本不同，
      同号镜头不再互相覆盖；`assemble` 只在本次分镜自己的目录里拼接，
      `p13c_selftest.sh` 断言 100 集有 100 个目录、300 个镜头文件，并抽
      第 50 集合成（3 镜 / 768 B）。
- [x] 视频任务登记资产账本：每渲染一镜就 `asset.register`
      `v<board_version>/shot_<seq>.mp4`（现场算 SHA-256/大小），任务重置
      重跑按名字查重不重复登记；`asset.list` 在百集 300 条下可整份返回。
      接真实 Provider 时把 `v<board_version>` 换成集号目录即可。

## 验收

- [x] 百集 Mock 压力跑通，状态机与恢复零错误（`p13c_selftest.sh`，
      100 集 100 个任务、300 次渲染、100 条提交全量重放无违规）。
- [ ] 真实百集产能报告与 DESIGN §0.3 基线误差 < 20%。

---

# 16. 操作目录与测试覆盖矩阵

**已实现的 58 个操作**（`registry.uya` 是唯一来源；`describe` 就是从这张表
生成的）。"覆盖脚本"列是能跑到它的自测，空着表示只有间接覆盖。

| 操作 | 阶段 | 权限 | 覆盖脚本 |
|---|---|---|---|
| project.create | P3 | write | p3 / p5b / p11 |
| project.get | P3 | read | p2 / p3 |
| project.configure | P3 | write | p3 |
| episode.review | P5 | write | p9 |
| budget.limit | P13 | write | p9 |
| project.list | P3 | read | p3 |
| bible.put | P3 | write | p3b / p12b |
| bible.get | P3 | read | p3b |
| bible.history | P3 | read | p3b |
| asset.register | P3 | write | p3b / p13c |
| asset.list | P3 | read | p3b |
| asset.get | P3 | read | p10 |
| canon.inspect | P4 | read | p4 / p6 |
| canon.commit | P4 | write | p4 / p12 / p12b |
| canon.recover | P4 | write | p4 |
| canon.audit | P12 | read | p12 / p12b / p11 |
| continuity.inspect | P4 | read | p2 / p13c |
| llm.ping | P5 | read | p1 / p5 |
| llm.complete | P5 | read | p5 |
| episode.get | P5 | read | p11 |
| episode.generate | P5 | write | p5b / p6 / p11 |
| episode.approve | P5 | write | p5b / p6 / p11 |
| context.inspect | P5 | read | p5c |
| episode.produce | P5/P8 | write | p2 / p5d / p8 |
| episode.retry | P9 | write | p9 |
| production.status | P8 | read | p9 |
| task.run | P5 | write | p5d |
| task.get | P5 | read | p5d |
| task.list | P5 | read | p5d |
| storyboard.build | P7 | write | p7 / p11 |
| storyboard.get | P7 | read | p7 |
| provider.capabilities | P8 | read | p8 |
| qa.run | P9 | write | p9 / p11 |
| media.assemble | P10 | write | p10 / p11 |
| media.probe | P10 | read | p10 |
| media.encode | P10 | write | p10 |
| media.subtitle | P10 | write | p10 |
| media.mux | P10 | write | p10 |
| media.mix | P10 | write | p10 |
| media.loudnorm | P10 | write | p10 |
| shot.retry | P9 | write | p10 |
| queue.get | P8 | read | p8 |
| final.approve | P11 | write | p11 |
| project.migrate | P3 | write | p3 |
| episode.batch | P13 | write | p9 |
| budget.report | P13 | read | p11 |
| production.report | P13 | read | p13c |
| index.rebuild | P13 | write | p13b |
| qa.align | P7 | read | p7 |
| canon.diff | P4 | read | p4 |
| story.review | P5 | read | p5b |
| index.list | P13 | read | p13b |
| series.plan | P5 | write | p5e |
| outline.approve | P5 | write | p5e |
| series.get | P5 | read | p5e |
| promise.report | P12 | read | p12b |
| invariant.check | P12 | read | p12 |
| production.cancel | P8 | write | p9 |

**还没实现、但文档里承诺过的操作**（照实记着，别当已完成）：

| 操作 | 出处 | 缺口 |
|---|---|---|



| series.plan / outline.approve | P5 | 百集大纲与批准 |




---

# 17. 关键风险登记

| 风险 | 影响 | 缓解方式 | 阶段 |
|---|---|---|---|
| 无 fsync（已核验） | 掉电可能丢最后一次提交 | 明确写入已知限制；只保证"不留半个文件" | P0/P4 |
| HTTPS 校验（1.5 已修） | 曾经只能 insecure = 泄 Key | 上游已补 ECDSA/RSA/信任库；反例未回归 | P0/P5 |
| MCP Host 与规范能力不一致 | 插件无法连接 | 只依赖已核验的四方法 + `-32601` 约定 | P0/P1 |
| 协议帧写错（多行/超 1 MiB） | 宿主整条丢弃，工具全部失效 | 单行紧凑输出的自测判据 | P1 |
| `call` 超过 60 s | 宿主超时，任务状态不明 | 一律先落盘再返回 `queued` | P1/P8 |
| 陈旧锁（进程被 kill） | 项目变永久只读 | pid 探活 + LOCK_STALE 口径 | P4 |
| Worker 未运行 | 任务长期排队 | 状态明确返回、启动检查和文档 | P1/P8 |
| Provider 提交后进程崩溃 | 重复任务、重复 GPU 消耗 | 先查历史，`prompt_id` 即幂等键 | P8 |
| GPU 单卡串行 | 排队延迟不可控 | 并发固定 1、队列顺序、超时可见 | P8 |
| GPU 工时超支（实测 2.9 h/集） | 百集成本失控、交付延期 | 预算账本 + 熔断 + 重做率告警 | P13 |
| 跨集漂移（人物/场景/语气） | 中后段人物变样、观众弃剧 | 每 10 集闭环审计 + 冻结 hash | P12/P13 |
| 审批注意力枯竭 | 审核流于形式，缺陷漏过 | 抽样审批 + 异常优先 + 日终报告 | P13 |
| 不变量误报 | 提交门被绕过或被人为放宽 | 反例库先立、每条错误可定位 | P12 |
| LLM 输出结构不稳定 | 剧本流程中断 | Schema 验证和有限修复 | P5 |
| 资产路径对 Host 不可见 | 无法播放成片 | 首版同机共享目录，后续下载服务 | P3/P10 |
| 已批准剧本被修改 | 后续剧情冲突 | 不可变版本和依赖重验 | P4/P5 |
| 视频与剧本不一致 | 成片穿帮 | QA、局部重试、Canon 不受视频污染 | P9 |
| MCP 单工具权限过粗 | 无法区分内部操作风险 | Plugin 内部策略和预算 | P2 |

---

# 18. 首个可交付版本的严格边界

建议把第一个可交付版本定义为 **Drama Plugin 0.5**，只包含：

- 独立 Uya 程序；
- MCP 三工具（`list`/`describe`/`call`，单行紧凑输出，60 s 内返回）；
- Operation Registry；
- Project/Bible 文件存储（含 `format_version` 与迁移）；
- Canon、事件、提交记录和恢复；
- LLM 传输层 + LLM Adapter；
- Story Engine + 100 集大纲（`series.plan`/`outline.approve`）；
- Worker 持久任务机制；
- **闭环引擎最小版**（四本账 + 九条不变量 + 提交门 + 重放）；
- 连续三集剧本测试。

0.5 不要求接本地队列，不要求视频、音频、FFmpeg，不要求网页 UI。

0.5 的验收核心（M1）：**在 MCP Server 和 Worker 进程至少两次停止、重启的
情况下，仍能正确生成并提交三集连续剧本；四轴不变量零红；抽 3 集历史重放
复现率 100%；所有状态变化可追溯、可验证、可恢复。**

通过后再开始 0.6 及之后的视频生产阶段。百集不靠"跑得久"，靠每升一个台阶
都把不变量与回归集重新跑绿（M1→M2→M3→M4）。

---

# 19. 文档落点与单一来源

现状（1.2 记录）：三份文档（DESIGN / TODO / REVIEW）当前躺在
`uya-agent/drama_plugin/docs/` 下，而 DESIGN §0 的决策是"Drama 是独立项目"。
两者必须收敛到一个落点，二选一：

- **A**：跟着独立仓走 —— 迁到 Drama 仓的 `docs/`，本仓只留一行指路；
- **B**：留在本仓 `drama_plugin/docs/` 并**纳入版本控制**（推荐：现阶段
  还在设计与评审，跟宿主仓一起 review 成本最低）。

无论选哪个，都要做到：

- [ ] `~/Downloads/` 下的同名副本删掉（现在与仓内两份逐字节相同）。
- [ ] 一次改动只改一处，另一处要么是生成的，要么是符号链接。
- [ ] 每次升版本时同步 `DRAMA_DESIGN` 的 §0 摘要与本文件 §0.1 摘要。
