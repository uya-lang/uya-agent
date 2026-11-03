# Drama Plugin 文档评审

- 评审对象：`DRAMA-DESIGN-001 v1.1`（1323 行）、
  `DRAMA-TODO-001 v1.1`（741 行）
- 评审依据（全部现场核验，不凭规范假设）：
  - 本仓 `uya-agent` 源码：MCP 客户端、文件/锁/进程用法、DESIGN §21；
  - Uya stdlib：`uya/stdlib/lib/` 下的 osal / std.io / std.json / std.process /
    std.sql / std.http / lib.tls；
  - 真实产线：`~/ersunfu/micro-drama/顶楼误闯`（系列规范、场景/角色资产包、
    分镜表、shots.py/qc.py/build_film.py、qc/ 产物）；
  - 已有先例：`~/uya-aigw`（**Uya 写的 MCP server**，两工具门面模式）。
- 评审结论分三级：**P0** 会返工/方向性错误；**P1** 应该改；
  **P2** 建议；**已核验** 表示文档里标"待验证"但今天已有确定答案。
- 落地状态：**24 条已全部落进 DESIGN/TODO 的 v1.2**（映射见文末 §G）。

---

## 0. 一句话结论

架构骨架站得住：三工具门面、Canon 与 Production 分离、提交记录即事务边界、
MCP 控制面与持久 Worker 分离，这四条都有先例（`uya-aigw` 就是
`api_catalog` + `api_call` 的同一模式）且与宿主能力匹配。

问题在两处：

1. **把今天就能定死的事写成了"待 P0 验证"**（帧格式、超时、锁、原子写、JSON
   上限、stdin/stdout 语义），白留 10 条不确定性；
2. **把真正没底的事整块漏掉了**：真实视频产线是**本机 ComfyUI + 单卡串行**，
   不是云 API；磁盘上已经有一条能跑的 130 KB Python 产线；真实资产包与分镜的
   字段（冻结文本、锚点、锚帧接戏）一条都没进模型；stdlib 里**没有 HTTP 客户端**
   也**没有 fsync**，而 TODO 里没有对应的任务。

按现状开工，P3/P7 的数据模型必然返工，P5 会撞上没有传输层的墙。

---

## A. 业务与产线事实层

### A1（P0）视频 Provider 的假设与真实环境不符

文档写的是：MiniMax H3 **云 API** + 异步轮询 + 幂等键 + 费用预算
（§10.3、§18.9、§9.4）。

真实环境是：

- `第001集/scripts/h3_lib.py:15` → `HOST = "http://127.0.0.1:8188"`
  （**本机 ComfyUI**，队列接口）；
- `queue_all.py:4` → 「GPU 只有一个，必须串行」，七部片子排一条队；
- `短剧制作指南.txt` → 工具位置 `/media/winger/_dde_data/minimax-h3-local`；
- `系列规范.md §一` → H3 **硬约束**：宽高必须是 32 的倍数、帧数必须是 17k+5。

⇒ 「幂等键 / 计费 / submission_unknown」这套话术对本地队列**不适用**。
真正的约束是：GPU 互斥（全局一把队列锁）、job 可查性（ComfyUI 的
`prompt_id` 天然就是幂等键与查询句柄）、显存与时长上限、单卡串行的排队优先级。

动作：

1. §10.3 改成两层接口：`LocalQueueProvider`（首版，ComfyUI `prompt_id` 当
   provider task id，天然幂等）与 `HttpProvider`（未来云 API）；
2. 成本模型从"钱"改成"GPU 分钟 + 串行排队时间"，`cost_class` 的取值表重写；
3. §18.9 的核验项从"核对 H3 最新 API 文档"改成"核对本机 ComfyUI 的
   `/prompt`、`/history/{id}`、`/view` 行为与 H3 节点参数"。

### A2（P0）既有可工作产线没有进设计，重写边界未定义

磁盘上已经有一条跑通的产线（Python）：

| 文件 | 大小 | 作用 |
|---|---|---|
| `第001集/scripts/shots.py` | 51 KB | **本集分镜/冻结文本/台词的唯一来源** |
| `scripts/cards.py` | 40 KB | 字幕/角标/片尾卡 |
| `scripts/qc.py` | 23 KB | `asr` / `vision` / `continuity` / `final` |
| `scripts/build_film.py` | 20 KB | 剪辑 + 字幕 + 片尾卡 + 响度 |
| `scripts/lint_shots.py` | 11 KB | 分镜静态体检（0 硬错误才可上机） |

`分镜表.md` 开头逐字写着：「机器可读定义：`scripts/shots.py`（唯一来源，
本表由它摘出来）」。`系列规范.md §四` 还定死了每集六步流程
（工程化 → 静态体检 → 出图 → 质检 → 成片 → 终检）。

文档侧：§1.2 是「Uya 优先」，§15 给了一套从零起的 `src/**` 目录，
TODO 里**没有任何**一条"是否复用现有产线 / 如何迁移"的任务，也没有对
130 KB Python 重写量的评估。

动作：在 §1.2 与 TODO P0 里先定档，三选一并写进文档：

- **A 档（全 Uya 重写）**：风险最高，需要给出分阶段迁移表与"两套并存期"；
- **B 档（推荐）**：Uya 只做 Canon/Task/MCP/Registry/审批，Python 产线降级为
  `MediaProvider` / `VideoProvider` / `QaProvider` 的子进程适配；
- **C 档（薄编排）**：Uya 只做 MCP 门面 + 状态，其余全留 Python。

选 B 的理由：设计的核心价值在"剧情事实可验证 + 可恢复"，这恰好是现有
Python 产线没有的部分；而 shot 生成/剪辑/QC 是它的强项，重写收益低。

### A3（P0）数据模型缺真实资产包的关键字段

`场景资产/SC01_68楼会议室.md` 的字段表是真实一致性机制：

- 一致性锚点（5 条，缺一条就不像）；
- **冻结描述文本（连续性锁）**：逐字粘贴、不换近义词、不调词序；
- 状态变体（时段/光/道具状态，**不写进连续性锁**）；
- 参考图组（全景/中景/特写分层）；
- 潜空间缓存（首镜 latent 当后续接力起点）；
- 适用镜头清单、维护记录（防无声漂移）；
- 正/反向提示词（反向词是漂移排除项）。

`角色资产/S1_苏晚.md` 同样是两层：身份级冻结（脸/发型/服装/配饰/年龄）+
状态变体（手中道具/污渍/情绪弧/凌乱度）+ 「参考图**只取身份**，不复制
背景与棚灯」+ 禁止项 + 表演口径。

文档侧：§6.2 只有 `CharacterProfile`/`CharacterState`，§6.3 只有
"静态布局 + 动态状态"。**没有冻结文本、没有反向词、没有锚点、没有潜空间
缓存、没有"只取身份"的口径**。而这些字段正是"跨集不漂移"的唯一执行机制。

动作：P3 的 Bible 子模型**直接采用**这三个资产包的字段（别另设计），
把「连续性锁」与「反向提示词」列为一等字段；P7 的 Shot 引用它。

### A4（P0）分镜模型缺接戏机制

真实分镜表（`分镜表.md`）有、设计里没有的：

- `anchor_prev`：上一镜最后一帧当本镜第 0 帧（`MiniMaxH3AddGuide`,
  `frame_idx=0`），以及"硬切 + 开场接戏句"这条替代路径；
- `<Picture n>` 的**顺序**（决定参考图身份绑定）；
- 台词逐字（后续 ASR 核对与字幕定时都以它为基准）；
- 成片时间轴到 0.01s（"源/成片"两列，逐镜核算）；
- 片尾卡（时间轴里是独立一行）；
- 生成规格与成片规格**两套**（448×800 → 440×800）。

TODO P7 目前只有一句 `ShotReference`，§9 分镜章节说"镜头状态能衔接"，
但没给判定机制。

动作：P7 的 Shot 增加 `anchor_prev` / `prev_last_frame` / `ref_image_order`
/ `line_text` / `timeline_in_out` / `card` 字段，并把"接戏类型"变成枚举
（同机位硬接锚帧 / 换机位硬切 + 接戏句）。

### A5（P1）成片规格与时长判定缺失

`系列规范.md §一` 的口径表：生成画布 448×800（32 倍数、17k+5 帧）、成片
440×800 竖屏 24fps、单集正片 ≈56 s + 片尾卡 ≈4 s、编码
libx264/crf 20/yuv420p/aac 128k/32kHz/faststart、响度 loudnorm 两遍
（I=-16 LUFS、TP=-1.5 dBTP）。

文档侧：只有 `duration_seconds`（10–180，默认 60）；全篇"画幅"出现 1 次，
"帧率""片尾卡""编码""响度"**0 次**；§16.3 的"每集目标约 60 秒"没有判定方法。

动作：`episode.produce` 增加 `format` 规格块（画布/成片/帧率/正片+卡/编码/
响度），并把"时长核算"写成确定性规则：Σ镜头时长 = 正片时长，误差 ≤ 0.05 s，
判据可由 selftest 断言（现有 `lint_shots.py` 已在做同类核算，可直接对照）。

### A6（P1）QA 口径与真实产线冲突

真实口径（`系列规范.md §三`）：

- 台词由 H3 直出（`<d>[Chinese] …</d>`），**后期只做 loudnorm，不做配音替换**；
- ASR 只用来核对与定时字幕；
- QC 有 ASR 相似度阈值（`QC清单.md`：台词「ASR 相似度 ≥0.85」）；
- 机器项由 `qc.py asr|vision|continuity|final` + `check_join.py`
  （`qc/join.json`）跑。

文档侧：§10.1 列了 `AudioProvider`（配音、音效），P10 有"配音与音效轨道
合成"——与本产线口径直接矛盾；§13.2 的 QA 清单里没有 ASR 对齐项。

动作：删/降级"配音替换"，改成"声音设计 + 现场声 + loudnorm"；
§13.2 增加三类**确定性**检查：ASR 对齐（相似度阈值）、锚帧接戏差
（相邻镜末帧/首帧）、成片终检（静音段、黑边、可解码、时长）。

### A7（P1）P6 的固定测试项目是虚构的

设计用"爸爸/妈妈/遥控器/冰箱"当黄金 fixture。仓里其实既有真实的家庭系列
（`queue_all.py` 的 s4–s10 七部），也有已产出的《顶楼误闯》（都市爱情、
60 s 竖屏、9 镜、ASR 与 QC 全齐）。

动作：P6 换成**真实脚本**做 golden fixture（推荐《顶楼误闯》第 001 集：
它已有分镜、台词、QC 清单，验收可逐条比对），虚构 fixture 只保留为最小
单元测试样例。

### A8（P2）中文/时长计量全篇缺失

`grep 中文 / UTF-8 / 帧率 / 片尾卡 / ASR / loudnorm` 在两份文档里命中 **0**。
而"一集 60 秒"的核心计量恰恰是"汉字数 → 秒"。

动作：§16 增加"文本与时长"小节：UTF-8 字节口径、汉字→秒的估算式
（对白 4–5 字/秒、停顿按标点计）、字幕定时规则（按 ASR 对齐后回写）。

---

## B. 与本仓互操作层（这些今天就能写死，不必等 P0）

### B1（P0）stdio 帧格式是硬约束，文档没写

宿主客户端按 `\n` 切行，**一行必须是一条完整紧凑 JSON**：

- `src/plugin/mcprun.uya:14,41`：`MCP_LINE_MAX = 1 MiB`，超限**整行丢弃**
  （不是截断后解析）；
- `src/plugin/mcprun.uya:577`：`mcprun_recv` 逐行取，只认 `id` 匹配的那一行；
- DESIGN §21 亦记：「stdio 帧 = 一行一条 JSON（`\n` 分隔，容忍 `\r`）」。

文档 §4.5 / §4.6 的示例全是**缩进多行** JSON，也没提 1 MiB 上限。
实现者照示例 pretty-print 输出 ⇒ 协议当场判死。

动作：§4.2 加一条硬约束（"单行紧凑、无多余换行、单条 ≤1 MiB"）；
P1 自测加两条判据：① 任意响应的原始字节里除结尾 `\n` 外不含 `\n`；
② 超 1 MiB 时改为返回资产引用而不是截断 JSON。

### B2（P1）工具名归一化已定死，`drama.list` 是自找麻烦

规则（`src/plugin/mcp.uya:163-215`，自测 `src/selftest/st_mcp.uya:163`）：

- 公开名 = `mcp__<server>__<raw>`；
- 非 `[A-Za-z0-9_-]` 一律换 `_`（`drama.list` 的点会变下划线）；
- 超过 64 字符或发生过替换 ⇒ 截到 51 + `_` + sha256 前 12 hex。

⇒ 模型侧看到的是 `mcp__drama__drama_list`（"drama" 出现三遍，22 字符）；
更糟的是 `drama.list` 与 `drama_list` 会归一到**同一个**公开名（撞名）。

动作：MCP 工具 raw 名直接用 `list` / `describe` / `call`
（公开名 `mcp__drama__list` 等），把点号**只**留给业务操作名
（`project.create` 这类不经过 MCP 层）。这条还能顺手删掉 P0 里
"验证带点工具名的发现、归一化和调用映射"——答案已经有了。

### B3（P0）`toolCallTimeoutMs` 默认 60 s，`drama.call` 的 SLA 要写死

- `src/plugin/mcpcfg.uya:42`：`MCP_TIMEOUT_DEFAULT = 60000`；
- 配置可给 1–3,600,000（`mcpcfg.uya:827`）；
- 超时表现：一句 `Error: …` 工具文本，server **不被杀**（§21.8）。

文档没写 SLA，也没写建议配置值。动作：§4.5 写明"`drama.call` 必须在 60 s
内返回"，所有重活先落盘再返回 `queued`；P0 记录建议
`toolCallTimeoutMs`（与 Worker 开工前的"入队"语义匹配，60 s 足够）。

### B4（P1）`isError` 的语义必须写死，否则实现者必然用错

宿主侧行为（`src/plugin/mcp.uya:850-905`）：

- 结果投影规则：`content[]` 里 `type=="text"` 的 `text` 逐段拼接（`\n` 连接），
  非 text 段落占位行；
- `isError:true` ⇒ 结果文本前缀 `Error: `；
- 另外本仓**优先读 `structuredContent`**（`mcp.uya:873`），即
  `structuredContent` 是**已支持**的。

文档 §4.6 让所有失败都走 `success:false`，但没说是置 `isError` 还是只放在
文本里。动作：

- 业务/校验失败（`CONTINUITY_CONFLICT` 等）⇒ `isError` **false**，
  文本里给 `{"success":false,…}`（模型应当读到并自己纠正）；
- 协议/基础设施失败（未知方法、内部异常、Worker 缺席）⇒ `isError` true；
- §4.2 的"不依赖 `structuredContent`"降级为"可选增强"。

### B5（P1）权限、环境、路径的真实行为

1. **read-only 下 MCP 工具一律拒绝**（不给"问用户"的机会）
   —— `DESIGN.md §21.6`、`src/plugin/mcp.uya:1072-1077`。
   后果：文档要写明"必须 workspace-write 或 danger-full-access"。
2. **workspace-write 下每次调用都要 `ask_approve_action` 批准**
   —— `src/plugin/mcp.uya:1098`。后果：一集十几次 `drama.call` ⇒ 用户被
   逐次弹批准；§14.2 的"插件内二次授权"不能替代宿主批准。
3. **子进程 env 只继承白名单**（`HOME LOGNAME PATH SHELL TERM USER`）
   **+ 配置里的 `K=V`** —— `DESIGN.md §21.6`。后果：API Key **只能**走
   `mcp.json` 的 `env` 或插件自己的配置文件。
4. **`command` 不做 PATH 查找**（`execve` 只吃路径）
   —— `DESIGN.md §21.6`。后果：配置示例必须写绝对路径。
5. **子进程不套 bwrap 沙箱**（`mcp_spawn_server` 直接 execve）
   —— `src/plugin/mcp.uya:612-660`。好消息：写 `DRAMA_ROOT` 不受工作区
   限制；这条要在文档里确认，别自己加戏。

动作：§11.1 / P11 的"MCP Host 配置示例"给出完整样例（绝对路径 +
`env` 注入 key + `toolCallTimeoutMs`），§14.2 补一句宿主批准粒度。

### B6（P2）宿主只实现 stdio

`src/plugin/mcpcfg.uya:57`：`transport=HTTP` 字段存在但"本版不实现，只为如实
报告"。动作：§4.2 直接写"宿主仅 stdio"，删掉对应的 P0 核验项。

### B7（P2）`mcp` 元工具已存在，与 `drama.list` 语义重叠

宿主**无条件**注入一个 `mcp` 元工具（`{action:"list"|"reload"}`，
`src/plugin/mcptool.uya:27`）。它会列出每个 server 的工具与失败原因。

动作：文档里把两件事分清——"宿主层发现（`mcp` 工具）"与"业务层发现
（`drama.list`）"，并提醒实现者不要重复造诊断入口。

---

## C. 文档 §18「P0 必须核验」十条：6 条今天已有确定答案

1. **Uya 怎么写 stdio MCP Server** —— 本仓只有客户端；但 `~/uya-aigw` 已有
   **Uya 写的 MCP server**（HTTP `POST /mcp`，两工具 `api_catalog` +
   `api_call` = 与本文档同一个门面模式），骨架可复制。
   出处：`~/uya-aigw/README.md §7.1`、`src/net/serve.uya:5457`。
2. **宿主协议版本/方法/映射** —— 协议 `2024-11-05`；只 tools + 自定义钩子
   方法；不认的方法须回 `-32601`（宿主按放行处理）；名字映射见 B2。
   出处：`src/plugin/mcp.uya:50`、`DESIGN.md §21.8`。
3. **临时文件/原子重命名** —— **有**。`os_rename` 在 osal；本仓已有成熟模式
   「O_EXCL 建 tmp(0600) → 写满 → rename」，三处实现。
   出处：`uya/stdlib/lib/osal/osal.uya:325`、`src/session/dshsave.uya:615-632`、
   `src/session/dshfile.uya:159-192`、`src/pm/pm_repo.uya:351-378`。
4. **跨进程锁/排他创建** —— **没有 flock**；O_EXCL 锁文件是既有做法
   （退避 20→200 ms、超时让位）。注意文档漏了**陈旧锁**：持锁进程已死会让
   项目永久只读。出处：`src/session/dshsave.uya:580-612`、
   `osal.uya:226`（`os_kill` 可做 pid 探活）。
5. **子进程/信号/守护** —— `std/process` 有完整 pipeline
   （fork/exec/env/cwd/capture/status）；`os_spawn`/`os_waitpid`/`os_kill`
   齐全。出处：`uya/stdlib/lib/std/process.uya`、`osal.uya:418,422,226`。
6. **JSON 大小/嵌套** —— `std/json` 有 parser/encoder +
   `to_json<T>`/`from_json<T>` 宏；**嵌套上限 256**；非 ASCII 是否转义
   **仍未验证**（P0 该保留的一条）。出处：
   `uya/stdlib/lib/std/json/parser.uya:13`。
7. **追加/刷新/同步语义** —— **stdlib 没有 `fsync`/`fdatasync`**（全树 grep
   为空）⇒ §8.2 第 6 步"完成可用的持久化操作"**当前无法满足**。
   出处：`grep -r fsync uya/stdlib` = 0。
8. **配置/环境变量/密钥** —— 见 B5。
9. **H3 现行 API** —— 前提错了，见 A1。
10. **FFmpeg 调用/输出校验** —— 真实产线已在用（抽末帧、拼接、loudnorm），
    可实证。出处：`h3_lib.py:218`、`build_film.py`。

**两条 P0 里根本没写的大头：**

1. **stdlib 没有 HTTP 客户端。** `std/http` 全是 server 侧（`server.uya`、
   `router.uya`、`epoll_server.uya`…），`lib/tls/https.uya` 只有
   `https_client_handshake`；请求构造、响应解析、重定向、超时、连接复用、
   分块/SSE 全要自己写。量级参照：本仓 `src/net/httpc.uya` **2318 行**。
   ⇒ TODO 里**一条相关任务都没有**（P5 只有"定义 LLMProvider 接口"）。
2. **`std/sql` 只有 Driver/Conn 接口，没有随仓 sqlite 驱动。** ⇒ 设计选"文件
   + 不可变提交记录"（§8）是对的，但文档里**没有一句理由陈述**，下一轮评审
   还会再问"为什么不用数据库"。把这条写进 §8 开头即可。

---

## D. 文档内部问题

### D1（P1）§8.1 的文件布局漏了三样东西

§4.5 要求"检查请求 ID 和幂等记录"、§8.4 要求"项目单写者锁"，但布局里没有：

- `idempotency/`（幂等记录）；
- `locks/`（锁文件，且要写清命名与陈旧锁处理）；
- `audit/operations.jsonl` 无上限、无轮转（长期跑会吃满磁盘）。

### D2（P1）`request_id` 必填且由模型生成

§4.5 把 `request_id` 列为 `required`。模型临时编 ID ⇒ 碰撞、复用、
"重试时换了新 ID 于是重复执行"三种错都能出。

动作：`request_id` 改**可选**（缺省由插件生成并回显），幂等键 = `(operation,
input_hash)`，`request_id` 只当 tracing 用。§9.1 的 Task 字段同步。

### D3（P1）磁盘数据没有 `format_version` 与迁移策略

`bible_v001.json`、commit record、task 文件的结构一旦改版，旧盘就读不了；
文档只有"版本号"，没有"版本迁移"。动作：P3 加一条迁移任务，§8.1 的每类
文件加 `format_version` 字段，§8.3 的启动恢复加"遇到旧版本先迁移/拒绝"。

### D4（P1）§17 版本路线与 TODO 阶段没有映射

§17 是 0.1–0.8，TODO 是 P0–P11，只有"0.5 = 连续三集剧本验收"是靠猜的。
动作：§17 表加一列"对应阶段"（0.1→P1、0.2→P3、0.3→P4、0.4→P5、
0.5→P6、0.6→P7、0.7→P8、0.8→P9+P10）。

### D5（P1）TODO 的 `[!]` 阻塞标记零预置

标记定义在那儿却一条没用。已知三条应立刻标上：

- `[!]` 无 fsync ⇒ 提交只能保证"不出现半个文件"，不保证掉电不丢；
- `[!]` stdlib 无 HTTP 客户端 ⇒ P5 之前必须先有传输层任务；
- `[!]` 无 sqlite 驱动 ⇒ 存储只能走文件方案（与 §8 一致，但要写明）。

### D6（P1）文档落点自相矛盾，且没有单一来源

- §0.1 决策「Drama 是独立项目，不放进 `uya-agent/src/`」；
- 实际却躺在 `uya-agent/drama_plugin/`，而且**未被 git 跟踪**
  （`git ls-files drama_plugin` 为空，`git status` 显示 `?? drama_plugin/`）；
- `~/Downloads/DRAMA_DESIGN.md`、`~/Downloads/DRAMA_TODO.md` 与仓内两份
  **逐字节相同**（`diff -q` 无输出）。

动作：定一个落点（独立仓根 `docs/`，或本仓 `drama_plugin/docs/` 并提交），
删掉 Downloads 副本，之后只改一处。

### D7（P2）P0 的 30+ 项没有优先级/时间盒

动作：把"能改架构决策"的 8 项排前——帧格式、超时、锁（含陈旧锁）、fsync、
HTTP 传输层、JSON 上限、env/密钥注入、资产可见性；其余（Provider 调研、
FFmpeg 边界）排后。

### D8（P2）§15 的逐文件 `*.uya` 清单容易被当成定稿

§0 明说"示意语法不得直接当作可编译代码"，§15 却给了整棵 `src/` 文件树。
动作：标注"职责示意，落地以 Uya 编译规则为准"，或只留目录职责不留文件名。

### D9（P2）点号语义混乱

MCP 工具名用点（`drama.list`）、业务操作名也用点（`project.create`）。
在归一化规则下（B2），两者会混。动作：统一为"MCP 工具名无点、业务操作名
有点"。

---

## E. v1.2 修订清单（按文档定位，可直接照做）

### `DRAMA_DESIGN.md`

1. §0 修订摘要：加 v1.2 条目（Provider 本地化、既有产线边界、资产包字段、
   帧格式/isError/fsync 三条硬约束）。
2. §1.2：把 A2 选定的档位（推荐 B 档）写成明确决策。
3. §4.2：写死"仅 stdio"、"单行紧凑 JSON ≤1 MiB"、`structuredContent` 可选、
   `isError` 语义（B1/B4/B6）。
4. §4.5：`request_id` 改可选（D2）；写明 60 s SLA（B3）。
5. §4.6：成功/失败示例改成**单行紧凑**形态（B1）。
6. §6.2/§6.3：吸收角色/场景资产包字段（冻结文本、锚点、状态变体、反向词、
   潜空间缓存、适用镜头清单）（A3）。
7. §7：接戏口径（锚帧/硬切）进"视频与剧本一致性"（A4）。
8. §8 开头：加一句"为什么不是数据库"（C 的第 2 条大头）。
9. §8.1：补 `idempotency/`、`locks/`、audit 上限与轮转、`format_version`
   （D1/D3）。
10. §8.2：第 6 步降级为"rename 原子性 + 崩溃后重建"，并记"掉电可能丢最后
    一次提交"（C-7）。
11. §8.4：补陈旧锁处理（pid + `os_kill(pid,0)` 探活）（C-4）。
12. §10.3：换成 `LocalQueueProvider`（ComfyUI `prompt_id`）+ 未来
    `HttpProvider`（A1）。
13. §13.2：加 ASR 对齐 / 锚帧接戏 / 成片终检三类确定性检查；删配音替换
    口径（A6）。
14. §16.3：黄金 fixture 换成真实脚本（A7）；补"文本与时长"计量（A8）。
15. §17：加"对应阶段"列（D4）；§18 十条按 C 组结论改写为"已核验/待核验"。
16. §15：标注职责示意（D8）。

### `DRAMA_TODO.md`

1. P0 新增任务：HTTP 传输层（含 TLS 客户端、证书、超时、重试）、
   stdout 单行紧凑输出的自测、陈旧锁、fsync 缺失的替代方案确认、
   非 ASCII JSON 转义确认（C 的两条大头 + B1 + C-4/C-6/C-7）。
2. P0 预置三条 `[!]`（D5）；P0 任务按 D7 排序。
3. P5 加"LLM 传输层 + Prompt 版本 + 结构化输出校验"的任务组
   （现在只有接口定义，没有传输）。
4. P7 的 Shot 补 `anchor_prev` / 参考图顺序 / 台词逐字 / 时间轴 / 片尾卡
   （A4）。
5. P10 删"配音与音效轨道合成"或降级为"可选"，补编码/响度口径（A5/A6）。
6. P11 的"MCP Host 配置示例"给出完整样例（绝对路径 + `env` + 超时）（B5）。
7. 阶段总览加"对应版本"列（D4）；P3 加 `format_version` 与迁移任务（D3）；
   P2 的 `request_id` 校验改成"可选/生成/幂等键 = 输入 hash"（D2）。

---

## F. 证据索引

| 结论 | 文件 | 位置 |
|---|---|---|
| 帧格式/1 MiB | `src/plugin/mcprun.uya` | 14、41、577 |
| 名字归一化 | `src/plugin/mcp.uya` | 163-215 |
| 名字自测 | `src/selftest/st_mcp.uya` | 163 |
| 协议版本 | `src/plugin/mcp.uya` | 50 |
| 结果投影 / `isError` | `src/plugin/mcp.uya` | 850-905 |
| `structuredContent` | `src/plugin/mcp.uya` | 873 |
| 超时默认 60 s | `src/plugin/mcpcfg.uya` | 42、827 |
| 仅 stdio | `src/plugin/mcpcfg.uya` | 57 |
| 起进程（无沙箱/env 白名单） | `src/plugin/mcp.uya` | 612-660 |
| 权限闸门 | `src/plugin/mcp.uya` | 1072-1077、1098 |
| `mcp` 元工具 | `src/plugin/mcptool.uya` | 27 |
| 插件系统事实表 | `DESIGN.md` | §21.1、§21.6、§21.7、§21.8 |
| `os_rename` | `uya/stdlib/lib/osal/osal.uya` | 325 |
| 原子写 + 锁文件 | `src/session/dshsave.uya` | 580-612、615-632 |
| 原子写（第二处） | `src/session/dshfile.uya` | 159-192 |
| 原子写（第三处） | `src/pm/pm_repo.uya` | 351-378 |
| JSON 嵌套上限 256 | `uya/stdlib/lib/std/json/parser.uya` | 13 |
| 进程 pipeline | `uya/stdlib/lib/std/process.uya` | 3053-3325 |
| 无 fsync / 无 HTTP 客户端 | `uya/stdlib/lib`（grep） | — |
| HTTP 客户端量级参照 | `src/net/httpc.uya` | 全文件 2318 行 |
| Uya 写的 MCP server 先例 | `~/uya-aigw/README.md` | §7.1 |
| 同上（代码位置） | `~/uya-aigw/src/net/serve.uya` | 5457 |
| 真实视频接口 | `顶楼误闯/第001集/scripts/h3_lib.py` | 15 |
| 单卡串行 | `顶楼误闯/第001集/scripts/queue_all.py` | 4 |
| 成片规格/冻结/流程 | `顶楼误闯/系列规范.md` | §一、§二、§三、§四 |
| 场景资产包字段 | `顶楼误闯/场景资产/SC01_68楼会议室.md` | 全表 |
| 角色资产包字段 | `顶楼误闯/角色资产/S1_苏晚.md` | 一~五 |
| 分镜/接戏机制 | `顶楼误闯/第001集/分镜表.md` | §一、§三、§四 |
| QC 口径（ASR ≥0.85） | `顶楼误闯/第001集/QC清单.md` | 镜3 条目 |

---

## G. 落地映射（评审 → v1.2 改动位置）

| 编号 | 落到哪 |
|---|---|
| A1 Provider 本地化 | DESIGN §10.3、§9.4、§9.5、§2.3、§12.2；TODO §10（P8） |
| A2 既有产线边界 | DESIGN §1.2.1、§10.1、§12.2、§15、§19；TODO §2.4、§0 约束 13 |
| A3 资产包字段 | DESIGN §6.1、§6.2、§6.3；TODO §5（P3「Bible 子模型」） |
| A4 分镜/接戏 | DESIGN §6.8、§7.3；TODO §9（P7） |
| A5 成片规格/时长 | DESIGN §5.3、§16.3；TODO §12（P10）、§7（P5 验收） |
| A6 QA 口径 | DESIGN §13.1、§13.2、§10.1；TODO §11（P9）、§12（P10） |
| A7 黄金 fixture | DESIGN §16.3；TODO §8（P6） |
| A8 中文/时长计量 | DESIGN §16.3；TODO §7（P5 验收） |
| B1 帧格式 | DESIGN §4.2、§4.6；TODO §0 约束 11、§3（P1）、§2.1 |
| B2 工具名去点 | DESIGN §4.1、§4.8、全篇；TODO §0 约束 2、§3、§4 |
| B3 60 s 超时 | DESIGN §4.5、§4.2；TODO §0 约束 12、§4、§10（P8 验收） |
| B4 `isError` 语义 | DESIGN §4.6；TODO §3（P1 自测） |
| B5 权限/env/路径 | DESIGN §10.4、§11.1、§14.2；TODO §13（P11 发布） |
| B6 仅 stdio | DESIGN §4.2；TODO §2.1 |
| B7 `mcp` 元工具 | DESIGN §4.1 |
| C §18 十条 | DESIGN §18（拆分「已核验 / 仍需实测」）；TODO §2.1/§2.2 |
| C HTTP 客户端 | DESIGN §18.2 第 2 条；TODO §0.2 阻塞、§7（P5 传输层） |
| C 无 sqlite | DESIGN §8.1.1；TODO §0.2 阻塞 |
| C 无 fsync | DESIGN §8.2；TODO §0.2 阻塞、§6（P4） |
| D1 布局缺项 | DESIGN §8.1、§8.6；TODO §5（P3 存储） |
| D2 `request_id` | DESIGN §4.5；TODO §4（P2） |
| D3 `format_version` | DESIGN §8.1、§8.3；TODO §5（P3） |
| D4 版本映射 | DESIGN §17；TODO §1（阶段总览加列） |
| D5 `[!]` 预置 | TODO §0.2 |
| D6 文档落点 | TODO §17 |
| D7 P0 排序 | TODO §2「任务排序」 |
| D8 §15 示意标注 | DESIGN §15 |
| D9 点号语义 | DESIGN §4.1、§4.2；TODO §0 约束 2 |
