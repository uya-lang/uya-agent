# DESIGN.md — uya-agent 设计文档

uya-agent 是一个**纯 Uya 源码**实现的命令行编程 agent：给它一句话任务，它自己看文件、改文件、
跑命令，多轮 loop 直到给出结论。**不引入任何 C 代码、`@c_import` 或其它语言**，只依赖 Uya
语言与随编译器分发的标准库。

本文是**设计与实现文档**：解释系统**为什么长成现在这样** —— 分层、状态放在哪、每条不变量的
来历、每次踩坑的现场。目标是让一个「会用 Uya 但没见过本仓」的人（或 agent）能安全地动手改。

## 0. 三份文档的分工（别重复读）

| 文档 | 读者 | 回答什么 | 不回答什么 |
|---|---|---|---|
| [README.md](README.md) | 使用者 | 怎么装、怎么跑、有哪些选项与命令、退出码、能力一览 | 实现细节、为什么 |
| [CODING.md](CODING.md) | 改代码的人 | 目录/文件/命名约定、文件头模板、验收纪律、编译器的硬约束 | 系统怎么工作 |
| **DESIGN.md**（本文） | 接手的工程师 | 分层与数据流、每处状态与不变量、每条设计决策的**理由**、踩坑现场 | 用法表（去 README） |

配套事实：`src/` 按**域**分目录，一个文件一个职责；文件头 5 行（`本文件/不变量/依赖/命名`）
是**本地索引** —— 按 `CODING.md` §3 的「命名即索引」用前缀 `grep` 直接命中，不必读全仓。

## 1. 目标与非目标

### 1.1 目标

1. **纯 Uya**：所有实现都在 `src/*.uya`。用 `@c_import` 或写 C 都算违约。
2. **与 DSH 对齐**（DSH 是本项目对标的既有 agent）：直接读 `~/.dsh` 的配置与会话、工具用 DSH
   原名与同名参数、事件与状态词逐字对齐 —— 好在两者之间互换与对照实验。
3. **离线可验收**：`make selftest` 内置 mock LLM，不起网络、不要 key，就能跑完整 agent 循环
   并逐项断言（见 §19）。**「改完没跑就不算完」**（`CODING.md` §5）。
4. **可读性靠结构**：一个域一个目录、一个文件一个职责、一个前缀一个身份。改一处只需读一小块。

### 1.2 明确不做（非目标）

| 不做 | 为什么 |
|---|---|
| 多线程渲染（TUI 与 agent loop 分两条线程） | 机制成立（`libc.pthread` + `sys_tgkill` 唤醒），但工具链堆并发分配实测 8/8 崩（`double free detected in tcache 2`）、pthread 互斥不干净 ⇒ 选「单线程 + 泵点加密」（踩坑 47，见 §11） |
| 真抢占式中断 | 同上，只能是**协作式**：所有阻塞循环按 ≤50 ms 的粒度插泵点 |
| 代码语法高亮、图片在终端里渲染、鼠标拖选 | 纯 Uya 没有编码器/渲染器；末端体验交给终端自己（见 §15） |
| 改标准库 `lib/tls` | 链校验的缺陷在标准库侧，本项目**不改标准库**，改为在 agent 侧提供三档信任策略（§18） |
| 会话内落盘的 tool 输出 spill（DSH 有） | 只保留内存尾部；记为**已知偏离**（§6.5） |

## 2. 分层与依赖

### 2.1 域划分

| 域 | 装什么 | 判定问句 |
|---|---|---|
| `foundation/` | 零依赖底座：字节缓冲、JSON、YAML | 「它能依赖谁？」—— 只依赖 `libc`/`std` |
| `net/` | 传输与协议：HTTP、流式、SSE、LLM 协议、web | 「它说网络协议吗？」 |
| `term/` | 终端与界面：tty、markdown、转录显示、任务块 | 「它在画屏幕吗？」 |
| `term/tui/` | 全屏 TUI（按依赖序拆成 11 个文件） | 「它是 TUI 的哪一段？」 |
| `tools/` | agent 的工具实现：fs、shell、search、jobs、审批、沙箱 | 「它是模型能调用的一个工具吗？」 |
| `session/` | 会话与运行时：日志、DSH 配置、统计、进程采样、信号 | 「它是进程/会话的生命周期吗？」 |
| `agent/` | agent 主体：主循环、prompt、上下文、todo、plan、goal、子代理 | 「它决定 agent *怎么想*吗？」 |
| `vcs/` | git：只读跑 git、worktree | 「它跑 git 吗？」 |
| `diff/` | 写工具正文的行级 diff + `/diff` 显示层（5 个文件） | 「它是 diff 的哪一段？」 |
| `media/` | 图片附件、剪贴板 | 「它是二进制媒体吗？」 |
| `selftest/` | 自测轮 | 「它只在 `--selftest` 里跑吗？」 |

### 2.2 依赖方向

**依赖是单向的、分层的**。底座不认识上层；`foundation/bufx.uya` 是全仓被依赖最多的文件
（60 个文件用到它），它自己不依赖任何本仓文件。

```
                       ┌───────────── foundation/ ─────────────┐
                       │  bufx（字节，0 依赖）                  │
                       │   ↑        ↑            ↑             │
                       │ jsonx    yamlcfg      （所有域都用）   │
                       └───┬──────────┬──────────────────────┘
                           │          │
        ┌──────────────────┴───┐  ┌───┴──────────────┐
        │ net/                 │  │ session/         │
        │  httpc → httpstream  │  │  sigx session    │
        │   → sse → llm  webx  │  │  dshcfg dshsess  │
        └───────┬──────────────┘  │  inbox stats     │
                │                 │  procx modelx    │
                │                 └───────┬──────────┘
                │                         │
        ┌───────┴─────────┐   ┌───────────┴────────────┐
        │ term/           │   │ tools/                 │
        │  tty mdview     │   │  fsx shellx jobs       │
        │  tasks view     │   │  search perm sandboxx  │
        │  tui/ (11 文件) │   │  askuser               │
        └───────┬─────────┘   └───────────┬────────────┘
                │                         │
                │              ┌──────────┴─────────┐
                │              │ media/ vcs/ diff/  │
                │              └──────────┬─────────┘
                └───────────┬────────────┘
                            ▼
                     agent/（最上层：把上面全部装起来）
```

实测的**被依赖次数**（`export` 符号的跨文件引用计数，用于判断「改这个文件会波及多大范围」）：

| 文件 | 被多少文件引用 | 说明 |
|---|---|---|
| `foundation/bufx.uya` | 60 | 全仓底座；动它等于动全部 |
| `foundation/jsonx.uya` | 21 | 所有 JSON 组装/解析 |
| `term/tty.uya` | 20 | 显示列原语与行编辑 |
| `term/tui/style.uya` | 20 | `TuiRow`/`TuiSeg` 帧模型 |
| `agent/agent.uya` | 18 | 反向依赖：其它域回调它（泵点、`Config`、ds_home） |
| `term/tui/entry.uya` | 17 | 转录条目 |
| `session/session.uya` | 13 | 会话日志读写 |
| `term/tui/hook.uya` | 13 | `tui_poll_tick` 等统一入口 |

> 注意 `agent/agent.uya` 出现在被依赖侧（18 个文件）—— 这是**有意的反向接缝**：工具层与显示层
> 需要「泵一次界面」「拿 `Config`」「拿 agent home」，这些**回调**集中在 `agent.uya` 里导出，
> 于是底层不需要认识主循环，主循环却能驱动它们。改这些接缝签名要全仓 `grep`。

### 2.3 编译器带来的三条硬约束（设计被它们塑形）

这三条**不是风格偏好**，是本仓实测出来的编译期事实（详见 `CODING.md` §1.2.1 与 §6）：

| 约束 | 症状 | 对设计的塑造 |
|---|---|---|
| **显式输入文件数上限 64**（uya 0.10.1） | 第 65 个文件开始报「**收集模块依赖失败: <编译器路径>**」，报错完全指不到根因 | `src/` 一片不能无限拆；当前 62 个构建文件，**加文件前先数** `make -s print-src \| wc -w` |
| **文件顺序有意义** | `if c { CONST_A } else { CONST_B }` 里常量所在文件排在后面时，报「期望类型 u8，推断为 void」 | `SRC` 里 `term/tui/` 与 `diff/` 两块是**按依赖序**排的，不是字母序（实测：把 `style.uya` 排到使用者之后，三处当场红） |
| **函数表是定长表**（`FUNCTION_TABLE_SIZE`，无开关） | 报「函数表容量不足，请增大 FUNCTION_TABLE_SIZE」，**报错点落在标准库里** | 贡献函数的改动一律按**净增 0** 处理；优先合并语义同族函数、就地展开只有一两处调用的转发、删零调用死函数；且**必须清缓存重编**才看得见（增量编译被缓存掩盖） |

`uya 0.10.3` 解除了前两条（实测 +3000 个空函数、70 个输入文件都通过），但它目前**编不过本仓**
（另有一处 codegen 回归：`lib/std/thread.uya` 的 `thread_worker_set_nonblock` 定义没被发射而调用
点还在，在**未改动的 main** 检出上同样复现）⇒ 在它修好之前，上面三条继续按有效处理。

### 2.4 跨目录的合并命名空间（改代码前必须先懂这条）

Uya 是「目录即模块」，但本仓实测：**跨目录是合并命名空间**。

* 把文件搬进子目录**不需要**改源代码里的 `export` / `use`（实测 `git mv` 后直接编过）；
* 所以「按域分目录」是**纯搬移**，不是重构 —— 两次大拆分（`diff/` 152 个声明、
  `term/tui/` 721 个声明）都是逐声明**代码逐行相同**地验的，全仓 69226 行代码的多重集合与拆分前
  **完全一致**；
* 于是**名字会撞**：`Conn` 撞 `std.http.types.Conn`、`now_ms` 撞 `std.time.now_ms`、
  `MAX_NESTING`/`ParseState` 让 `std.yaml` 与 `std.json` 无法共存（§5.1 的 YAML 自实现就是这个原因）。

两条纪律由此而来：

1. **不许在仓内写 `use <本地域>.xxx;`** —— 本仓 62 个构建文件之间至今**零本地 `use`**，全靠合并
   命名空间 + 前缀区分。加了本地 `use` 反而把「搬文件」变成「改代码」，并可能引入循环依赖。
2. **一个域/文件一个前缀**，前缀就是「命名空间」（`buf_`/`jwx_`/`yt_`/`gd_`/`tui_`/`fs_`/`sh_`/
   `sess_`/`gx_`/`wt_`/`deleg_`/`wf_`/`goal_`/`mdv_`/`llm_`…）。唯一的例外是 `diff/` 的 5 个文件
   共用 `gd_` —— 它们是同一个历史模块的内部拆分，对外是一个整体。

## 3. 启动与主循环

这一节回答：**一次运行从进程启动到第一个请求之间发生了什么，之后每一轮又按什么顺序转。**
改主循环是这份仓里最容易出事的地方，所以顺序与「为什么必须在这一步」都写清。

### 3.1 配置来源链与优先级

三个来源，**优先级从低到高**：DSH 设置文件 → 环境变量 → 命令行。

| 顺序 | 阶段 | 做什么 | 为什么必须在这一步 |
|---|---|---|---|
| 1 | **预扫 4 个 flag** | `--dsh-home` / `--dsh-root` / `--no-dsh-config` / `--strict-dsh-config` | 它们决定**「去哪儿读设置、读不读」**。放到主循环再解析就**静默失效**了 —— 设置早就读完并覆盖了一轮配置 |
| 2 | 读 DSH 设置 | `dsh_cfg_load(dsh_home, cwd, &dsh)`；`--strict-dsh-config` 时读不到直接 `AGENT_USAGE` 退出 | 设置要给「模型路线 / 凭据 / 权限 / 技能根」打底 |
| 3 | 环境变量默认 | `UYA_AGENT_*` 一族（见 README 的环境变量表） | 覆盖设置文件 |
| 4 | CLI 解析 | 长选项 + 位置参数拼成 `task_words` | 最高优先级；`--print-config` 就是把这四步之后的**结果与来源**一起印出来 |

**设计要点**：`--print-config` 存在的唯一目的是**让「配置到底生效了没有」可证**。这类 CLI 最
常见的故障不是崩溃，而是「我以为它生效了」—— 所以每个取值都带来源标签（cli / env /
dsh-settings / default）。`--permission` 非法取值必须**报错退出**，理由同源：静默按默认跑会让
人以为模式生效了（而默认是**全权**）。

### 3.2 启动阶段序列

```
main()                                    src/agent/agent.uya:9884
 ├─ 预扫 4 flag → dsh_cfg_load → agent_apply_dsh → CLI 解析
 ├─ agent_workspace_canon()               工作区规范化（chdir + getcwd）
 ├─ 早退分支：--list-sessions / --list-dsh-sessions / --print-config /
 │            --dry-run / --selftest / --probe / --tui-demo / --help
 ├─ agent_models_ensure() → agent_effort_recheck()   模型目录（P37）
 ├─ 形态选择
 │   ├─ 有任务词 → run_once() → agent_run(cfg)          一次性
 │   ├─ 无任务词 → agent_run_tui(cfg)                    全屏 TUI
 │   │             └─ 终端 < 32×8 或启动失败 → agent_run_interactive(cfg)  滚动模式
 │   └─ TUI 起来后 tty_sink_on = true：此后所有显示字节进转录条目
 └─ 回合前准备（下面 3.3）
```

**回合前准备**（`fsctx_init` 一族，全部幂等）：

| 调用 | 建什么 | 状态全局 |
|---|---|---|
| `fsctx_init` | 权限模式 → 沙箱探测（`san_probe`，fail closed） | `g_fsctx` / `g_fsobs` |
| `jobs_init` | 后台任务表 | `g_jobs` |
| `deleg_init` | 子代理槽位表（4 个） | `g_deleg` |
| `view_init` / `diffx_init` | 显示层与 diff 层 | — |
| `st_reset` | 会话统计折叠 | `Stats` |
| `agent_session_scoped_reset` | **只清** todo 与标题的会话标志 | `g_todos` / `g_title_*` |
| `agent_history_begin` | 恢复则导入/读父历史/开会话；否则开新会话 | `g_sess` / `h` |

`agent_history_begin` 内部（新会话路径，`agent_hist_init`）的顺序**不能换**：
`agent_worktree_begin`（可能要建 worktree 并 chdir）→ `agent_system_prompt`（求值 `{{cwd}}`、
读 AGENTS.md、扫技能目录）→ push system 消息 → `agent_inject_context` → `agent_log_delegation`
（子代理记 `subagent/start`）→ push 首条 user 消息。

> **为什么 worktree 必须在最前**：`agent_system_prompt` 里的 `{{cwd}}`、AGENTS.md 的发现、
> 技能目录的 5 个根**全部按当前工作目录求值**。worktree 会 chdir，晚了整个 prompt 就是错的。

### 3.3 状态全局表

本仓**没有 DI 容器**，运行期状态就是一批模块级全局。改主循环前先查这张表 ——
**「这个状态属于谁的生命周期」决定了它该在哪里复位**。

| 全局 | 类型 | 生命周期 | 用途 |
|---|---|---|---|
| `g_sess` | `SessionLog` | 会话 | 当前会话日志（读写都与它相关，§8） |
| `g_home` / `g_dsh_home` | `Buf` | 进程 | agent home / `$DSH_HOME` |
| `g_turn` | `i64` | 会话 | 回合号（`turn/start` 用） |
| `g_jobs` | `JobTable` | 进程 | 后台任务（§6.5） |
| `g_deleg` | `DelegTable` | 进程 | 子代理 4 槽（§9） |
| `g_last_prompt_tokens` | `i64` | 回合 | 上一次 `usage_in + usage_cache_read` —— **压缩压力的口径**（§5.3） |
| `g_compact_enabled` | `bool` | 进程 | `--no-compact` |
| `g_skills` | `SkillSet` | 进程（懒扫描） | 技能目录（§5.1） |
| `g_texts` / `g_plan` / `g_todos` / `g_knobs` | 提示词与清单 | 会话 | system prompt 分节与运行时状态段 |
| `g_plan_snap` | 快照 | 回合 | **模型已被告知**的 plan 状态（对比它才知道要不要补推） |
| `g_ws_snap` | 快照 | 回合 | 同上，工作区 |
| `g_fsctx` / `g_fsobs` | `FsCtx`/`FsObsTable` | 会话 | 工作区 + 已读版本观测（§6.3） |
| `g_exec` | `ExecState` | 回合 | 执行期两条纪律（§5.5） |
| `g_pending_imgs` | `ImgList` | 回合 | 待发图片（**批次**语义：一次请求带走一批） |
| `g_watch` + `g_watch_*` | 跟随态 | 回合/进程 | `/watch`（§11.6）；**进程状态，`--resume` 不回填** |
| `g_mc` | `McTable` | 进程 | 模型目录（§3.1 第 3.5 步） |
| `g_title_*` | 标题 | 会话 | 终端标题栈 / 钉住 / 自动起标题 revision |
| `g_interactive` | `bool` | 进程 | 交互模式（决定泵点与提示词形态） |
| `g_pump_cfg` / `g_pump_hist` | 泵点上下文 | 回合 | 让**阻塞循环内部**的泵点也能派发命令 |

> **`g_pump_cfg/g_pump_hist` 为什么存在**：工具执行、DNS、TLS 握手这些**阻塞循环**里也要泵界面，
> 而它们手里没有 `Config`/`History`。`agent_pump_ctx_begin` 在回合开始时登记一份，泵点就能
> 「当场派发只读命令并当场画一帧」（P30/P31）—— 这是「运行中的命令不再等 step 边界」的实现基础。

### 3.4 回合循环

`agent_turn_loop` →（每回合）`agent_turn_loop_inner`，`h` 是**唯一的历史**（回合之间保留）。
step 循环 `while cfg.max_steps <= 0 || step < cfg.max_steps`：

| # | 检查/动作 | 为什么必须在这里 |
|---|---|---|
| a | **收工预算**：`grace_steps > 0 && step > accept_step + grace_steps` → 提前收工 | 锚点是「验收命令在**改动之后**首次跑绿」那一步（§5.5） |
| b | `tui_abort_state()` 中断检查 | 用户按下 esc/ctrl+d 后要的是**马上**回输入态，不是等一个注定被掐断的来回网络（真机 1–2 秒） |
| c | `agent_claim_steer` | DSH 的 steer 语义：**回合运行期间**用户敲的文本投到收件箱，在 step 边界领取，作为**普通 user 消息**进入下一请求（不加任何包装文案） |
| d | `agent_tui_poll_pending_cmd` | 运行中在命令面板选中的命令在这里落地（以前只有主循环会取，而主循环整个回合都不跑 ⇒ 屏幕「没反应」） |
| e | `agent_tui_step_boundary_cmd` | `/compact` 这类**只能排 step 边界**的命令的落点 |
| f | `agent_maybe_compact(..., false)` | DSH 也是在 request derivation **之前**测压 |
| g | `agent_plan_snapshot_sync` | 变了就补推一份 plan 快照。**放在压缩之后**：别刚推就被折进 checkpoint |
| h | `agent_ws_snapshot_sync` | 工作区变了要补推 —— 运行时上下文里那句 `Current workspace` 与新工作区的 AGENTS.md 都要跟上 |
| i | `agent_bound_step_start` | step 边界记账（`step/start` 事件） |
| j | **低思考执行态切换** | §5.5；`g_exec.on`/`off` 保证只切一次、档位不合法就不每一步白试 |
| k | 建 `req`/`url` → 内层 `while !sent` 循环（见下） | 请求重发与协议协商都在这里 |
| l | `agent_bound_step_end` | step 边界记账（`step/end`） |

**内层 `while !sent` 循环**（两个「同一步重发」共用，形状刻意对齐）：

```
api_style_now(cfg)                 → 当前协议
api_url_into(cfg, style, &url)     → 每轮**重算** url/req
build_model_request(cfg, h, &req, style)
agent_step_stream / agent_step_plain
  ├─ api_negotiate(cfg, style, status)  404/405/501 → continue（换协议重发，每进程一次）
  └─ rc == STEP_RETRY → continue（退化响应重发，每步一次）
```

> **为什么 `url`/`req` 要在循环**内**重算**：重发必须与上一次**逐字节相同**。
> §5.4 的退化响应自测就钉这一条（把重发请求体改成不相等 → verdict 249 当场红）。
> 两个重发**都不推进 step、不动历史**，所以「同一份历史重新拼出来」必然一致。

### 3.5 一步的收尾 `agent_finish_step`

| 步骤 | 做什么 |
|---|---|
| 1 | 记 `g_last_prompt_tokens`（= `usage_in + usage_cache_read`），打 usage 行 |
| 2 | `LLM_FINISH_ERROR` → `AGENT_PROTO` |
| 3 | **退化响应判定**（§5.4）：`finish` 不是 error / 不是 max-tokens，而 `content` 与工具调用**都是 0** → `agent_note_degenerate` → 决定 `STEP_RETRY` |
| 4 | `agent_bound_assistant_message`（写 `assistant/message`；**退化那一步不写**） |
| 5 | max-tokens 截断 → **丢弃所有 `tool_calls`**（半截参数没法用，留着只会让协议错） |
| 6 | 有 `ncalls > 0` → 写历史 + 派发（见下） |
| 7 | 无 `tool_calls` 且有正文 = 最终答复 → `AGENT_OK`；两者皆无 → `AGENT_PROTO` |

第 6 步的两种写历史方式：

| 模式 | assistant 消息 | 工具结果 |
|---|---|---|
| **严格协议**（默认） | `ROLE_ASSISTANT_CALLS`，`extra` = `tool_calls` 原文 | 每条结果**一条** `role:"tool"` 消息，带 `tool_call_id` |
| `--compat-fold` | 普通 assistant 文本 | 工具结果**折叠成一条 user 消息**（老端点兼容） |

**原子组不变量**：历史里 `assistant(tool_calls)` + 它触发的 **N 条 tool 结果**是一个**不可分割
的组**。派发失败要**整组回滚**（`hist_truncate_to`）—— 只回滚一半会让历史里出现「有
`tool_calls` 但没有对应 tool 结果」的悬空引用，下一轮请求直接被网关拒。

### 3.6 历史模型

```
struct Msg     { role: u8, kind: u8, text: &byte, text_len, extra: &byte, extra_len }   agent.uya:676
struct History { items: &Msg, len, cap, bytes }                                          agent.uya:688
```

`Msg` 用的是**裸指针 + 长度**（不是 `Buf`）：历史里存的是构请求时拼出来的字节，
`bytes` 单独记总字节数供 `request_bytes_needed` 算缓冲。`kind` 复用 `CMP_KIND_TOOL` /
`CMP_KIND_BASH`（决定构请求时用哪条剪枝规则，§5.3）。

| 不变量 | 破坏后果 |
|---|---|
| **任何 `&Msg` 不许跨 `hist_push*` / `hist_reserve` 使用** | 堆数组按需翻倍 realloc，旧指针**搬家**了，再解引用就是读已释放内存 |
| 单条消息上限 `MSG_CONTENT_MAX = 200000`（与 `term/tui/screen.uya`、`term/tui/keys.uya` 的 `TUI_IN_MAX` **同值，改一处要改两处**） | 超限先按 DSH 口径剪枝缩，再头尾截断（head 预算 = `max - mark - 16384`，`HIST_TRUNC_MARK`） |
| 历史**不限条数** | 条数由上下文压力管，不由历史管（§5.3） |

### 3.7 三种运行形态与退出码

| 形态 | 入口 | 说明 |
|---|---|---|
| 一次性 | `run_once` → `agent_run` | 有任务词就走这条 |
| REPL（滚动） | `agent_run_interactive` | 终端 < 32×8、或 TUI 启动失败时**自动退回** |
| 全屏 TUI | `agent_run_tui` → `agent_run_tui_body` | §11；起来后 `tty_sink_on = true` |

退出码（`AGENT_*`）：`0` 成功 · `1` 用法/配置 · `2` 传输（DNS/TCP/TLS/超时）· `3` 模型或协议 ·
`4` 工具/工作区。内部码：`STEP_CONTINUE = 100`（还有下一步）、`STEP_RETRY = 101`（同一步重发）、
`AGENT_INTERRUPTED = 130`。

> **「步数熔断」为什么只在显式给了 `--max-steps N` 时才体现为退出码 3**：默认
> `--max-steps 0` = **不限**（对齐 DSH：它没有步数上限）。只有调用方**主动**设了上限，
> 「撞上限」才算一种失败；不然「跑到模型给出最终答案」是**正常**收尾。

---

## 4. 协议层

这一节回答：**一次模型请求从字节到 `ChatOut` 怎么走**，以及两种线上协议怎么被归一成一份结果。

### 4.1 分层

| 层 | 文件 | 输入 → 输出 | 边界 |
|---|---|---|---|
| 字节 | `foundation/bufx.uya` | 字节操作 | 不认识任何协议 |
| JSON | `foundation/jsonx.uya` | `Buf` ↔ `JsonValue` | **自带 RFC 8259 转义**（§16 踩坑 27） |
| 传输 | `net/httpc.uya` | URL/headers/body → 连接 | 明文 + TLS 两条路同一接口 |
| 流式 | `net/httpstream.uya` | 头部 + 增量体字节 | 三种体编码状态机；**复用 httpc 的私有函数** |
| 分帧 | `net/sse.uya` | 体字节 → 事件 | 不读网络，调用方喂 |
| 协议 | `net/llm.uya` | 事件 → `ChatOut` | 两种协议归一；上层不知道协议 |

`httpstream` 直接调用 `httpc` 的**私有**函数（`url_parse` / `tcp_connect` / `tls_open` /
`build_request` / `conn_read`）—— 这是合并命名空间（§2.4）允许的，也是**刻意**的：
连接建立只有一份实现，流式与非流式不会漂移。

### 4.2 HTTP 客户端（`net/httpc.uya`）

**为什么不用现成的**（三条，都是实测）：

1. `std.http` 的请求头构造器**固定只发** Host/Connection/Content-Type/Content-Length，
   **加不了 `Authorization`** —— 而这是 LLM 网关的硬要求；
2. `tls.https` 只导出 GET，且单次只读一个 4096 字节 record，**装不下 LLM 的响应**；
3. `lib/tls` 的链校验在真实站点上基本不可用（§18），所以要自己接 leaf 指纹钉扎。

**信任策略**：三档 `chain`（默认）/ `pin` / `none`，详见 §18。leaf SHA-256 从
`HandshakeCtx.server_flight_msg` **自己解析**（不依赖 `cert_parse` 的 RSA 前提），实测与
`openssl s_client | openssl x509 -outform DER | sha256sum` 完全一致。

**TLS 噪声静音**：`lib/tls` 把握手全过程写到 fd 2（`[HS] ...`），发请求期间要把 fd 2 指向
`/dev/null`（dup2 往返）。**副作用**：显示层也被一起静音了 —— 所以 `tls_noise_mute` 把
`dup(2)` 存进 `g_err_fd`，显示层一律走 `err_fd()` 写（§16 踩坑 21/30）。

**明文与 TLS 同一条上层路径**，调用方只给 URL，不需要分支。

### 4.3 流式响应：三种体编码

`hc_open` **只读到响应头结束**就返回，body 由 `hc_fill` 按需增量解码 —— SSE 才能在字节到达时
立刻被解析并打印（这是「流式」的全部意义）。

| 编码 | 状态机 | 结束条件 |
|---|---|---|
| `chunked` | 长度行 → DATA → CRLF →（循环）→ 0 长度 → TRAILER | 空行结束 trailer |
| `content-length` | 按长度取 | 取满 |
| 读到连接关闭 | 有多少取多少 | 对端关闭 |

`hc_fill` 返回值语义（调用方靠它决定继续 poll 还是收工）：

| 返回 | 含义 |
|---|---|
| `1` | 本次**新增了可读体字节**（`st.dec` 变长） |
| `2` | 读到网络数据但**还没解出体字节**（继续 poll） |
| `0` | 体已结束（且无新字节） |

三条不变的规矩：

* **每个 DATA 段之后 `break`** ——「先把手上的数据交出去，别一次吃完整条流」。不这么做，一个
  大响应会把流式的全部好处吃掉（界面上是一段段跳而不是连续滚）；
* `dec.len > max_body` → 立刻 `HcTooLarge`（响应体上限，默认 256 KiB）；
* 循环有 `guard < 8192` 上限防畸形流死循环。

**P31 的教训**：等响应头那段以前是**纯阻塞** `conn_read` —— 头没到之前一个泵点都没有，
「请求刚发出、模型还没吐第一个字」整段里 `/status`、esc、ctrl+c 全部石沉大海（**真终端实测
4879 ms 才出浮层**，上限还是 `timeout_ms` = 默认 120 s）。现在改成 poll(≤50 ms) + 泵点，
超时按**墙上时间**判（比原来更严：原来每帧各有一次 timeout，慢滴流可以无限拖）。
非 TUI 保持阻塞读。

### 4.4 SSE 分帧（`net/sse.uya`）

在「已解码体字节」之上做事件切分。规则逐条（都有对应的自测断言）：

| 规则 | 说明 |
|---|---|
| 字段行 | `name: value`；`data:` 之后剥掉**一个**前导空格；字段名 `data` 按 **4 字符精确比对** |
| 多行 data | 用 `"\n"` 连接 |
| dispatch | **空行** dispatch 一个事件 |
| 注释 | 以 `:` 开头的行是注释（计数后忽略） |
| 非 data 字段 | 只有非 data 字段的事件**不 dispatch** |
| 未终结事件 | 流在未终结的事件处结束**不冲刷**半截事件（与 DSH 用的 `eventsource-parser` 一致） |
| CRLF | 行尾 `\r` 被剥离 |

`sse_next` 的返回码是**契约**：

| 返回 | 含义 |
|---|---|
| `1` | 取到一个事件（payload 写入 `out`，`out` 先被 reset） |
| `0` | 手上数据不够 —— 调用方应先 `hc_fill()` |
| `-1` | 流已结束且没有更多事件 |

**`SSE_LINE_MAX = 262144`**（256 KiB）：单行上限，防畸形流把内存吃光（正常 SSE 行远小于此）。
「消费总是在把数据拷进 `acc` **之后**」—— 保证半截事件的状态只活在 `acc` 里，它就是这个上限
约束的对象。

### 4.5 两种协议归一成 `ChatOut`

`ChatOut` 是协议层的**唯一出口**：一条 assistant 消息 + usage + finish 语义。上层的
`agent_finish_step` / 历史 / 会话日志**完全不必知道用的是哪种协议**。

| 字段组 | 字段 |
|---|---|
| 正文 | `content` / `reasoning` |
| 工具 | `calls[16]` / `ncalls`（`LlmCall{index, id, name, args}`） |
| 收尾 | `finish` / `have_finish` / `bad_finish` / `err_text` / `saw_done` |
| usage | `usage_in` / `usage_out` / `usage_cache_read` / `usage_cache_write` / `usage_reasoning` |
| 观测 | `first_token_ms` / `printed_chars` / `events` |

`finish` 取值：`LLM_FINISH_NONE/STOP/TOOL_CALLS/MAX_TOKENS/ERROR`。
`LLM_MAX_CALLS = 16` 是 `calls` 的固定容量，槽位用尽 `llm_slot` 返回 -1。

#### 4.5.1 chat/completions 侧

**增量累积 `llm_apply_delta`**：

* `content`：`sv_unescape` 后**追加**进 `o.content`；长度增长才算首 token；要打印时**先**
  `view_think_end()`（P16：正文前的思考块到此结算，成品思考行要落在正文**之前**）；
* `reasoning_content`：追加进 `o.reasoning`。P24 起**思考 delta 也算首 token**；
  `view_think_live` 的常驻实时行默认开，**与 `--show-reasoning` 无关**；
* `tool_calls`：数组非空时**先** `view_think_end()`（工具行必须排在思考成品行之后）。
  每个元素取 `index`（缺失时用数组下标兜底，同帧多调用），`llm_slot` 按 index 找/建槽，
  然后 `id` / `function.name` / `function.arguments` 各自 `sv_unescape` 后**追加**。

> **拼接正确性论证**（写进注释了）：每个 `arguments` 片段都是**合法 JSON 字符串**，
> 所以「逐片段解码后拼接」与「整体解码」**等价**。这就是为什么可以边收边拼。

**`got_payload` 门闩（P24）**：网关有时先发一帧只带 `index`/空串的**元数据**，那不算增量、
不能当「生成已开始」—— 否则首 token 打点会提前，tok/s 直接虚高。

**`llm_apply_finish` 的映射**：

| 上游值 | 映射 |
|---|---|
| `stop` | `STOP` |
| `tool_calls` | `TOOL_CALLS` |
| `length` | `MAX_TOKENS` |
| 其它（`content_filter` / `insufficient_system_resource`…） | **一律当错误**，原文存进 `bad_finish` |

**`llm_apply_usage` 的两个陷阱**：

1. 缓存读数**只在本帧给了明细时更新** —— 有些网关尾随的 usage-only 帧只带
   prompt/completion，无条件覆盖会把已拿到的缓存命中**清成 0**；
2. `o.usage_in = prompt_tokens - cached`：**DeepSeek 的 `prompt_tokens` 含缓存命中**，
   所以这个字段的语义是「**非缓存输入**」，不是原始 prompt_tokens。

#### 4.5.2 responses 侧

事件表按作用分组：

| 作用 | 事件 | 处理 |
|---|---|---|
| 正文 | `response.output_text.delta` / `response.refusal.delta` | 追加正文 |
| 思考 | `response.reasoning_summary_text.delta` / `response.reasoning_text.delta` | 追加思考；`reasoning_summary_part.done` 追加 `"\n\n"` 分段 |
| 工具参数 | `response.function_call_arguments.delta` | **没有 `output_index` 就没法定位**（规范里一定有），靠 `output_item.done` 兜底 |
| 工具参数完成 | `response.function_call_arguments.done` | 给的是**完整 JSON 文本**：若累积值是它的前缀就只补差值，否则**保留已累积的**（别把算好的参数弄坏） |
| 工具项 | `response.output_item.added\|done` | `function_call`/`custom_tool_call` 时优先按 `output_index` 建槽，否则按 `call_id` 反查 |
| 终局 | `response.completed\|incomplete\|failed` | `saw_done = true`，结束流 |
| 错误 | `error` | `code: message` 拼进 `err_text`，`finish = ERROR` |

两处**兜底**（都是真机遇到的形状差异）：

* 有些网关把 `/v1/responses` 的流**按 chat 形状回**（`choices[].delta`）—— 检测到 `choices`
  就转交 chat 解析器；
* 有些网关**只发 `created` + `completed`**，工具调用只出现在终局里 —— 所以终局要回填
  `response.output[]`（先按 `call_id` 找槽、没有才新建）；`message` 回填正文用
  `only_if_empty = true`。

**`call_id` 只留 `'|'` 前那段**：DSH 的形状是 `"call_x|fc_y"`，我们只回放 `call_id`。

**`llm_resp_usage`**：`input_tokens` **含缓存与缓存写入，两类都要减掉**（与 pi-ai 同口径）；
`tin < 0` 时钳到 0。

**`llm_resp_map_status`**（status → finish，对齐 pi-ai 的 `mapStopReason`）：

| status | 映射 |
|---|---|
| `completed` | `STOP` |
| `incomplete` + `max_output_tokens` | `MAX_TOKENS` |
| `incomplete` + 其它原因 | `ERROR`，`err_text = "incomplete: <reason>"`（无 reason 时 `"incomplete (no reason given)"`） |
| `failed` / `cancelled` | `ERROR`，无明细时至少留下状态名 + `" (no error details)"` |
| `in_progress` / `queued` / 缺 status | **按正常收尾**（防御）；有工具调用时由 `llm_resp_finalize` 升级为 `TOOL_CALLS` |

**缺终局事件 = 流被截断**（responses 协议本身不发 `[DONE]`）；少数代理仍发 `[DONE]`，也当正常收尾。

#### 4.5.3 arena 生命周期的硬不变量

```uya
// 每个事件 payload 先复制进本模块自己的 arena（逐事件 reset），
// 解析后立刻 sv_unescape 进 ChatOut 的堆缓冲；绝不让 JsonStrView 活过下一次 arena_reset。
```

**为什么**：`std.json` 的 `parse_string` 是**零拷贝**，`JsonStrView` 指向原始缓冲区**且未反转义**。
`LLM_EVENT_ARENA = 262144` 是每事件 parse 的 arena。平台里凡是想图省事把 view 直接留下，
下一次 `arena_reset` 之后读到的就是别人的数据（或未初始化内存）。所以规则只有一条：
**view 的生命周期 = 本事件**，要留下就 `sv_unescape` 进 `ChatOut` 的堆缓冲。

### 4.6 首 token 打点

判据：**本帧出现任意一种非空增量** —— 正文、思考、工具参数都算；空串 delta / `delta:{}` /
usage-only 帧**不算**。

> **为什么改过**：P21 之前只认**正文** delta，于是推理模型与工具型回合**常常打不到点**；
> 偶尔打到时 tok/s 爆表（实测 60087 tok / 8990 ms = **6684 tok/s**，真值约 157）—— 因为分母
> 只覆盖最后几个百分点、分子却是**全部**输出 token（含思考）。

**非流式解析与 responses 终局回填仍然不打点**：那两处拿到的是整段正文，打点会把 TTFT
记成整段请求时间（DSH 也只认 chunk 边界）。

### 4.7 读流总循环与泵点（`llm_stream_style`）

```
malloc(LLM_EVENT_ARENA) + arena_init
 → hc_open
 → status != 200 ⇒ 不当事件流解析：把体前 LLM_ERR_HEAD 字节收进 err_text，直接返回状态码
 → 循环：
     先把手上的**完整事件**全部 sse_next 处理掉
     没有完整事件再读一段
     交互模式下每轮先 llm_pump_input，用 hc_fill_wait(&st, 50) 代替阻塞 hc_fill
 → 收尾：!saw_done && finish != ERROR ⇒ error.LlmStreamClosed（对齐 DSH 的 STREAM_CLOSED）
```

**交互模式下 `Ctrl-C` / `Esc` / `EOF` 都立刻返回 `LlmInterrupted`。** EOF 这条是 P44 补的：
以前它被吞掉，界面还在哗哗地流，看着像退不出。

**`llm_pump_input` 的一条纪律**：**后台请求（自动起标题）一个字节的键都不许读** ——
它不是用户发起的，用户不知道它在飞；一旦读键，那几秒敲的字会被半路取走（`/` 进了我们的缓冲、
`status` 还留在终端，之后拼成 `//status`）。只泵「别让界面冻住」那一半，键原样留给主循环。

### 4.8 协议协商

`--api=` 是**三态**，不是布尔：

| 取值 | 行为 |
|---|---|
| 不写（**未声明**） | 先打 `/responses`；只有 **404/405/501** 才回退 `chat/completions`，**每进程一次**，在**同一步**重发 |
| `openai-responses` | 显式，不回退 |
| `openai-completions` | 显式，不回退 |

> **为什么只有 404/405/501 回退**：这三个码的语义是「**这个端点不存在**」。其它 4xx 是请求
> 内容问题 —— 换协议重发只会掩盖真正的错误。

`api_style_now` / `api_url_into` / `api_negotiate` / `api_lock` 四个函数实现这条链。

### 4.9 错误分层

| 层 | 错误 | 收口 |
|---|---|---|
| 网络/TLS | `Hc*` 一族 | 退出码 `2`（传输） |
| 坏 payload | `LlmMalformed` + `err_text` 头部（`LLM_ERR_HEAD = 240` 字节） | 退出码 `3` |
| 流截断 | `LlmStreamClosed` | 退出码 `3` |
| 上游 finish 异常 | `bad_finish` 原文 + `finish = ERROR` | 退出码 `3` |
| 用户中断 | `LlmInterrupted` / `AGENT_INTERRUPTED` | `130` |

**P54 的推论**：「上游正常收尾却什么都没给」与「上游报错」必须在日志里**长得不一样** ——
以前日志里只剩一条 `content=""` 的 assistant 消息，两者事后无法区分（§5.4 就是为此加的）。

## 5. 提示词与上下文管理

这一节回答：**模型每一轮到底看到什么**（system prompt 怎么拼、运行时上下文怎么更新），
以及**上下文装不下时怎么处理**（剪枝与压缩）。

### 5.1 system prompt 分节装配

对齐 DSH 的 `renderPrompt`。规则四条（`src/agent/prompt.uya:4-8`）：

1. 分节按 **order 升序**；
2. 渲染后**为空**的节**丢弃**；
3. 节之间用 `"\n\n"` 连接；
4. 最终**只有一条** system 消息。

变量替换只认 `{{model}}` 与 `{{cwd}}`，而且**只替换完整变量组、替换结果不再二次扫描**
（防止内容里的 `{{` 被反复展开）。

| order | 节 | 来源 | 何时出现 |
|---|---|---|---|
| 0 | persona | DSH preset（`agent.cordis.yml` 的 persona 行）；读不到用 DSH 标准 preset 的内置默认值（逐字） | 总是 |
| 50 | plan 策略 | preset 的 `plan-mode.section`，否则内置 | **仅 plan 模式激活时** |
| 100–106 | 工具引导（`SEC_READ`/`SEC_WRITE`/`SEC_EDIT`/`SEC_GLOB`/`SEC_GREP`/`SEC_BASH`/`SEC_JOBS`） | 本仓常量；read/bash 两条与 DSH 原文一致，其余为等价精简表述 | `SEC_BASH`/`SEC_JOBS` **仅 `allow_shell` 时** |
| 107 | 收工纪律（`SEC_FINISH`） | 本仓常量（DSH 没有） | 总是 |

**persona 默认文案**（`prompt.uya:18`）：
`"You are a coding agent powered by the {{model}} model. Your working directory is {{cwd}}."`

**`SEC_FINISH` 的来历**（P44 + P55）：它不是「礼貌建议」，是针对**实测出来的固定浪费**写的，
而且措辞刻意限定在**可判定**的情形：

| 三句纪律 | 实测证据 |
|---|---|
| 读到 `(End of file - total N lines)` 就别再读一遍 | 整份已读到的文件被重读 |
| 验收命令通过后**不得再跑**、也**不得另造**一条验收 | 同一条 `make build` 在一回合里跑了**三遍** |
| 与本次改动无关的**既有失败**：记一行就走 | 一条本来就红的 selftest 吃掉了 **6 步** |
| 方案一次定下并外化（写进 todo），不要在推理里一步步重列 | 50 个文件的映射在推理里被重列了 **8 步** |

这三句都由 `--selftest` 的**字符串钉子**守着（verdict 79/80/81），与 P44 那三句同一个形状 ——
**改了措辞就会红**，这是有意的：提示词是行为的一部分。

**AGENTS.md / CLAUDE.md**（`agent/instr.uya`）：从工作区向上发现，按 **65536 字节预算**截断。
技能目录（`agent/skill.uya`）的 5 个发现根见下，**没有可模型调用的技能时整节不注入**
（`skills_catalog` 返回 false）。

### 5.2 运行时上下文

运行时上下文**不是 system 的一部分**，而是一条**独立的 user 消息**（对齐 DSH 的
`joinContextSections`），开头固定一句：

```
Current runtime context. This snapshot supersedes earlier runtime-context snapshots.
```

含三节（`prompt_runtime_context`）：

| 节 | 内容 | 为什么要有 |
|---|---|---|
| `file-policy` | 三级访问模式的说明句 + **按沙箱实际可用性收尾** | 模型得知道自己的写权限与沙箱是否真的生效（「沙箱不可用」与「不需要沙箱」是两件事） |
| `workspace` | `Current workspace: <path> (…)` | 工作区是**当前会话**的状态、运行中会被切（`workspace` 工具 / `/workspace`）—— 模型每轮都要一眼看到自己在哪 |
| `plan` | plan 模式激活时的「不许改文件，先出计划」 | 与 §7.4 的写闸门配对（提示 + 硬拒） |

**「supersedes earlier snapshots」这句话是有功能的**：工作区 / 权限 / plan 都可能在会话中途变，
历史里会堆积多份快照。模型需要知道**以最后一份为准**，否则会按已经失效的工作区去解析路径。

`body` 为空时输出
`"Current runtime context: none. Earlier runtime-context snapshots no longer apply."`
—— 空节丢弃的规则同样适用于这里。

**补推机制**：`agent_ws_snapshot_sync` / `agent_plan_snapshot_sync` 在**每个 step 边界**比较
「模型已被告知的」快照（`g_ws_snap` / `g_plan_snap`）与当前值，变了才补推一条新的运行时上下文。
plan 的补推**放在压缩之后**：别刚推就被折进 checkpoint。

### 5.3 上下文管理的两件事

#### 5.3.1 tool 结果剪枝（只在构请求层）

| 旋钮 | 值 | 含义 |
|---|---|---|
| `cmp_prune_threshold` | `8192` | 触发阈值（**码点**，不是字节） |
| `cmp_prune_head` | `4096` | 保留头部码点数 |
| `cmp_prune_tail` | `1024` | 保留尾部码点数 |
| `CMP_PRUNE_MARK` | `"\n\n[... tool result middle pruned ...]\n\n"` | 固定标记，**逐字对齐 DSH** |

**「只在构请求时生效（不动历史）」是刻意的不变量**：① 天然幂等 —— 每一步都重新从原文算，
不会「剪了又剪」；② 会话日志里留的是**原文**，事后能用完整证据复盘；③ `--resume` 后重新
构请求仍得到同一结果。代价是每步都要重算一次（可接受，这是纯字节操作）。

**按码点而不是字节计数**：对齐 DSH 的 `Array.from(text).length` —— 中文内容按字节算会
比按字符算早 3 倍触发，剪枝阈值就失去意义。`bufx_utf8_count` / `bufx_utf8_prefix_bytes` /
`bufx_utf8_suffix_offset` 三个函数就是为它服务的（§2.1 的 `bufx`）。

#### 5.3.2 bash 结果的专用剪枝（P27）

**为什么 bash 要单开一条规则**：真轨迹分析（34 个真会话 / 1375 个 bash 结果）实测：
bash 结果占请求窗口 **57.9%**，read 只占 **12.9%**；其中会走到剪枝的只有 13 个样本，
而**旧规则（头 4096 + 尾 1024）在这 13 个上只保住 60.2% 的信号行**（error/fail/panic/…），
输出十分位覆盖**只有首尾两段** —— 中间那一大段错误全丢了。

新规则在**同一预算**内改三段分配：

| 段 | 占比 | 为什么 |
|---|---|---|
| 头 | 1/5 | 命令开场（能看出跑的是什么） |
| 尾 | 1/5 | 构建/测试结论通常在末尾 |
| 中段 | 其余 | 先收**信号行**（最多占 80% 预算），余量按**等距抽样**铺满整个输出；抽样行带**原始行号** `@N:` |

**同一样本实测**：信号行保全 **0.602 → 1.000**，十分位覆盖 **0.2 → 0.83**，token
**23,619 → 21,379（−9.5%）** —— **同预算下反而更省**。结构标记保全略降（0.358 → 0.309），
这是有意的取舍：宁可丢格式标记也要保住错误行。

**带 `@N:` 的用意**：模型据此能再跑一条更窄的命令（`sed -n '500,520p'`），
把剪枝变成「可继续操作」而不是信息丢失。

**退化保护**：预算太小（`< CMP_BASH_MIN_BUDGET = 512`）或保留量不足预算 1/4 时，
**退回通用规则** —— 保证任何输入都不会比旧行为更差。

**两个旋钮默认 0 = 沿用通用值**，所以默认行为与「没有这两个旋钮时」**逐字一致**
（A/B 实验的两条臂就靠它们切换）。

#### 5.3.3 自动压缩

```
触发：step 边界 (agent_maybe_compact)
压力：g_last_prompt_tokens = usage_in + usage_cache_read   ← 与 DSH tokenMeter 同口径
      拿不到 usage 时退化成「字节 / 4」的估算
线：  压力 >= floor(contextWindow × 0.8)
```

压缩产物是一条 user 消息：`CHECKPOINT_PREAMBLE + "\n\n" + <compacted-summary>…</compacted-summary>`，
保留最近 `retainRatio = 0.16` 的原文。**硬规则**：摘要**不比被遮蔽内容短就拒绝**（DSH 的规则）
—— 否则「压缩」会反而把上下文撑大。

开关：`--no-compact` / `--context-window N` / `/compact`（运行中敲的排 step 边界）。
`compaction/summary` 事件落日志。

### 5.4 退化响应（空回复）：证据 + 同一步重发一次

**判据**（`agent_finish_step`）：`finish` **不是** error、**不是** max-tokens，而这一步
`content` 与工具调用**都是 0** —— 也就是上游「正常收尾」却什么都没给。
最典型的样子是**只有思考**：正文一个字都没上来（也可能反过来，上游说 `tool_calls` 而调用在流里丢了）。

**证据**（转录一行 + 会话日志 `llm/degenerate` 事件，同一个出处）：

| 字段 | 说明 |
|---|---|
| `finish` / `have_finish` / `bad_finish` | 未知 `finish_reason` 的原文（转义后） |
| `content` / `reasoning` | 各自**字节数** |
| `calls` | 工具调用条数 |
| `usage{in,cache_read,cache_write,out,reasoning}` | 提供方读数 |
| `promptBytes` / `promptTokens` | 本次**请求体**的真实字节数 / 提供方读数（`in + cache_read`） |
| `sawDone` / `events` | 流是否正常收尾 / 事件数 |
| `retries` / `maxRetries` / `retrying` | 重发额度使用情况 |

> **为什么非要有它**：以前日志里只剩一条 `content=""` 的 assistant 消息，
> 「上游说 stop」与「tool_calls 丢了」在事后**长得一模一样** —— 用户就是靠别的旁证才定的性。

**重发**：额度**每步一次**（`EMPTY_RETRY_MAX = 1`）。重发**不推进 step、不动历史**，
请求由同一份历史重新拼出来 —— 所以重发的请求体与上一次**逐字节相同**
（自测按字节比对，不是数请求条数）。形状对齐 DSH 的 `agent/request-error` → `{kind:"retry"}`
（DSH 的 `compaction-basic` 接 context-overflow 走的就是这条通道）；**区别**是 DSH 只对
`finish.kind === "error"` 开这个口子，「正常收尾但空」它没有兜 —— 这一条是本项目自己补的。

**退化那一步不留痕**（三条理由，缺一不可）：

1. 不写 `assistant/message` —— 否则「退化」与「模型真的回了空串」在日志里长得一样；
2. 不进历史 —— 否则 `--resume` 会把一条空 assistant 消息拼回历史；
3. 不计统计 —— 没有产出。

重发仍然空 → 与以前一样按协议错误收口（退出码 3），但**带证据**；转录里那句
`error: model returned neither content nor tool_calls` 保持在最前面（文案没变，只是后面挂了证据）。

非流式（`--no-stream`）走**同一条收尾函数**，行为完全一致。

### 5.5 执行期两条纪律（P55）

**来由是一次同任务 A/B 实测**：任务 = 「把 `src/` 下 50 个 `.uya` 按职责拆进子目录、全部改动
落在同一个 commit、`make build` 要过」，同一个模型、同一个网关、两边各自默认配置、单发无追问。
把输出 token 按来源拆开：

| 输出构成 | 对比方（DSH 口径） | uya-agent |
|---|---|---|
| 思考 reasoning | 48,018 字（70%） | 217,608 字（**90%**） |
| 给人看的正文 | 1,428 字（3%） | 4,527 字（2%） |
| 工具参数（真干活） | 15,785 字（27%） | 18,433 字（8%） |

也就是**差额 100% 在思考上，不在「话多」**：正文两边都极少（把 uya 的正文全删掉也只值
$0.0009），工具参数两边几乎一样多。日志里两条固定浪费：① **方案在推理里被反复重列**
（50 个文件的映射在 step 10–17 逐步升级，单步 `src/` 出现 281 次，11 步吃掉约 150k 字符
= 它全部思考的 69%）；② **验收通过之后还不收工**（同一条 `make build` 在一回合里跑了三遍，
另有 6 步去追一条**既有**的 selftest 失败）。

#### 5.5.1 低思考执行态（`--exec-effort V` / `--exec-after N`）

* 前 N 步用配置档位把方案想清，**第 N+1 步起**把档位切到 V 执行；
* 切换走 `agent_effort_apply`（与 `/effort` 同一条路：只收模型公布的档位、切完刷 UI、
  落 `session/model`），日志来源标签 `exec-effort`；**回合结束还原**成配置档位
  （标签 `exec-restore`），所以降档只作用于「这一个回合的执行段」；
* **人优先**：人运行中 `/effort` 或 TUI 浮层改过档位（来源标签 `human`）就**整个会话**不再自动切；
* 档位不在当前模型公布的清单里则**当场放弃**（`g_exec.off = true`，不每一步白试一次）；
* **默认关**（`exec_after = 0`）：不配这两个开关的行为与改动前**逐字节一致**。

#### 5.5.2 收工提醒 + 收工预算（`--grace-steps N`）

* **验收类命令**词表：`make` / `pytest` / `unittest` / `npm test` / `cargo test|build` /
  `go test|build` / `tsc` / `gradle` / `cmake --build`；
* 在**改动之后**第一次跑绿时，往**工具结果尾部**追加一行
  `[acceptance] 验收命令已通过（第 N 步）：收工纪律 —— …`（一回合最多 2 条），
  并把该步记成收工预算的锚点；
* **「改动之后」这一条是必须的**：否则开局那次冒烟 `make build`（那时候一行代码都还没改）
  就会被当成「干完了」。实现上是一对计数：`bash` / `write` / `edit` 都算「可能改动」
  （本项目里搬家、改引用本来就全靠 bash），验收通过时记下当时的计数值；
* 提醒进的是**工具结果**（模型这一步就看得到）也进会话日志（事后看得见），
  **不是只写在 system prompt 里** —— 踩坑 88 的教训就是「只写在描述/提示词里等于没写」；
* `--grace-steps N > 0` 时，从锚点起再给 N 步，用尽即提前结束本回合；
  **默认 0 = 只提醒、不截断** —— 硬截断会让模型来不及给最终答复，而且有把正常任务切半截的风险。

#### 5.5.3 实测结论与方差（如实记录，别把它读成收益）

同一个任务、同一份 prompt、同一个基线、同一个网关；uya 侧一共 5 发，每发一个干净副本 +
独立 HOME：

| 腿 | 步 | 思考字符 | 输出 token | 金额 |
|---|---|---|---|---|
| 旧（两条机制都没有） | 34 | 217,608 | 74,144 | $0.0560 |
| 新·仅纪律（提醒当时静默失效） | 24 | 81,749 | 32,025 | **$0.0272** |
| 新·降档 `low`/6 | 26 | 149,625 | 50,749 | $0.0419 |
| 新·纪律+提醒（提醒误报 2 次） | 50 | 127,248 | 50,366 | $0.0472 |
| 新·提醒+`medium`/12（误报 1 次） | 33 | 194,304 | 68,731 | $0.0531 |
| 对照：DSH 复测（同任务、同时段） | 18 | 32,269 | 13,646 | $0.0193 |

1. **同一配置的重复给不出稳定数**：配置相同的两发（「仅纪律」与「纪律+提醒」，差别只是提醒当时
   是否真的注入）差了 24 步 vs 50 步、$0.0272 vs $0.0472 —— **1.7 倍**。uya 默认**不发
   `temperature`**（用网关默认值），轨迹本身就是随机的，所以这张表**不能**给「省了 51%」这类
   结论背书（第一版就是这么读的，随即被重复实验推翻）。要下结论得同一配置跑 ≥3 发。
2. **降档这一轮没有任何正收益**：`low`/6 与 `medium`/12 两发都不比「只改纪律」便宜，
   `low`/6 那发的思考量还是全表第二高（149,625 字）——「少想」不必然「干得少」。
   所以它**默认关着**，开关在、**结论待测**。
3. **提醒的第一版是负面的**：判据只看「命令文本里出现过 make」，真机上当场误报两次。
   改成**按段锚定**之后由 `make e2e-accept-nudge` 守着，但「修好之后到底赚不赚」这一轮没测出来。
4. **墙钟这一轮不可用**：同一配置两发 249 s vs 626 s（机器 load 42/44）—— 时间维度的对照要
   等机器安静下来重做。

### 5.6 技能与联网搜索

**技能发现根**（靠前先胜，`agent/skill.uya`）：

| 优先级 | 根 | 备注 |
|---|---|---|
| 100 | `<项目根>/.dsh/skills` | |
| 200 | `<项目根>/.agents/skills` | |
| 300 | `--skill-dir` | 冒号分隔，可多次 |
| 400 | `$DSH_HOME/skills` | **跳过 `.system`** |
| 500 | `$DSH_AGENTS_HOME` 或 `~/.agents/skills` | |

布局只两种且**只扫一层**：`<root>/<name>/SKILL.md` 或 `<root>/<name>.md`。
front-matter = `---` 包起来的 YAML，必填 `name`（kebab-case，`[a-z0-9-]`、≤64）与 `description`；
可选 `whenUse` / `disable-model-invocation`（= true 则**不进目录也不可被工具调用**）。
同名先到先得。上限：`SKILL_MAX=64`、`SKILL_DESC_MAX=500`、`SKILL_BODY_MAX=262144`、
`SKILL_PATH_MAX=4096`、`SKILL_ROOTS_MAX=12`。

`web_search` 见 `net/webx.uya`：走 provider 侧搜索（Anthropic 兼容 Messages API +
服务端工具 `web_search_20250305`），`queries` 1–4 条去重保留首次出现，最多 8 条来源，
凭据缺失回 `WEB_PROVIDER_CREDENTIAL_MISSING`。

---

## 6. 工具层

这一节回答：**模型能调用哪些工具、每个工具的契约是什么、失败怎么表达**。

### 6.1 工具目录：固定顺序

28 个工具按**固定顺序**拼进请求（`tools_json`，`src/agent/agent.uya:2867`）。
顺序**恒定**是关键设计：工具目录跨模式稳定 ⇒ 前缀缓存不会因为「模式变了」而失效。

| 组 | 工具 | 条件 |
|---|---|---|
| 文件 | `read` `write` `edit` `glob` `grep` | 总是 |
| 执行 | `bash` `job_list` `job_output` `job_kill` | **`allow_shell` 时**（否则整组不出现） |
| 会话与交互 | `workspace` `worktree` `set_title` `todo_write` `exit_plan_mode` `ask_user_question` | **总是**（含 plan 模式 —— 工具目录跨模式稳定） |
| 技能与搜索 | `skill` `web_search` | 总是 |
| 子代理 | `subagent` `subagent_fork` `list_agents` `subagent_output` `send_message` `interrupt_agent` `ralph` | 总是 |
| 目标 | `create_goal` `get_goal` `update_goal` | 总是 |
| 编排 | `workflow` | 总是 |

schema 文本是 `TOOL_*` 常量（`agent.uya:2782-2838`），逐字对齐 DSH v0.1.1-rc.2 的
standard preset（`agent.uya:2779`）。

**两种协议的 schema 差异只用文本变换实现**：`TOOL_FLAT_STRIP`（31 字节）去掉
`{"type":"function","function":{` 前缀 + 去掉尾部大括号 → Responses 形状。这样**只有一份**
schema 真值，不会两边漂移。

**已知死代码**（如实记录，P14 起未清理）：

* `TOOL_RUN_SHELL`（`agent.uya:2840`）—— **未被 `tools_json` 引用**的死常量；
* `src/tools.uya` —— P50 起不在构建里的死文件（三个旧工具 `read_file`/`write_file`/`run_shell`）；
* `agent.uya` 的 `dispatch_tool` —— 无调用者。

### 6.2 工具契约总表

| 工具 | 必填 | 可选 | 结果形状 |
|---|---|---|---|
| `read` | `file_path` | `offset`(默认 1) `limit`(默认 `fs_read_limit`) | `<path>…</path>\n<type>file</type>\n<content>\n` + 逐行 `N: text` + footer + `\n</content>` |
| `write` | `file_path` `content` | — | 同信封，正文 `Updated file` / `Created file` |
| `edit` | `file_path` `old_string` `new_string` | `replace_all`(bool) | `The file X has been updated successfully.` / `…All occurrences were successfully replaced.` |
| `glob` | `pattern` | `path` | 每行一个相对路径（去 `./`）；`No files found`；超出加 `… (N of M paths shown; narrow the pattern to see more)` |
| `grep` | `pattern` | `path` `include` | `path:` 分组行 + 每命中 `Line N: <preview>`；`No matches found`；超出 `… (N of M matches shown; …)` |
| `bash` | `command` `description` | `timeoutMs` `workdir` `run_in_background` | stdout + 可选 `[stderr]\n…` + 标记行 + `[exit code: N]` |
| `job_list` | — | — | 每行 `job-N [bash] <status> — <label>`；无任务 `(no background jobs)` |
| `job_output` | `job_id` | `wait` `timeout_ms` | 增量正文 + `[output truncated]`? + `\n[status: …, exit N]`；无新输出 `(no new output)` |
| `job_kill` | `job_id` | `reason`（仅 schema，代码未读） | `requested cancellation of job N` 或 `job-N had already finished [status: …]` |
| `ask_user_question` | `questions[]`（每项 `id`+`question`） | `header` `options[{label,description}]` `multi_select` | JSON `{"answers":[{"id":…,"selected":[…],"custom":…}, …]}` |
| `workspace` | — | `path` | 无参 = 报告；带 `path` = chdir + 规范化 + 重指 `FsCtx` + 清技能缓存 + `gd_reset` + 记 `session/workspace` |
| `todo_write` | `todos[]` | — | 整表替换；去重与状态校验 |
| `exit_plan_mode` | `plan` | — | plan 非空且**首字符 `#`**；非 plan 模式调用报错 |
| `skill` | `name` | — | `<skill_content name="…"><skill_resources>…</skill_resources><skill_instructions>…</…>` |
| `web_search` | `queries[]` | — | 答案 + `Sources:` 列表（详见 §5.6） |
| `subagent` | `prompt` `description` | `run_in_background`(默认 true) | `started background subagent sub-N` / 前台等到终态 |
| `subagent_output` | `subagent_id` | `wait` `timeout_ms` | 增量正文 + `[status: …]` |
| `send_message` | `subagent_id` `message` | — | `delivered message to sub-N; continuing as sub-M` |
| `interrupt_agent` | `subagent_id` | — | 仅 RUNNING 时 SIGKILL + 结算 |
| `ralph` | `objective` | `maxRounds` | `[round N] <answer>` 逐轮 |
| `create_goal` / `get_goal` / `update_goal` | 见 §9.3 | | |
| `workflow` | `meta` `script` | `args` | 见 §9.4 |
| `worktree` | `action` | `message` `keepWorktree` | 见 §10 |
| `set_title` | `title` | — | 见 §11.7 |

**统一约定**：工具内部任何失败**都不抛错**，一律写成 `error: ...` / `Error: ...` 文本回给模型，
让它自己纠正。只有「必须中断回合」的才走错误码。

### 6.3 文件工具与观察策略

#### read 的信封与三道上限

`<path>…</path>\n<type>file</type>\n<content>\n` + 逐行 `N: text` + footer + `\n</content>`，
绝对行号 = `first + k + 1`。

| 上限 | 值 | 行为 |
|---|---|---|
| 单行 | `fs_read_max_line = 2000` **字符** | 按**字符数**截断（**不切断 UTF-8**），追加 `... (line truncated to 2000 chars)` |
| 选中行总字节 | `fs_read_max_bytes = 51200` | 每行预留 24 字节 |
| 行数 | `fs_read_limit = 2000` | 默认值，可被 `limit` 覆盖 |

三种 footer（**逐字节**被自测断言）：

| footer | 含义 |
|---|---|
| `(End of file - total N lines)` | 读到了文件末尾。**这句同时是给模型的信号**：`SEC_FINISH` 让它据此判断「整份已到手，别再读一遍」 |
| `(Output capped. Showing lines A-B. Use offset=B+1 to continue.)` | 撞了字节上限 |
| `(Showing lines A-B of N. Use offset=B+1 to continue.)` | 还有更多行 |

失败（不存在 / 是目录 / 不可读）都以 `Error: cannot read "X": …` 文本返回。

#### 观察策略（read-before-write / 版本守卫）

观察表 `FsObsTable`：`FS_OBS_MAX = 128` 条，键是**解析后的绝对路径**字节；
版本 = `(mtime, mtime_nsec, size)` 三元组。三种观测态：

| 态 | 含义 |
|---|---|
| `OBS_UNSEEN` | 从没见过 |
| `OBS_PRESENT` | 读到过（含读到**空内容**） |
| `OBS_ABSENT` | 读到**不存在** |

**记录时机**：read 命中记 `OBS_PRESENT`，读到不存在记 `OBS_ABSENT`；
write/edit **成功后刷新**记录。

**write 的判定**（文件已存在时）：

| 情况 | 结果 |
|---|---|
| 表中该路径 `kind == OBS_UNSEEN` | `Error: write requires reading "X" first — read the file, then retry` |
| `!fs_obs_same_version` | `Error: cannot write "X": file changed since it was read (FS_STALE_VERSION) — re-read the file, then retry` |
| 文件**不存在** | 不要求先读（直接创建） |

`fs_obs_same_version` 要求 `kind == OBS_PRESENT && st.exists` **且三元组全等**。

**edit 的判定**：

| 情况 | 结果 |
|---|---|
| 不存在 + `OBS_UNSEEN` | 先 read 提示 |
| 不存在但见过（`OBS_ABSENT`） | `Error: cannot edit "X": file not found` |
| 存在但 `OBS_UNSEEN` | 先 read 提示 |
| 存在但版本变了 | `FS_STALE_VERSION` |
| `old_string` 为空 / `new_string` 缺失 / 两者**相同** | 对应拒串 |
| `old_string` 找不到 | `old_string not found in the file` |
| `old_string` 出现 N 次 | `old_string appears N times; make it unique or pass replace_all=true` |
| 文件 > 4 MiB | 拒 |

**观察表是内存态、不持久化**：恢复会话后要**重新 read** 才能 edit（与 DSH 的已知限制一致）。
这是**有意的**：持久化版本号会让「另一个进程改过文件」变成检测不到的静默覆盖。

#### 路径守卫（best-effort，**不是安全边界**）

所有 `path` 相对 `--workspace` 解析，拒绝**绝对路径**、`~` 开头、以及含 `..` 段的路径。
`fs_resolve` 返回码：`0 = ok` / `1 = unsafe` / `2 = oom`。

> **这条必须说清**：守卫是**防手滑**，不是安全边界。`bash` 在 `danger-full-access` 下本来就能
> 执行任意命令 —— 要真隔离请用 `workspace-write` / `read-only`（§7）。

#### 第三道守卫：worktree 共享 checkout

`wt_guard_path_crosses`：目标在 repo 内（**前缀 + `'/'`**，避免 `/x/ab` 被 `/x/a` 误判）
却不在 worktree 内 → 拒。fsx 的 read **与** write **都**调用它，拒串`s_fs_wt_denied` 明确说
「共享 checkout 不可改；请写到 `<worktree>/<同一相对路径>`」（详见 §10）。

### 6.4 bash 工具

**进程模型**：`pipe` → `fork` → 子进程 `dup2` + `chdir(workspace)` + `execve("/bin/sh",
["sh","-c",cmd], envp)` → 父进程 `poll` 读 stdout+stderr → 墙钟超时 `SIGKILL` → `waitpid`。

| 不变量 | 理由 |
|---|---|
| 命令**没有终端**（stdin = `/dev/null` + `setsid`） | 有些命令会去读 tty；给了它就会**偷走用户的输入** |
| 收尾读管道**必须非阻塞** | 否则「子进程已退出但管道没关」会让父进程永久卡住 |
| 超时 → 先杀**进程组**（`sh_kill_tree`），不是只杀壳进程 | `bash -c "sleep 300 &"` 这类会留下孤儿 |
| confined（read-only / workspace-write）下沙箱**起不来必须拒绝** | fail closed（§7.3） |

**结果标记的出现顺序**（`src/tools/shellx.uya:596-648`，自测按这个顺序断言）：

```
(no output) → [stderr]\n… → [timed out after Nms] → [aborted by user]
 → [stopped by signal: N]（附一段说明） 或 [killed by signal: N]
 → [output truncated]   ← out/err 各自达到 cfg.max_tool_out（默认 65536）
 → [sandbox] the <mode> file …
 → [exit code: N]
```

`[stopped by signal: N]` 附的那段是给模型的**行动指引**：「命令碰了它没有的终端，整棵树已被
收掉，**别原样重试**」。没有这句，模型会反复重试同一条必定失败的命令。

**两道闸门**：权限（§7.1）+ 沙箱（§7.3）。`--no-shell` 时整个 bash 组**连 schema 都不出现**。

### 6.5 后台任务（`job_*`）

`fork` + `pipe` 的注册表，`JOB_MAX = 8` 个槽位（`src/tools/jobs.uya`）。
状态词对齐 DSH：`running` / `completed` / `failed` / `killed`。

| 设计点 | 说明 |
|---|---|
| 输出只保留**内存尾部** `JOB_BUF_MAX = 1 MiB` | 超出丢弃并标 `[output truncated]` |
| **已知偏离 DSH** | DSH 会落盘 spill，本项目不落 —— 长输出任务的后半段会**永久丢失**。如实记为偏离（`jobs.uya:6-8`） |
| `job_output` 默认**增量**（只给上次以来的新输出） | 否则每次 poll 都把 megabytes 重灌进上下文 |
| 收僵尸走 `jobs_poll_all` / `job_check` | 与子代理槽位回收同一套形状（§9.1） |

### 6.6 glob / grep

都是 **ripgrep 子进程**封装。与 DSH 一致：

* `glob`：`rg --files --glob <pattern> --sort=modified --no-ignore --hidden` + VCS 目录排除；
* `grep`：`rg` + VCS 排除。

| 上限 | 值 |
|---|---|
| `search_glob_max` | 100 |
| `search_grep_max` | 250 |
| `search_line_max` | 2000 |
| `search_timeout_ms` | 30000 |

**错误语义**：`SEARCH_FAILED`（不能跑 rg）/ `SEARCH_INVALID_PATTERN`（**rg 退出码 2**）。
预览**按字符**截断，绝不切坏 UTF-8。

---

## 7. 权限、沙箱与写闸门

这一节回答：**「不许做」这件事在几处被拦、每处是硬拦还是问人、失败时是拒还是放。**

### 7.1 三级访问模式

机器名与 DSH **逐字一致**（`src/tools/perm.uya:2-5`），这样 DSH 设置文件里的
`permission.defaultPreset` 能**直接喂进来**：

| 值 | 机器名 | 显示名 | 写工具 | bash | 沙箱 | 审批 |
|---|---|---|---|---|---|---|
| 0 | `read-only` | Read Only | **拒** | 允许 | read-only 沙箱 | **每条命令要批准** |
| 1 | `workspace-write` | Workspace Write | 只写工作区内 | 允许 | workspace-write 沙箱 | 不需要 |
| 2 | `danger-full-access` | Full access | 不限 | 不限 | **不沙箱** | 不需要 |

语义来自 DSH 的实测表（`dsh-base/cordis.patch.yml:193-205`）：
`read-only = (sandbox read-only, approval ask)` / `workspace-write = (workspace-write, ask)` /
`danger-full-access = (danger-full-access, never)`。本项目没有内核沙箱之外的审批升级链，
所以「approval ask」落地成 **read-only 下 bash 的逐条人工批准**。

**默认 = `danger-full-access`**（`perm.uya:23`，内置默认即全权）。

**来源链与优先级**（低 → 高）：默认 → `DSH 设置 permission.defaultPreset` → `UYA_AGENT_PERMISSION`
（env）→ `--permission <v>` / `--permission=<v>`（cli）。**非法取值必须报错退出** ——
静默按默认跑会让人以为模式生效了（而默认是全权，这个错觉很危险）。

**不进会话恢复语义**：模式是**进程级运行期状态**；`--resume` 时按**当前进程**重新求值运行时
上下文（不按日志里那次）。切一次只记**一条审计事件** `permission/mode`。

### 7.2 三个独立旋钮，别混

| 旋钮 | 管什么 | 默认 |
|---|---|---|
| `--permission` | 权限模式（上面三级） | `danger-full-access` |
| `--sandbox` / `UYA_AGENT_SANDBOX` | **是否**尝试内核沙箱（`0`/`off` = 等价于 `--no-sandbox`） | 开 |
| `--tls-verify` | 传输信任策略（§18） | `chain` |

`SAN_AUTO=0`（未指定，按可用性探测）/ `SAN_OFF=1`（明确关）。

### 7.3 内核沙箱（bwrap）

后端是 **bubblewrap**（`src/tools/sandboxx.uya`）。探测结果缓存在进程级
`g_san_probed` / `g_san_backend`。

| 档 | argv |
|---|---|
| read-only | 只读 bind 工作区；只 `/dev/null` 可写 |
| workspace-write | 可写 bind 工作区（`san_bind_root` = 当前工作区） + `--tmpfs /tmp` |
| full access | **不套壳**（`san_build_exec` 返回 0 = 不套壳） |

`san_build_exec` 返回码：`0 = 不套壳` / `1 = 套壳` / `2 = **沙箱不可用**`。

**两条硬不变量**：

1. **后端不可用时 fail closed，绝不静默降级成不沙箱**（`sandboxx.uya:7`）；
2. **沙箱只作用于 spawn 出去的 shell 代码**（bash 前台/后台、子代理里的 bash）。
   进程内的 `write`/`edit` 是**策略栅栏**，不是内核边界（`sandboxx.uya:13-15`）—— 这点必须
   写清楚，否则会误以为「有沙箱 = 进程内也安全」。

### 7.4 三道闸门的关系

| 闸门 | 拦什么 | 拦法 | 与谁独立 |
|---|---|---|---|
| **权限模式** | 写工具（read-only 全拒）+ bash 审批 | 硬拒 / 问人 | 独立于 plan |
| **plan 写闸门** | `write` / `edit` | 硬拒（`plan_blocks_write`） | 独立于权限；**不拦 bash** |
| **worktree 共享 checkout** | 对共享 checkout 的 read/write 与含 git 变更子命令的 bash | 硬拒 | 独立于前两者（P37） |

**plan 模式为什么拦 `write`/`edit` 而不拦 `bash`**：DSH 的 plan mode 是**纯引导**（它自己的
文档写明「需要强制只读规划的部署必须组合独立的沙箱与审批策略」）。本项目把那条策略落在写工具
上是因为：**不这么做，模型压根不调 `exit_plan_mode` 就直接开工**，审阅浮窗永远不会出现
（现场证据：踩坑 36）。而 `bash` **不拦** —— 探索要用它，它归访问模式（§7.1）管。

拒串（**测试逐字断言**）：plan 模式 `Error: write is refused in plan mode (no file changes
before the user approves the plan). …`；read-only 模式 `Error: write is refused in read-only
mode (the user granted no write access). Do not retry; …`。

### 7.5 审批与提问：fail closed 与「换个地方问」的区别

| 动作 | 无渠道时 | 名字 |
|---|---|---|
| bash 批准 / plan 审阅 | **拒**（fail closed） | 「看不见就不许做」 |
| `ask_user_question` | **换地方问**（回落） | 「提问只是换个地方问」 |

**为什么提问故意 fail closed 会错**：审批的语义是「没被批准就不许做」——看不见就等于没批准，
必须拒。提问的语义是「需要用户输入」——看不见只意味着**换个地方问**，拒掉会让模型以为
「用户拒绝回答」而不是「没有界面」，两者的后续行为完全不同。

**批准三通道**（`ask_approve_action`）：TUI 浮层 → 滚动模式真 TTY → **fail closed**（返回 2）。
**子代理一律 2**（没有前台界面）。返回码：`1 = 批准` / `0 = 拒绝` / `2 = 没有渠道`。

plan 审阅的四条裁决：`PLAN_KEEP=0` / `PLAN_APPROVE=1` / `PLAN_NO_CHANNEL=2` / `PLAN_DISMISS=3`。
画不出来时返回 `PLAN_NO_CHANNEL` —— **绝不等于批准**。`plan_verdict_of` 对认不出的项
一律当 KEEP（保守）。

---

## 8. 会话持久化与恢复

这一节回答：**一次会话落在哪、写成什么样、崩溃了怎么办、怎么恢复。**
改日志格式要极其小心：它是**向前兼容的公开接口**（DSH 与外部工具都读它）。

### 8.1 落盘布局

```
<agent-home>/sessions/--<normalized-cwd>--/<session-id>/session.jsonl    日志
<agent-home>/index.jsonl                                                  索引
```

`agent-home` 默认 `~/.uya-agent`（`--agent-home` 可改）。
`sess_norm_cwd` 把 `/` 换成 `-`，前后加 `--`。

**索引是追加写的**：每关一次会话就多一条记录，**同一个 id 以最后一条为准**。
真机实测：308 行 / 298 个会话，一个 id 出现 4 次。这是有意的 —— 追加写不需要写锁，
代价是读时要自己去重（§8.5）。

### 8.2 格式

**header 行**（每个日志的第一行）：

```json
{"type":"session","version":0,"id":"session-…","createdAt":N,"cwd":"…","delegationDepth":0,
 "agentPreset":"standard","model":"…","provider":"…"}
```

**`cwd` 是「创建时」的工作区**，是**元数据、不再改写**；会话**当前**工作区由
`session/workspace` 事件记录（最后一条为准）。索引里的 `cwd` 是它的一份「最后已知」缓存。

> 这条区分是 P34 的核心：工作区可以在会话中途切（`workspace` 工具 / `/workspace`），
> 如果直接改 header，就分不清「这个会话从哪开始的」与「它现在在哪」。

**会话 id**：`/dev/urandom` 16 字节 → `session-xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`
（version 4 / variant 10）；读失败时用「时间 + pid 派生」兜底。

**事件行**：`{"type":"<event>","seq":N,"time":N,"data":{…}}`，`seq` 从 0 **连续递增**，
**追加-only**；崩溃时最后一行可能不完整。

| 事件 | 载荷 | 何时写 |
|---|---|---|
| `turn/start` / `turn/end` | `{turn[, reason]}` | 回合边界 |
| `step/start` / `step/end` | `{turn, step}` | step 边界 |
| `user/message` | — | 用户消息（`source.kind` 可为 `steer`） |
| `assistant/message` | — | 助手正文（**退化那一步不写**，§5.4） |
| `assistant/reasoning` | — | 思考（**步末**才落盘 —— 这是 `/watch` 粒度的根源，§11.6） |
| `assistant/first-token` | `{turn, step}` | 首 token；**时间用 `sess_begin_at` 钉在首 token 那一刻**（不是落盘时刻） |
| `tool/call` / `tool/result` | — | 工具调用/结果（`tool/call` 在工具**执行前**写） |
| `session/title` | — | 标题变更 |
| `session/workspace` | `{workspace, previous, source}` | 工作区切换 |
| `session/model` | `{provider, model, reasoningEffort, source}` | 模型/档位变更（`source` 见 §5.5.1） |
| `session/worktree` | `{action, worktree, branch, base}` | worktree 动作（§10） |
| `permission/mode` | `{mode}` | 权限模式切换（§7.1） |
| `plan/mode` | — | plan 模式切换 |
| `compaction/summary` | — | 自动压缩（§5.3.3） |
| `subagent/start` | — | 子代理派生（§9.1） |
| `cache/evicted` | — | 缓存淘汰 |
| `llm/degenerate` | 证据字段（§5.4） | 退化响应 |
| `diag/dump` | 诊断原文（**原始字节**） | `--debug-dump` |

**`assistant/first-token` 用 `sess_begin_at` 钉时间**是一个细节但很重要：事件是**步末**才落盘的，
若用落盘时刻，TTFT 统计就变成了「整步耗时」而不是「首 token 耗时」。

### 8.3 写入路径

| 函数 | 用途 |
|---|---|
| `sess_open` | 按 cwd **算路径**、写 header |
| **`sess_open_resume`** | P34：往**已经解析出来的那份日志**续写，`write_header = false`，不建目录 |

> **为什么必须分开**：`sess_open` 按 cwd 重算路径，而恢复时日志在**找到它的那个目录**里。
> 重算会在同 id 下造出一个**没有 header 的空文件**、把会话**劈成两半**（旧实现实测如此，踩坑 48）。

`sess_begin_at` / `sess_begin` 只拼前缀，`sess_end` 补 `}\n` 并落盘、`seq++`。
`--no-save` 时 `sess_write_line` 直接返回 true **但 `seq` 仍推进** —— 保持 seq 连续。

**已知坑**：写入过程**中间不要**用 `buf_append_cstr_z` 补 NUL，否则后续内容落在 NUL 之后，
系统调用只看到**前半截**。

### 8.4 崩溃尾部裁剪

`sess_next` 找行尾 `'\n'`；**找不到 = 最后一行不完整** → 置 `dropped_tail = true` 并停止。

对应 DSH 的「保留有效尾部工作」：崩在写一半的那条记录**丢掉**，前面的都算数。
这与「追加-only + 每行自包含 JSON」是配套的：**任何前缀都是合法日志**。

### 8.5 读取与索引

`sess_index_rows_sorted` 六步（**顺序有讲究**）：

| 步 | 做什么 |
|---|---|
| ① | 数非空行 → **一次** `malloc((2n+2) * esz)` |
| ② | 填表（无 id 的行丢掉）。**每行先拷进 `line` 再解析** —— 不能写 `idx.ptr[lo: ll]`，因为 uya 的 `p[a:b]` 是「偏移 + 长度」不是区间 |
| ③ | 按 `(id 升序, 行号升序)` 归并排序，把同 id 归到相邻 |
| ④ | 每个 id **只留组内最后一条** |
| ⑤ | 按 `(lastActiveAt 降序, 行号降序)` 排序 |
| ⑥ | 原样输出索引记录（排版交给调用方） |

`sess_idx_sort` 是**自底向上归并排序 O(n log n)**，与老插入排序**逐字节等价** ——
可证因为比较键是**严格全序**（次级键 `line_off` 在同文件里唯一）。
性能：老插入排序在真机索引 1.4K 行时 `--list-sessions` 要 **70 ms**、12.8K 行升序时要
**~1.4 s**；换归并后 12800 行升序 **1475 → 205 ms**（踩坑 68）。

**排序键细节**：缺 `lastActiveAt` = `-1` → **排最后**；时间相同时**后写的排前面**。

**行级硬裁只给滚动模式与 `--list-sessions` 用；TUI 里 id 在条目文本里永不裁剪** ——
因为选中项的 id 就是**从条目文本里取回来的**，裁了就取不到。

### 8.6 恢复数据流

| 入口 | 行为 |
|---|---|
| `--continue` | `sess_find_last`：读索引，按 `lastActiveAt` 选最大；**`delegationDepth > 0` 的子代理会话不参与**（否则会接到子代理身上）；可按 cwd 过滤 |
| `--resume <id>` | `sess_find`：先看当前 cwd 目录，再扫所有 `--*--` 目录 |
| `/sessions` | 浮层，数据层最新在前、**展示层翻成最新在最后一行** |
| `--resume-dsh <前缀>` | 走 `dshsess` 导入（§8.7） |

解析结果写进 `cfg.resume_id`（**绝对路径**）。恢复过程：

```
sess_read_meta      一次读盘拿 header(id/cwd) + 逐行扫最后一条 session/workspace 与 session/model
   ↓  ★ 必须在 agent_hist_from_log 之前定工作区 ★
agent_hist_from_log sess_reader_load 整文件读入、跳 header → sess_next 逐行
   ├─ 每行先 st_fold_line（折叠统计）
   └─ 按 seq 连续性校验（不连续打印 [session] 警告：seq 不连续）
hist_trim_incomplete_tail   丢未完成一轮的尾部
sess_open_resume            用会话自己的路径 + next_seq 续写
```

> **为什么工作区必须在 `agent_hist_from_log` 之前定**：system prompt 的 `{{cwd}}`、AGENTS.md、
> 技能目录的 5 个根**全都在那里求值**（§3.2）。定晚了整份 prompt 就是上一轮的。

`l.cwd` 传**当前**工作区（索引的工作区列按它写，**header 不动**）。
折叠统计与日志在 resume 时对齐：`st_reset()` + 逐行 `st_fold_line`。

### 8.7 与 DSH 会话格式的兼容读取

`session/dshsess.uya`：扫 `<DSH_HOME>/sessions`；`session.jsonl` 里是 zstd 压缩时走
`/usr/bin/unzstd`。导入时**不是新增事件类型** —— 例如标题按 `source.kind = "user"` 记一条
`session/title`（§15）。

### 8.8 DSH 设置兼容

| 文件 | 读什么 |
|---|---|
| `$DSH_HOME/settings.yaml` | 模型路线（`providers.<key>`）、权限 `permission.defaultPreset`、技能根、preset 旋钮（persona / plan-mode.section / 各上限） |
| `$DSH_HOME/.credentials.yaml` | 凭据（`refs.DEEPSEEK_API_KEY` 等） |
| `$DSH_HOME/.env` | 环境变量兜底 |

**为什么自带 YAML 解析器**：`std.yaml` 与 `std.json` 在 uya 0.10.1 里**不能共存**
（同名私有符号在合并命名空间撞车），而线上协议必须用 `std.json` ⇒ 自实现子集
（`foundation/yamlcfg.uya`，§2.4）。

## 9. 子代理、目标、任务与编排

这一节回答：**怎么把一个任务分出去并行做、怎么盯住它、怎么把多个子代理编排起来。**

### 9.1 子代理一族（`agent/deleg.uya`）

**核心机制：`fork` 而**不** `exec`**。子进程是**同一二进制的一份拷贝**，直接跑 `agent_run`，
最终答复写进管道。这样做的三个好处：

1. 不用把配置**序列化进命令行**（`Config` 有约 100 个字段）；
2. 共享**已验证**的流式/工具/会话代码 —— 子代理不会因为「另一条代码路径」而与主代理行为漂移；
3. 会话 id 可以在 fork **之前**由父进程生成（父子共享这份内存）。

| 常量 | 值 | 含义 |
|---|---|---|
| `DELEG_MAX` | 4 | 槽位数 |
| `DELEG_RUNNING/DONE/FAILED/KILLED` | 0/1/2/3 | 状态 |
| `DELEG_KIND_SUB/RALPH` | 0/1 | 种类 |
| `DELEG_BUF_MAX` | `262144` | 管道读取缓冲上限 |

#### 父↔子通信协议

**管道只承载终态答复。** 子进程的 fd 1/2 **重定向到 `/dev/null`**
（`UYA_AGENT_DEBUG_SUBAGENT=1` 时保留 stderr），读端在父进程里 `O_NONBLOCK`。
缓冲上限 `DELEG_BUF_MAX`，超出丢**前缀**并同步 `read_off`。

**子代理回合的准备**（顺序不能换）：

```
deleg_child_main
 → tui_child_detach()      ★ 一个字节都不许碰父的 TUI/终端
 → sigx_reset_for_child()  信号处置是继承的：不重置的话子进程收到 TERM 会去写父的终端
 → sh_child_detach_stdio() stdin = /dev/null 且自成会话（P38）
 → deleg_clone_cfg()       继承凭据/工作区/线协议/推理档位/模型路线；
                           强制 quiet=true, show_reasoning=false, save_session=true,
                                stream=true, is_subagent=true, plan=false
 → agent_run → agent_last_answer() 写管道
```

无终态文本时写 `(subagent finished with no final text, exit N)`。

**会话 id 由父进程预生成**（`sess_new_id` 在 fork **之前**调用）：子进程用它
`force_session_id` 开会话、父进程记进 `d.sid`。

> **这是一个修过的真 bug**：原实现 `d.sid` 恒空 ⇒ `send_message` 续跑时每次都**新开会话**、
> **上下文全丢**（模型看到的是一个空历史，于是重复劳动）。

头部记 `parentSession` + `delegationDepth`（父侧落 `subagent/start` 事件）。

**`subagent_fork`**：`fork_parent = true` ⇒ 子进程设 `cfg.fork_from = g_sess.id`，
`agent_history_begin` 会**先读父会话历史**再开自己的新日志（于是子代理知道父在干什么）。

**槽位回收 `deleg_reclaim`**：

> **也是一个修过的真 bug**：原实现 `used` 只置 true **从不复位** ⇒ 4 个槽用满之后
> `subagent`/`fork`/`ralph`/`send_message` **全部永久失败**（真机实测卡死）。
> 现在：先 `deleg_poll_all` 收僵尸，再优先回收「输出已被父读空」的终态槽，
> 否则回收**最早开始**的。

**终态结算 `deleg_check`**：`waitpid(WNOHANG)`；`sig != 0 → KILLED(code = 128+sig)`；
`code == 0 → DONE`；否则 `FAILED`。`deleg_settled` **只通知一次**并刷面板。
`deleg_status_name`：`DONE → "idle"` —— DSH 口径：**跑完就是 idle**，可以再 `send_message`。

**`deleg_wait_slice` 用裸 `nanosleep`**，**不要**写成 poll 一个无效 fd —— poll 对 fd<0
**立刻返回**，50 ms 的等待会变成 50 ms 的自旋（CPU 打满）。

#### 工具语义

| 工具 | 语义 |
|---|---|
| `subagent` / `subagent_fork` | 必填 `prompt` + `description`；`run_in_background` 默认 **true**（立刻返回 `started background subagent sub-N`）；前台模式轮询到终态，超时上限 = `cfg.timeout_ms`，超时 SIGKILL 并报 `timed out and was interrupted`；每 50 ms 一次 `agent_pump_block()` 检查用户叫停 |
| `subagent_output` | `wait=true` 时最多转 600 次 × 100 ms、墙钟 30 000 ms，或用户叫停即返回；**增量**读 `read_off`；无新内容给 `(no new output)`；尾部 `[status: …]` |
| `send_message` | 要求槽位**不处于 RUNNING**；`d.sid` 空时报 `has no session to continue (ralph rounds are fresh-agent by design)`；实现是**新 spawn 一个槽位**并用同一个 `force_session_id` **续写同一份日志**，回 `delivered message to sub-N; continuing as sub-M` |
| `interrupt_agent` | `deleg_poll_all` 后仅在 RUNNING 时 SIGKILL + 结算 |
| `list_agents` | 逐槽打印 `sub-N [subagent\|ralph] <status> — <label>`；无则 `(no background agents)` |

**`ralph`**：默认 `rounds = 4`、上限 20；每轮构造**全新** prompt：

```
Round N of M. Objective (immutable): …You are a fresh agent with no memory of earlier rounds;
the shared workspace is the only durable memory…
```

`fork_from`/`resume_id` **清空**，每轮会话 id = `<父预生成的基名>-rN`，管道里写
`[round N] <answer>`；答复含 `RALPH: COMPLETE` / `RALPH: BLOCKED` 即停。
**为什么是 fresh-agent**：这是 ralph 这个名字的全部意义 —— 每轮从干净上下文开始，
只有**共享工作区**是长期记忆（`send_message` 对 ralph 槽位报错就是这个原因）。

#### `/watch`：实时过程消息怎么传

**不走管道。** 运行中管道里**没有**过程消息（fd 1/2 指向 `/dev/null`），但子进程把每个事件
**实时落进自己的会话日志**，`/watch` 按需读那份日志。

| 纪律 | 说明 |
|---|---|
| **不看不读** | 没有 active 的 watch 时**一个字节都不读盘** |
| **只读** | 只读会话日志，**绝不消费管道** —— 所以 `subagent_output` 的增量游标不受影响 |
| **纯函数渲染** | `watch_render_event` 把日志行变成事件行 |

**实时粒度 = 事件，不是 token 级**：`assistant/reasoning` 与 `assistant/message` 都在**步末**
才落盘 ⇒ 单个长 step 内部（模型正在流式吐字的那几秒到几十秒）日志不增长。
那段时间能看到的实时信号是「**正在跑哪个工具**」（`tool/call` 在工具**执行前**写）以及面板上的秒数。

**路径解析 `deleg_watch_path`**：subagent/fork → `d.sid` 直接 `sess_find`；
ralph → `<watch_base>-rN`，N 由管道里已收到的 `[round N]` 行推出
（`deleg_round_current`：RUNNING 时 = 已见最大 +1，终态时 = 已见最大 —— **弄反会读上一轮日志**）。

**重入保护闸门 `g_watch_in_tick`**：

> 不设闸门就是 `watch_tick → deleg_check → deleg_drain → pump → watch_tick` **无限递归**，
> **实测 SIGSEGV，core 里 25 层全是这个环**。

其它：1 Hz 节流；空闲 TUI 主循环也继续（靠 `g_watch_cfg` 保存的 cfg 指针）；
逐字节比、内容变了才重推；ralph 换轮 `watch_retarget` **保留已渲染内容** + 插一行
`[轮次切换]`；槽位回收/换人（id 对不上）**自动结束**跟随。

### 9.2 todo / plan

**todo（`agent/todo.uya`）**：

| 设计点 | 说明 |
|---|---|
| **整表替换** | 每次提交**完整**列表；回显 `Updated todo list: N pending, N in progress, N completed.` |
| 校验顺序 | 先**全量**校验再落状态（content 去空白非空、列表内不重复、status ∈ 三值）—— 不这么做会出现「一半校验过一半没过」的半更新 |
| 上限 | `TODO_MAX = 32` |
| **回合开始时清空** | DSH 口径：todo 是**这一回合**的执行清单 |
| 换会话时也清 | `agent_session_scoped_reset`。**修过的 bug**：原来没人清 ⇒ `/new` 之后清单还挂着上一条会话的「第几步」 |
| **列表不再注入回上下文** | 与 DSH 一致 —— 那是 UI/replay 状态，不是模型输入 |

**plan（`agent/plan.uya`）**：见 §7.4。
状态 `PlanState{active, pending}`，`pending` 是 DSH `set()` 语义的简化（这里只在 step 边界检查，
所以立即改 `active`）。进程级镜像 `g_on` + `tui_set_plan` 同步。
`plan_tool_exit` 要求 plan 非空且**首字符 `#`**；非 plan 模式调用报错。

### 9.3 会话目标（`agent/goal.uya`）

**持久化**：`<agent_home>/goal.json`（**手写 JSON**，`O_WRONLY|O_CREAT|O_TRUNC` 权限 420）。
字段：`id` / `revision` / `phase` / `objective` / `round` / `maxRounds` / `blocker` / `armed`。
读文件上限 65536，用 64 KiB arena 解析。

| 工具 | 语义 |
|---|---|
| `get_goal` | 读状态 |
| `create_goal` | `max_goal_rounds` 默认 20、**上限 200**；id = 上一个 id + 1，revision 1，phase active，armed true |
| `update_goal` | **CAS**：`goal_id` 与 `revision` **都必须精确匹配**（`goal-3` / `3` 两种写法都收），过期即报错并要求重取；动作 `edit/pause/resume/complete/blocked`；`blocked` 需要非空 `blocked_reason` 且 **`round < 2` 时拒绝**（DSH 规则：同一阻塞条件至少连续 3 轮）；每次成功 revision + 1 |

**CAS 是必须的**：goal 是**跨进程/跨回合**的持久状态，没有 revision 校验的话两个并发分支会
互相覆盖（后写的静默赢）。

**人类命令面 `goal_cmd_run`**：`/goal`（看状态/用法）、`/goal <objective>`（已有未完成 goal 时拒绝）、
`/goal edit <objective>`（phase/armed/round 不动）、`/goal pause|resume`（armed 跟着翻）、
`/goal clear`（**删文件**，不留 tombstone ⇒ clear 之后 id 从 1 重新开始）。

**控制词只有独占整行时才不区分大小写**，其余非空后缀都是**字面目标**
（例：`/goal pause after verification` 创建的就是那个字面目标）。

**与主循环的交互点**：派发 create/get/update 后立刻 `tasks_goal_reload`；启动/TUI 建历史时也
reload；内存投影放在 `term/tasks.uya`（`tasks_goal_ref`），面板读它。

**两个 `armed`**：`Goal.armed` 是**盘上**那份（跨进程持久、`get_goal` 报它），`g_goal_armed`
是**进程本地**的续跑授权（驱动器认的是它）。分开的理由见 §9.5 —— 合并的话 `--resume` 会把
上一条会话的授权继承过来。

### 9.5 同会话续跑驱动器（P58，`goal_round_admit`）

`phase=active` + 有授权 = 自动开下一轮。对齐 DSH 的
`@deepseek-ai/dsh-goal-round-driver`（本机 DSH 安装里的 `node_modules`，README.zh.md）：
每一轮是**同一个会话**里追加一条 user 消息，不是开新 agent、也不 fork 历史（那是 Ralph 那条线）。

**触发点 = idle 检查点**：`agent_goal_drive` 挂在主循环**真空闲**的那一支（TUI 与滚动模式各一处），
也就是「没有待提交输入、没有浮层结果、steer 已领取」的那一刻 —— 与 DSH 的
「`agent.status === 'idle'` 且没有竞争 prompt」同一个位置。

**六条让路/停止判据**（顺序即优先级）：

| # | 判据 | 行为 |
|---|---|---|
| 1 | 非交互 / 子代理 | 不驱动（管道与 CI 里没人叫停，而每一轮都真的发请求） |
| 2 | 进程本地无授权 | 不动（DSH：`activation !== armed`） |
| 3 | 无目标 / phase 非 active | 不动（complete / paused / blocked 都是「别再跑了」） |
| 4 | `round >= maxRounds` | 盘上改成 **blocked + blocker=round-limit + armed=false + revision+1**，本地授权收掉（DSH 的 `round-limit`：是终态，不是悄悄停下） |
| 5 | 记不上账（goal.json 写失败） | 一个字节都不发，授权收掉（不许出现「跑了没记账」的轮次） |
| 6 | 某一轮异常收场（非 OK / 非中断） | 停下，要人 `/goal resume`（DSH：**异常不自动重试**） |

TUI 那一条另加两道**人的优先权**：`tui_abort_state() != QUIT`（按了退出就不许再开轮；这里
**刻意不用** `tui_quit_wanted()` —— 那个还含 headless 的「注入键用完」，是自测的收工信号）
与 `tui_input_pending()`（fd 0 上还有待读的键就让行）。

**`round` 只在真正开轮之后才 +1**（`goal_round_admit` 里与 revision 一起落盘）：记账与投递成对，
只有记上账的轮次才会被投递。反过来（先投递后记账）一旦落盘失败就是个没有记录的轮次，下一轮
驱动又会拿同一个轮号重发一遍。

**正文**（模型可见）：`<goal_round>\nObjective: "<JSON 转义的 objective>"\nRound: N/M\n\n…`
—— 措辞与 DSH 的 `renderGoalRoundPrompt` 逐句对应。objective 走 `jw_str_into`：目标里带引号、
反斜杠或形似标签的片段只能是**数据**，不许在提示词里变成结构（DSH 的 `JSON.stringify` 同理由）。

**授权不跨进程**：`agent_session_scoped_reset`（启动 / fork / `--resume` / `/new` / `/resume`
都走的那个收口）把 `g_goal_armed` 清掉，**盘上的 phase / revision 一个字节不动**。要接着自动跑
必须由人明确授权（`update_goal action=resume` 或 `/goal resume`）—— 与 DSH 的
「会话 resume / fork 之后 active 目标是 disarmed」同一条。

**为什么把驱动器收在一个函数里**：本仓顶层函数表的余量是 **0**（CODING.md §6 / §16 坑 87），
所以「该不该开」与「记账 + 拼正文」合成一个 `goal_round_admit`，收口那段内联在 `agent_goal_drive`。
为此删掉了 3 个零调用的死函数（`js_view_to_buf` / `mock_glob_body` / `dg_run2`）
与一个恒 `false` 的占位（`g_tui_quit_flag_pending`），并内联了 `agent_goal_reload`
（纯转发）—— 净增声明数 **≤ 0**（实测 = 基线）。


### 9.4 workflow（`agent/workflow.uya`）

用 **Uya 的 `.ush` 脚本**（`uya run`）编排子代理，脚本里的钩子**代理回父进程**。

```
① 父进程写 <tmp>/uya-wf-<now_ms>/main.ush + 同目录生成 hooks.uya（钩子客户端，只用
   libc socket + std.json）
② 父进程监听 127.0.0.1:0（SO_REUSEADDR，getsockname 取端口）；
   端口与参数走环境 UYA_AGENT_WF_PORT / UYA_AGENT_WF_ARGS
   （libc 没有 setenv ⇒ 自己拼 envp）
③ fork + execve <uya-bin> run main.ush
   （--uya-bin 指向 /bin/bash、python3 之类时走「<bin> <script>」直接解释器模式；
    execve 失败子进程退 127）
④ 父进程边等脚本边 poll(lfd, 25ms)：每来一行 `op payload` 就真做，
   再回一行 {"ok":true,"text":…}
```

**钩子 op**：

| op | 行为 |
|---|---|
| `phase` | 拼 ` → ` 串 + 打印 |
| `log` | 追加 + 打印 |
| `agent_start` | `deleg_spawn(..., DELEG_KIND_SUB, 1, false)`，回 sub id |
| `agent_wait <id>` | 轮询到终态或父 timeout，`deleg_take_output` 增量回传 |
| `done` / `failed` | 收 result / 失败 |
| 未知 op | 回 `unknown op` |

脚本侧 API：`wf_args` / `wf_phase` / `wf_log` / `wf_agent_start` / `wf_agent_wait` /
`wf_agent` / `wf_done`。

**与 DSH 的差别**（如实记录）：脚本语言是 Uya、并发靠 `agent_start`/`agent_wait` **显式配对**
（DSH 是 Promise）、**只有一层**钩子协议。

**收尾**：每圈 `agent_pump_block()` 让用户叫停能杀脚本进程（`exit_code = 128+SIGKILL`）；
循环上限 `WF_MAX_STEPS * 40 = 10240` 圈；超限 SIGKILL；结束 `deleg_poll_all` 兜底。
输出 `# <name>: <desc>` / `phases` / `hooks handled: N, agents started: M, script exit: C` /
log / result；没调 `wf_done` 时给 `(the script finished without calling wf_done)`。

### 9.5 任务状态面板（`term/tasks.uya`）

**只做两件事**：

1. **纯函数**把四张表（todo 清单 / 后台任务 / 子代理 / 会话目标）折叠成「折叠行 / 展开箱体 /
   `/tasks` 报告」—— 不 poll、不读盘、不写终端，`now_ms` **显式传入**；
2. **一张面板块快照**：`tasks_panel_sync` 重建 → 与上次推送**逐字节比** → 变了才推。

**刻意不做的三件事**（都是性能决定）：

| 不做 | 理由 |
|---|---|
| 不在每帧重建文本 | TUI 只 `memcpy`；重建在 `tasks_tick` / 工具结果之后，**最密 1 Hz** |
| 不用行数统计后台输出 | 1 MiB 缓冲逐行扫太贵 —— 用**字节数** |
| 不给 job/deleg 加结束时间戳 | 要改状态机；所以**已结束项不显示时长** |

**状态字形两套值空间别混**：todo 用 `TD_*`、job 用 `JOB_*`、deleg 用 `DELEG_*`
（`view_status_glyph` 只认这一套）。

---

## 10. Git worktree

这一节回答：**怎么让 agent 在一个隔离副本里干活、干完怎么合回来、残留怎么收。**
逐字对齐 DSH 的 `git-worktree` preset。

### 10.1 配置口径

| 项 | 值 |
|---|---|
| `baseBranch` | 默认 `''`（探测 `main` → `master` → `HEAD`） |
| `branchPrefix` | `dsh/` |
| `worktreeRoot` | `.git/dsh-worktrees` |
| `mergeStrategy` | `merge`（`--no-ff --no-edit`） |
| `commitOnFinish` | true |
| `guardMainCheckout` | true |

**放 `.git` 下的理由**：`glob`/`grep` 会**剪掉 `.git` 子树** ⇒ 每个文件不会被搜出两遍。

**有意的偏离 DSH**：DSH 让模型**显式**调 `worktree start`；这里在**会话开始时自动建**
（对齐 preset 的 `agent/session-start` 钩子）。`start` 仍保留（幂等）。

**子代理共享父的 worktree**；非仓库/无 git ⇒ `phase = skipped` **照常干活**（fail soft）。

### 10.2 状态机

```
NONE ──wt_provision──▶
     ├─ 子代理 / deleg_depth > 0            → SKIPPED(SUBAGENT)
     ├─ rev-parse --show-toplevel 失败      → SKIPPED(NO_REPO)
     ├─ git 不可用 / 超时                    → FAILED
     ├─ slug 冲突（会话分支 == 基分支）       → FAILED(WT_E_BASE)
     ├─ 已注册（worktree list --porcelain）  → READY
     └─ worktree add [-b <branch>] <path> [<base>]
          ├─ 成功 → READY
          └─ 失败 → FAILED(WT_E_ADD)

READY ──wt_finish──▶ FINISHED
      └─wt_discard─▶ DISCARDED
```

**`wt_finish` 五步**：

1. `wt_commit_pending`：`status --porcelain` 非空 → `git add -A`；
2. commit message 默认 `"chore: session checkpoint"`。**本函数自己补 NUL** ——
   调用方从 JSON 解出的 message **没有 NUL**，实测 `bufx_cstr_len` 读到堆尾，
   merge 的提交说明后面黏上 `.rodata` 里的**工具 schema**（P48）；
3. 有暂存改动才 `git commit -m <msg>`（用 `diff --cached --quiet` 判断）；
4. `wt_merge_into_base`：共享 checkout 不在 base 上先 `git checkout <base>` →
   `git merge --no-ff --no-edit -m <msg> <branch>`；**冲突** → `git merge --abort` +
   `WT_E_MERGE`，报错文案给出修法（「在 worktree 里把 base 合进你的分支、解冲突、提交、再 finish」）；
5. `keep = false` → `wt_remove`：`git worktree remove --force <path>`
   （失败且目录已不存在 → `git worktree prune`）+ `git branch -D <branch>`
   （合并已完成，所以用 `-D`）；`keep = true` → 保留。

**接入点**：`agent_worktree_begin` 在建 system prompt **之前**调用（§3.2），成功后
`agent_workspace_apply` 把工作区切到 worktree；**切不过去则回滚状态、关模式、退回原工作区**。

### 10.3 命名

`wt_slug` = 会话 id 里 `[A-Za-z0-9]` 保留、其余全变 `-`，**截到 40 字节**，空则 `"session"`。

> 这个口径是 DSH 的 `sessionSlug` —— 因为**分支名/目录名要能安全进 git ref**（`/` 之类的
> 字符会让 `git branch` 直接报错）。路径 = `<repo_root>/.git/dsh-worktrees/<slug>`；
> 分支 = `dsh/<slug>`。

### 10.4 写闸门

| 闸门 | 判据 | 调用点 |
|---|---|---|
| `wt_guard_path_crosses` | 目标在 repo 内、却**不在** worktree 内 ⇒ 拒 | fsx 的 read **与** write |
| `wt_guard_bash_crosses` | workdir 在 repo 内、不在 worktree 内，**且命令里有变更类 git 子命令** ⇒ 拒 | shellx |

两侧都按「**前缀 + `'/'`**」比较（避免 `/x/ab` 被 `/x/a` 误判）。
命令里**点名了 worktree 路径就放行**。`wt_has_git_mutation` 逐词扫 `git <子命令>`
（词边界 + `git` 后必须跟**空白**，避免匹配到 `github`）。

**变更子命令表**：`add` `am` `apply` `checkout` `cherry-pick` `clean` `commit` `merge` `mv`
`push` `rebase` `reset` `restore` `revert` `rm` `stash` `switch` `tag` `update-index` `worktree`。

**提示词段 `wt_section_into`** 按 phase 给四种文案：skipped/failed、finished/discarded、
非 READY、READY（含 repo root / worktree / branch / base 与「**共享 checkout 是只读的**」纪律）。

### 10.5 残留回收（P49）

**为什么需要**：worktree 只在**显式** `finish`/`discard` 时删；会话正常退出**不会**替你 finish
（这是对的：没验完的活不该被自动合并），但**目录和分支留在那儿**。
真机实测：一个月攒下 **17 个残留（129 MiB）+ 25 个没人认领的 `dsh/*` 分支**。

**「确定是垃圾」四条 —— 全部都必须成立（缺一不动，宁可留着也不误删）**：

| # | 条件 | 为什么 |
|---|---|---|
| 1 | 本进程自己建的 READY worktree，**或** `reclaim` 动作扫到的某个残留 | 先划范围 |
| 2 | `git status --porcelain` **完全干净**（**不带 `--ignored`**） | `build/` 这类产物是常态 —— 真机 17 个里**15 个**都带 ignored 文件，带上 `--ignored` 就一个都清不掉 |
| 3 | `rev-list --count base..branch == 0`（**零提交**） | 有提交的活不能删 |
| 4 | **没有任何活着的进程**把它或它的子树当 cwd（`wt_any_cwd_under` 扫 `/proc/*/cwd`，`skip_pid` 传自己以免自锁） | 见下 |

> **第 4 条是大头。** 同一仓库可以同时开好几个会话，**别人那个「刚建好还什么都没干」的
> worktree 既最像垃圾、也最不该动** —— 只按「干净 + 零提交」判会把它清掉，**实测这种残留占多数**。
> 它顺带也保护「用户开个终端 `cd` 进去看一眼」。

**判定与删除都交给 git**：我们不自己 `rm`；只用 `git worktree remove`（**不带 `--force`**）
与 `git branch -d`（**不是 `-D`**）—— 这两道是 **git 自己的闸门，比我们的判据更硬**。
所以条件 2/3 是快速路径，条件 4 是防「邻居正在用」。`wt_reclaim_one` 失败时返回 false，
**不假装成功**。

**报文范围**：`wt_reclaim_consider` 只碰 `dsh/` 前缀的（`locked` 的明确保留），
其余**一根汗毛不动**。

**孤儿分支**（P49 补的另一半）：`git worktree list` 只能看到还挂着注册的条目；
目录被手工删掉 / prune 之后，分支成了**没有 worktree 的孤儿**（真机实测：清完 14 个目录后，
仓库里还躺 **25 条**零提交 `dsh/*` 孤儿分支）。判据只用一条硬的：**基分支..它零提交**；
有提交的一律留着（`git branch -D` 是人的事）；外加两条防御（还被 worktree 占着的跳过、
用 `branch -d` 让 git 兜底）。

**顺序有意为之**：先目录那条路（连带删分支）再孤儿分支，否则同一分支会被看两遍。

**会话退出回收 `wt_reclaim_own`**：**必须排在 `sess_close` 之前** —— 回收结果要落一条
`session/worktree` 日志事件。注释明确「**不在这里自动 finish**：没验完的活不该被自动合并」。
`reclaim` 动作对**子代理直接拒**（子代理共享父的 worktree，不许它来清）。

---

## 11. 显示层与全屏 TUI

这一节回答：**屏幕上那一屏是怎么算出来的**，以及为什么是这个形状。
本域 16 个文件、约 1.4 万行，是仓里最大的一块。

### 11.1 两套显示层：二选一，不是回退关系

| 层 | 文件 | 形态 |
|---|---|---|
| 滚动模式（`--no-tui`） | `term/tty.uya` + `term/view.uya` | 行式输出（每次工具调用**一行**）、思考行、子代理面板块、diff 正文 |
| 全屏 TUI | `term/tui/` 11 个文件 | 备用屏幕 + 帧 diff |

**交接点**：`agent_tui_start` 成功后设 `tty_sink_on = true` —— **从这一刻起所有显示字节都进
转录条目**，不再落终端。`agent_tui_stop` 里 `tty_sink_on = false` → `tty_title_end()` →
`tui_stop()` → `tty_raw_off()` → `sigx_disarm()`（顺序不能换：先停 sink 再退屏幕）。

**两者不是「TUI 挂了退回滚动」**：TUI 起不来（`cols < 32 || rows < 8`，或 `agent_tui_start`
失败）时 `cfg.tui = false` 并转 `agent_run_interactive()`，走的是**另一套**实现。
`view_render_block()` 仍被复用 —— 用它**生成**工具块文本（`tui_add_tool_block`），
所以工具块的文案只有一份真值。

`tty.uya` 是**唯一直接写终端字节的层**：termios、尺寸、行编辑、`ui_out_*` 渲染协议、
面板块、标题栈、显示列原语。`view.uya` 写的是 **`err_fd()`** 而**不是 fd 2** ——
因为 `tls_noise_mute` 可能把 fd 2 重定向到 `/dev/null`（§4.2）。
> P16 修的坑就是这条：显示层必须写到那个**还看得见的** stderr，否则 `--show-reasoning` 等于没开。

### 11.2 单线程 + 泵点

**为什么不做渲染线程**（踩坑 47，这也是全仓最重要的架构决定之一）：

> 机制**成立**（`libc.pthread`、`sys_tgkill` + 无 `SA_RESTART` 处理器 EINTR 唤醒，errno = 4）；
> 但**工具链堆并发分配 8/8 崩**（`double free detected in tcache 2`）、pthread 互斥不干净
> ⇒ 选「**单线程 + 泵点加密**」。

所以中断是**协作式**的，所有阻塞循环必须按 ≤50 ms 的粒度插泵点：

| 泵点位置 | 触发时机 |
|---|---|
| `llm_pump_input`（`net/llm.uya`） | 流式每 ≤50 ms |
| `httpc` 读响应头 / 非流式请求 | `poll(≤50ms)` |
| `httpstream` 头等待 + 每条 16 KiB TLS record 之后 | 分片处 |
| `deleg` 子代理等待 | 每 50 ms |
| `clipx` 贴剪贴板期间 | `tui_poll_tick()` |
| **`tui_poll_tick`**（`term/tui/hook.uya`） | **所有阻塞循环的统一入口** |

**`tui_tick` 是每帧的唯一动作**：`尺寸（含 SIGWINCH）→ 键盘 → spinner → 节流重绘`。

**「现在要不要停」**：`tui_abort_check()` —— TUI 下顺带 `tui_tick`；非 TUI 的交互模式服务一遍
键盘（整行进 steer、Ctrl-C = 中断）；管道/CI/子代理是**空调用**。
**headless 下不刷帧**：headless 的 poll 把「注入的键用完」当成 stdin EOF 并置 quit，
刷一下就等于让**每个工具循环立刻自杀**。

**派发点有三条**（这是「运行中的命令不再等 step 边界」的全部实现）：

| 派发点 | 哪些命令 |
|---|---|
| **泵点**（当场派发 + 当场画一帧） | 只读命令：`/status` `/help` `/tasks` `/sessions` `/goal` `/diff` `/watch`（**含** `/watch sub-N`） |
| **step 边界** | `/compact` |
| **主循环**（回合结束后） | `/continue` `/exit` 与其余；`/new` `/resume` **立刻回执** + 先中断当前回合 |

**插不进泵点的只有两段**：DNS 解析（≤5 s）与 TLS 握手（≤`timeout_ms`），都在工具链调用内部。

### 11.3 帧是怎么拼出来的

```
行模型        每行 = 若干段 (style, len)
   g_tui_text        所有行正文的连续缓冲
   g_tui_rowtab[256] 每行 {seg_start, seg_n, text_off}
   g_tui_segs[8192]  所有行的段按行序拼在一起
        ↓  行与行靠行号分开，不靠 '\n'
行编码       每行段 → SGR + 文本，追加进 g_tui_out，行边界记在 g_tui_out_off
        ↓
帧 diff      逐行 bufx_mem_eq 与 g_tui_prev 比
   ├─ 脏行 > 60% 或上一帧更长 → 全量（先 ESC[2J ESC[H）
   └─ 否则只对脏行发 cursor_to(r,0) + ESC[2K + 该行字节
   ★ 一次 sys_write 到私有 fd；g_tui_out / g_tui_prev 交换
        ↓
纯文本快照   tui_screen_text —— --tui-demo 与自测逐字节断言都走它
```

**「行与行靠行号分开，不靠 `'\n'`」**是核心：正文里可以有任意 `\n`（多行粘贴、代码块），
用 `\n` 分行会让「一行」的概念失效。段模型（`{style, len}`）则让「一行里多种样式」成为
一等公民 —— 这是 §11.5 行内样式的基础。

**`tui_screen_text` 必须与画帧同源**：否则自测断言绿而屏幕错。

**写到启动时 `sys_dup(1)` 的私有 fd**：`tls_noise_mute` 会把 fd 2 重定向到 `/dev/null`，
用 fd 2 画帧就会整屏丢失。

**时钟用 `sys_gettimeofday` 不用 extern libc `gettimeofday`**：后者会拉进 `libc.time`，
与 `libc.stdlib` **双定义 `CLOCKS_PER_SEC`**，split-C 下 multiple definition 链接失败。

### 11.4 键解码与输入编辑

**键解码**（`term/tui/keys.uya`）：字节流 → 按键事件。要点：

| 情况 | 处理 |
|---|---|
| UTF-8 | 逐字符编辑；续字节 `10xxxxxx` 是半个字符，绝不单独处理 |
| 切开的 `ESC [ D` | 一帧里可能只到一半，要**缓存跨帧** |
| SGR 滚轮 | `ESC[<b;x;yM` 解析 |
| xterm.js 无鼠标协议 | 会把滚轮伪装成 ↑/↓ —— 那一路就变成了**历史**（自测钉这一条） |

**输入编辑器**：UTF-8 按**字符**编辑、按**显示列**定位（宽字符占 2 列）、历史（`TUI_HIST_MAX = 32`）、
多行粘贴（括起粘贴 `ESC[?2004h`）、`pend`（切开的序列）。

**主要键绑定**（问 `--tui-demo` 或源码；这里只列易错的）：

| 键 | 行为 |
|---|---|
| `tab` | 输入为空 = **切 plan 模式**；否则插入两空格 |
| `shift+tab` | 输入为空 = 访问模式选择器；否则插入两空格 |
| `esc` | **运行中 = 中断本回合**；空闲 = 清行 |
| `F2` | 切换鼠标上报（**关掉即可拖选复制**） |
| `F11` / `ctrl+f` | 浮层全屏 |
| `alt+enter` / `ctrl+j` | 输入框内换行 |
| `ctrl+↑/↓` | 转录滚动（普通 ↑/↓ 是历史/光标） |
| 滚轮 | 滚 5 行；**不进历史** |

### 11.5 内容层：转录条目与 markdown

**转录条目模型**（`term/tui/entry.uya`）：6 种 kind（`USER` / `ASSIST` / `REASON` / `TOOL` /
`NOTICE` / `STEER`），**环形 512 条**，两条量上限（单条 `TUI_ENTRY_MAX = 256 KiB`、
总量 `TUI_TEXT_MAX = 4 MiB`）。

| 上限 | 值 | 理由 |
|---|---|---|
| `TUI_MAX_ENTRIES` | 512 | 条目环形表 |
| `TUI_ENTRY_MAX` | `262144` | 单条 256 KiB |
| `TUI_TEXT_MAX` | `4194304` | 转录正文总量 4 MiB |
| `TUI_REASON_TAIL` | 4096 | 思考条目只留最新一段 |
| `TUI_NOTICE_MAX` | 512 | **无它则一条 4 KiB 的网关错误体就能把整屏转录冲掉** |
| `TUI_IN_MAX` | 200000 | **与 agent 的 `MSG_CONTENT_MAX` 同值，改一处必须改两处** |

头部字形：`▎ 你`（USER 与 STEER 都是）、`◆ 助手`、`✻ 思考`。

**清洗规则**：正文层（`g_tui_text` / 行文本）里**不允许出现 ESC** ——
外来字节不许改写终端状态（否则一个恶意/损坏的工具输出就能改掉光标或颜色）。
宽度、换行、擦除**全按显示列**算。

**markdown 渲染**（`term/mdview.uya`，纯函数层）：

| 块级 | 行内 |
|---|---|
| ATX 标题（分级） | 转义 |
| 引用 | `` `code` `` |
| 无序与有序列表 | `~~删除线~~` |
| 任务清单 | `**粗体**` / `__粗体__` |
| 分隔线 | `*斜体*` / `_斜体_` |
| 围栏代码块（含语言标签） | `[文字](url)` / `![alt](url)` |
| GFM 表格 | |

**「样式随字节走」的意义**（P47 的关键设计）：把样式挂在**可见字节**上，而不是「一行一段」：

1. 折行落在**任何位置**都天然继承样式 —— 不需要「续行重开强调」的状态机；
2. 围栏代码块的样式由 md 层承载，不再依赖「从第 0 行扫一遍复原 `g_md_code`」的全局状态
   —— **旧实现滚到代码块中间就会串样式**。

它还顺带修掉了旧的 markdown-lite 的「长行静默丢 1–3 个字符」与「滚到代码块中间串样式」两处硬伤。
**`mdv_layout_into` 把「前缀字形 + 内容」放进同一条折行流**里算，绘制侧不再裁剪
（`tui_put_clipped` 只当安全网）。

**各显示区的取数来源**（改一处要连带改它的刷新时机）：

| 区域 | 来源 | 刷新 |
|---|---|---|
| 转录 | `g_tui_entries` ← `tui_sink_bytes`（**唯一入口**，来自 `tty_write` / `tty_reason_write`） | 每帧按需折行（宽度变了才重折） |
| 常驻状态区（1–2 行） | `g_tui_run` / `g_tui_run_label` / `g_tui_run_since_ms` / `g_tui_think` | 每次 `tui_tick`；`tui_set_run` 置脏 |
| 思考实时行 | `view_think_live()` → `tui_think_live()` | 每次收到 reasoning 增量 |
| 脚注左半 | `g_tui_cwd` / `g_tui_home` / `g_tui_branch` / `g_tui_ctx_pct` / `g_tui_cpu_pct` / `g_tui_mem_kb` | `procx_tick`（每 tick）；变了才置脏 |
| 脚注右半 | `g_tui_stats`（agent 侧**成品文本**）/ `g_tui_version` | `tui_set_stats` 逐字节比 |
| 信息行 | `g_tui_plan` / `g_tui_access` / `g_tui_model` / `g_tui_provider` / `g_tui_effort` | 各 setter 逐字节比 |
| 常驻任务块 | `tasks_latest()`（**只 memcpy**） | `tui_tasks_refresh()`（每帧拉文本） |

**脚注的退化规则**（`:499-507`）：统计行按 `" | "` 拆组、**从尾部**丢组并补 `…`；
`cwd` 是唯一弹性字段（少于 8 列整段丢）；**内存**是状态字段里唯一会**先**让位的
（32 列最小画布只剩 `ctx` / `cpu`，**`ctx` / `cpu` 永远不丢**）；没统计时右半区退回版本号。

**常驻状态区为什么钉在面板上方而不是留在转录里**：
转录铺满视口时，那条「转录最后一行」的状态行会被**挤掉** —— 长会话里屏幕上**一个动的字节都没有**
（踩坑 32）。

### 11.6 浮层与几何

**几何的唯一来源**：`tui_ov_box_w(base_w, cap_h, &w, &h, &left, &top)`（`overlay.uya:187`）。

| 参数 | 含义 |
|---|---|
| `base_w` | 形态自己的宽度观感（列表 60 / reader 78 / ask 与 input **内容自适应**） |
| `cap_h` | 形态自己的高度上界（列表 16 / reader-ask 20 / input 固定 4） |

`base_w <= 0` = 列表默认档（60 列，终端 < 70 退 `cols - 6`，下限 24）。
**全屏时** `w = 终端列数` / `h = panel_top` / `left = top = 0`。

> **为什么必须收敛成一个函数**：之前几何在**四份**绘制里各写一遍，全屏要动就得改四处，
> 漏一处就是「方框右边参差」（踩坑 42 一族）。
> **为什么是「一个函数 + 四个输出参数」而不是四个小函数**：函数表余量极小（§2.3），
> 拆成四个直接超容，`make build` 从干净缓存起必红（踩坑 87）。

**面板几何**：`panel_top = rows - panel_h - footer_h`；`panel_h` 夹在 `[2, 10]` 且 `≤ rows - 6`；
`footer_h = 1`。

**浮层种类**：

| 形态 | kind 前缀 | 状态 | 用途 |
|---|---|---|---|
| 列表 | `TUI_OVK_*`（18 种） | 条目 + 游标 + 过滤词 | 命令面板 / `/sessions` / `/help` / `/model` / `/permission` / `/worktree` / `/watch` 清单 |
| reader | `TUI_OV_READER` | 可滚动正文 | plan 审阅 / `/status` / `/tasks` 长文本 |
| diff | `TUI_OV_DIFF` | 左文件列表 + 右两栏 | `/diff` |
| ask | `TUI_OVK_ASK` | 问题 + 选项 + 自定义行 | `ask_user_question` |
| input | `TUI_OVK_INPUT` | 单行 | `/title` / 目标 |

**全屏（P53）**：`ctrl+f` / `F11` / `/fullscreen [on|off]` —— `tui_overlay_full(want)` 一个函数管
查询（`-2`）/ 翻转（`-1`）/ 关（`0`）/ 开（`>0`），返回**设置之后**的状态。

| 规矩 | 理由 |
|---|---|
| **只吃转录区**（终端列数 × `panel_top`），面板/状态区/脚注不参与 | 不做「盖住整屏」的真全屏 |
| 上限（列表 16 行 / reader 与 ask 20 行）**随之解除** | 全屏的意义就是「长内容一屏看全」 |
| **只改「画出来多大」，不改「画不画得出来」** | 「画不画」由 `panel_top` 判（fail closed）：**审批必须「看不见就不许做」** |
| 生命周期**按浮层一次性生效**（开/关浮层都清回 `false`） | 与 `g_tui_ov_want_w` 同一条纪律 |
| `input` 型全屏后仍是 4 行高 | 单行输入的语义；全屏给它的是宽度 |
| `/diff` 本来就占满转录区，全屏态对它无意义（开 `/diff` 时该态被清掉） | |
| 滚动模式没有浮层，`/fullscreen` 只回一行说明 | 两边要一致的「没东西可切」语义 |
| 没浮层时**不**顺手开一张帮助浮层 | 那是隐形副作用 |

终端高度不够（`panel_top < 5`）时浮层画不出来，由 `tui_overlay_available()` 的
**fail-closed** 语义管（审批不会「看不见却仍吞键」）。

**行偏移表 `TuiLineIdx`**（踩坑 68，本域最重要的一条性能设计）：

> 表里存的是每行的**终点**（存起点会在末行差 1 字节 —— 末行长度在「缓冲区以 `\n` 收尾 /
> 不以 `\n` 收尾」两种情形不一致，实测 reader 浮层画到末行多占一列、**右边框被顶出去**，
> 被 `--tui-demo` 逐字节对照当场抓住。存终点一个减法完事，O(1)）。

**生命周期与 wrap 严格绑定** —— `tui_entry_init` / `tui_entry_drop_oldest` /
`tui_transcript_clear` **三处都跟着重置，漏一处就是**「取行读到上一份内容的偏移」或堆泄漏。
表没建起来（malloc 失败）时退回线性扫描：结果**是同一个**，只是慢 ——
这样「取行」永远不会静默给空。

**结果 kind 的 one-shot 口径**：`tui_overlay_kind` 的 `close` 会把 `g_tui_ov_kind` 清零，
而它在 accept 里是**收尾**调用的 ⇒ 必须回 `g_tui_ov_done` 记的**结果** kind。
否则主循环读到的永远是 0，命令面板/会话列表选出来的被**静默丢掉**（`/exit` 与 `/sessions`
全「按了没反应」，踩坑 44）。

### 11.7 终端标题

`ctrl` 之外的第三个「会话身份」通道。三件事钉死（踩坑 39）：

1. **只写给真 TTY**（`tty_title_begin()` 门控）；
2. **直接 `sys_write`**，不能走 `tty_write`（sink 会把它吞成转录里的乱码）；
3. 统一 `tty_title_clean_into` 清洗截断（**前 5 词 / ≤40 B**，上屏 ≤80 B）。

`--continue` 的 `sess_open` 会清空标题。不支持 xterm 标题栈（`CSI 22 t` / `CSI 23 t`）的终端
会忽略压栈/弹栈，退出后保留最后写的标题（**故意不写空标题**）。

**执行中改标题（P46）**：`/title`、`set_title` 工具、模型自动起标题。
自动起标题的三条硬边界：

| 边界 | 说明 |
|---|---|
| **同步的** | 单线程（踩坑 47 起不了第二条线程）：排在空闲主循环里，只有「距回合收尾与距最后一次敲键都 ≥900 ms」才发 |
| **用户一动键盘就中止自己** | 那一轮标题不更新，下一条人类消息再试 —— 代价是标题偶尔「慢半拍」 |
| 后台请求**不读键** | §4.7 |

要彻底关掉用 `--no-title-auto`。

---

## 12. diff 显示层

这一节回答：**写工具的 diff 正文与 `/diff` 浮窗的数据从哪来、各自算什么。**

### 12.1 两条独立的链路

| 链路 | 文件 | 服务谁 | 数据来源 |
|---|---|---|---|
| **写工具正文** | `diff/render.uya` | `write` / `edit` 的结果文本 | **自己算**（LCS） |
| **`/diff` 浮窗** | `diff/model` + `gitcmd` + `rows` + `view` | 用户敲的 `/diff` | **git 算**（`git diff`） |

> **这不是重复实现**：前者要的是「这次写操作改了什么」（两段文本，两段都在内存里）；
> 后者要的是「工作区相对 HEAD 改了什么」（旧侧内容在 git 的 packfile/zlib/delta 里 ——
> **不 fork git 就得自己实现对象读取**）。取舍写在了 `gitx.uya:3-6`。

**gitx 与 shellx 的分工**：`shellx` 是**模型**发起的 bash（逐条批准闸门 + bwrap）；
`gitx` 是**用户** `/diff` 触发的只读查询 —— 不经 bash、不套沙箱、不走审批，**也不写任何东西**。

### 12.2 `diff/render.uya`：写工具正文

**只服务显示，不参与线上协议**（这条要记住：改它不会影响模型看到的内容）。

```
公共整行前缀（顺带用两个变量记最后两行做上下文，不用环形数组）
 → 公共整行后缀
 → 无变化则不输出上下文行
 → 中间段：两侧各 ≤ DIFFX_MID_MAX(60) 行才走 LCS 精细 diff，
            更大只给两行精确汇总（- (N 行旧内容) / + (N 行新内容)）
 → 行样式 "    " + "- " / "+ " / "  " + 内容，宽 w-6（< 16 时 w = 16），截断补 …
 → 头截断到 max(tool_lines * 4, 20) 行，超出追加 "    … (省略 N 行)"
```

| 常量 | 值 | 含义 |
|---|---|---|
| `DIFFX_MID_MAX` | 60 | 走 LCS 的中间段行数上界 |
| `DIFFX_MID_LINES` | 3721 | `(60+1)²` —— LCS DP 表大小 |
| `DIFFX_CTX_LINES` | 2 | 上下文行数 |
| `DIFFX_MAX_BYTES` | `2*1024*1024` | 采集上限 |

**「行」的口径与 `read` 工具一致**（`\n` 分隔，结尾换行不算多一个空行）——
不一致的话「read 看到 100 行、diff 说 101 行」，模型会开始怀疑人生。

**采集**：`diffx_init`（**幂等** —— REPL 每轮调用，不能每次 `buf_new`）、
`diffx_note`（**关闭态下连旧内容都不读**；超 `DIFFX_MAX_BYTES` 写
`(diff skipped: file too large)`）、`diffx_take`（**取即清**）。

**调用点**：fsx 的 `write` 在 `O_TRUNC` **之前**读旧内容（晚了旧内容就没了）；`edit` 亦然。

### 12.3 `diff/` 其余四个文件

| 文件 | 职责 | 关键不变量 |
|---|---|---|
| `model.uya` | 数据模型 / 状态 / 文件列表 / 假数据 | **`GdRow.l_off/r_off` 指向最近一次解析的文本**（`g_gd_textp`），在 `gd_open`/`gd_move`/`gd_refresh`/`gd_parse_into` 之后**失效** —— 渲染层每帧现取，**不许跨帧缓存** |
| `gitcmd.uya` | git 子进程调用 | **只读**：只用 `status` / `diff` / `rev-parse`，**绝不** `add` / `stash` / `commit` |
| `rows.uya` | unified diff → 行表 | 一次增/删块配对上限 `GD_RUN_MAX`（超了放弃配对，但**内容一行不丢**）；行表上限 `GD_MAX_ROWS`（超了置 `g_gd_rowcut`） |
| `view.uya` | 打开/刷新/查询/滚动/跳转/文本回退 | 任何失败**都不抛错**，落 `g_gd_err` 文本回给界面；失败时**状态不半更新** |

**`gd_` 前缀的归属**：`diff/` 的 5 个文件共用 `gd_` —— 这是 §2.4 说的**唯一例外**
（同一个历史模块的内部拆分，对外是一个整体）。

| 上限常量 | 值 | 理由 |
|---|---|---|
| `GD_MAX_FILES` | 400 | 文件列表硬上限 |
| `GD_MAX_ROWS` | 8192 | 行表上限 |
| `GD_MAX_DIFF` | `512*1024` | 单文件 diff 上限 |
| `GD_FULL_CTX` | 100000 | `-U` 参数：事实上「整份文件」 |
| `GD_TXT_CTX` | 3 | 截断 / 文本回退的上下文 |
| `GD_RUN_MAX` | 4096 | 一次增/删块配对上限 |
| `GD_HSTEP` | 8 | ←/→ 每次滚多少**显示列** |
| `GD_TXT_MAX_LINES` / `GD_TXT_FILE_LINES` / `GD_TXT_FILES` | 400 / 120 / 20 | 滚动模式文本回退的预算 |

**`g_gd_real`**：数据是真的从 git 来的还是 fixture 注入的 —— **假数据下不许去跑 git**
（没有仓库，`-C` 会指向未初始化的路径）。`gd_load_fixture` **必须从干净状态开始**
（不然标题会挂着上一次的工作区）。

**`gd_open` 的失败分级**：空工作区 → `NOT_REPO`；`gitx_available` 假 → `NO_GIT`；
`rev-parse --show-toplevel` 失败 → `NOT_REPO`；`status` 失败 → `NOT_REPO`。

**`gd_load_sel` 的三条降级**：

| 情况 | 降级 |
|---|---|
| 假数据 | 直接返回 true（既不清行表也不跑 git） |
| 文件太大（`gitx_last_truncated`） | 改用 `-U3` 重取 + note「文件过大：只显示改动附近的 3 行上下文」 |
| `rowcut` | note「行数超过上限，已截断」 |

`nrows == 0` 时还要区分三种「没有」：**仅文件模式变更**（如 `chmod`）/
**没有可显示的差异** / **没有可显示的内容** —— 这三种对用户是不同的信息。

**`gd_refresh` 失败时保留原列表与内容**，只把原因写进 note（不半更新）。

**跳转**：`gd_next_change`、`gd_row_is_change`、首/末改动、同文件环绕、跨文件 `gd_next_change_file`。

**非 TUI 的单列回退 `gd_print_text`**：`[diff] <工作区label> · N 个文件（HEAD ↔ 工作区）`，
逐文件 `--- <path>` + `tui_clean_into` 清洗（ESC/TAB/控制字节都换掉，P19 口径）后按
`GD_TXT_FILE_LINES` / `GD_TXT_MAX_LINES` 预算输出，超预算给提示「TUI 里的 /diff 是双列全文比对」。

**`/diff` 浮窗**（`term/tui/diff.uya`）：左文件列表（占宽 **30%**，夹在 18–36 列）+
右**旧/新两栏**（**不是 unified**），中间一条竖缝。数据来自 `diff/view` 的 `gd_*` 访问器，
**本文件只管画**。行表指针**每帧现取**（§12.3 的不变量）。

| 几何 | 值 |
|---|---|
| `TUI_DIFF_COLS_MIN` / `ROWS_MIN` | 60 / 11 |
| `TUI_DIFF_GUTTER` | 6（行号列 5 位 + 1 空格） |
| `TUI_DIFF_MARK` | 2 |

**配色三档（P36）**：整行铺底 `TUI_ST_ADD_BG` / `DEL_BG`，行内变化片段再亮一档
`ADD_HL` / `DEL_HL`。**配对行（MIX）两侧都铺底，上下文行不铺** —— 「一屏里到处都是底反而
看不清『哪几行改了』」。

**行内高亮切分**：**公共前缀 + 公共后缀**，只给中间段上亮底；切点必须落在 **UTF-8 字符边界**
（`tui_diff_char_start`，续字节 `10xxxxxx` 往回退），否则会把一个汉字切成半个。

**文件列表状态码配色**按 git 的 XY：`??` = ADD、`D`/`A` = ADD/DEL、`M`/`R` = WARN、其余 DIM。

---

## 13. 媒体：剪贴板与图片

这一节回答：**终端里的图片与剪贴板怎么进到请求里**，以及纯 Uya 能做到哪一步。

### 13.1 图片附件（`media/imgx.uya`）

多模态要**内联 base64**，而这中间要回答四个问题：**是不是图片/哪种、多大、装得下吗、存哪儿**。

**硬约束（纯 Uya 的现实）**：stdlib **没有 zlib/deflate、没有 JPEG 编解码** ⇒
**没法缩放或重压**。DSH 会把超预算的图重新编码到预算内；本项目只能「**接受原图**」或
「**明确拒绝**」—— 拒绝时说清超了多少。

> **这条约束决定了本模块只做判定、不做变换。** 尺寸解析**只读文件头**；
> 读不出来（畸形/截断）一律当「不认识的图片」**拒绝**，**绝不猜一个尺寸往下走**。

| 预算 | 值 | 来历 |
|---|---|---|
| `IMGX_DEF_MAX_BYTES` | `8*1024*1024` | 取 DSH 请求层的 **8 MiB**（更严的那个）—— 因为**没有编码器**，收下来也缩不小 |
| `IMGX_DEF_MAX_PIXELS` | 640000 | DSH `imagePixelBudget` 缺省 |
| `IMGX_MAX_PER_MSG` | 8 | DSH 单条上限 20，这里取 8（界面一次也粘不了那么多） |

**魔数与尺寸**：

| 格式 | 判定 |
|---|---|
| PNG | 8 字节签名 + 偏移 12..16 必须是 `IHDR`；宽高各 4 字节**大端**在 16/20；`n < 33` 直接拒 |
| JPEG | `FF D8` 起头，**必须走段链**（EXIF/ICC 段可以很长，尺寸段位置不固定），找 SOF0/1/2/3/5/6/7/9/10/11/13/14/15，宽高在段内 `i+5`/`i+7`（大端 2 字节），`SOS(0xDA)` 之后放弃，`seglen < 2` 判畸形（**避免死循环**） |
| GIF | `GIF87a` / `GIF89a`，宽高在 6/8（**小端** 2 字节） |
| WebP | `RIFF`+`WEBP`；`VP8X` 24 位（各减一）在 24/27；`VP8L` 签名字节 `0x2F`、14 位打包在 21 起的 4 字节；`VP8 ` 起始码 `9D 01 2A` 在 23..25、2 字节各 14 位在 26/28 |

**落盘是内容寻址的**：id = `sha256` 的 64 位十六进制，路径 `<dir>/<id>.<ext>`；
`imgx_store` **幂等**（已存在且大小相同就跳过）。

**目录 = `<agent_home>/attachments`** —— **不能用 `g_home`**：那个全局只在会话打开时才填，
而 `/image` 可以在会话没开时敲 ⇒ 实测那时路径退化成 `/attachments`、mkdir 建不出、
**必然落盘失败**。`cfg.agent_home` 在启动时就定下来。

**两处必须自己补 NUL**（都是实测踩过的）：

| 函数 | 不补的症状 |
|---|---|
| `imgx_store` | `sess_mkdir_p` 按 C 串扫 ⇒ 只建到**半截路径**，症状是「图片落盘失败」 |
| `imgx_load` | 按 `bufx_cstr_len` 扫会一路读到缓冲区后面的垃圾 ⇒ 症状是「文件明明在磁盘上，读回来却是 false」 |

**附件表的形态刻意选「路径 + 元数据」而不是「字节」**：历史里几十条消息各带几 MB 会把内存与
请求缓冲顶爆；字节只在**构请求那一刻**从磁盘读一次并立刻 base64。JSON 形状：

```json
[{"mime":"image/png","path":"…","w":1024,"h":768,"bytes":51200,"name":"shot.png"}]
```

**解析刻意「能认多少算多少」**：缺字段就跳过那一项，**绝不让一条坏记录废掉整段历史**；
kind 认不出用扩展名兜底，仍不认则**整项丢掉** —— 因为**认不出类型的图发出去只会得到网关 400**。

**批次语义**：`g_pending_imgs` 随**下一条**用户消息发出后清空（对齐 DSH composer 的
「附件跟着这一次提交走」）。构请求时 completions 用 `{"type":"image_url",…}`、
responses 用 `{"type":"input_image","detail":"auto","image_url":…}`；
`agent_request_img_extra` 按 **4/3 膨胀 + 4096 预留**算缓冲。

**展示**：终端**不渲染图片**，屏幕上只有一行
`⎿ 图片 <mime> WxH · 512.0 KiB · name` —— 这行就是它存在的**全部证据**，
所以宽高与大小必须是真的。

### 13.2 剪贴板（`media/clipx.uya`）

**为什么手写 X11 协议**：本机（deepin-terminal / X11）**没有** `xclip` / `xsel` / `wl-paste`，
而「粘一张截图给多模态模型」是核心诉求 —— 没有外部 helper 就得自己说协议。

**协议范围（刻意最小）**：

| 阶段 | 细节 |
|---|---|
| 连接 | `/tmp/.X11-unix/X<n>`（`DISPLAY` 的 unix 分支）+ `~/.Xauthority` 的 **MIT-MAGIC-COOKIE-1** 认证（family 256 = Local，名字 18 字节，display 号按 socket 名末尾十进制配对）；读不到 cookie 就**匿名试一次** |
| 请求 | `InternAtom` / `CreateWindow`（**InputOnly**，PropertyChangeMask）/ `GetSelectionOwner` / `ConvertSelection` / `GetProperty` / `DeleteProperty` |
| 数据 | `bytes_after` 循环取完；**`INCR`**（大图必然走这条）按 `PropertyNotify` 增量收 |
| 目标优先级 | **`image/png` → `jpeg` → `gif` → `webp` → `UTF8_STRING`** |
| 边界 | 只支持 X11 unix socket（不做 TCP 转发、不做 Wayland 原生协议）；Wayland 下走外部 helper 回落 |

| 上限 | 值 | 理由 |
|---|---|---|
| `CLIPX_MAX_BYTES` | `24*1024*1024` | 一张 4K 截图 PNG 通常 2–8 MiB，给到 24 MiB 足够；超过**明确拒绝、不静默截断** —— 半个 PNG 发给模型只会得到坏请求 |
| `CLIPX_TIMEOUT_MS` | 2500 | 整次读取（建连/认证/TARGETS/取数据/INCR） |
| `CLIPX_POLL_MS` | 20 | |

**五个实测踩到的协议细节**（每一条都值得单独记住，因为症状都指向别处）：

| # | 细节 | 写错时的症状 |
|---|---|---|
| 1 | `clipx_req` 的长度字段 = 整条请求的 **4 字节单位数**，**含 4 字节头与自己补的 pad**（先算 body pad **再**加头） | 服务端按短长度截断、请求体尾部被当成**下一条请求**开头，随后一堆 X 错误 |
| 2 | `clipx_call` 应答**就是成功** —— **不要**把 `head[1]` 当错误码 | `GetInputFocus` 的 `revert-to = 1` 被读成「错误 1」（实测） |
| 3 | `clipx_convert` 的 `deadline` 是**每一步**的预算，不是整轮总预算 | 当总预算时，前面握手 + 8 次 `InternAtom` 花掉大半，`ConvertSelection` 一进去就过期 ⇒ 表现为「**永远等不到 SelectionNotify**」 |
| 4 | `SelectionNotify` 的事件类型在 `head[0] & 0x7f == 31`，property 在**偏移 16** | 读成 `[12]`（那是 target）⇒ 拿非属性 atom 去 `GetProperty` **永远取不到数据**（实测日志 `ev first=159 type=0`） |
| 5 | `clipx_getprop` 的 body 是 `window(4) property(4) type(4) long-offset(4) long-length(4)`，**没有 delete 字段** —— `delete` 走请求头 data 字节 | 塞进体里 ⇒ 服务端把 `window` 解成 `delete`、其余全错位 ⇒ 「**读回来永远是空**」 |

**INCR 判定用「`format == 32` 且首块 4 字节」**这个特征，随后按 `PropertyNotify`
（type 28、state = 0 NewValue、atom 匹配）逐块 `GetProperty`，空块 = 结束；
累计超 `CLIPX_MAX_BYTES` 即失败。

**`clipx_paste`**：自己 `CreateWindow` 一个 InputOnly 窗口当 requestor ——
**用 root 会被对端拒**（实测拿 root 当 requestor **永远等不到 SelectionNotify**）；
`CreateWindow` 是**无应答**请求，紧跟一条 `GetInputFocus` 做 **Sync**
（不同步的话后面每条请求都会读到错位的一条消息）。

**读剪贴板期间 `clipx_read_exact` 里 `tui_poll_tick()` 泵界面** ⇒ 界面不假死、esc 也进得来。

**结果并入 agent**：`CLIPX_IMAGE` → `agent_image_attach_bytes(..., from_clip = true, cfg.input_image)`；
`CLIPX_TEXT` → TUI 插进输入行（**不提交**，可以接着编辑）/ 滚动模式直接打；
其余 → notice「粘贴失败：`<reason>`」。

## 14. 上限常量与不变量总表

这一节是**速查表**：改代码时先在这里找一眼，比翻源码快。
「理由」一列写的是**为什么是这个数** —— 数字本身可以改，理由不能丢。

### 14.1 上限常量

| 域 | 常量 | 值 | 理由 |
|---|---|---|---|
| bufx | 初始容量下限 | 512 | `buf_reserve` 的下限；小缓冲不值得单独优化 |
| bufx | 增长因子 | 2× | 摊还 O(1) |
| yamlcfg | `YN_MAX` / `YL_MAX` | 8192 / 8192 | 节点池与行表容量；DSH 配置远小于此 |
| jsonx | `js_obj_get` key 上限 | 120 字节 | 内部 key 缓冲固定 128 |
| sse | `SSE_LINE_MAX` | `262144` | 防畸形流把内存吃光；正常 SSE 行远小于此 |
| httpstream | chunk 长度行 / trailer 行上限 | — | 同上 |
| httpstream | `HC_PUMP_POLL_MS` | 50 | poll / 泵点粒度（= 「阻塞循环 ≤50 ms 插泵点」那条纪律） |
| httpstream | `HC_TLS_CHUNK` | 16384 | TLS record 明文上限；每条 record 之后插泵点 |
| httpc | 响应体上限 | 默认 `262144` | `--max-response` |
| llm | `LLM_MAX_CALLS` | 16 | `calls` 固定数组容量；槽位用尽 `llm_slot` 返回 -1 |
| llm | `LLM_EVENT_ARENA` | `262144` | 每事件 parse 的 arena；逐事件 reset |
| llm | `LLM_ERR_HEAD` | 240 | `err_text` 只留坏 payload / 错误体的**头部** |
| agent | `MSG_CONTENT_MAX` | `200000` | 单条消息入史上限（**与 `TUI_IN_MAX` 同值，改一处要改两处**） |
| agent | `HIST_TRUNC_MARK` | — | 超限裁剪的标记；head 预算 = `max - mark - 16384` |
| agent | `EMPTY_RETRY_MAX` | 1 | 退化响应每步重发额度 |
| agent | `request_bytes_needed` | `h.bytes*2 + 8192 + 8192 + model.len*2 + img_extra` | 请求缓冲预算 |
| agent | `TOOL_FLAT_STRIP` | 31 字节 | Responses 形状的 schema 前缀，去掉即 flat |
| compact | `cmp_prune_threshold` / `head` / `tail` | 8192 / 4096 / 1024 **码点** | 对齐 DSH `thresholdChars` / `headChars` / `tailChars` |
| compact | `CMP_BASH_MIN_BUDGET` | 512 | 低于此不剪 bash 结果（剪了也没信息量） |
| compact | `CMP_BASH_SIGNAL_PERMILLE` | 800 | 中段预算里信号行最多占 80% |
| compact | `CMP_BASH_LINE_MAX` / `CMP_BASH_MARK_ALLOW` | 200 / 160 码点 | 单行保留 / 标记预算预留 |
| compact | `retainRatio` | 0.16 | 压缩时保留最近原文的比例 |
| compact | 压缩触发线 | `floor(contextWindow × 0.8)` | 压力 = `usage_in + usage_cache_read` |
| instr | AGENTS.md 预算 | 65536 字节 | 每次请求固定注入，不能无限大 |
| fsx | `fs_read_limit` / `fs_read_max_line` / `fs_read_max_bytes` | 2000 行 / 2000 字符 / 51200 字节 | 行数默认 / 单行 / 选中行总量 |
| fsx | `FS_OBS_MAX` | 128 | 观察表条数 |
| fsx | edit 读文件上限 | 4 MiB | 再大就不该用 edit |
| fsx | `FS_PATH_MAX` | — | 路径缓冲 |
| search | `search_glob_max` / `grep_max` / `line_max` / `timeout_ms` | 100 / 250 / 2000 / 30000 | 与 DSH 一致 |
| shellx | `cfg.max_tool_out` | 65536 | out/err 各自的截断线（标记 `[output truncated]`） |
| shellx | 默认 timeout | 120000 ms | `--timeout-ms` |
| jobs | `JOB_MAX` / `JOB_BUF_MAX` | 8 / `1 MiB` | 槽位 / 输出只留内存尾部 |
| sandboxx | `SAN_MAX_ARGS` | 24 | bwrap argv 上限 |
| session | 会话 id | 16 字节 urandom | version 4 / variant 10 |
| session | 索引排序 | O(n log n) 归并 | 与老插入排序**逐字节等价**（比较键是严格全序） |
| session | goal 文件读上限 | 65536 | `goal_load` |
| delegation | `DELEG_MAX` / `DELEG_BUF_MAX` | 4 / `262144` | 槽位 / 管道缓冲（超出丢前缀并同步 `read_off`） |
| delegation | `subagent_output wait` 上限 | 600 次 × 100 ms、墙钟 30000 ms | 防无限等待 |
| delegation | `ralph` rounds | 默认 4 / 上限 20 | 防无限轮 |
| goal | `max_goal_rounds` | 默认 20 / 上限 200 | |
| goal | `blocked` 最小轮数 | `round < 2` 拒绝 | DSH 规则：同一阻塞条件至少连续 3 轮 |
| workflow | `WF_MAX_STEPS` | 256 | 钩子处理上限；循环上限 `× 40 = 10240` 圈 |
| worktree | `WT_ROOT` / `WT_BRANCH_PREFIX` | `.git/dsh-worktrees` / `dsh/` | 放 `.git` 下让 glob/grep 剪掉它 |
| worktree | slug 长度 | 40 字节 | 分支名/目录名要能安全进 git ref |
| worktree | `GITX_TIMEOUT_MS` / `POLL_MS` | 10000 / 50 | git 调用超时（按进程组杀） |
| diff | `GD_MAX_FILES` / `MAX_ROWS` / `MAX_DIFF` | 400 / 8192 / `512*1024` | |
| diff | `GD_FULL_CTX` / `GD_TXT_CTX` | 100000 / 3 | 「整份文件」/ 截断回退的上下文 |
| diff | `GD_RUN_MAX` / `GD_HSTEP` | 4096 / 8 | 配对上限 / ←→ 显示列步长 |
| diff | `GD_TXT_MAX_LINES` / `FILE_LINES` / `FILES` | 400 / 120 / 20 | 滚动模式文本回退预算 |
| diff | `DIFFX_MID_MAX` / `MID_LINES` / `CTX_LINES` / `MAX_BYTES` | 60 / 3721 / 2 / `2 MiB` | LCS 表与采集上限 |
| TUI | `TUI_MAX_ROWS` / `MAX_SEGS` | 256 / 8192 | 行表 / 段表容量 |
| TUI | `TUI_COLS_MIN` / `ROWS_MIN` | 32 / 8 | 与 agent 侧「终端小于 32×8 退回滚动模式」**同值** |
| TUI | `TUI_LOGO_COLS` | 66 | 低于此不画块字 logo |
| TUI | `TUI_MAX_ENTRIES` / `ENTRY_MAX` / `TEXT_MAX` | 512 / `256 KiB` / `4 MiB` | 条目环形表 / 单条 / 总量 |
| TUI | `TUI_REASON_TAIL` | 4096 | 思考条目只留最新一段 |
| TUI | `TUI_NOTICE_MAX` | 512 | 无它则一条 4 KiB 的网关错误体就能把整屏转录冲掉 |
| TUI | `TUI_IN_MAX` / `TUI_IN_MAX_TEXT` | `200000` / 4096 | 输入行上限（与 `MSG_CONTENT_MAX` 同值）/ 单行输入（标题 ≤80 B，防手滑粘贴） |
| TUI | `TUI_EVQ_MAX` / `HIST_MAX` / `WHEEL_STEP` | 512 / 32 / 5 | 事件队列 / 历史 / 滚轮一步 |
| TUI | `TUI_ASK_MAX_OPT` / `MIN_W` / `CHROME_W` / `EDGE_W` | 16 / 34 / 6 / 6 | DSH 的提问一般 2–4 个；最多 9 个数字直选键 |
| TUI | `TUI_OV_READER_MAX_H` / `W` / `MIN_PANEL_TOP` / `BODY_MAX` | 20 / 78 / 6 / `131072` | 框高 / 期望宽 / 再矮就别开 / 正文上限 |
| TUI | `TUI_OV_LIST_W` / `BOX_W_MIN` | 60 / 24 | 列表型默认宽 / 下限 |
| TUI | `TUI_DIFF_COLS_MIN` / `ROWS_MIN` / `GUTTER` / `MARK` / `HL_MAX` | 60 / 11 / 6 / 2 / 4096 | |
| TUI | `TUI_THINK_TAIL` | 1024 | 状态区实时行只留最新一段 |
| TUI | `TUI_LOGO_H` / `W` / `PAD` | 5 / 61 / 1 | 9 字形 × 7 列 − 2 |
| TUI | `TUI_SGR16_LEN` | 192 | = `TUI_ST_COUNT * 8`；每样式 8 个 SGR 参数槽（P36 从 4 扩到 8：256 色「亮前景+显式背景」是 6 个参数，4 槽会被**静默截断**） |
| tasks | `TASKS_BLOCK_MAX_ROWS` / `TASKS_*` | 12 / 20, 6, 10, 24, 8000, 262144 | 常驻块上限 / 进度条格数, 清单行, 标签列, 最小宽, tty 与 TUI 字节预算 |
| mdview | `MDV_MAX_COLS` / `MAX_LEVEL` / `URL_MAX` / `INLINE_DEPTH` / `INDENT` | 8 / 3 / 48 / 3 / 2 | 表格列 / 嵌套层 / 链接列 / 行内递归 / 缩进 |
| tty | `TTY_LINE_MAX` / `HIST_MAX` / `EVQ_MAX` / `BLOCK_TEXT_MAX` | 8192 / 32 / 16 / 8192 | |
| tty | `TTY_TITLE_MAX_BYTES` / `FALLBACK_WORDS` / `FALLBACK_BYTES` | 80 / 5 / 40 | 对齐 DSH preset |
| view | `VIEW_LINE_FALLBACK` / `AG_MAX` / `AG_INNER_MIN` / `AG_MSG_MAX` / `THINK_MS` | 80 / 4 / 30 / 320 / 80 | 面板与思考节流 |
| watch | `WATCH_BUF_MAX` / `WATCH_PREVIEW_MAX` | `262144` / 320 | 跟随缓冲 / 单行预览 |
| media | `IMGX_DEF_MAX_BYTES` / `MAX_PIXELS` / `MAX_PER_MSG` | `8 MiB` / 640000 / 8 | 见 §13.1 |
| media | `CLIPX_MAX_BYTES` / `TIMEOUT_MS` / `POLL_MS` | `24 MiB` / 2500 / 20 | 见 §13.2 |
| web | `WEB_MAX_QUERIES` / `MAX_RESULTS` / `MAX_USES` | 4 / 8 / 5 | 参数校验串写死 "at most 4" |
| web | snippet 截断 / 非 200 body 摘要 | 300 码点 / 400 字节 | |
| skill | `SKILL_MAX` / `DESC_MAX` / `BODY_MAX` / `PATH_MAX` / `ROOTS_MAX` | 64 / 500 / `262144` / 4096 / 12 | |

### 14.2 不变量清单（按「破坏了会怎样」分组）

**内存与所有权**

| 不变量 | 破坏了会怎样 |
|---|---|
| `Buf` 的 `ptr` 要当 C 字符串用必须走 `buf_append_cstr_z` | 系统调用把残留字节当路径一部分（莫名 `ENOENT`） |
| `buf_reserve` 失败不改 `ptr/cap` | 调用方拿到悬空指针 |
| 任何 `&Msg` 不许跨 `hist_push*` / `hist_reserve` 使用 | realloc 搬家后读已释放内存 |
| `chat_out_new` 必须配对 `chat_out_free` | 泄漏 content/reasoning/每个 call 的 id/name/args |
| `JsonStrView` 不许活过下一次 `arena_reset` | 读别人的数据或未初始化内存（零拷贝） |
| `js_obj_get_str_unescaped` 的产物是堆缓冲 | 调用方必须 `buf_free` |
| `GdRow` 偏移指向最近一次解析的文本 | 跨帧缓存会读脏（渲染层每帧现取） |
| `TuiLineIdx` 生命周期与 wrap 严格绑定 | 三处重置漏一处 ⇒ 读到上一份内容的偏移或堆泄漏 |
| 出参缓冲必须 `buf_empty()` 而非 `buf_new(N)` | 实测每次调用**泄漏 N 字节**（踩坑 92） |

**协议与序列化**

| 不变量 | 破坏了会怎样 |
|---|---|
| JSON 转义必须覆盖 `0x00…0x1f` **全部** | 网关 400，且该结果**永久留在历史里** ⇒ 之后每轮都 400（踩坑 27） |
| `jw_str_esc_len` 与 `jw_write_escaped` 规则一一对应 | 预算与实际写入不一致 ⇒ 缓冲溢出或截断 |
| `jw_str_into`（session）与 `jw_str`（jsonx）转义规则一致 | 「写进去能读回、发上去就 400」 |
| SSE 未终结事件**不冲刷** | 半截 JSON 被当事件解析 |
| `finish_reason` 未知值一律当错误 | 静默按正常收尾 ⇒ 空回复（§5.4） |
| `usage_in` = `prompt_tokens − cached` | 缓存命中被重复计入输入 token |
| responses 的 `input_tokens` 要减**两类**缓存 | 同上 |
| 工具调用按 wire index 累积 | 同帧多调用会串成一堆乱参数 |
| 历史里的 assistant(tool_calls) + N 条 tool 是**原子组** | 悬空 `tool_call_id` ⇒ 网关拒 |
| 重发的请求体必须与上一次**逐字节相同** | 自测 verdict 249 当场红（§5.4） |

**界面与终端**

| 不变量 | 破坏了会怎样 |
|---|---|
| 正文层不许出现 ESC | 外来字节改写终端状态（光标乱跳、颜色污染） |
| 帧写到 `sys_dup(1)` 的私有 fd，不是 fd 2 | `tls_noise_mute` 把 fd 2 指到 `/dev/null` ⇒ 整屏丢失 |
| 显示层写 `err_fd()` | 同上（P16：`--show-reasoning` 等于没开） |
| SGR 序列用数组字面量或逐字节拼，**绝不** `&"字面量"[a:b]` | codegen 生成「切片描述符地址 → char*」强转 ⇒ 屏幕乱码（踩坑 22，`make codegen-audit` 守着） |
| 一切宽度按**显示列**算 | 宽字符/UTF-8 错位 |
| 几何唯一来源 `tui_ov_box_w` | 四份绘制各写一遍 ⇒ 全屏改漏一处就「方框右边参差」 |
| `tui_overlay_available` 等 fail-closed 判据**一个字节都不许动** | 审批会「看不见却仍吞键」 |
| 浮层全屏**只改多大、不改画不画** | 同上 |
| `tui_overlay_kind` 必须回 `g_tui_ov_done` 的结果 kind | 主循环读到 0 ⇒ 选中项被静默丢掉 |
| headless 下不刷帧 | 每个工具循环立刻自杀 |
| `/watch` 有重入闸门 | `watch_tick → deleg_check → deleg_drain → pump → watch_tick` 无限递归，实测 SIGSEGV |
| 行偏移表存**终点**不存起点 | 末行差 1 字节 ⇒ 右边框被顶出去 |
| 表格收不下就**整块**退回普通行 | 内容一个字节都不丢 |

**并发与进程**

| 不变量 | 破坏了会怎样 |
|---|---|
| 阻塞循环 ≤50 ms 插泵点 | 界面假死、esc/ctrl+c 石沉大海 |
| 后端子进程一律 `sigx_reset_for_child()` | 子进程收到 TERM 会去写父的终端 |
| 子进程一律 `sh_child_detach_stdio()` | 命令偷走用户的终端输入 |
| 沙箱不可用**必须 fail closed** | 静默降级成不沙箱（用户以为隔离了） |
| `deleg_wait_slice` 用 `nanosleep` 不用 poll(fd<0) | 50 ms 等待变 50 ms 自旋，CPU 打满 |
| `deleg_reclaim` 会复位 `used` | 4 槽用满后子代理永久失败 |
| backlog：管道只承载终态答复，过程消息走会话日志 | `/watch` 读到管道 ⇒ 抢掉 `subagent_output` 的增量游标 |
| 回收「确定垃圾」四条缺一不动 | 会清掉邻居会话**刚建好还没干活**的 worktree（实测占多数） |
| 回收删除交给 git（`remove` 不带 `--force`、`branch -d` 不带 `-D`） | 绕过 git 自己的闸门 |
| `wt_reclaim_own` 排在 `sess_close` 之前 | 回收结果落不进日志 |

**会话**

| 不变量 | 破坏了会怎样 |
|---|---|
| 事件行 `seq` 连续递增 + 追加-only | 前缀不再是合法日志 |
| `sess_open_resume` 不按 cwd 重算路径 | 同 id 下造出无 header 的空文件，**会话劈成两半**（踩坑 48） |
| 恢复时工作区**必须在** `agent_hist_from_log` 之前定 | system prompt 的 `{{cwd}}`/AGENTS.md/技能根全求值错 |
| 索引同一 id 取**最后一条** | 用旧的 cwd/title |
| TUI 里 id 永不裁剪 | 选中项 id 从条目文本取 ⇒ 取不到 |
| 写入中间不补 NUL | 后续内容落在 NUL 之后，系统调用只看前半截 |
| 级联：`session.model` 的 `source` 标签要如实记 | `human` 被记错 ⇒ 低思考执行态会覆盖人的选择（§5.5.1） |

---

## 15. 边界：明确不做的事

这一节是**清单式**的：这些不是「还没做」，是**决定不做**。写在这里是为了让后来者知道
「这不是遗漏」，以及为什么。

### 15.1 架构

| 不做 | 理由 |
|---|---|
| 多线程（渲染线程 / 真抢占式中断） | 工具链堆并发分配 8/8 崩（踩坑 47）⇒ 单线程 + 泵点 |
| DNS 与 TLS 握手期间可中断 | 在 `lib/tls` 调用内部，插不进泵点（DNS ≤5 s、握手 ≤`timeout_ms`） |
| 明文 `http://` 的请求体写入分片泵 | 明文路径没有分片 |
| 改标准库 `lib/tls` | 见 §18 —— 缺陷在标准库侧，本项目在 agent 侧提供三档策略 |
| 换到 `uya 0.11` | `tls/https.uya`、`std/json/*`、`x509/verify.uya` 与 0.10 逐字节相同，但 `libc/syscall.uya`、`std/runtime/runtime.uya`、`tls/ssl/context.uya` 有差异，需重新验证 |

### 15.2 会话与界面

| 边界 | 说明 |
|---|---|
| **换会话只换「当前会话的」那段屏幕**（P39） | TUI 里 `/new`、`/resume <id>` 把转录清成「只剩新会话」（`/resume` 再回放历史）；但**滚动模式（`--no-tui`）不重画** —— 那边的正文是终端自己滚出去的。回放复用启动时那一份口径（最近 200 条 + 一条「更早的会话记录已省略」提示，注入类消息不回放） |
| **子代理面板里那条「最新消息」是父进程发给它的那句话**（P40） | 预览取 `Deleg.prompt`（首行、空白折叠、超长贴尾）；子代理 stdout 按 P11 口径**只在跑完时**才回传管道，所以「它刚说了什么」得等终态或 `subagent_output`（面板那个 `· N` 是已收输出行数，运行中通常是 0）。贴尾只收窄**显示**，`Deleg.prompt` 本身一个字节不动 |
| **`/watch` 的实时粒度是「事件」不是 token 级**（P42） | 见 §9.1；且 `/watch` 是**进程状态**（`--resume` 不回填）；被跟随的子代理跑完或槽位回收时跟随自动结束 |
| **浮层高上限 16 行**（非全屏） | `↑/↓`、`pgup/pgdn`、`home/end` 滚，标题栏 `↑`/`↓` 是溢出指示 |
| **浮层全屏只吃转录区** | 不做「盖住整屏」的真全屏，不做鼠标拖拽缩放/点击边框，不做「每个形态各自记住全屏偏好」 |
| **TUI 不做**鼠标点击/拖选/选择（滚轮做了）、可折叠卡片、分屏、主题切换 UI | 末端体验交给终端自己 |
| **终端里不渲染图片** | 屏幕上只有一行占位；也不支持缩放/重编码（纯 Uya 没有编码器，超预算只能拒绝） |
| **「选中文字复制」是终端自己的事** | TUI 默认开鼠标上报（为了滚轮），拖选被我们吃掉 ⇒ 想拖选要按 `F2` / `/mouse off`（或按住 shift 拖） |
| **`--resume` 只回填最近 200 条历史** | 注入类消息不回填；`--resume-dsh` 走同一条回填路径 |
| **滚动模式是纯文本字形、不做 markdown 渲染** | TUI 有颜色 + markdown |
| 终端 < 32×8 自动退回滚动模式；`cols < 66` 时块字 logo 退化成一行标题 | |
| **终端标题是 best-effort 的礼貌** | 不写空标题；导入 DSH 会话时按 `source.kind = "user"` 记一条 `session/title`，**不是新增事件类型** |
| **自动起标题是同步的** | 见 §11.7 |
| **退出与中断**：任何时刻都退得出去（P28） | 中断在**下一个 step 边界**生效；esc 当场杀工具；`ctrl+d` 5 秒内退出 |
| **工具目录跨模式恒定可见** | 前缀缓存不会因为模式变了而失效 |

### 15.3 markdown 渲染的边界（P47）

**不做**：代码**语法高亮**（围栏只给整块一个颜色 + 语言标签）、引用式链接 `[x][ref]`、
脚注、HTML 块、自动链接 `<url>`、setext 标题（`===` 下划线）。

**换行**仍是「一个逻辑行一段」，**不做** CommonMark 的软换行合并 —— 行数与原样一一对应，
读日志时不丢行。

**表格**：单元格**不折行**（每格一行；超列宽按显示列裁剪补 `…`），列宽按「反复收最宽那列」
压到下限 3，**列数 > 8 或收不下时整块退回普通行**（`|` 原样保留，**不丢内容**）；
单元格里的 `|` 用 `\|` 转义。

**删除线**靠终端的 SGR 9，不支持的终端只当普通文字（内容照常可见）。

助手正文与 plan 审阅浮层**共用**这一份渲染；**`/watch` 跟随浮层不套 markdown**
（那是事件行，会被 `---` / `|` 误判）；用户消息与思考仍只认行内反引号。

助手条目因此多一份「逐字节样式」缓冲（与折行文本等长），转录总量上限仍是 4 MiB。

### 15.4 协议与模型的边界

| 边界 | 说明 |
|---|---|
| **对话协议是刻意「极简」的** | 历史只带文本与工具调用；不做多模态之外的内容类型 |
| Responses 下**不回放 reasoning item** | 不发 `include: ["reasoning.encrypted_content"]`，也不发 `prompt_cache_key` / `prompt_cache_retention` |
| 历史按「外来消息」重放 | 只带文本与工具调用 |
| 工具 schema **不带 `strict`** | |
| **不做 404 之外的协议自动探测** | 换协议请显式 `--api=` |
| 不做 DSH 的 `reasoningEfforts` **模型级 clamp** | `reasoning.effort` 原样透传设置里的值（网关不认就 `--reasoning-effort off` 或 `--api=chat`） |
| **不发 `temperature`（默认）** | 用网关默认值 —— 这也意味着**轨迹是随机的**，A/B 对照要跑 ≥3 发（§5.5.3） |
| **不落盘 tool 输出 spill** | DSH 会 spill，本项目只留内存尾部（§6.5）—— 长输出任务的后半段会永久丢失 |
| **观察表不持久化** | 恢复会话后要重新 read 才能 edit（与 DSH 一致） |
| `goal` 的**异常续跑不自动重试** | 某一轮以网络/协议错收场就停下，要人 `/goal resume`（与 DSH 一致，§9.5） |
| `goal` 的续跑**授权不跨进程** | `/new`、`--resume`、fork 之后目标还在盘上但停着，接着跑要人明确 resume（§9.5） |
| **路径守卫是 best-effort，不是安全边界** | 要真隔离请用 `workspace-write` / `read-only` |

### 15.5 平台

目标平台是 **Linux x86-64**（代码里的 syscall / 常量按这个平台写）。
剪贴板只支持 **X11 的 unix socket**（不做 TCP 转发、不做 Wayland 原生协议）。

## 16. 用 Uya 写这类程序踩过的坑

（都已在代码里修掉，值得单独记住。）

1. **`std.json` 字符串零拷贝、未反转义**：`JsonStrView` 指向原始缓冲，`\"` `\n` 未解码；工具 `arguments` 先 `sv_unescape` 再 parse，否则报 arguments are not valid JSON。
2. **`buf_append_cstr` 不补 `\0`**：传给 `sys_open`/`execve` 要用 `buf_append_cstr_z`，否则残留字节当路径，报莫名 `ENOENT`。
3. **错误值不能当参数**：`fn f(err: error)` 非法；只能在 `catch |err| {}` 内用 `@error_name`/`@error_id`。
4. **union 构造是 `JsonValue.json_null()`**，不是 `JsonValue{ json_null: 0 }`。
5. **一行 `catch` 要带分号**：`catch { 0 as usize; }`，缺分号是语法错误。
6. **数组下标安全证明只认局部变量**：`h.items[h.len]` 报「数组索引安全证明失败」，先 `const idx: usize = h.len;`。
7. **模块级名字全局合并**：`Conn` 撞 `std.http.types.Conn`、`now_ms` 撞 `std.time.now_ms`；私有函数带项目前缀。
8. **`export fn main() i32`，不要 `!i32`**：split-C 下 `!i32` 生成的 `main_main` 与 `entry.uya` 冲突（conflicting types for 'main_main'）。
9. **`&"text"[0:n] as &const byte` 错**：那是切片，转指针拿到切片地址；要 C 指针传 `&buf[0]` 或 `slice.ptr`（`sys_write` 用 `s.ptr, s.len`）。
10. **`sys_fork` 是标准语义**：父进程拿子 pid，`pid == 0` 是子进程，子进程用 `sys_exit(n)`。
11. **TLS**：`ssl_write` 每次加密整段明文，按 `RECORD_MAX_PLAIN = 16384` 分片；`close_notify` 是 record 类型 21（alert），当 EOF 不当错误。
12. **`poll` 要处理 `POLLHUP`**：子进程「写完就退出」只给 POLLHUP 不给 POLLIN，漏掉就「命令早结束却读到超时」。
13. **从已解析 JSON 取字段还要再反转义（最隐蔽）**：内层 `content`/`path`/`command` 仍是未解码视图，`write` 把 `\n` 当两字符写文件；std.json 交出的字符串用前必过 `sv_unescape`。
15. **`std.json.parse` 零拷贝，用完 JsonValue 树前不能释放响应体（最严重，偶发）**：否则报 `response has no choices[0].message`；先复制响应体进 arena 再 parse。诊断代码同样守生命周期。
16. **`&"text"[0:n]` 是切片不是指针**：传给 `&const byte` 形参拿到切片结构体地址，`llm.uya` 比 `finish_reason` 时全部变 error；用 `s.ptr` 或 `bufx_eq_cstr`。
17. **checker 不抓「对已是指针的参数再取址」**：`fn f(o: &const T)` 里 `g(&o)` 得到 `**T`，C 编译阶段才报 `incompatible pointer type`。
18. **数组字面量初始化带结尾 `0`**：`var m: [byte: 9] = "got-term\n";` 报「容量不足：至少需要 N>=10」，要求 `N >= 字符数 + 1`。
19. **别对已是指针的参数再取址（同 17，`**History`）**：拆 `agent_turn_loop(cfg, h: &History)` 后遗留 `&h`，checker 过、C 只 warn、运行段错误。
20. **信号处理器在 uya 0.10.1 不可用**：`libc.signal.signal(SIGTERM, &handler as &void)` 一被调用就 SIGSEGV（`kill -TERM` 后 139）；恢复终端功能只能不做。
21. **`lib/tls` 把握手全过程写到 fd 2**（`https_debug`/`hs_debug`）：发请求期间把 fd 2 指向 `/dev/null`（dup2 往返），否则满屏 `[HS] ...`；`--tls-debug` 保留。
22. **把 `&"字面量"[0:n]` 传给 `*const byte`**：写的是切片描述符地址的字节（终端乱码，`\r\x1b[2K` 发不出去）；用数组字面量取址或 `as *const byte`；`make codegen-audit` 会扫。
23. **光标位置用「挂起换行」口径**：写满 `cols` 列时光标仍在最后一列，写满 80 列行号是 0（`tty_end_row_col`/`tty_rows_of` 同口径）；`ESC[0A` 上移 1 行，参数 0 宁可不发。
24. **流式输出期间输入行不在第 0 列**：擦除前先回该行起始列再 `ESC[J`，否则擦掉同行正文；`tty.uya` 维护 `out_col`/`out_wrap`/`start_col`。
25. **「影响加载的 flag」必须预扫**：`--dsh-home`/`--no-dsh-config`/`--strict-dsh-config` 因解析顺序静默失效（`--print-config` 仍显示 `source: dsh-settings`）；主循环前预扫，回归 `make e2e-config-flags`。
26. **「只压了一半」的历史是毒药**：`MSG_MAX = 64` 打满后 assistant(tool_calls) 已入史，端点永久回 `insufficient tool messages following tool_calls message`；追加要么成功要么整组回滚，尾部修复只丢不完整组（`hist_pairing_ok`）。
27. **请求体少转义一个控制字节=会话报废**：NUL 被 `json_write_str_view`（只转义 `"` `\` `\n` `\r` `\t`）原样落进 content，网关回 `invalid character '\x00' in string literal`；自实现 RFC 8259 转义（`jw_str`），反转义走 `sv_unescape`。
28. **`libc.signal.signal()` 处理器一收信号就 SIGSEGV**：裸 `rt_sigaction` 传 `sa_flags=0`/`sa_restorer=null`，缺 `SA_RESTORER = 0x04000000`；`src/session/sigx.uya` 声明宿主 `sigaction`（152 字节，`sig-abi` 断言）；工具链已修 `fad26acd`。
29. **装信号处理器后阻塞 `read` 返回 `EINTR` 不是 EOF**：一次 `SIGWINCH` 缩放就关掉 REPL；`catch |err|` 取 `@error_id(err)`，`== 4` 就 `continue`（`agent.uya`/`askuser.uya`）。
30. **第 21 条的 fd 2 静音会把显示层一起静音**：`--show-reasoning` 从未生效（写在 `llm_apply_delta`，处 `tls_noise_mute` 窗口）；`tls_noise_mute` 把 `dup(2)` 记进 `g_err_fd`，view 层用 `err_fd()`。
31. **多行块（子代理面板）擦除四条**：别用 `ESC[J`（会清可见正文）；块变矮禁「光标已在目标就不发」捷径；`cur_row` 相对块首存；列数从行首量起用 `tty_cols_between`。
32. **运行状态行被铺满的转录挤掉**：状态行与转录上界都是 `r < panel_top`；给状态区预留 `status_h = tui_status_rows()`，先扣掉再画转录；回归 `tui-status`。
33. **外来字节原样打给 fd 2 = 一屏乱码**：400 错误体回显整个请求，TUI 每行变 `· ` NOTICE；按字节截断切坏 UTF-8、控制字节上屏、无上限。修法 `tty_diag_escape_into` 唯转义、`out_diag` 唯出口（320 B 预览 + 一行），NOTICE 上限 `TUI_NOTICE_MAX = 512 B`。
34. **`read` 把读到的前缀当整个文件**：`fs_tool_read` 只读 `cap = 51200+65536` 前缀，total 是前缀行数、offset 越界假 EOF；改用 `fs_read_window` 流式数真实行数、撞上限回滚半行走 `(Output capped …)`；回归 `read-window`。
35. **固定容量把「参数有点大」报成 OOM**：`calls_json_from_chat` 的 `buf_new(8192)` 写不下就 `error: out of memory serializing tool_calls`；容量由 `jw_str_esc_len`+`calls_json_need` 算，上限 `MSG_CONTENT_MAX`（200 KiB）。
36. **「当前状态」和「刚才发生了什么」混在一个变量会被静默丢**：`tui_ov_accept()` 先写结果再 `tui_overlay_close()` 清掉 `g_tui_ov_kind`，take 后读 kind 永远 0；kind 另存 `g_tui_ov_done`（见 §2）。
37. **TUI 主循环丢命令返回值 → `/exit` 是摆设**：`agent_tui_command()` 三处写成 `_ = …`，直接输入或面板选 `/exit` 都不退出（`ctrl+d` 掩盖）；三处接上返回值，回归 `tui-pty` 改 `/exit`。
38. **浮层标题字节数写死 = 读越界**：`tui_overlay_list` 的 `tn` 是字节数按它 memcpy；会话标题写 44（实 38）、状态 46（实 22）、确认 6（实 9）；能用 `bufx_cstr_len()` 量就别写死。
39. **终端标题 OSC 三件事钉死**：只写给真 TTY（`tty_title_begin()` 门控）；直接 `sys_write` 不能走 `tty_write`（sink 会吞成乱码）；统一 `tty_title_clean_into` 清洗截断（前 5 词/40 B，上屏 80 B）。`--continue` 的 `sess_open` 会清空标题。
40. **「`/status` 没反应」四件事**：①面板派发后输入行留 `/`（拼成 `//status`），用 `tui_input_drop_slash_trigger()`；②无匹配静默，改还回输入行 + notice；③运行中面板结果等到回合末，加 `agent_tui_poll_pending_cmd()`；④`g_tui_ov_top` 是死变量，用 `tui_ov_box_h()`。
41. **首 token 只认正文 delta**：推理/工具回合几乎空着，偶尔打到时 tok/s 爆表（实测 6371，真值 ≈158.6）；判据改「任意非空增量」（`got_payload`：正文/`reasoning_content`/`tool_calls` 参数），元数据帧不算；回归 `stream-firsttok-*`。
42. **「被裁要补 `…`」的预算必须先扣一列**：`tui_put_clipped` 的 `…` 不在预算里，长行比方框宽 1 列；新增 `tui_ov_put_clipped()` 用 `tty_clip_bytes` 量后减一；回归拿会撑满的 `/permission` 量边界。
43. **uya 0.10 四坑**：①全局初始化式必须常量（`initializer element is not constant`）；②循环里 `const x = if …` 生成给只读变量赋值的 C（改 `var`+if）；③`match` 是保留字；④`buf_new` 缓冲无 NUL，画 Buf 用 `tui_putn`/`tui_put_clipped`。
44. **plan 模式只是提示词软引导时模型直接开工**：无 `exit_plan_mode` 调用；`write`/`edit`/`bash` 无闸门（`perm_allows_write()` 只看访问模式），审阅走 CLI `ask_write`+y/N 与 TUI 键队列互不相干；加 `plan_blocks_write()`+`tui_reader_wait`。
46. **「把键收下来」不等于「看键」，有东西在跑就退出不了**：阻塞循环只 `tui_poll_tick()` 不读标志 → 统一 `tui_abort_check()`；`llm_stream_style` 忽略 `TTY_EV_EOF`；`g_tui_interrupt` 没人复位；子代理抢 fd 0 → `tui_child_detach()`；headless 与 quit 标志拆开。
45. **`const x = if c { a } else { b };` 在 0.10 C 生成里变成给 const 赋值**：`make build` 报 `assignment of read-only variable '__uya_ifexpr_8'`；同类 `out` 已是 `&Buf` 时 `&out` 是 `Buf**`（C 阶段才报）；check 后必须再 `make build`。
47. **「TUI 渲染与 agent loop 分两条线程」被分配器否掉**：机制成立（`libc.pthread`、`sys_tgkill`+无 `SA_RESTART` 处理器 EINTR 唤醒，errno=4）；但工具链堆并发分配 8/8 崩（`double free detected in tcache 2`）、pthread 互斥不干净；选「单线程+泵点加密」。
48. **「`/status` 还是慢」慢在「请求在飞」那段**：①`hc_open` 读响应头纯阻塞（头压 3 s：2280→53 ms），加 `poll(≤50 ms)`+`agent_pump_light()`；②命令完只 `tui_mark_dirty()`，改派发后直接 `tui_render()`；③`agent_maybe_compact` 写死 `interactive=false`。
49. **「工作区不能滚动」三缺陷**：①xterm.js 无鼠标协议把滚轮转成 `ESC O A/B`（被当输入历史）→ 开 `ESC[?1000h`+`ESC[?1006h`，退出与信号打断都要关；②`ESC[1;5H` 解析错，CSI 收 p1/p2/p3、`mods = p2 - 1`；③长条目把 `max_scroll` 夹成 0，溢出指示 `^` 是死代码。
50. **第一列换了选中项口径要跟着换**：`/sessions` 改三列后 `agent_tui_item_head` 取到标题词，`/resume` 静默失败；取行尾 token（`agent_tui_sessions_head`）且须以 `session-` 开头；id 只在显示层裁；`index.jsonl` 同 id 多条按「取最后一条」去重。
51. **uya 0.10 的 `p[a: b]` 是「从 a 起 b 个字节」不是「到 b 为止」**：`p[0: n]` 两种语义同所以没露头；探针 `"0123456789"` 的 `p[2: 5].len` 打印 5；正解别用非 0 起点切片，先拷进 scratch Buf 再 `[0: len]`（正确例 `httpc.uya` 的 `head[i: name.len]`）。
52. **恢复会话时按当前目录重算日志路径**：`agent_session_open` 造出 0 字节无 header 新文件、`sess_write_index` 改写索引 cwd（同 id 两条）；日志只往原文件续写（`sess_open_resume`），工作区由 `session/workspace` 事件记录；用例须含 `git worktree`。
53. **`bufx_eq_cstr(p, n, lit)` 第三参必须是字面量**：按 `strlen(lit)` 量而 `Buf` 无 NUL，量偏大 ⇒ 静默 false（幂等分支走不到、每 step 补推上下文）；Buf 对 Buf 用 `a.len == b.len && bufx_mem_eq(...)`。
54. **`p[a: b]` 第二次咬人（第二参当终点）**：`sess_read_meta` 写 `data.ptr[pos: nl]`，小日志静默越过本行、大日志 realloc 走 mmap 读映射尾 SIGSEGV（`rc=139`）；修 `data.ptr[pos: nl - pos]`；验收 `sess-meta-big`。
55. **「拼在后面的清单」把前缀抹掉**：`mx_levels_into` 开头 `buf_reset(out)`，`/effort bogus` 只剩档位表；函数体不 reset 只追加（out 是调用方的），「没档位就一个字节都不加」写进契约；「返回串」与「往 out 加一段」是两种接口。
56. **`buf_free(&cfg.X)` 后又读 `provider` 参数（它就是 `cfg.X.ptr`）**：`agent_model_apply` free 后再 append，于是 provider 字段变乱字节；先拷进临时 Buf 再 free（`keep`）；参数可能是 self 视图的收口函数都要先拷贝。
57. **C 字符串参数：`Buf.ptr` 没有尾 NUL**：`worktreex` 把 `repo_root`/`branch` 等当 argv，git 报 `fatal: cannot change to '...'` 多出半截，用 `wt_nul(&buf)`；`agent_models_ensure` 拼 `$DSH_HOME+"/settings.yaml"` 没补 NUL 导致建目录失败。**P49 又踩了同一个形状两次**：`wt_list_into` 把 `g_wt.repo_root` 抄进一个新 `Buf` 时只抄了内容、没抄那个尾 NUL —— `git -C <ptr> worktree list` 于是报「fatal: cannot change to」并**静默**返回「(git worktree list failed)」，`/worktree list` 一直是坏的（真机上只表现为「列不出东西」）；新写的 `reclaim` 动作抄 `repo_root` 时同样漏了。`buf_new` 不做零初始化（`malloc` 原样），所以这类漏 NUL 一定读到堆里上一轮的脏字节 —— 抄路径进新 `Buf` 之后，**只要它要当 argv/路径用，就必须自己补 NUL**。
58. **`&out` 是「Buf 的指针的指针」**：`out` 参数本就是 `&Buf`，`buf_append(&out,…)` 把栈上描述符当缓冲区首地址 ⇒ 立刻 SIGSEGV；批量正则替换把 25 处输出追加一起改错 —— 改完必须 `make check` + 跑真路径。
59. **自测要跟真机 DSH 设置隔离**：`agent-presets.default=git-worktree` 与真机 `~/.dsh/settings.yaml` 相同，`--selftest` 每个 fork 子进程都建 worktree，真 PTY 轮整片红；`selftest_main` 开头 `wt_set_on(false); wt_reset();`。
60. **工具子进程继承父 TTY → 命令树被 job control 停住但显示「运行中」**：fd 0 原样继承，碰终端收 `SIGTTIN`/`SIGTTOU` 整组停住，而 `waitpid(WNOHANG)` 与还在跑同形；改 stdin→`/dev/null`+`setsid()`、waitpid 带 `WUNTRACED`、收尾读 `O_NONBLOCK`。
61. **别把 make 的「挂起」当「进程被停住」**：那是 `Hangup`（SIGHUP）不是 `Stopped`；make.mo 的 zh_CN 把 `Hangup` 译成「挂起」、`Stopped (tty input/output)` 译成「已停止 (tty 输入/输出)」；按这四个词对号入座。
62. **每样式 SGR 参数槽只有 4 个**：`TUI_SGR256` 装不下 `38;5;N;48;5;M` 六个参数，背景色被静默吃掉；表尺寸 `TUI_ST_COUNT*4`→`*8`、循环 4→8、暂存缓冲 32→64，扩槽不改既有样式编码；与踩坑 2 同族。
63. **自测「关掉 TUI」要关对开关**：`tui_set_headless(on)` 只置 `g_tui_headless`，而 `tui_active()` 看 `g_tui_on`，只有 `tui_headless_enable(on)` 两个都置；按模式分叉的断言先断言「真在这个模式里」。孪生：headless 轮须自开 `tty_sink_on = true`。
64. **uya 的 `{ }` 块在生成的 C 里不是作用域**：同一函数里同名局部变量（`win_round` 的 A0 `pb` 与新 G 段 `pb`）在**平铺的 C 函数体**里直接 `redefinition of 'pb'`，而 `make build` 末尾只报「链接失败」（cc 的真错埋在编译日志里、`-o` 那步根本没跑到）——看到「链接失败」先去 `build/uyacache/**/<file>.c` 里找 cc 报错；同一 `.uya` 函数里的局部名当全局取（本轮一律 `p40_` 前缀）。
65. **浮层开着就会盖住转录 → 「结果落进转录」的断言必须先关浮层**：headless 自测里 `tui_build()` 画的是一整帧，底对齐菜单正好压在转录最新那几行上，`tuis_screen_has("…")` 于是永远看不到刚写进去的 notice（P41 的 `tui-worktree` 轮实测：选 `on` 之后模式真翻了、文本也真写进了 `tui_add_notice`，断言照样红）。孪生：`tui_overlay_kind()` 在 `take` 之后回的是**结果**的 kind，所以「直接造一行 Buf 喂给 handler」之前必须先开一次浮层 —— 否则读到的是上一张浮层的 kind。
66. **运行中把输入行的光标藏了 → 「能打字却看不见光标」**：`tui_cursor_place()` 按 `g_tui_run == TUI_RUN_IDLE` 决定可见性，于是 `THINK`/`STREAM`/`TOOL` 期间 `tui_flush()` **每帧**补一个 `ESC[?25l`（真 PTY 实测运行中敲字 20×`?25l` / 0×`?25h`），而运行中插入点仍是活的打字目标（steer 收件箱；P43 起 `ask_user_question` 走弹窗，只在回落时才用输入行）⇒ 屏幕上没有插入点。可见性**只跟浮层走**：`run == IDLE || !tui_overlay_open()`；判定要看字节（冒烟只看标志位会把 `tui_flush` 那段改坏了还判绿）。同族陷阱：光标错误按**状态**而非**焦点**开关。
67. **「工具结果在请求体里」搜的是转义后的字节**：`assert contains(rx, "\"selected\":[\"beta\"]")` 永远搜不到 —— 工具结果作为 `messages[].content` **字符串**嵌在请求体里，引号已经被转义成 `\"`（P43 的 `tui-ask` 轮第一版就是这么假红的，判据必须写 `\\\"selected\\\":[\\\"`）。孪生两条：① `contains` 走 C 字符串口径（`strlen`），拿 `buf_new` 造的 needle **必须补 NUL**（踩坑 57 同款），否则一路读到堆尾巴；② 同一个字符串在两处各写一份字面量必然漂移 —— PTY 用例里父进程打的任务文本与 mock 断言的必须是**同一个常量**（第一版父进程打 "ask me something …"、mock 断言 "pick a name …"，round 0 当场红）。
68. **「session 选择框显示后很卡」慢在「取第 i 行都从头重扫」×「插入排序」**（本轮，不占阶段号）。两处各自独立：①**界面侧**：`tui_ov_line_at()` 为取第 i 行**从缓冲区第 0 字节重新扫一遍**，而 `tui_draw_overlay()` 每画一行都要从第 0 项数到目标项 ⇒ 一帧 = O(可见行数 × n²) 字节步；`tui_ov_accept()` / `tui_ov_sel_move()`（经 `tui_ov_filtered_count()`）同病。真机 842 个会话、80 列、底部按一次 ↑ 实测 **1.28–1.63 s**，而**同一张浮层按 HOME 跳到顶上只要 85 ms** —— 这一对数字就是根因的判据（慢的不是解析，是「跨了多少项」）。修法：条目/折行缓冲每次重写时**一次性**建行偏移表（O(n) 建、O(1) 取），外加「过滤器为空 ⇒ 第 fi 个通过项就是第 fi 项」的快路径（这条才是把绘制从 O(行数×n) 打到 O(行数) 的那一刀）。②**数据侧**：`sess_idx_sort_by_id` / `sess_idx_sort_by_at` 是**插入排序**（O(n²)），而会话索引是追加写的、`lastActiveAt` 天然升序 ⇒ 每次插入都把新记录一路挪到最前，正好是最坏情况（12800 行：升序 1475 ms / 降序 192 ms，`--list-sessions` 与 `/sessions` 一起受害）。修成自底向上归并（O(n log n)，比较键是严格全序 ⇒ 与插入排序**逐字节等价**）。
    * 复现与验收（before → after）：真 PTY 842 个会话「打开浮层 1617 → 46 ms」「底部方向键 1617 → 10 ms」；`--list-sessions` 12800 行升序 1475 → 205 ms（降序 192 → 207 ms，两种顺序拉平）。
    * 等价性：`--list-sessions` 在冻结索引与 9 份合成夹具上**逐字节相同**；`--tui-demo` 输出**逐字节相同**（50019 字节，布局一个字节没动）。
    * 本轮踩到的两个「假绿」陷阱，都写进自测：**(a)** 取行有「表不在就退回线性扫描」的兜底，兜底结果与查表**一模一样** ⇒ 只验文本/成帧预算的话，把表整个停掉照样绿（实测）。所以 `tui-sessions-big` 里补了两条真判据：查表路径 vs 线性扫描路径的**差分对照**（同一 i、逐字节），与「取末项 20000 次」的**自校准比值**（查表腿 vs 扫描腿，修好后 1 ms : 8166 ms；退回扫描则 ≈1:1 当场红）。**(b)** 行偏移表初版存「行的起点」、拿「下一行起点减一」当终点 ⇒ 末行在「缓冲区以 `\n` 收尾 / 不收尾」两种情形下算法不一致，末行长度算成 1 而不是 0，reader 浮层（计划审阅）画到末行多占一列、右边框被顶出去 —— 是 `--tui-demo` **逐字节对照**当场抓住的，所以最终改成存「每行的终点」（一个减法，O(1)，无歧义）。
69. **`/new` 之后任务清单还挂着上一条会话的（本轮，不占阶段号）**。清单在进程里是一张全局表（`todo.uya` 的 `g_todos`，`todo_write` 整表替换），但**换会话时没人清**：`/new` 只做了 `agent_session_close` + `hist_free` + `hist_init` + 统计 `st_reset`（后者在 `agent_history_begin` 里），清单原封不动 —— 用户看到的是新会话的常驻任务块与 `/tasks` 里还列着上一条会话的「第几步」。根因不是「清单没地方存」，而是**「进程状态」与「会话状态」没分家**：同一批表里，todo 清单只活在这一条会话里，后台任务/子代理是独立进程（P7 起 `/new` 的 `fsctx_init` 已经会 `jobs_init`/`deleg_init` 把它们复位，那是「新进程状态」而不是「清空历史」），会话目标在盘上（`goal.json`，按设计跨会话）。修法：把「清什么」收进一个 `agent_session_scoped_reset()`（只 `todo_clear`），挂在 `agent_history_begin` 里 `st_reset()` 旁边 —— 启动、fork、`--resume`、`/new`、`/resume` 走的都是这条路，一处收口。孪生一条：**清了状态还得推显示** —— 常驻块是「推」出来的（`tasks_panel_sync` 逐字节比快照后往下推），不重推的话清单虽已清空、屏幕上那块要等到下一个 1Hz 心跳才换，滚动模式更是要等下一回合；所以两个换会话的落点各补一次 `tasks_panel_sync`。
    * 验收（对照实验，两条都做）：`tui-switch` 的 D 段在**真实 globals** 上装夹具（清单 2/4 + 后台 1/2 + 子代理 1/1 + 目标 3/20）→ 敲 `/new` → 钉住「清掉的」（`g_todos.n == 0` 且屏幕上没有「任务 2/4」）与**「不该被清掉的」**（屏幕上仍有「目标 3/20」）两件事；同一条口径再罩一遍 `/resume`。①把 `agent_session_scoped_reset()` 的函数体停掉重编 → 该轮红 4 条（`/new` 与 `/resume` 各两条：`g_todos.n != 0` + 块里还挂着清单）；②只把 `/new` 落点的 `tasks_panel_sync` 去掉重编 → 红 1 条（块里还挂着清单，状态其实已经清了）—— 证明「清状态」与「推显示」两截都真在起作用，不是其中一条在兜底另一条。
70. **`--dsh-root` 与 `--dsh-home` 同类：决定「去哪儿读文案」，必须在预扫里生效**（P44）：主循环那次完整 CLI 解析排在 DSH 加载之后，而 `agent_texts_ensure()` 是**幂等的一次性**初始化（`g_texts_ready`），一旦在解析之前被叫过，`cfg.dsh_root` 就永远是空的 —— 症状是 flag 静默无效、persona 仍来自默认 preset 树，而环境变量 `UYA_AGENT_DSH_ROOT` 却正常（那条路在 `preset_path()` 里直接读 env）。判据：同时给 env 和 flag 各指一个**文案不同**的 preset 树，看哪个生效。**孪生一条：相对路径也静默失效** —— 这个值要到「第一次构 system prompt」才被读，那时进程已不在启动时的 cwd，所以 `--dsh-root testdata/x` 读不到、`--dsh-root $PWD/testdata/x` 才读到；修法是解析时就补成绝对路径（`cfg_set_dsh_root()`，预扫与主循环共用）。与踩坑 25 同因；回归补在 `e2e-config-flags`。
71. **completions 不发 `reasoning_effort` = 静默丢弃用户配置**（P44）：`--effort` / `--reasoning-effort` / DSH 的 `agent-default-model.reasoningEffort` 三条路径的值都进了 `cfg.reasoning_effort`、`--print-config` 也照实显示，但 `build_chat_request` 里没有那一段，于是**默认的 openai-completions 路由上模型按网关默认档思考**，用户配的 `max` 没有落到线上，也没有任何提示。同一份设置下 DSH 是发的（实测抓包 `reasoning_effort: "max"`），所以「uya 比 DSH 省」这类对比会掺进一个与 harness 无关的混杂项（实测偏差 41%）。修法：与 responses 同一条门槛（`cfg.api_reasoning`）发顶层 `reasoning_effort`，字段放最后以保住前缀缓存。**注意效果依网关而异**：官方端点同任务 `max` vs `off` 的 reasoning 占输出 51% vs 27%，autodl 网关 12% vs 17%（**P56 复测更新**：autodl 是**认**这个字段的 —— 同题 `none`→reasoning 0、`xhigh`→completion 1078，但中档之间差别被采样噪声淹没；另见 P56 段与踩坑 93：当时那句「不认」很可能混进了 `off` 被静默丢弃的效果）——收益主要是「配置不再说谎」，不是省钱。
72. **「TUI 里不能拖选复制文本」是鼠标上报的代价，不是渲染坏**（本轮修复，不占阶段号）：P25 为了让滚轮不被 xterm.js 伪装成 ↑/↓，**无条件**开了 `ESC[?1000h`+`ESC[?1006h`；而终端只要把鼠标交给我们，**它自己的拖选就没了** —— 左键按下/拖动全变成 `ESC[<b;x;yM` 事件灌过来，TUI 只吃滚轮（`b` 的 bit6）、其余**丢弃**（`tui_mouse_finish()`），于是拖选期间屏幕上什么都不动、PRIMARY 一个字节都不变。真机实测（deepin-terminal / qtermwidget，即用户环境）：同一块屏幕、同一个拖拽轨迹，**鼠标上报开着时拖选后 PRIMARY 仍是旧值（等于没有选中），手动发一条 `?1000l?1006l` 关掉之后立刻拿到 TUI 正文的文本**；再把 `?1000h?1006h` 发回去又选不动 —— 这一对对照就是根因的判据（render 与选区无关，屏幕重画也不会清掉已选区，实测 T+3 s 仍在）。所以这不是「哪一行画错了」，而是**一个必须可逆的开关**：修法是把鼠标上报做成可关的（`g_tui_mouse` + `tui_set_mouse()`，`tui_term_enter` 按开关发序列、运行中切换当场写 `1000h/1006h` 或 `1006l/1000l`），默认仍开（滚轮口径一字节不变），出口给三个：`F2`（`ESC O Q`，也认 `ESC[12~`）、`/mouse on|off`、启动期 `--no-mouse` / `UYA_AGENT_MOUSE=0`。**取舍写清楚**：关掉之后滚轮交给终端（不再翻转录），翻滚录用 `ctrl+↑/↓`（`ESC[1;5A/B` 那条已修好的路）或 `pgup/pgdn`；不想关也可以在开着时**按住 shift 拖选**（多数终端把这个当本地拖选）。防假绿对照实验：①`tui_term_enter` 改成忽略开关、恒发 `1000h` 重编 → `tui-mouse` 的 D4 当场红（`--no-mouse` 会失效）；②删掉 F2 的 SS3 映射 → B 段红；③`tui_set_mouse` 去掉运行中那段写序列 → D2/D3 红；④启动处把 `tui_set_mouse(cfg.mouse)` 写成恒 `true` → 真 PTY 那条腿红（`mouse=false` 的捕获里仍有 `1000h`）。**与既有口径的一致性**：这是「显式开关」而不是「猜终端」——不去探测、不自动关，因为关掉就等于放弃滚轮，必须由人决定。
73. **「选中一个代理」与「敲 `/watch sub-1` 没反应」是同一种坑：结果没人接 + 只读命令被当成给模型的文本**（P46）：用户报「输入 /watch 选代理没反应」「/watch sub-1 也没反应」，真机（真 PTY + 假网关 + `build/uya-agent`）复现出**三条各自独立**的静默路 ——
    ① 裸 `/watch` 的现役清单一直用 `tui_overlay_list(TUI_OVK_TASKS, …)` 开，与 `/tasks` 共用 kind，而那个 kind 在接收端的语义是「纯查看，enter 不派发」：主循环的结果分发只认 PALETTE / SESSIONS / ACCESS(_CONFIRM) / MODEL / EFFORT / WORKTREE(_CONFIRM)，**没有 TASKS 分支**，于是 `tui_overlay_take()` 把选中行取走 → 落到链尾 `continue` → **静默丢弃**。实测：`/watch` → 清单里 `sub-1 [running]` 在屏上 → ↓ 选中它 → 回车 ⇒ 浮层关掉、没有跟随浮层、没有 notice（三个判据 `list_gone=True` / `follow_opened=False` / `notice=False`）。
    ② `agent_cmd_watch` 只回 bool，「已开始跟随」与「目标无效」挤在同一格 ⇒ TUI 那条路分不出来，只好把回执整段丢掉：`/watch sub-9`（编号不存在）、`/watch off` 在 TUI 里都是**一片静默**（实测 `bad_target_visible=False`）；目标写错时连「用法」提示都看不到。
    ③ 回合运行中敲 `/watch sub-1`：`agent_tui_cmd_safe()` 在 steer 那条路上拿到的是**整行**、而它按整行相等匹配 ⇒ 不在只读集合里 → 被当成用户文本推进 steer 收件箱（模型收到一句 `/watch sub-1`）；而**就算它进了集合也不够** —— 提交队列只有两个消费者（`llm_pump_input` 在流式开始时、主循环在回合结束时），「等响应头」那一段（`hc_open` 的 poll 泵点）两个都轮不到。实测把网关按住 12 s：第二次回车之后 1.2 / 5 / 10 s 屏幕上都**没有**跟随浮层，直到回合收工才开出来 —— 这正是「趁子代理在跑时想看它」最需要的那一段。
    修法：①清单换成自己的 kind `TUI_OVK_WATCH_LIST`，主循环**与泵点**两条分支收它的结果（选中行 → 纯函数 `watch_line_id` 取编号 → `agent_watch_start`），游标默认落在**第一个代理行**（第 0 行是表头，不放的话「打开就回车」只会得到一句「没认出编号」）；②返回值换成落点码 `WATCH_CMD_LIST/STARTED/STOPPED/BAD`，BAD 与 STOPPED 在 TUI 里落 notice（滚动模式照旧打回执）；③带参数的 `/watch` 进只读集合，泵点上由 `agent_steer_line()` 当场派发 —— 并为此补了 `tui_peek_submit()` + `agent_pump_submitted_cmd()`：**只读命令**用掉队列里那一行，其余行一个字节都不动（留给流式循环的 `TTY_EV_SUBMIT` 语义）。顺带把两处**测试自身的假绿**也修了：④假网关按「`WATCH_MARK` 在不在请求里」判父子，而助手那条 `tool_calls` 的**参数里会回显提示词**（实测父代理第 2 条请求里 MARK 计数 = 1）⇒ 父代理的收尾请求被误判成子代理收尾，`PARENT_HOLD_SECS` 那个「把父代理按住」的窗口根本没生效，`--mode running` 那条腿连旧代码都能「过」；改成按「父代理那句任务在不在请求里」判（网关日志回到 `REQ #2 kind=parent-final` + `HOLD parent-final 12s`）。⑤P42 的两个 selftest 轮（`watch-render` / `watch-poll`）的返回值 `wch0`/`wch1` **声明了却没进 `SELFTEST PASS` 的聚合条件** —— 渲染改坏整套 selftest 照样绿；现在 `wch0 && wch1 && wch2` 都在条件里（对照：把 `watch_line_id` 改成恒 `true` 重编 → `watch-pick-parse` 红 8 条 + `SELFTEST FAIL`）。

74. **折行与绘制各扣一次列 = 长行静默丢字**（P47）：正文的 markdown-lite 曾经把宽度算在两个地方 ——
   `tui_wrap_into` 按 `cols - 6` 折，绘制侧 `avail` 按 `cols - TUI_BODY_COL - 3` 给，列表/代码行
   在 `tui_draw_assist_line` 里再扣 2 列。三个数字谁也对不上谁，结果是**每一行都丢 1–3 个字符、
   再补一个 `…`**（实测 60/80/100 列下 100 字符的代码行只显示 97 个、60 个汉字只显示 58–59 个）。
   为什么没人早发现：`…` 看着像「正常的截断」，而丢的又是行**尾**那几个字符 —— 只有拿连续
   同种字符（`QQQQ…`）做夹具、并**统计屏幕上出现了几个**才量得出来（看文本「像不像」不行）。
   修法是结构性的一条：预算只由 `tui_entry_indent_cols()` 一处给，折行与绘制都问它，且把
   「前缀字形 + 内容」放进**同一条折行流**里算；绘制侧不再裁剪（`tui_put_clipped` 只当安全网）。
   教训：**同一个量在两处各算一次**，迟早会漂；宁可在折行侧算成最终形态、绘制侧照抄。
   回归落在 `tui-md` 的 C 段（「不丢字」），对照实验见 §6 的 P47 条。
75. **样式挂在「帧级全局」上，滚到中间就串**（P47）：旧的代码围栏状态是 `g_tui_md_code` —— 一个
   全局 bool，`tui_build()` 每帧开头复位、浮层则「从第 0 行扫到窗口首行」复原。于是窗口一旦落在
   代码块**中间**（往上翻、或计划正文很长时），从 0 起算的状态必然是错的：代码行掉样式、闭合围栏
   被当成「开始」、之后的正文整段被染成代码样式。修法不是「把复原扫描写对」，而是**换掉承载方式**：
   排版时就把样式**逐字节**落在可见文本上（`mdview` 输出与行文本等长的样式数组），绘制只按字节取色
   —— 样式随字节走，折行/滚动/浮层从哪儿开始都对，顺带省掉浮层那次 O(窗口首行) 的复原扫描。
   教训：**需要按窗口位置重算的渲染状态，本身就说明它挂错了地方**。
76. **`mc` 是 uya 的关键字，当标识符用会报「意外的 token」**（P47）：给任务清单写
   `const mc: byte = ...` 时解析直接失败（`mc` 是 uya 的宏构造关键字），编译器只报
   「意外的 token 'mc'」而不说「这是保留字」。同一个坑的邻居：**`&arr[i]` 的边界证明**——
   循环条件是「运行时值」（如从 out 参数带回来的列数）时证明器认不出来，得写成
   `while i < n && i < MAX`，或者干脆取 `&arr[0]` 当基址指针（本轮表格的列宽数组就是这么过的）。
77. **手数字面量长度 = 屏幕上的 NUL 与错位**（P47，自测当场抓到的自身缺陷）：`mdv_put(t, m, "· ", 4, …)`
   把 3 字节的 `· `（U+00B7 两字节 + 空格）当成 4 字节，于是多复制一个字节 —— 屏幕上就是
   `· \0项目一`（NUL 被 `tui_rows_have_nul` 抓住，任务块/状态区的 `…` 也一起挪位）。修法是
   一律走 `mdv_puts`（内部 `bufx_cstr_len`），把「长度」这件事只留一个来源。同族两条：
   拿 `bufx_cstr_len` 去量 `buf_new` 造出来的**裸 malloc** 缓冲区（不保证 NUL 结尾，会读到堆尾巴，
   踩坑 57/67 同款），以及**假判据**——「整屏里有 `…`」这条断言会把脚注缩略与任务块
   「还有 N 行」的 `…` 也算进来，必须**按行、按字面量**定位。

78. **「取第 k 行」两处各写一遍 = 同族 O(n²) 修了一半**（P47）：踩坑 68 给**浮层**的条目
   与 reader 正文都挂了行偏移表（`TuiLineIdx`，取行 O(1)），但**转录条目**那条路
   （`tui_entry_line`）当时漏了 —— 它仍然「为取第 k 行从 wrap 头部重新扫一遍」，而 draw
   循环对每个可见行都调一次。于是同一个坑在另一处又活了：一个几 MiB 的长助手正文进转录
   之后，**每一帧**都要几秒（`tui_build_chat` 实测 2819 ms/帧），贴尾也一样、滚轮与思考行的
   重绘把界面拖死。教训有两条：① 同一族的缺陷**要么全修、要么在注释里点名剩下的那处**
   （当时只修了看得见卡顿的那两处，条目那条没被触发就没人管）；② 「性能问题」不一定在新
   代码里 —— 这次是给新渲染做稳健性扫查时顺手量出来的，**修完渲染那部分才开始看整体帧价**。
   修法与踩坑 68 逐字同源：折行后 `tui_lineidx_build()` 建表 O(n)，之后取行 O(1)；
   生命周期与 wrap 严格绑定（`tui_entry_init` / `tui_entry_drop_oldest` / `tui_transcript_clear`
   三处都跟着重置，漏一处就是「取行读到上一份内容的偏移」或堆泄漏）。
79. **「后台请求」必须对输入完全透明 —— 否则用户敲的命令会被拼坏**（P48，本轮被自己的验收抓到）：
   自动起标题要发一个**用户没发起**的侧路请求，第一版把它放在回合收尾同步发，于是踩了两个坑：
   ① 它在流式期间照常读键盘（`llm_pump_input`），用户那几秒里敲的字被半路取走 —— `/` 进了我们的
   缓冲、`status` 还留在终端里，两个字节一拼就是 `//status`，屏幕上显示「未知命令」；
   ② 更隐蔽的是**存量缺陷**被它暴露：命令面板的结果在泵点里若被判为「不安全」（要等 step 边界），
   `agent_tui_palette_apply` 里那句收走触发用 `/` 的 `tui_input_drop_slash_trigger()` 就一直没跑，
   输入行里那个孤零零的 `/` 陪着用户的下一条命令一起被提交 —— 同样得到 `//status`。判据是
   p30-check 的 `status-during-compact`（`/compact` 之后紧接着敲 `/status`，浮层必须 ≤300 ms 出来）：
   修前稳定红（不只是慢，是整条命令被吞）。修法两处：**①后台请求不读键盘** —— `g_bg_request`
   让泵点退化成「只刷帧 + watch 跟随」，并且只在**两段静默**（距回合收尾、距最后一次敲键各
   900 ms，`tui_last_key_ms` 由唯一的键盘入口记）之后才发；发出去之后 `agent_bg_input_pending()`
   一发现终端缓冲里有待读字节就让这次请求自己中止（标题这一轮不更新，下条消息再试）；
   **②`/` 的收走从「派发时」提前到「accept 时」**（`tui_ov_accept` 里按 kind 判断），
   三条派发路径（主循环 / step 边界 / 泵点）就不会再各漏一次。**教训**：
   「锦上添花的后台任务」在单线程 harness 里就是「一段会占住主循环的时间」，
   要么它让路给用户，要么它就不许启动 —— 没有第三条路。

80. **`worktree` 工具的 `finish` 会把提交说明写成「传入的 message + 堆尾巴」**（P48 收尾时发现，**存量缺陷**）：
   本线做完 P48 调 `worktree finish` 合并回主干时，那条 **merge commit 的说明被污染**了 ——
   我传的是 `P48：会话标题可在执行过程中修改（…）`，落盘却是
   `…（…）:"function","funct1"type":"function","function":{"name":"get_goal",…`，
   后面黏的正是 `.rodata` 里**工具 schema** 的一段。根因是**同一个 `Buf` 的两种口径混用**：
   `wt_finish(msg)` 把 `msg` 当 C 串（`bufx_cstr_len` / `buf_append_cstr`），而工具那条路
   的 `msg` 来自 `js_obj_get_str_unescaped` → `sv_unescape_to_buf` → `sv_unescape`，
   **只写内容、从不补 NUL**（`jsonx.uya` 里那个函数没有一处 `append_byte(…, 0)`）⇒
   `bufx_cstr_len` 一直读到堆里的第一个 0 为止，读到多少字节完全看堆布局。
   **为什么一直没红**：`worktree` 轮的既有断言是 `wt_finish("p37 merge" as &const byte, …)`
   —— 自测直接传**字面量**，字面量天然带 NUL，正好绕过这条契约；而真机走工具入口，
   message 是 JSON 解出来的，必踩。修法两处**都要**（各自单独回退都会让新轮当场红）：
   ① `src/vcs/worktreex.uya` 的 `wt_finish` 在自己拼完 `cmsg` 后补一个 NUL（**契约在本函数收口**，
   连带 `wt_do_commit` / `wt_merge_into_base` 两个下游消费者一起安全，默认说明那条分支同样受益）；
   ② `src/agent/agent.uya` 的 `worktree` 工具在把 `msg` 交给 `wt_finish` 前也补 NUL（调用方不赖账）。
   回归：新增 `worktree-tool-msg` 轮 —— 走**真工具入口**（`wt_tool_worktree` + JSON
   arguments，message 由 JSON 解出来）跑一次 finish，再用 `git log -1 --pretty=%s` 把
   提交说明读回来**逐字节**比对；读越界会多出后面的字节，断言当场红。
   与踩坑 57/67 同族（「`buf_new` 造的东西必须补 NUL 才能当 C 串用」），
   但这次踩在**函数间的口径契约**上，而不是自测夹具里。

81. **「文本跑出框外」不是宽度算错，是「帧里的一行内部带着换行」**（修复，不占阶段号）：
   用户报「提问的窗口内容很长时没有自适应，而且现在文本会跑出框外」—— 两条症状、三个根因，
   而且**都不是渲染算错**：
   * **① 换行被原样送进「帧里的一行」**。帧的每一行是 `g_tui_text` 里的一段，行与行之间靠
     **行号表**（`g_tui_rowtab`）分开，不是靠字节里的 `'\n'`；段内再出现 `'\n'`，终端就当换行 ——
     那一行被拆成两行画出来，**后一行从第 0 列开始**，方框右边框再也对不齐。实测（三行问题）：
     第 2、3 行整个落在框外，右边框孤零零留在上面。同族两处：问题正文走 `tui_clean_into`
     （**故意保留 `\n`**，那是给多行正文用的），标题**根本没清洗**（`header` 里的 `\n` 与 ESC
     原样进帧 —— ESC 还能改写终端状态，「正文层不许有 ESC」的不变量当场破）。
   * **② 宽度上限被写死**。P45 的自适应把上限钉在 `TUI_ASK_WANT_W = 78`（= reader 的宽度档），
     于是宽终端上长问题也只画到 78 列就补 `…` —— 「没有自适应」的观感就来自这里。
   * **③ 问题正文只画一行**。折行/截断只处理第一行，后面的行根本没有位置。
   修法三件配套：**进帧的文本一律单行清洗**（新增 `tui_clean_line_into`：`'\n'` → 空格，
82. **自测夹具的路径没补 NUL —— 只在「完整 selftest」里炸**（P49 加孤儿分支轮时被自己的新断言抓到）：
    `wt_ws_pid` 只往 `Buf` 里写内容、**不补尾 NUL**，而新写的那段把 `wsz.ptr` 直接当 git 的 `-C`
    参数（C 串）用 ⇒ git 报 `fatal: cannot change to '/tmp/selftest_p37_wt_2300741111-111111111111ce":
    "/selftest/meta-big/TRUNCuild/…'` —— 路径后面黏的那截，是**前面某轮留在堆里的字节**
    （`sess-meta-big` 的 TRUNC 标记 + 另一个会话日志路径）。三个「为什么难查」叠在一起：
    ① 单独跑 `UYA_SELFTEST_MODEL_ONLY=1` 永远绿（堆布局不同，那片内存恰好是 0）；
    ② 报错文本本身像「路径不存在」而不像「读越界」；③ 我最初把失败原因猜成「前面轮次留下了同名分支」，
    还照着这个错判去加预清理（无效）。真正定位靠的是：**先让断言把 git 的 stderr 打出来**
    （原先 `worktree remove` 的返回值被丢弃，只看到一句「它还被 worktree 占着」，看不出为什么），
    看到那截堆垃圾才认出这是踩坑 57 的形状。修法：这一轮里另备一份带 NUL 的 `wszz`，凡是把 fixture
    路径当 argv 的地方都用它。教训：**「只在完整套件里红」优先怀疑堆/全局状态，而不是测试顺序**；
    夹具里的路径缓冲与生产代码同等要求（补 NUL），别因为「它只是个 /tmp 路径」就省。
   修法三件配套：**进帧的文本一律单行清洗**（新增 `tui_clean_line_into`：`'\n'` → 空格，
   其余与 `tui_clean_into` 同一份实现、只多一个 `one_line` 开关；ask 型的标题/问题/选项/
   自定义回答行 + 共享的标题/prompt 槽位都用它）、**上限改成「终端宽 − 6」**（不再写死 78）、
   **问题按框宽折行并把能放下的行全画出来**（末行被砍时补 `…`；行数预算按框高算，有选项时
   给选项窗口留至少 1 行）。附带：多选提示的 full 档（76 列）在旧上限下是**死文案**
   （`body_w ≤ 74` 永远够不着），放开上限后补上这一档。
   **判据是字节级的**：新增不变量 `tui_rows_have_lf()`（帧里不许有「行内的 `'\n'`」），
   进 `tuis_scan_rows` 与「无 ESC / 无 NUL」并列；只断言宽度数值会漏掉 ①（宽度算得对、
   行仍被拆开）。六条防假绿对照实验（全部实测到红再改回）：
   ① `tui_clean_line_into` 退回不清洗 → `tui-ask`/`tui-frame` 的「行内换行」「方框不闭合」红 5 条；
   ② 上限退回写死 78 → 四条宽度断言红；③ 正文退回固定 1 行 → headless 与真 PTY 两条
   「只画了前几行」红；④ 折行缓存永不失效 → 「缩窗后没重折 / 仍按旧宽度折」红 2 条
   （**这条是第一版测试的漏洞**：起初只测「长问题折行」，缓存失效只在缩窗时才暴露，补了
   `tui_set_size` 缩窗那一段才逮住）；⑤ 共享槽位不清洗 → `tui-frame` 的确认浮层那两条红
   （同样是补测之后才有的覆盖）。
   `--tui-demo` 与修前**逐字节相同**（50391 B：这是浮层内的排版，demo 不画浮层）。
83. **「下一个状态」写在被调用方、清零写在调用方 = 整个状态机从未生效**（P50，本轮修）：
  括起粘贴（`ESC[200~` … `ESC[201~`）在 TUI 里**一次都没生效过**：`tui_esc_final(c)` 的
  `a == 200` 分支把 `g_tui_esc` 置成 5（粘贴中）之后 `return`，而两个调用点在它返回后又各写了
  一句无条件 `g_tui_esc = 0` —— 状态当场被冲掉。**症状**：粘 3 行 → CR 被当成回车**逐行提交**
  （三条 user 消息，屏幕上只留最后一行）；粘贴里的 TAB → 切换 plan 模式。
  **为什么老自测没抓到**：自测喂的是 **LF**，而不通粘贴态时裸 LF 也走 `TUI_K_NEWLINE` ——
  两者恰好等价，唯一的差别（CR 提交 / TAB 切模式）一条都没被覆盖。判据是**可判定的**：
  `ESC[200~` + `A1\rA2` + `ESC[201~`，修前得到一条 `A1`（CR 提交了），修后是一条两行的输入。
  **修法**：下一个状态由 `tui_esc_final` 自己定（函数开头默认清零，需要停在别的状态的分支
  自己覆盖），调用点不再补清零。同族的两处一起修了：粘贴收尾标记改成**逐字节前缀匹配**
  （旧实现复用 CSI 数字累加器，`ESC[31m` 这类 ANSI 序列会被吞掉数字），以及断流时
  （buffer 正好断在 `ESC` / `ESC[20`）把攒下的字节吐回输入而不是静默吞掉。
  **本轮又踩了两次「手数字面量长度」**（踩坑 77 同族）：`"session.jsonl"` 写成 12（实际 13）、
  `"\"type\":\"user/message\""` 写成 23（实际 21）—— 两处都是「断言永远匹配不上」，
  且都发生在**自测代码**里，产品代码是对的。教训与 77 相同：长度要么用 `bufx_cstr_len` 求，
  要么当场核对。

84. **纯 Uya 没有图片编码器 ⇒ 图片只能「接受原图」或「明确拒绝」**（P51）：stdlib 里没有
  zlib/deflate，也没有 JPEG 编解码，所以**没法缩放或重压**图片。DSH 会把超预算的图重新编码到
  预算内，我们只能拒绝并说清超了多少（「图片像素太多（4032×3024 > 上限 640000 像素）——
  纯 Uya 没有图片编码器，缩不小，请自己压一下再来」）。这条**不是取舍而是事实**，所以预算
  判定必须发生在**下载/读取之后、构请求之前**（`imgx_check`），且两个协议的内联形状
  （completions 的 `image_url` 对象 / responses 的 `input_image` + `detail`）要用**抓包**核对，
  不能照抄文档（实测网关两种都收，但形状不同）。

85. **X11 协议：五个「差一格」全都会表现成同一个症状 ——「什么都读不到」**（P52）：手写 X11
  客户端时踩到的坑**彼此独立**，但现象全都是「剪贴板读不到」：
  ① `CreateWindow` 是**无应答**请求，等应答会一直等到超时（要用一条有应答的请求做 sync）；
  ② 请求长度字段是「**含头与自己补的 pad** 的 4 字节单位数」，先算 body 的 pad 再加头会少算一格；
  ③ `InternAtom` 的 `only_if_exists` 走请求头的 **data 字节**，不是体里的第一个字节；
  ④ `GetProperty` 的 `delete` 同理走 data 字节（体里只有 5 个 u32）；塞进体里会让服务端把
     window 解成 delete、其余全错位；
  ⑤ 事件消息的第 0 字节**就是事件类型**，且 requestor 与 owner 不同源时会带上 **SendEvent 位
     （0x80）**：`SelectionNotify` 读成 159 —— 直接比对 `== 31` 就永远等不到。要 `& 0x7f`。
  外加两条：`GetProperty` 应答里 `bytes-after` 与 `n-items` 的偏移容易读反（**最后改成直接信
  应答的 length 字段**：`clipx_read_msg` 已按它读满，那才是权威长度）；以及 `deadline` 是
  **每一步**的预算而不是整轮总预算（当成总预算的话，前面几条握手花掉大半之后，
  `ConvertSelection` 一进去就已过期）。**验收方式**：拿 GTK（`python3-gi`）当 owner、
  我们的客户端当 requestor，真读一次文本与一张 376 字节的 PNG（120×90），再用抓包网关确认
  它在下一条消息里变成 `data:image/png;base64,…`。


86. **「看起来还在」不是判据 —— 浮层画过头盖住面板，面板又被补画的帧盖回来**（P53，对照实验抓到的假绿）：
   浮层全屏的第一版对照实验是「让全屏顺手把面板也吃掉」（高度从转录区 `panel_top` 换成整个
   `rows`），预期 `tui-full` 当场红 —— 结果**全绿**。根因在帧组装顺序（`tui_build`）：
   `tui_draw_overlay()` 先画浮层，**之后**紧接着补状态区、面板与脚注
   （`while g_tui_nrows < g_tui_panel_top …` + `tui_draw_panel_rows`），所以浮层画过头的那几行
   会被后画的面板**原地覆盖**；屏幕上「Ask anything」那行字照样在，我那条断言
   `tuis_screen_has("Ask anything")` 于是照样绿。教训：**判据要读几何事实**（底边行号与
   `panel_top` 的关系），不能读「那行字看起来还在」—— 后者对「画过头 + 被覆盖」这种组合完全无感。
   修法：把「底边必须正好在 `panel_top - 1`」放进共用的 `tuis_full_frame_ok`（列表 / reader /
   ask 三种形态一起管，不各写一份），对照实验 ③ 随即红（底边 29 ≠ 26）。与踩坑 65（浮层盖住
   转录 ⇒ 「结果落进转录」的断言必须先关浮层）同族，都是**屏幕断言的可见性陷阱**。
   本轮自测自身另外两处翻车也记在这里，都是老坑的新现场：① 用 `buf_new` + `buf_append_*`
   拼出「第 N 条命令」再去 `tuis_screen_has` 查 —— 裸 malloc 不保证 NUL，`bufx_cstr_len`
   读到堆尾巴，数出来「可见条目 = 9」（实际 20+），断言假红（踩坑 57/67/77 同族，改用
   **固定字面量**）；② 断言 `/fullscreen bogus` 的报错 notice 时没先关浮层 —— 浮层盖着转录，
   那条 notice 在屏幕上根本看不见（踩坑 65 的现场），改成先 `tui_overlay_close()` 再判。
   还有一处**状态泄漏**（不是判据问题，但同属「只在完整套件里红」那一族，与踩坑 82 相邻）：
   `tui-full` 的 F 段为调 `agent_cmd_fullscreen` 打开了 headless TUI，收尾只做了 `tuis_reset`
   （它**关不掉** `g_tui_on`）⇒ 后一轮 `perm-readonly` 里 `ask_approve_action` 走进
   `if tui_active() && tui_overlay_available()` 那一支（以为有浮层可弹），不再回
   `no answer channel`，mock 第 1 轮断言 110 当场红 —— 现场看着像权限轮的缺陷。
   修法是 `tui_headless_enable(false)`（它同时清 `g_tui_on`）；`tui-switch` 的 C 段早就
   为同一个坑留过注释，本轮又踩了一次：**「只在完整套件里红」先查上一轮留下的全局状态**。

87. **uya 0.10 的「函数表」是固定容量 —— 加函数会让整个仓编不过，而且本仓已经贴着上限**（P53，本轮最大的坑）：
   浮层全屏的第一版实现很自然：几何收成四个小函数（`tui_ov_w` / `tui_ov_h` / `tui_ov_left` /
   `tui_ov_top`）、全屏态三个（get / set / toggle）、命令一个、自测五个 —— 一共 12 个新函数。
   写完全部自测都是绿的（增量 `make build` 用缓存），直到**清掉 `build/uyacache` 重编**：
   ```
   /home/winger/uya-0.10/lib/std/http/uyagin_router.uya: 错误: 函数表容量不足，请增大 FUNCTION_TABLE_SIZE
   ```
   报错点在**标准库**里，跟我的代码毫无关系 —— 这是编译器里写死的 `FUNCTION_TABLE_SIZE`
   （无开关、无环境变量、无文档）。实测边界（`make build`、当时的规模）：
   | | 声明数 | 结果 |
   |---|---|---|
   | main 原样 | 6756 | 通过 |
   | main + **1** 个空函数 | 6757 | **红** |
   | main + 15 个空函数 | 6771 | 红 |
   | 本仓去掉 15 个函数 | 6745 | 通过 |
   也就是说 **main 当时已经没有余量了**：任何一条线只要净增函数就让 `make build` 从干净缓存起
   必红。变量与常量**不占**这个额度（实测 +40 个 `const` / `+20` 个 `var` 都不红），
   只有函数占。
   **上限是「绝对条数」而不是「本仓余量为 0」——余量随各线合并而变，要现测**。P54 重测
   （同一台机器、同一份 uya 0.10、本仓 6789 声明起）：
   | | 声明数 | 结果 |
   |---|---|---|
   | 本仓（改动前） | 6789 | 通过 |
   | + **6** 个空函数 | 6795 | 通过 |
   | + 8 个空函数 | 6797 | 红 |
   即表容量在 **6796** 上下，本仓当时还剩 6 个左右；P54 这条线净增 **2** 个函数
   （`agent_note_degenerate` + 自测的 `empty_retry_check`）之后是 6792，仍然通过 ——
   但结论不变：**净增函数的改动一律清缓存重编一遍**，别拿增量编译的绿当绿。
   教训三条：① **增量编译的绿不算绿** —— 这类容量上限只有「删掉缓存重编」才暴露，
   所以改完必须 `rm -rf build && make build` 走一遍（本轮就是靠这一步才发现的）；
   ② 报错点可能在**标准库**里（先被编译到的那一批），别顺着报错文件去找原因，
   要看「声明总数」这个量；③ 整理手段按优先级：**合并语义同族的函数**（get/set/toggle 合成
   一个带 `want` 参数的）、**就地展开只有一两处调用的转发函数**（`fn f(){ g(); }` 这种）、
   **顺带删掉仓里现成的零调用死函数**（`tui_repeat` 就是零调用）。
   本轮的最终形态：几何收成**一个** `tui_ov_box_w(base_w, cap_h, w, h, left, top)`（四个出参），
   全屏态收成一个 `tui_overlay_full(want)`（`-2` 查询 / `-1` 翻转 / `0` 关 / `>0` 开），
   `/mouse` 与 `/fullscreen` 合成一个 `agent_cmd_display(line, which)`，自测的两个 helper 合进
   轮函数 —— 净增函数数压到 **0**（`tui_ov_box_w` 与 `agent_cmd_display` 复用了原有的名字槽位，
   另删掉 `tui_putn` / `tui_repeat` 两个死转发）。

88. **「保持清单最新」的纪律只写在工具描述里 = 事后没人回头看**（本轮修复，不占阶段号）：
   用户观察到「经常不更新任务状态」。查下来**不是措辞问题**：uya-agent 的 `todo_write`
   描述与 DSH 的 `dsh-tool-todo` **逐字相同**（HEAD/PARALLEL/TAIL 三段全一致），
   而 DSH 自己的 README 明说 *"the discipline of keeping the list current are left to the
   model via the tool description"* —— 它刻意不写进 system prompt。**真正的差异在防线**：
   DSH 还有 `dsh-repeat-tool-reminder`（看工具调用重复）与 session projection 兜着，
   uya-agent **两样都没有**；而 `src/agent/prompt.uya` 原有 8 节（read/write/edit/glob/grep/bash/
   jobs/finish）**没有一节讲 todo**。
   **为什么工具描述那句不够**：它说的是**事前**纪律（"mark a todo `completed` the moment it
   is done"），而「完成」那一刻注意力已经跳到下一个动作上 —— 事后没有任何东西回头看。
   本线自己就漏了 4 次（P50/P51/P52 各自做完没标、合并完也没标），形状完全一致。
   **修法（最小、只改字符串、不占函数名额）**：`SEC_FINISH`（order 107，模型**收工前必读**
   的那一段，已在管「别重读文件」「验收绿了就收工」两件同性质的事）加第三条：
   报「做完了」之前真正做完的步骤必须都是 `completed`、不许留 `in_progress`，
   陈旧清单算交付物的一部分。措辞同样**限定在可判定情形**（「自己维护了清单」）。
   顺带给这一节补了三条断言（verdict 76/77/78）—— 它此前**完全没有自测覆盖**，
   纯字符串常量被改坏不会有任何编译期信号；对照实验：把第三条改写成
   "a stale list is fine" 后 `prompt-todo-plan` 当场红（verdict 78），不是假绿。

89. **mock 的判定码经 `sys_exit` 回来只留低 8 位 —— 261 会显示成 5、264 会显示成 8**（P54，本轮踩到）：
   退化响应那两轮的判定码第一版顺着既有的号段往下写了 261…268。跑那条「重发前动一下历史」的
   对照实验（§6 的 P54 段实验 ⑥，期望「重发的请求不再是同一个」那条断言红）时，报出来的是
   `FAIL: mock server verdict 8` —— **8 和 264 差着 256**：mock 是 `fork` 出来的子进程，
   判定码要经 `sys_exit(rc)` 回到父进程，而退出码只有低 8 位（`264 & 255 = 8`）。
   这条**不会造成假绿**（非 0 就是失败），但会让报出来的码**张冠李戴**：8 落在「一遍过不了的
   号段」里，照着去查会一路查到别的断言上（我第一反应就是「mock 没走到我的分支」）。
   同族的 267 → 11（读请求失败）、268 → 12（另一条真断言）都是会误导的值。
   **规矩**：mock 的判定码一律 `< 256`，并且先用
   `grep -o "verdict = [0-9]*" | sort -nu` 与 `,\s*[0-9]+,\s*&verdict` 两处一起核一遍
   占用情况（只在 `verdict = N` 里找会漏掉 `expect(..., N, &verdict)` 那一半 ——
   本轮就是这么撞上 241/242 的）。

90. **静态链接：开关必须落在 Makefile 里，命令行上给的那次不算数**（本轮，不占阶段号）：
   uya 0.10 的 `uya build` 不自己决定链接方式，而是把环境里的 `LDFLAGS` 透传给它**生成**的
   `build/uyacache/Makefile`（那条链接行是 `$(CC) $(OBJS) -o $(UYA_OUT) $(LDFLAGS) -lm`）。
   于是「改出静态链接」看起来只要 `LDFLAGS=-static make build` 就够了 —— 我第一版就是这么
   验证的，产物确实 `statically linked`、`--probe` 也真跑通了 TLS。**但这个绿是假的**：
   下一次不带这个变量的 `make build`（或 `make selftest`，它依赖 `build`）会照常重编并把
   产物**换回动态**，全程零告警 —— 实测就是这么被换回去的（`readelf -d` 又出现 `libc.so.6`）。
   判据很简单：**验证完静态之后，再跑一次不带 flag 的 `make build`，看产物还是不是静态**；
   是的话才算数。所以修法是把开关写进 Makefile：`STATIC ?= 1` + `AGENT_LDFLAGS`，
   由 `build` 那条命令前缀 `LDFLAGS="$(AGENT_LDFLAGS)"` 带进去。
   **为什么不全局 `export`**：那会把 `LDFLAGS=-static` 漏进**每个** recipe 的环境 ——
   包括 `make selftest`，而 selftest 内部会 fork bash、由 agent 自己去 `uya build` 编东西，
   等于悄悄改掉别人的编译行为；行内赋值只作用于编译那一条命令。核对办法：
   `make -n selftest | grep -c 'LDFLAGS='` 应当是 **1**（就是 `build` 那条命令前缀，
   selftest 自己那一串里一个都没有）。
   **孪生两个坑**：① 编译器文档 §C.2 里的 `LINK_MODE=static` **对这条路径无效** ——
   实测 `LINK_MODE=static uya build …` 产物仍是 PIE 动态（那个变量是编译器自身构建脚本
   `compile.sh` 用的），照文档做会得到一个「我明明设了」的假象；
   ② 生成的 Makefile 里是 `LDFLAGS ?=`，而 `?=` 对**已定义（哪怕空串）**的变量不生效 ——
   所以调用方环境里一个空的 `LDFLAGS=` 就能把静态吃掉。行内赋值（而不是 `?=`/`:=`
   全局赋值）两个都挡得住：外部怎么设都覆盖不了那一条命令前缀（实测 `LDFLAGS="" make build`
   产物照样静态）。
   **验收怎么钉**：`make build` 末尾自带 `link-audit`（`build` 绿 ⇒ 真静态），读的是 ELF
   结构性 token —— `readelf -lW | grep -c INTERP` 与 `readelf -dW | grep -c "(NEEDED)"`
   两个都要是 0。**不解析散文**：中文 locale 下 `readelf -d` 会把
   「There is no dynamic section in this file」整句翻掉，`file` 输出的
   「statically linked」同样本机化 —— 只认 `INTERP` / `(NEEDED)` 这类类型名，它们不翻
   （实测 C / zh_CN.UTF-8 / en_US.UTF-8 三个 locale 下行为一致）。
   这条**不是假绿**：把 `STATIC=0` 编出来的动态产物拿给 `make link-audit STATIC=1` 判，
   当场红在「产物有 PT_INTERP」并打出那行 INTERP。
   **顺带确认的事实**（静态 glibc 的常见雷区，本仓都没踩）：生成的 C 里没有任何
   `getpwnam` / `getaddrinfo` / `dlopen` 调用（NSS 是静态 glibc 最经典的坑：那些函数会
   `dlopen` 库，静态链接时会告警并在运行时失效），DNS 是 `lib/std/net/dns.uya` 自己
   收发 UDP 报文实现的；`dlsym` 那一族只出现在 `__APPLE__` 分支里（`extern` 声明在
   Linux 下不被引用），静态产物里 `nm | grep dlsym` 是 0 条。
   真机复核：静态产物拷到 `/tmp` 空目录、`env -i` 起得来（`--print-config` 正常），
   `--probe` 对 `api.deepseek.com` 拿到 HTTP 401 —— DNS 与 TLS 这两条最容易在静态
   glibc 上出事的路径都是通的。

   > **另一件事（不是这条线引入的，已在后续一轮修掉）**：整轮 selftest 里 `worktree-reclaim`
   > 偶尔红在 fixture **准备**阶段（`造 A/B/C/F/F2 失败`、`收尾时把有提交的孤儿分支清掉了`），
   > 报的还每次不一样。当时这条线顺手做了对照，三组证据都指向「与链接方式无关」：
   > ① **A/B 交替**：同一台机器、静态与动态各跑三轮交替进行，静态第 1 轮红、
   > 动态第 2 轮红（签名逐字相同）；② **拿未改动的对照**：从共享检出里取一份
   > `main` 上 07:25 编好的产物（**动态、本线一行都没碰**），与静态产物交替各跑 4 轮
   > —— **对照 2/4 红，静态 1/4 红**，而且对照红的那两次正是同一个 `worktree-reclaim`；
   > ③ **聚焦**：`UYA_SELFTEST_MODEL_ONLY=1`（0.4 s，含这一轮）连跑 30 次、
   > 每次先清 `/tmp/selftest_p37_wt_*`，**0 失败**。
   > 当时的猜测是 `gitx` 的 10 s 墙钟上限（`GITX_TIMEOUT_MS`）在高负载下偶发超时。
   > **后续一轮把它查清了，不是超时 —— 是踩坑 57 的 C 串口径**：那两轮多出来的
   > fixture 辅助函数（`wt_residue_slug`）返回的 slug 是个**裸 `Buf`（没有尾 NUL）**，
   > 而它立刻被 `wt_residue_make_named` / `wt_branch_gone` 按 C 串口径消费
   > （`buf_append_cstr` / `bufx_cstr_len`）。`buf_new` 的 `malloc` 不清零，于是
   > `bufx_cstr_len` 一路读到堆里的脏字节：实测 `dsh/inuse1-4` 后面黏着
   > `\x9d\x13@\0\0\0\0` 与半截 fixture 路径，`git worktree add -b <那个名字>` 时好时坏。
   > 完整 selftest 里前面几十轮已经**真的 chdir / 拼过大路径**，堆是脏的 ⇒ 必红；
   > 而 `UYA_SELFTEST_MODEL_ONLY=1` 那条路上堆还干净（后面那些字节恰好是 0）⇒ 三十次都不红。
   > 这正好解释了三组对照为什么都说「与链接方式无关」，也解释了「报得每次不一样」
   > （黏上的脏字节随前面跑过哪几轮变化）。**修法**：`wt_residue_slug` 补一个尾 NUL
   > （`len` 仍留**可见长度**），并在 `worktree-reclaim` 轮里钉一条
   > 「`bufx_cstr_len(slug) == slug.len`」的断言 —— 补错/漏补都当场红，
   > 不用再等下一次偶发。（`mine #1` 那次红在 `tui-plan` 的「审阅浮层里没有三个动作」，
   > 同样是 `tuis_drain` 有界轮询的时序快慢，与本条无关。）

91. **函数表容量还有第二、第三种症状：链接期 `undefined reference` 指向你没改过的函数**（P55，本轮踩到）：
   踩坑 87 的结论是「变量与常量不占额度、只有函数占」，写代码时很容易只记住前半句 —— 这轮给执行期
   两条纪律很自然地开了两个小函数（`agent_exec_step_switch` / `agent_exec_after_tool`，各 20~30 行），
   另外顺手加了 7 个全局、1 个常量、3 个 `Config` 字段、1 个结构体。清缓存重编：
   ```
   agent.c:(.text+0x4bce): undefined reference to `agent_note_answer'
   tuiselftest.c:(.text+0x14487): undefined reference to `tuis_ask_opts'
   collect2: error: ld returned 1 exit status
   ```
   两个符号**都在源码里定义得好好的**（`src/agent/agent.uya` 的 `agent_note_answer`、
   `src/selftest/tuiselftest.uya` 的 `tuis_ask_opts`），
   `uya check` 也绿。表满时塞不进去的条目被丢掉，一直等到链接期才暴露 —— 报错点与被丢的东西
   毫无关系。同一次实验里换一种写法还报过第三种形态：`src/selftest/tuiselftest.uya:(<tuis_ask_opts 所在行>:1): 错误:
   顶层函数 reachable 集合已满`（这一句才像话，但它什么时候出现靠运气）。
   实测边界（同一台机器、同一份 uya 0.10、`make build` 清缓存重编）：
   | 形态 | 声明数 | 净增函数 | 结果 |
   |---|---|---|---|
   | 本仓（合并 main 后） | 6792 | 0 | 通过 |
   | + 7 全局 + 1 常量 + 2 函数 | 6802 | **2** | 链接期 undefined reference（两个无关函数） |
   | + 3 `Config` 字段 + 7 字段结构体 + 1 变量 + 1 常量，**0 新函数** | 6805 | 0 | 通过 |
   结论：**唯一安全的判据是「净增函数数 = 0」** —— 声明总数涨 13 条照样通过（再一次印证变量/常量
   不占额度），多 2 个函数就编不过；而且只能靠清缓存重编验，增量编译永远绿。
   本轮的最终形态：两段逻辑**内联**进既有函数 —— step 边界那段进 `agent_turn_loop_inner` 的
   step 边界处，工具收尾那段进 `dispatch_tool_body` 的尾部（流式/非流式两个派发点都必经它，
   一处顶两处）；为了让工具钩子拿到步号，`ExecState` 加了一个 `step` 字段（变量不占额度）。
   净增函数 **0**。

92. **`js_obj_get_str_unescaped` 的第一个参数是「已 parse 的 `&JsonValue`」—— 传 JSON 文本会被隐式强转、静默返回 false**（P55，本轮踩到）：
   工具收尾钩子要从 bash 参数里取 `command` 判断「是不是验收类命令」，很自然地写成
   `js_obj_get_str_unescaped(args_json, "command", 7, &cmd)` —— 而 `args_json` 是**工具参数的 JSON 文本**
   （`&const Buf`），函数签名要的却是 `v: &JsonValue`（`js_obj_get_str` 的入参就是它）。
   Uya 允许指针之间强转，于是**编译、`uya check`、整轮 `make selftest` 全绿**，运行时函数永远返回 false：
   提醒一次都没注入过，日志里连一条痕迹都没有（真机跑了三段腿、发现三段都没有 `[acceptance]`
   才回头查出来）。正确写法是把 `dispatch_tool_body` 里**已经 parse 好的** `arg_val` 传进去。
   **孪生一条**：这个函数的出参必须是**空 Buf** —— 它内部是 `out[0] = buf_new(s.len + 8)`
   （把整个缓冲换掉，不是往里追加），所以习惯性写的 `var cmd: Buf = buf_new(256)` 会把那 256 字节
   丢掉（每次调用泄漏一次）；正确形状是 `buf_empty()` + `defer { buf_free(&cmd); }`，
   仓里其它调用点（如 `agent_title_tool_set`）就是这个形状。
   教训：**「编译过了」对「参数语义对不对」零信息** —— 指针参数传错类型不报错，只有真机跑一遍、
   并且**断言看得见的行为**才抓得住。这一条现在由 `make e2e-accept-nudge` 守着（验收类命令 → 恰好
   1 行 `[acceptance]`；`ls -la` 这种非验收类命令 → 0 行）。



93. **`off` 写成「不发字段」= 把用户的「关掉」偷换成「你看着办」**（P56，本轮踩到）：
    `reasoning_effort` 的 off/none 在请求侧被当成「没有值」跳过，而 `mx_read_efforts` 只读
    `reasoningEfforts` 的**键**（公布哪些档位）、不读**值**（`off: none` 那层映射没用上）。
    于是同一个 off：DSH 发 `"none"`（实测 outputTokens 135），uya-agent 一个字段都不发 →
    网关按自己的默认档思考（实测 outputTokens 364，其中思考正文 326 字）；而 `--print-config`
    忠实地印着 `reasoning_effort = off`，用户**没有任何办法**看出这条配置没落地。
    判据很简单：同一道题分别打「不发字段」与「发 none」，看 `completion_tokens` 和
    `reasoning_tokens` —— 差 5 倍以上就是这个坑（不发字段≈755/647，发 none≈214/0）。
    与踩坑 71 同源（那条是「completions 完全不发」，这条是「该发的时候不发」），
    教训是同一句：**配置项的语义必须落到线上字节上**，别停在「我们这边的字段值」；
    这类静默失效一律用「组装请求体 → 断言字节」的自测钉住（本轮翻了两条旧断言、补了两条新的）。

94. **合并残留的冲突标记没有任何测试看得见 —— 它在 README 里躺了一整天**（本轮修掉，不占阶段号）：
    `README.md` 的「踩坑节 → 工具实现要点节」之间（本文 §16 → §17）有一行孤立的 `=======`，来自 P53 那次合并
    （`3e62301`「Merge main（P50–P52 剪贴板粘贴 + 踩坑 81–85）到『浮层全屏』」）—— 该合并的**两个父
    提交都没有它**（`4800d23` / `66a521c` 各 0 次），是解冲突时留下的。它躺着的这段时间里
    `make build`、`make selftest`（含 147 轮具名断言）、`link-audit`、`codegen-audit` 全绿：
    **没有任何一条测试会去看文档里的冲突标记**。
    **第一次归因是错的**（我当时说是静态链接那次合并留下的）—— 那次的两个父提交也都没有它，
    判据是「在哪个提交第一次出现 + 它的父提交有没有」，别靠印象。
    防复发：新增 `make doc-audit`（行首锚定的 `<<<<<<<` / `=======` / `>>>>>>>` 扫描；只扫文本文件、
    跳过 `.git` 与 `build`，所以源码里 `// ============` 这类分隔线不误报），已并进 `make selftest`。
    反例验证：往 README 追加一行 `=======` → 审计立刻红并打印文件:行号（实测 rc=2）。
    顺带把 7 处 `---` 分隔符的上下空行统一成各 1 个（那一处是 0 空行顶着标记，正是它暴露的）。
    教训：**「全绿」只覆盖被断言过的东西**。文档这类没有断言的产物必须单独有一条审计，
    否则它坏多久都没人知道。
95. **同一个「越界怎么办」，在两种导航语义下答案相反 —— 判据要按按键分派，不能按 delta 猜**（P57）：
   给浮窗列表做循环选择（`↑` 在第一项再按 = 跳到最后一项）时，最自然的写法是
   `if sel < 0 { sel = n - 1; }`，改的正是 `tui_ov_sel_move(delta)`。**但 `Home` 也调它**
   （delta = `-n`）：`Home` 一旦回绕，`-n` 绕一次正好回到原位 —— 用户按 `Home` 变成**空操作**，
   而「按 Home 不动」看起来和「已经夹在顶上」一模一样，极难发现。`PgUp` 同理（在顶上按会跳到尾项）。
   第一反应是「按 `|delta| == 1` 判走一步」——**这条也是错的**，而且错得更隐蔽：
   `delta` 是 `tui_ov_body_rows()`（框里能放几行），当框矮到只剩 1 行正文时，
   `PgUp`/`PgDn` 的步长**也**是 ±1，于是它们会被误判成「走一步」而去回绕。
   这正是本轮自测 F 段那条判别腿的由来：它先**逐步调矮终端直到框里只放得下一行**
   （`body_rows == 1`，本例是 rows=8），再在末项分别按 `PgDn`（必须**不动**）与 `↓`
   （必须**回绕**）—— 同一个 ±1 步长给出不同结果，才说明判定真的看的是按键。
   教训：**当一个分支的语义取决于「哪个键」时，就得把键传进去**；任何从数值特征反推按键的
   写法都会在某个参数组合下失真。对照实验（把判定换成「按 delta 大小猜」）当场红 3 条。
   **写这条腿时自身踩到的两个假红**，同族，一并记下：① `tuis_reset(cols, rows)` 只改**画布尺寸**，
   而浮层几何（`panel_top` / 框高 / 能放几行）是 `tui_build()` 阶段算出来的 —— 只 reset 不 build
   的话，每一轮读到的都是**上一次画布**留下的 `panel_top`，「一屏几行」永远不随尺寸变，
   于是那条「找一屏只放得下一行的高度」的循环永远搜不到，症状是「这条腿没跑成」而不是「不通过」；
   ② `tuis_reset` 会 `tui_reset_all`，**把命令表也清掉** —— 循环里不重新 `tui_set_commands` 的话
   条目数是 0，同样表现为「没跑成」。两条都是**判据自己没到位**，与踩坑 86「判据要读事实」同族。

---

## 17. 工具实现要点

> 这一节是**最早那三个工具**（`src/tools.uya`）的实现记录。P6/P7 起它们已被
> `tools/fsx.uya`（`read`/`write`/`edit`，见 §6.3）与 `tools/shellx.uya`（`bash`，见 §6.4）
> 取代，`src/tools.uya` 本身从 P50 起**不在构建里**。表里的名字是历史名，括号里是对应的
> 现役工具 —— 保留下面的形状是因为**进程模型与截断口径至今一致**，读它比读 962 行现役代码快。

| 当时的工具（现役） | 实现 | 限制 |
|---|---|---|
| `read_file`（`read`） | `sys_open` + `sys_read` 循环读进堆缓冲 | 单次最多 64 KiB，超出附 `[truncated]` |
| `write_file`（`write`） | `sys_open(O_WRONLY\|O_CREAT\|O_TRUNC, 0644)`；父目录缺失时 `mkdir` 一层后重试 | 整文件覆盖写 |
| `run_shell`（`bash`） | `pipe` → `fork` → 子进程 `dup2`+`chdir(workspace)`+`execve("/bin/sh", ["sh","-c",cmd], envp)` → 父进程 `poll` 读 stdout+stderr → 墙钟超时 `SIGKILL` → `waitpid` | 输出上限 64 KiB（现役是 `cfg.max_tool_out`）；默认超时 120 s（现役是 `--timeout-ms`）；`--no-shell` 关闭整组 |
| `workspace`（P34） | 无参 = 报告（工作区 / 来源 / 分支 / 会话 id）；带 `path` = `chdir` + `getcwd` 规范化 + 重指 `FsCtx` + 清技能缓存 + `gd_reset` + 记 `session/workspace` 与索引；工具目录跨模式恒定可见 | 目标必须**存在且是目录**（`chdir` 就是校验，失败什么都不改）；非全权下逐次要用户批准（无渠道 fail closed）；不建目录、不解析 `~` |

路径守卫（best-effort，**不是安全边界**）：所有 `path` 相对 `--workspace` 解析，拒绝绝对路径、
`~` 开头、以及含 `..` 段的路径。工具内部任何失败都不抛错，一律写成 `error: ...` 文本回给模型，
让它自己纠正；bash 在 `danger-full-access` 下本来就能执行任意命令，所以别拿它当沙箱用
（要沙箱请用 `workspace-write` / `read-only`）。

还有三条工具级策略（拦在参数校验之后、动文件之前）：plan 模式下 `write` / `edit` 直接回
`Error: write is refused in plan mode (no file changes before the user approves the plan). …`；
`read-only` 模式下回
`Error: write is refused in read-only mode (the user granted no write access). Do not retry; …`，
且 `bash` 每条命令先过人工批准闸门。

---

## 18. TLS 信任策略（重要，和标准库现状有关）

`lib/tls` 是**真 TLS 1.2 客户端**（SNI、ECDHE-P256、PRF、Finished、系统信任库），实测对
`api.deepseek.com` 能完成握手并拿到 `HTTP/1.1 401`。但它的**链校验在真实站点上基本不可用**：

* `verify_chain_rsa` 要求「服务端发来的**链顶**证书公钥 == 某个信任锚」——真实站点不会把自己的
  根证书一并发来，所以这条路对 `api.deepseek.com` / `ping0.com` 都失败（`example.com` 恰好能过）；
* `cert_verify_signature` 只支持 SHA-256 + RSA PKCS#1 v1.5，SHA-384 的链过不去；
* `ssl_set_peer_identity` 把 `peer_san/peer_cn` 设成**我们自己传进去的期望域名**，
  所以标准库那一步「主机名校验」实际是拿期望值和期望值比，等于没校验。

因此本项目**不改标准库**，而是在 agent 侧提供三档策略：

| 模式 | 行为 |
|---|---|
| `--tls-verify=chain`（默认） | 握手后调用导出的 `verify_chain_rsa`，语义与标准库一致——安全，但真实站点通常会失败，失败时会打印精确原因 |
| `--tls-verify=pin` | 跳过链校验，直接校验**服务端 leaf 证书 DER 的 SHA-256** 是否等于 `--tls-pin`。指纹从 `HandshakeCtx.server_flight_msg` 自己解析出来（不依赖 `cert_parse` 的 RSA 前提），实测与 `openssl s_client \| openssl x509 -outform DER \| sha256sum` 完全一致 |
| `--tls-verify=none` | 不校验，仅打印观测到的 leaf SHA-256 与告警，方便你先 TOFU 再改成 `pin` |

推荐用法：先跑一次 `--probe --tls-verify=none` 拿到指纹，之后一律用 pin 模式：

```bash
./build/uya-agent --probe --tls-verify=none                 # 记下 leaf_sha256
DEEPSEEK_API_KEY=sk-xxx ./build/uya-agent \
  --tls-verify=pin --tls-pin 30d82529d19c5da6175a80db1c5522ac3ba5b42589212405cdc8783a1bf047fa \
  "创建 hello.uya，编译并运行它"
```

本地明文端点（ollama / llama.cpp 的 OpenAI 兼容接口）不走 TLS，直接
`--base-url http://127.0.0.1:11434/v1` 即可。

> 后续可做的（本项目**没做**）：给 `lib/tls` 补一条真正的链构建（用 issuer/签名关系从 leaf 走到
> 信任锚、支持 SHA-384）、并把 leaf 的 SAN 真正解析出来做主机名校验。做完之后 `chain` 模式就能
> 直接对云端可用、也不再需要 pin。

---

## 19. 自测与验收

`make selftest` 完全离线（在 `127.0.0.1:0` 上 fork 一个纯 Uya 写的 mock LLM），跑两轮真实 agent 循环并逐项断言；`make e2e` 则打真实网关。

| 轮次 | 覆盖点 |
|---|---|
| `shell` | schema 有 `bash`；一轮两个 tool_calls；第二轮请求含 `wrote … note.txt`/`SELFTEST-SHELL-OK`/`exit=0`；落盘逐字节 |
| `no-shell` | 请求不出现 `"name":"bash"`，其余同 `shell` |
| `tools` | 4 调用：`write`（换行/引号）、`read` 回读、`../escape.txt` 被拒、`sleep 5 timeout=300` 被 SIGKILL；`esc.txt` 逐字节 |
| `noshell-nostream` | `--no-stream` 回归：同一 mock 数据走非流式 |
| `shell-fold` | `--compat-fold` 回归：请求含折叠头、无 `role:"tool"` |
| `stream-basic` | SSE 分帧 + content 累积 + usage 合并（尾随 usage-only 帧不带明细） |
| `stream-tools` | `tool_calls` 按 index 交错分片（两调用、arguments 切 4 段） |
| `stream-nodone` | 缺 `[DONE]` → `STREAM_CLOSED`，已收内容保留 |
| `tty-editor` | 行编辑/历史/粘贴多行/pend；UTF-8 按字符编辑；显示列宽；擦除序列逐字节 |
| `stream-badjson` | 坏 JSON 帧 → `MALFORMED_RESPONSE` + payload 头部，前文保留 |
| `stream-length` | `finish_reason=length` → max-tokens，reasoning 正常累积 |
| `stream-firsttok-reasoning` / `-call` / `-none` | P24 首 token 三边界：只有 reasoning 或 tool_calls 参数必打点；空 delta+usage-only 不打点 |
| `resp-firsttok-reasoning` / `-call` | responses 同口径两条 |
| `steer` | 回合中输入的文本出现在下一 step 请求（`STEER-MARKER`） |
| `interrupt` | Ctrl-C：`AGENT_INTERRUPTED`、工具未派发、只一次请求 |
| `tui-frame` | 八尺寸每行 ≤ cols、正文层无 ESC；脚注按列退化；浮层方框左右边界同列（踩坑 42） |
| `tui-keys` | UTF-8 逐字符编辑、切开的 `ESC [ D`、Ctrl-J、↑历史、tab plan、面板、Ctrl-D/Ctrl-C、`tui_abort_state()` 三档 |
| `tui-turn` | headless 端到端：用户条目、`✓ Write`/`✓ Bash(`、最终答案、状态区收掉无残影；脚注含 `1 轮 · `；**P58 续跑腿**（换一份 mock 重跑：`create_goal` 之后主循环空闲即自开第二轮 → 续跑轮用记账后的 revision 标 complete → 授权收掉、转录里不出现 `<goal_round>` 用户条目） |
| `tui-status` | 常驻状态区 + 思考实时行：铺满后仍钉住、只显示 `latestLine`、空闲 0 行、窄终端退化 |
| `tui-caret` | 踩坑 66：运行中（思考/输出/工具）输入行有光标（标志位 + 字节级 1×`?25h`/0×`?25l`）；空闲与「空闲+浮层」两格不变；运行中开浮层仍隐藏（1×`?25l`/0×`?25h`） |
| `tui-p30` | 泵点当场派发只读命令、`/new` 立刻回执、`/compact` 留 step 边界；真 PTY `/status` ≤800 ms（`mock_mode=40`） |
| `tui-p31` | 派发后同一次调用帧数 +1、结果留给主循环；真 PTY ≤800/≤150/≤300 ms |
| `tui-cmd` | 面板 ↔ `/status` 浮层：输入行不留 `/`、标题逐字节、正文层无 NUL、运行中 step 边界派发；**F 段（P57）**：循环选择（`↑` 顶→底 / `↓` 底→顶、中间项仍逐格走、`Home`/`End`/`PgUp`/`PgDn` 仍夹取、矮框里步长同为 ±1 时 `PgDn` 夹取而 `↓` 回绕的判别腿）+ 已输入文本画在标题栏（非空才画、退格跟随变短、长词保尾补 `…`、脏字节单行清洗、方框仍逐行闭合） |
| `tui-scroll` | P32：2400 行条目 PgUp 到 `LONG-ROW-1`、`ESC[1;5H` 尾巴不漏、SGR 滚轮、鼠标上报开关 |
| `stats-format` | 纯函数：duration/tokens/tok-s/缓存命中取整（12.5%→13%）与除零保护 |
| `stats-line` | 整行逐字节（DSH 截图那行）+ 四种判据 |
| `stats-fold` | 实时喂与日志回放 11 字段逐字节相同；重复 callId 取最后一次 |
| `stats-context` | 占用率/`projectedTokens`/`~已用 / 容量`/20 格分段条逐字节 |
| `stats-usage` | 端到端一轮（只给这轮开 usage），回合正常结束 |
| `stats-log` | `step/start`↔`step/end` 成对、回放与实时逐字节相同 |
| `procx-parse` | `/proc/<pid>/stat`：comm 取首 `(` 到末 `)`、utime/stime 第 12/13 字段、坏行必须失败 |
| `procx-percent` | `Δticks × 1000 / Δms`：0/37/100/250、`Δms=0` 不可算、钳 999、`USER_HZ=100` |
| `procx-mem` | `Pss:`/`VmRSS:` 解析与显示（`0K`…`65.7G`，`-1` 不写字节） |
| `cpu-live` | 忙循环子进程：进程数涨、`cpu ≥ 25`、内存 ≥ 1 MiB；只建基线不给百分比 |
| `tui-pty` | 真 PTY：备用屏幕、SIGWINCH、`/exit` 退出码 0、退出后 `TCGETS` 逐位还原；P22 标题 |
| `tui-exit` | 完整主循环：面板选 `/help` 后正文进转录；不发任何请求 |
| `tui-quit` | 真 PTY：`sleep 15` 时 ctrl+d 5 秒内退出、esc 当场杀工具、`/exit` 码 0 |
| `perm-modes` | 三级模式机器名 ↔ 值 ↔ 显示名、`custom`/空串判 -1、策略真值表 |
| `perm-readonly` | write 逐字拒绝且不落盘、bash fail closed、read 照常；带 file policy 句 |
| `san-profile` | 三档 bwrap argv 逐字；workspace-write 加 `--tmpfs /tmp`+bind；full access 不套壳 |
| `san-shell` | 直接 fork 沙箱实测：read-only 写 `/tmp` 被拒、区外写被拒；无 bwrap 打 skip |
| `san-tool` | 端到端：workspace-write 区内落盘、区外不存在（内核拦的） |
| `tui-access` | chip 三模式、`shift+tab` 只置请求、选 Full access 出确认层；`/status` 真派发、`/help` 开浮层；结果 kind 跨 close 存活（踩坑 44） |
| `plan-gate` | P26 plan 写闸门真值表 + 全权模式下 write/edit 被拒且 `plan-gate.txt` 不落盘 |
| `tui-plan` | 审阅浮窗四段：动作/滚动/`Plan approved`/`esc` dismissed；40 列不超宽 |
| `tui-ask` | P43/P45/踩坑 81 提问弹窗六段：① headless 排版与按键（标题/问题/编号选项/`▸`/`✎`/提示/方框闭合/每行 ≤ cols/无 ESC-NUL/**无行内换行**；`↓`、`1-9` 直选、打字进自定义、`backspace` 退、单选自定义排他、多选 `[x]` 交回两个下标、0 选项只画自定义行、40 列不越界、`esc` 取消）；② 框宽**自适应内容**（短内容缩到下限 34、长问题长到终端上限 −6、光标移动不抖列宽、提示与占位按 full→mid→min 退让且 `esc 取消` 不被截、40/30 列终端仍闭合不越界）；③ **长/多行内容不跑出框外**（超长问题折成多行且末行标记上屏、放不下时末行补 `…`、多行问题的 `\n` 折成空格、脏 `header`/ESC 被清洗、多行自定义回答仍在框内、**缩窗后按新宽度重折且每行仍在预算内**、宽终端上多选提示的 full 档真的会用）；④ 终端太矮 `tui_ask_wait` 返回 0（回落输入行，不 fail closed）；⑤ headless+agent 真调 `ask_user_question`：没人答 = dismissed + 空 `selected`，绝不假装有人答、浮层收干净；⑥ 真 PTY：弹窗把**长且多行**的问题首末行都画上屏（不是输入行那条提示）、`2`+回车后模型收到的工具结果里是第二个选项的 label |
| `tui-ws` | P34 工作区切换：脚注 cwd、`/diff` 标题、运行时上下文注入不上屏、幂等 |
| `tui-diff` | `/diff` 浮窗：圆角框/两栏/竖线同列；P36 底色与 `n`/`N` 跳转 |
| `diff-parse` | diff → 行表：MIX/多 hunk/CRLF/TAB/`Binary files`；P36 `gd_next_change` 环绕 |
| `ws-resolve` | 恢复时工作区判定：显式优先、记录不存在 fallback、`WS_E_SAME` 幂等 |
| `sess-meta-big` | ~3 MiB 日志 `sess_read_meta` 段错误回归（未修 139）、残行 `dropped_tail` |
| `model-catalog` | provider 级 compat 继承、档位集合、`reasoningEfforts: false` 不公布、`none`==`off` |
| `model-apply` | 切换跟随能力、旧档位回落 `off`、幂等返回 1、目录外不动能力 |
| `effort-apply` | 公布的收、同值幂等返回 1、未公布拒 2、透传但 `effort_set=false` |
| `model-log` | `session/model` 三字段取最后一条 |
| `worktree` | 真 git：建 worktree + `dsh/<slug>`、闸门、`wt_finish` 合并且目录消失 |
| `worktree-discard` | `wt_discard` 不合并；非仓库 `wt_provision` 判 `SKIPPED` |
| `worktree-tool-msg` | 踩坑 80：走**真工具入口**带 `message` 的 finish —— `git log -1 --pretty=%s` 读回来的提交说明**逐字节**等于传入的 marker（`wt_finish` 把 `msg` 当 C 串，JSON 解出来的 Buf 没有 NUL 时会读到堆尾巴） |
| `worktree-reclaim` | P49 残留回收（真 git，逐条对照）：**干净 + 零提交**的清了（目录与分支都没了）；**有未提交改动**的留、**有未合并提交**的留、**有活进程 cwd 在里面**的留（真 `fork`+`chdir`+`exec sleep` 当占用者，杀掉之后同一份扫描又能清掉它 —— 证明判据 ③ 真在判「活着」而不是碰巧被别的原因挡着）；**孤儿分支**（目录已没、`worktree list` 列不到）零提交的清掉、有提交的留（这一条钉的是判据自己：断言查报告里**没有** `kept branch …(git refused)`，否则会被 git 的第二道闸门兜成假绿 —— 第一版就漏在这儿）；`wt_reclaim_own` 清掉自己的空 worktree 后 `phase=DISCARDED` |
| `tui-model` | `/model` 与 `/effort` 浮层：分组标题、`✓` 只在当前行、只列公布档位 |
| `ws-tool` | workspace 工具：失败状态不变、日志/索引写入、`/diff` 头短路径 |
| `diff-git` | 真 git：XY 码/numstat、未跟踪/删除、`gd_refresh`、P36 跨文件跳转 |
| `tui-approve` | read-only 逐条批准：headless fail closed；真 PTY `↑`+回车后命令真跑 |
| `sig-abi` | `SigxAction` = 宿主 glibc 布局（152 字节）；恢复序列 26/18/31/23 字节 |
| `sig-basic` | 处理器真被调用、进程还活着；`SIGWINCH` 只置标志 |
| `sig-term-restore` | 收到完整 26 字节恢复序列、退出码 143 |
| `sig-child-reset` | `sigx_reset_for_child()` 后死于信号 15，不写父进程 fd |
| `preset-knobs-dshsess` | 假 preset 旋钮与 persona 标量；假 DSH 会话扫描/导入角色序列 |
| `workflow` | 五钩子协议 + 真 `uya run` 编译 `.ush` 脚本 |
| `subagent-goal` | 9 调用：goal 三工具、`subagent`/`subagent_output(wait)`、`ralph(maxRounds=2)` |
| `tasks-render` | 进度条/百分比/体量、空态零字节、箱体 11 行逐行等宽 |
| `tasks-scroll` | `--no-tui`：折叠行与 agents 箱体进面板；展开后每行 98 列 |
| `tui-tasks` | 常驻任务块层序、`ctrl+t` 只置 `TUI_REQ_TASKS`、矮/窄退化；P29 `/goal` 浮层 |
| `skills-web-search` | 目录型技能注入 + `skill` 工具；Anthropic 形状 `web_search` 鉴权与去重 |
| `compact-prune` | 20000 字符输出 → 剪枝标记、完整中段消失 |
| `compact-auto` | 窗口 200 触发：摘要请求 → `automatically generated checkpoint` |
| `history-long` | 40 轮 × 2（≈124 条）配对完整、最后一轮 80 条工具结果不少 |
| `hist-repair` | 完整组不丢、缺应答整组丢、`hist_pairing_ok` 复核 |
| `prompt-todo-plan` | system prompt/`{{cwd}}`/AGENTS.md 注入、请求无 NUL、todo 与 plan |
| `bash-jobs` | 一轮 6 调用：后台短/长任务、`job_list`、`job_output(wait=true)`、`job_kill` |
| `fs-tools` | 一轮 10 调用：write 未读拒、edit 多匹配拒、glob/grep；落盘逐字节 |
| `dsh-config` | 假 `$DSH_HOME`：YAML 预处理与四层凭据来源 |
| `resp-text` | `output_text.delta`；`input_tokens(100)-cached(40)=60`；`event:` 行忽略 |
| `resp-tools` | `reasoning_summary_text.delta` + 两 `function_call` arguments 交错分片 |
| `resp-args-done` | 只在 `output_item.done` 给完整 `arguments` 也能补齐 |
| `resp-terminal-only` | 只发 `created`+`completed`，正文在终局 `response.output[]` 回填 |
| `resp-incomplete` | `response.incomplete` → `finish=max-tokens` |
| `resp-failed` | `response.failed` → `finish=error`，不是 `STREAM_CLOSED` |
| `resp-noterminal` | 缺终局事件 = `STREAM_CLOSED`，正文保留 |
| `resp-doneframe` | 代理多补 `[DONE]` → 正常收尾 |
| `resp-chatshape` | 网关按 chat 形状回流 → 兜底解析仍拿到正文 |
| `resp-badjson` | 半截 JSON 帧 → `MALFORMED_RESPONSE` + payload 头部 |
| `resp-nonstream` | `responses_out_from_nonstream`：output[] 各类型 + usage |
| `resp-build` | 扁平工具 schema + `build_model_request` 的 input/store/max_output_tokens |
| `api-negotiate` | 仅 404/405/501 可协商、协商一次锁存、DSH `api:` 落到 cfg |
| `responses` | mock mode 19：整轮走 `/v1/responses`，`function_call` 配对 |
| `responses-nostream` | mock mode 20：`--no-stream` + responses |
| `responses-fallback` | mock mode 21：`/responses` 404 → 同一步改 chat，只协商一次 |
| `responses-compact` | mock mode 22：摘要与压缩后请求都走 `/v1/responses` |
| `api-flags` | `make e2e-api`：默认 responses+negotiable；`--api=chat`/env 生效 |
| `tasks-e2e` | `make e2e-tasks`：`/tasks`、`open`/`toggle`、非法参数报错 |
| `goal-cmd` | P29 `/goal` 纯函数：控制词独占整行、状态块四段、`clear` 幂等；**P58 续跑判定九腿**（未授权 / 授权即开 / 轮号递增 / complete 停 / 轮次用尽标 blocked+round-limit / resume 重开 / pause 收授权 / **objective 转义与信封完整性** / 无目标不开） |
| `goal-e2e` | `make e2e-goal`：真 REPL 11 条命令逐条 grep |
| `sess-list` | 去重取最后一条、按 `lastActiveAt` 降序、8 档列宽退化、完整 id |
| `sess-list-big` | 踩坑 68：6000 行大索引 —— 归并排序与「金标准（未修的插入排序）」逐行等价、两把键各自有序、排两次结果相同、去重 2000 条、行尾 id 完整（抽查首/中/末） |
| `tui-switch` | P39 换会话：清转录 → 回放 → 回执、脚注保留、滚动模式不动；P25 会话级状态：`/new`、`/resume` 清空 todo 清单（屏幕与 `g_todos.n` 两处），目标不跟着清 |
| `tui-sessions` | `/sessions` 浮层：箱体铺开、默认游标在最后一项、完整 id |
| `tui-sessions-big` | 踩坑 68：2000 项 —— 取行查表 vs 线性扫描**差分逐字节相同** + 取末项 20000 次的自校准比值（查表 ≪ 扫描）+ 第 0/中/末项文本正确 + home/end/↑/↓ 与 sel_set 自洽 + 列表与 reader 成帧各 < 1 s + 正文层无 ESC/NUL |
| `tui-model` | P37 `/model`/`/effort` 浮层：按提供方分组、只列公布的档位、反解、非推理模型不开浮层 |
| `tui-worktree` | P41 `/worktree` 动作选择浮层：标题/八个动作/✓ 标当前模式、反解只认动作行（「取消」不认）、默认游标 = `status`；`finish`/`discard` 选定不生效、先翻确认框（默认游标 = 取消）；**真 git**：确认前 worktree 目录与 phase 一个字节不动、确认后才合并 + 删除 |
| `tui-mouse` | 踩坑 72 鼠标上报开关（`F2` / `/mouse` / `--no-mouse`）：标志位默认开 + `tui_set_mouse` 幂等；`F2` 两种编码（`ESC O Q` / `ESC[12~`）与 `/mouse on·off·非法`；**字节级**进/关/再开/关着进都与开关一致；帮助浮层里有 `F2` 那一条；**真 PTY** 两个方向（默认开必有 `1000h`、`mouse=false` 必无 `1000h`/`1006h`） |
| `title-cmd` | P48 `/title` 与 `set_title`：清洗（80 B / 码点边界 / 控制序列全丢后为空 ⇒ 报错且标题**不动**）、钉住语义（`user` 置位后自动起标题不跑、`clear` 解锁）、revision 门控（同一条人类消息只生成一次）、落盘事件逐字节（kind 三档 + clear 的**空标题**事件）、索引同步、`set_title` 工具三支（合法/空串/缺键）、工具目录里有它 |
| `tui-paste` | P50 括起粘贴九段：进/出粘贴态的字节级判据、CR **不许**提交（踩坑 83 的原始症状）、CRLF 折成一个换行、TAB 是字面内容且**帧里**不出现 TAB、粘贴里的 ANSI 序列逐字节保留、收尾标记被切开也认、断流时悬着的 ESC 不吞、上限对齐 200000 且超限有提示、光标列按显示口径（TAB 四个空格）+ **真 PTY** 粘 3 行只提交一次（按会话日志断言） |
| `img-sniff` | P51 图片纯函数层：**真 PNG 字节**（zlib 压出来的 64×48）读尺寸、GIF87a/89a 小端、JPEG 段链（长度段在前，尺寸不在固定偏移）、WebP 三变体（VP8X/VP8L/VP8 ）、纯文本与截断 PNG 一律拒绝、字节/像素两道预算、内容寻址 id 稳定、base64（长度与 PNG 签名）、附件 JSON 往返（**数字字段** + 坏记录只跳那一项）、占位文案与 B/KiB/MiB 三档 |
| `clip-parse` | P52 X11 客户端可测部分：`DISPLAY` 五种形态（`:0`/`unix:7`/`host:1.0`/空/畸形）与三种畸形拒绝、**真 Xauthority 字节流**的两条目配对（family 256 + display 号 + MIT-MAGIC-COOKIE-1；不存在的 display 号**不许**回退到别的条目）、失败码文案非空 |
| `tui-title-input` | P48 标题输入框：预填 AI 建议可见 + 编辑（打字/backspace/delete/←→/home·end/ctrl+u/中间插入，**按码点**不劈汉字）+ enter 采纳交回编辑后的文本 / esc 取消**不算改名** + 太矮回落 0 + 方框逐行闭合 + 窄框不越界 + 运行中 `/title <t>` 进安全集而裸 `/title` 不进 |
| `title-cmd-e2e` | `make e2e-title-cmd`：行式真二进制的用法串 / 改名回执 / `/status` 的 title 行 / clear / 空标题报错 / `/help` 可查 / 索引与日志落盘 |
| `title-auto-e2e` | `make e2e-title-auto`：真 PTY + 假网关 —— 自动起标题**多发一次请求**并落 `kind=provider`；`--no-title-auto` 两样都没有；三来源（default/env/cli）与 CLI 优先 |
| `tui-md` | P47 markdown 渲染七段：① 行内（`**粗**`/`*斜*`/`~~删~~`/`` `code` ``/链接：标记不上屏、样式落在正确的列、`snake_case` 不被误判）；② 块级（标题去 `#` 并按级着色、无序/嵌套/有序列表、任务清单 `✓`·`·`、引用 `▏ `、分隔线、围栏去标记留语言标签且块内 CODE）；③ **长行不丢字**（60/80/100 列下 100 字符代码行 + 100 字符正文 + 60 汉字逐字符完整、且那些行没有 `…`）；④ **滚到代码块中间样式不串**（贴尾与上滚两面，闭合围栏不再被当成开始）；⑤ 表格（表头 BOLD、框线 DIM、各行列宽一致、8 列在 40 列下整块退回普通行且不丢内容）；⑥ plan 审阅浮层共用同一份渲染 + 方框逐行闭合；⑦ **长条目取行 O(1)**（查表 vs 线性扫描逐行差分 + 贴尾首帧/缓存帧/上翻 20 屏三条成帧预算） |
| `sessions-e2e` | `make e2e-sessions`：最新在最后一行、空标题落 `(无标题)` |
| `resume-big-e2e` | `make e2e-resume-big`：~3 MiB 会话 + 残行，`--resume --dry-run` 退出码 0 |
| `diff-render` | 纯函数：上下文、`… (省略 36 行)`、按显示列截断 |
| `tool-view` | P16 单行：`· exit N`、`· +A -D`、默认无正文、fd 2 端到端；工具内容块 + 多行面板块渲染协议 |
| `think-row` | 运行中从左截断、结算从右截断、`--quiet` 零字节、静音窗口 |
| `reasoning-log` | 日志 `assistant/reasoning` 与 mock 回包逐字节相同 |
| `subagent-panel` | 只收 running、每行显示列数 = `tty_body_width()`、秒数固定 5 列；P40 贴尾：纯函数 `view_ag_msg`/`view_ag_preview` + 80/40/200 列三档面板（锚一个不少、最新一段可见、消息开头不在板上、宽面板顶满预算） |
| `watch-render` | P42 `/watch` 事件渲染纯函数：`[step N]`（step 是数字）、`▸ 工具 参数`、`  ← 结果`、`✻ 思考 · 首行`、`⏺ 正文首行`、只有 tool_calls 的消息不单出一行、`step/end` 与未知类型静默跳过 |
| `watch-poll` | P42 `/watch` 增量读：分批写文件只取新增、**半行不吐**（补齐后才出现）、没有新字节时一个字节都不重渲染 |
| `watch-e2e` | `make e2e-watch`：真终端 + 假网关派一个「先思考、再跑 `sleep 8` bash」的子代理，`/watch sub-1` 后 `[step …]` 与 `▸ bash …` 必须**在子代理结束之前**上屏 |
| `watch-pick-parse` | P46 现役清单行 → 编号（纯函数）：`  sub-12 [running] …` 整段取两位数、标签里的 `sub-3` 不抢先、表头的 `sub-N`（N 不是数字）与空态行都不认、认出的编号必须能过 `deleg_id_parse` |
| `tui-watch-pick` | P46 清单浮层的 kind 是自己的 `TUI_OVK_WATCH_LIST`（借 `/tasks` 的 kind ⇒ 回车的结果被静默丢掉）+ 默认游标落在第一个代理行（喂一份带表头的清单给 `agent_watch_list_first_row`）+ 回车交出选中行原文 + 三条失败路都有回执（表头行、刚跑完的编号、`/watch sub-9`）+ 三种落点码 + 带参数的 `/watch` 在只读集合里 |
| `tui-full` | P53 浮层全屏四组：**A** 非全屏仍是居中框（不顶格、`≤16` 行上限、第 30 项看不见）→ 全屏框 = 转录区（顶边第 0 行、左右边框 0 与 `cols-1`、标题 ` · 全屏`、行偏移表口径的逐行闭合、底边**正好**在 `panel_top-1`）+ 16 行上限解除（第 20 项可见、第 30 项仍不可见）；**B** `ctrl+f`（`0x06`）与 `F11`（`ESC[23~`）都切换，且**四种形态各认一次**（列表 / reader / ask / input）；**C** 不吃面板 / 状态区 / 脚注；**D** 没浮层时只落 notice、全屏态不跨浮层残留、`esc` 关掉后转录回来，终端太矮时 fail-closed 判据不变；**F** `/fullscreen` 四态（裸报状态 / `on` / `off` / 非法值只报错且状态不动、重复 `off` 幂等） |
| `overlay-fullscreen` | `make p30-check` 第 9 场（真终端 + 假网关）：屏幕几何判据 —— 非全屏顶边 > 0 行且左边框 > 0 列 → `ctrl+f` 后顶边第 0 行、左右边框正好 `0` 与 `cols-1`、标题带 ` · 全屏`、面板与脚注都还在、底边行 < 面板行 → `F11` 关回居中 → 再全屏、`esc` 关掉后方框消失 |
| `watch-pick-e2e` | `make e2e-watch-pick`：真终端 + 假网关两条腿 —— ①裸 `/watch` → 清单 → **一次回车**开跟随浮层（`[step …]`/`▸ bash …` 仍在子代理结束之前上屏）；②假网关把父代理的收尾按住 12 s，期间敲 `/watch sub-1` 必须**当场**开浮层（屏幕上还没有 `PARENT-DONE-OK`） |
| `session-log` | 控制字节按字节往返、半条记录 `dropped_tail`、重建历史 |
| `json-escape` | `0x00…0x1f` 全转义、无裸控制字节、`jw_key` 同规则 |
| `ctrl-bytes` / `ctrl-bytes-resp` | mock mode 23：`printf 'A\000B'` 以 `\u0000` 回请求；判定码 240 |
| `diag-preview` | cap 停字符边界、`\xNN`、`out_diag` ≤512 B |
| `diag-echo-400` / `diag-echo-400-ns` | mock mode 24：400 回显 → fd 2 一行转义预览、无裸 CR/NUL/ESC |
| `empty-retry` | P54（mock mode 41）：第一轮回「finish_reason=stop + 只有思考、没有正文」→ 转录里那一行证据（`finish=stop have_finish=1 bad_finish=(none) content=0B reasoning=45B calls=0 usage={in=60 cache_read=40 cache_write=0 out=7 reasoning=3} prompt=…B/100tok retries=0/1`）+ 日志一条 `llm/degenerate`（字段逐项核对）→ **同一步重发**：第二轮请求与第一轮**逐字节相同**、`step/start` 仍只有一条、唯一那条 `assistant/message` 的正文是 `SELFTEST-RETRY-OK`、回合退出 0 |
| `empty-retry-giveup` | P54（mock mode 42）：重发也只给空响应 → 只重发**一次**（两条 `llm/degenerate`：`retrying=true/retries=0` → `retrying=false/retries=1`）、退化那一步**一条 `assistant/message` 都没有**、转录里留下带同一条证据的错误行、回合按协议错误退出 3 |
| `tui-diag` | 4 KiB JSON 只留 ≤512 B、半截汉字变 U+FFFD、`tty_sink_on` 收尾关回 |
| `read-window` | `(Showing lines 1-1000 of 4000. …)`、`offset=3500` 真读到、`limit=2000` |
| `title-format` | OSC/CSI 清洗、40 B/80 B 上限切码点边界、`ESC[22t`/`ESC[23t` |
| `tty-title-pty` | 滚动模式真 PTY：`fd 2 + 无备用屏幕` 接线，弹栈在最后标题之后 |
| `http401` | mock 401 + 错误体：打印状态与错误体并退出 3 |
| `max-steps` | 显式 `max_steps=3`：3 步后熔断退出 3 |
| `unlimited-steps` | 默认不限步数：跑满 14 步、14 条 `tool_call_id` 带回、退出 0 |
| `hist-keep` | `hist_drop_oldest` 留住 system 与任务原文、整组丢 tool；40 组后原文仍在 |
| `toolcalls-cap` | 踩坑 35：`jw_str_esc_len` 与实际逐字节相等、`calls_json_need` 预算严丝合缝 |
| `toolcalls-big` | 踩坑 35（mock mode 25）：9.6 KiB `write` 头尾标记回到第二请求、`agent_run` 返回 0 |

**验证用的 make 目标与快捷入口**

- 总闸门：`make selftest`（离线，含 `p30-check` 与全部轮次，SELFTEST PASS / 退出 0）、`make e2e`（真网关）。
- 离线配套：`make check`（A1 类型检查）/ `build`（A2 产出 `build/uya-agent`）/ `codegen-audit` / `tui-selftest` / `shell-selftest` / `e2e-config-flags` / `e2e-api` / `e2e-steps` / `e2e-permission` / `e2e-sandbox` / `e2e-tasks` / `e2e-goal` / `e2e-sessions` / `e2e-resume-big` / `e2e-title` / `e2e-model` / `e2e-worktree` / `e2e-diff` / `e2e-watch` / `e2e-watch-pick` / `diff-selftest` / `panel-selftest` / `e2e-ws`。
- PTY 场景：`make p30-check`（`testdata/pty_drive.py --suite`，8 个场景；P41 那场 `worktree-menu` 走
  两条入口 —— 命令面板里选中 `/worktree` 与裸 `/worktree` —— 到选择框 → ↓ 到 `finish` → 确认框 →
  回车取消，`PTY_DUMP=1` 会把两张框打出来）；
  `make tui-demo` 是排版基准：P47 之前各阶段只差脚注版本串（`p22-tasks` … `p46-wpick`），
  P47 起正文那一屏按新的 markdown 排版变（标题/强调/列表/引用/带语言标签的代码块/表格），
  脚注仍是版本串那一处；P53 新增第 ⑦ 屏（浮层全屏）并把前六屏**逐字节**保持不变
  （非全屏路径一个字节没动，所以这条本身就是「没有回归」的判据）。
- 只跑子集的开关：`UYA_SELFTEST_TUI_ONLY`、`UYA_SELFTEST_PERM_ONLY=1`（P21+P26）、`UYA_SELFTEST_GOAL_ONLY=1`（P29）、`UYA_SELFTEST_SHELL_ONLY=1`（P38）、`UYA_SELFTEST_PANEL_ONLY=1`（P15+P40，`make panel-selftest`）、`UYA_SELFTEST_EMPTY_ONLY=1`（P54，退化响应两轮 —— 跑对照实验时用它，一次约 0.2 s）。
- 探针：`make probe BASE=https://api.deepseek.com/v1` 期望 HTTP 401 + leaf 指纹。

**load-bearing 硬指标**

- PTY 延迟预算：`/status` 浮层 ≤800 ms、空闲 ≤150 ms、bash 跑着 ≤200/300 ms、压缩在飞 ≤300 ms。P30 实测 103–105 ms（旧 2245 ms）；P31 五场景 101/53/62/102/63 ms（旧 103/2280/242/103/2833 ms）；P39 `new-mid-turn` 回执 112 ms、中断 172 ms。
- 退出码：正常 0；401 / 熔断 / `tool_calls` 序列化失败 3；崩溃 139；`SIGTERM` 143；`SIGKILL` 137。`resume-big-e2e` 未修 139 → 修后 0。
- 结构尺寸：`sig-abi` 152 字节；`sig-term-restore` 恢复序列 26 字节（P22 四形状 26/18/31/23）；`tty-editor` termios 60 B；P32 四形状 42/34/47/39；`--title` 40 B / 80 B 上限切码点边界。
- 容量：`unlimited-steps` 14 轮；`history-long` 40×2 ≈124 条 / 80 条工具结果；`toolcalls-*` 9849 / 9618 字节（旧固定 8192）；`read-window` 4000 行 / 160 KB（读缓冲 116736）。
- 逐字节不变量：每行显示列 ≤ cols 且正文层无 ESC / 无 NUL；diff 两栏竖线同列、改动行左右边界列相同；请求体无裸控制字节（判定码 240）；NUL 必须往返成 `\u0000`；SGR 编码 `ADD`=`38;5;42`、`ADD_BG`=`48;5;22`、`DEL_HL`=`48;5;124`；`stats-format` 缓存命中 12.5%→13%。
- 真机：`autodl-api` / `DeepSeek-V4.1-Flash`，pin 指纹 `d0265eff…42538`；A5 任务 `write → bash → 结论` 3 步、产物 `hello` 独立运行输出 `Hello, Uya!`。`~/.dsh/.credentials.yaml` 那把 key 402 `Insufficient Balance`，故走 autodl 网关。Responses 真机只验到 `--print-config` 读对 `api = openai-responses (source: dsh-settings)` 且请求真打到 `/v1/responses`（`tirisen` 502、`aigw` DNS 失败）。

**分阶段验收要点（压缩）**

- P1/P2：5 轮流式轮 + 6 轮既有轮全过；请求字节断言 `"role":"assistant"`/`"tool_calls"`/`"tool_call_id"` 配对（shell 2 / no-shell 1 / tools 4）；真 pty（`script -qec`）验 raw 模式、粘贴 4 行拆 4 次提交。
- 中文乱码：一次性终端模拟器逐屏校验；修前 66 个替换符 → 修后 0；常驻回归是 `tty-editor` + `make codegen-audit`。
- 历史容量 / 尾部修复：旧实现 `dropped oldest message` + `could not append tool result to history`（返回 3）→ 修后 41 次请求全配对、80 条工具结果不少；真实故障会话旧丢 59 条 → 新丢 0、配对违规 0。
- 控制字节：本地假网关复现裸 `\x00`（真机 `invalid character '\x00' in string literal`）→ 修后 `A\u0000B`；真机 `--resume` 正常；chat 与 responses 各跑一遍。
- 踩坑 35：固定 `buf_new(8192)` 导致 `out of memory serializing tool_calls`；改按 `calls_json_need` 算容量后旧 exit 3 / 1 请求 → 新 exit 0 / 2 请求。
- P19：`testdata/mock_gateway_echo.py` 对照，流式 297 B/6 行 → 315 B/3 行、非流式 4153 B/12 行 → 405 B/3 行（裸 CR 0）；另有 `diag/dump` 事件与 `--debug-dump` 原文；read 窗口旧报 3080 行 → 新报 5949 行。
- P22：真 PTY 逐场景抓 OSC 2；`--no-title` / `UYA_AGENT_TITLE=0` 全 0；`SIGTERM` 143；`--resume-dsh` 导入 109 条取**最后一条**标题。
- P23：`/status` 四症状复现（输入行留 `/`、运行中 15 s、标题混 10 个 `\x00`、内容不可达）→ 全修；新增全局不变量「正文层无 NUL」。
- P24：旧 `60087 tok / 8990 ms = 6684 tok/s` 对照真值 `124741 / 786.3s ≈ 158.6 tok/s`；真网关长回答 4236 ms / 290 tok/s。
- 踩坑 42 浮层右边框：70/80/100/120 列修前右边界 `{65,66}`/`{70,71}`/`{80,81}`/`{90,91}` → 修后 `{65}`/`{70}`/`{80}`/`{90}`；回归落在 `tui-frame`。
- P25：空态零影响逐字节；`--tui-demo` 第 ④a/④b/④c 屏是真机产物。
- P26：`session-6918e8ef` 里模型在 plan 模式直接开工 = 「只有提示词没闸门」；闸门按现场补，把 `plan_blocks_write()` 改恒 `false` 该轮立刻红。
- P28：真机 A/B：`ctrl+d` 45 s 仍活 → +2.0 s 退出；`esc` 后 `ctrl+d` +0.04 s；两次 `ctrl+c` +0.03 s。
- P29/P33/P34/P35/P37/P38/P39/P40/P41/P42/P43：见对应轮次与踩坑 50–67；`make selftest` / `make tui-selftest` 全绿、退出 0。踩坑 68 另记（见下一段）。
- P40：子代理面板状态行改贴尾 —— 真机那一幕是两条 `send_message` 续跑的子代理收到一两百字节的催促，老口径整行从右边截断，屏幕上只剩 `Your output was still far too verbose: 325 lines / 68 KB…`，最新那半句 `…Do a second pass and cut it to under 25 KB.` 正好被切掉；80 列下实测 `│ ● running      53s · 0 · …KB). Do a second pass and cut it to under 25 KB. │`（78 列）、40 列收成 `…r 25 KB.`（38 列）。照 ①把 `view_ag_msg` 改回贴左重编 → G 段红 5 条；②把 `VIEW_AG_MSG_MAX` 改回 160 重编 → 200 列那条腿红 1 条。
- P41：`/worktree` 补齐选择框。真 PTY（`worktree-menu`）实测：命令面板里选中 `/worktree`（ctrl+p → 敲名字 → 回车）62–65 ms 上框、裸 `/worktree` + 回车 62 ms，框里七行 + `✓ off`（当前模式关）都在，↓ 一次到 `finish`、回车 52–62 ms 翻出 `确认 finish？`（动作框同时消失）；确认框上再回车（默认游标「取消」）什么都没发生。`tui-worktree` 轮的**真 git** 那半：fixture 仓里 provision 出 worktree → 键盘走到 `finish` → 此刻目录与 `phase` 都还是 `READY`（没确认就动不了）→ 取消后主干上没有那个文件 → 把游标挪到 `finish` 那一行确认才 `merged … / removed worktree …`（目录消失、主干上出现文件、`phase=FINISHED`）。照 ①把 `wt_act_needs_confirm` 改成恒 `false` 重编 → 该轮红 18 条（确认框不再出现，`finish` 当场合并并删掉 worktree）；②把默认游标从 `WT_ACT_STATUS` 改成 0 重编 → 红 14 条（「打开就回车 = status」与后面整条键盘路径全崩）。
- 踩坑 66（运行中输入行没有光标）：真 PTY 逐字节抓帧 —— 修前运行中敲字 1.0 s 内 `ESC[?25l` **20 次 / `?25h` 0 次**（敲进去的 `abc` 确实进了输入行），修后同一场景 **`?25h` 20 次 / `?25l` 0 次**（每帧「定位 + 显示」，与空闲态同一条序列，所以照常闪动）。对照实验（防假绿）：把 `tui_cursor_place()` 的可见性改回 `run == IDLE` 重编，`tui-caret` 四条断言当场红（三态标志位 3 条 + 字节级 1 条），改回来全绿。`--tui-demo` 输出与修前**同目录逐字节相同**（50019 字节，布局没动；只有 cwd 那一栏会随目录变）。
- P43：`ask_user_question` 在 TUI 里改成提问弹窗（`tui-ask` 轮四段，见上表）。真 PTY 那半实测：任务打进去后浮窗把问题原文与 `1) alpha` / `2) beta` 画上屏（同屏**没有**输入行那条「（在输入行回答后回车…）」），敲 `2`+回车之后 mock 收到的第二次请求里工具结果是 `{"answers":[{"id":"q1","selected":["beta"]}]}` —— 弹窗交回的是**选项下标**、由 `askuser` 按下标回查 label（不是按行文本反解）。headless 那半（没人回答）结果是 `"selected":[]` + dismissed 文案，且**没有** `no answer channel`（渠道与「人不答」两件事分开了）。踩坑 67 那两条假红（请求体里引号是转义的、needle 必须 NUL 结尾）都是这一轮当场抓出来的。
- 踩坑 68（`/sessions` 选择框卡）：真 PTY（100 列）逐次量「按一次 ↑ → 下一帧到屏」。修前 842 个会话：打开浮层 1617 ms、底部按 ↑ 1617 ms，而**同一张浮层 HOME 跳到顶上只要 85 ms** —— 慢的是「跨多少项」而不是解析。修后同场景：打开 46 ms、按 ↑ 10 ms。数据侧 `--list-sessions` 12800 行：升序 1475 → 205 ms、降序 192 → 207 ms（修前两种顺序差 7.7×，修后拉平）。等价性：`--list-sessions` 在冻结索引 + 9 份合成夹具上逐字节相同；`--tui-demo` 逐字节相同（50019 字节）。防假绿对照实验：①把 `tui_ov_item` 的取行改回线性扫描重编 —— 逐字节比对与成帧预算**仍然绿**（兜底与查表结果一样），补了「查表 vs 扫描差分 + 取末项 20000 次自校准比值」后当场红（查表腿 vs 扫描腿 = 1 ms : 8166 ms，退回扫描后 ≈1:1）；②把 `sess_idx_before` 的 `lastActiveAt` 次级键写反重编 —— `sess-list-big` 立刻红（与金标准不符）；③行偏移表初版拿「下一行起点减一」当终点，末行多出 1 字节 ⇒ `--tui-demo` 逐字节对照当场红（reader 浮层末行多占一列、右边框被顶出去），改成存「每行的终点」后恢复。
- 踩坑 69（`/new` 后任务清单没清空）：`tui-switch` D 段在真实 globals 上装夹具（清单 2/4 + 后台 1/2 + 子代理 1/1 + 目标 3/20）→ `/new`（与 `/resume`）→ 清单清空且屏幕上没有「任务 2/4」、目标仍在。防假绿对照实验：①停掉 `agent_session_scoped_reset()` 的函数体重编 → 该轮红 4 条；②只去掉 `/new` 落点的 `tasks_panel_sync` 重编 → 红 1 条（「清状态」与「推显示」两截各自都被判到）。
- P44：修掉两处「配置静默失效」+ 加一段收敛纪律（踩坑 70/71）。真机对照实验基于同一个 LSM 编程任务
  （落盘 KV：WAL 恢复 / SSTable / 压缩 / 范围删除 / CLI，40 个验收 + 12 个隐藏测试），同模型
  `DeepSeek-V4.1-Flash`、同 `effort=max`、官方端点 responses 协议，逐次抓包与评分：

  | | 步数 | 成本/次 | 评分 |
  |---|---|---|---|
  | DSH（对照） | 7.5 | $0.0149 | 52/52 |
  | uya 改前 | 14.0 | $0.0161 | 52/52 |
  | uya 改后（①+②） | **10.0** | **$0.0124** | 52/52 |

  改前的问题不在提示词写了什么（两边任务相关的引导段几乎逐字相同；DSH 多出的 5 段全是本次没用到的
  工具），而在**收工时机**：uya 在第 8 步就把验收跑绿，之后又自造额外验证脚本、多走 4–9 步；
  DSH 绿后只再确认一次。逐运行口径（首次全绿步数 / 总步数）：改前 8/16、8/15、10/14、7/11；
  改后 6/12、7/9、7/9。
  * **① 推理强度**：completions 补发 `reasoning_effort`（真机抓包 `"reasoning_effort":"max"`）。
    效果**依网关而异**：官方端点同任务 `--effort max` vs `off` 的 reasoning 占输出 51% vs 27%
    （明显生效）；autodl 网关 12% vs 17%（该网关不认这个字段，发出去也没用）。收益主要是
    「`--print-config` 不再说谎」，不是省钱。
  * **② 收敛纪律**：省下的是上面那 4–9 步；`$0.0161 → $0.0124`、`14 → 10` 步、52/52 不变。
    附带发现：只把 persona 换成带 harness 身份行的版本**没有效果**（15/17 步），可排除「模型认出
    DSH 身份」这一解释。
  * **③ `--dsh-root`**：与 `--dsh-home` 同类，必须在预扫里生效；另外相对路径会静默失效（见踩坑 70），
    所以解析时就补成绝对路径。回归：`make e2e-config-flags` 新增夹具 `testdata/preset-root`
    （`readLimit=1777`）三向断言（带 flag 生效 / 不带 flag 不生效 / 旋钮来源为 preset）。
- P45：提问弹窗**框宽自适应内容**（`tui-ask` 轮新增 A2 段，见上表）。修前无论问题多短都撑满
  78 列（P43 直接沿用 reader 的宽度档），短问题（「选哪个？」+ 两个短选项）框里一半是留白、窄终端
  还会被压到 24 列。修后按显示列宽算内容宽度、夹在 `[34, min(78, 终端宽−6)]`：短内容实测 34 列、
  长问题 78 列；提示行与自定义占位改文案而不撑框（34 列框里 `enter 提交 · esc 取消` 的 `esc 取消`
  不被截掉）。对照实验（防假绿）：①把框宽改回固定 78 重编 → A2 段红 5 条；②上限放宽 10 列重编 →
  红 2 条；③提示行改成永不退让重编 → 红 4 条（含老段的「没有按键提示」）；④不夹 `max_w` 重编 →
  红 8 条（含「有行的显示宽度超过终端列数」）。`--tui-demo` 只在脚注版本串那 1 行变化（`p43-ask` →
  `p45-askw`），`tui-ask` 其余三段（太矮回落 / headless dismissed / 真 PTY label 回模型）不受影响。
  （**后续修正**：P45 那句「长问题 78 列」在本轮被推翻 —— 上限写死 78 是「长内容没有自适应」
  的根因，现在上限是「终端宽 − 6」；见踩坑 81 与 `tui-ask` 的 A2/A3 两段。）
- 踩坑 81（修复，不占阶段号）：**提问弹窗的长内容 / 多行内容不再跑出框外**。用户报两条症状
  （「内容很长时没有自适应」+「文本会跑出框外」），根因三个且都不是渲染算错：内容里的 `\n` 被
  原样画进「帧里的一行」（终端拆行 ⇒ 后一行从第 0 列开始、右边框错位）、宽度上限写死 78、
  问题正文只画一行。修法与六条防假绿对照实验见 §16 踩坑 81；`tui-ask` 轮新增 A3 段（长/多行/
  缩窗/脏标题/确认浮层/最矮终端六条腿），真 PTY 那条腿改用**长且多行**的问题（首末行都要上屏）。
  `--tui-demo` 与修前逐字节相同（浮层内的排版，demo 不画浮层），版本串不动（修复轮不占号）。
- P53：**浮层全屏**（`ctrl+f` / `F11` / `/fullscreen [on|off]`）。先把几何收成**唯一来源**
  （`tui_ov_box_w`，宽/高/左上角四个值一次算出）—— 修前宽/高/左上角在四份绘制里
  各写了一遍（列表型 / reader / ask / input），全屏要动就得改四处、漏一处就是右边框参差
  （踩坑 42 那一族）；非全屏路径**逐字节返回本线之前的结果**，所以 `--tui-demo` 的前六屏
  与本线之前完全一致（本轮新增第 ⑦ 屏 = 全屏的任务报告，是这一屏的排版基准）。
  全屏的确切含义：宽 = 终端列数、高 = `panel_top`（转录区）、左上角 = (0,0)，**不吃**面板 /
  状态区 / 脚注 —— 底边正好压在面板之上（`tui-full` 的 A 段把这条写成了**数值**判据）。
  验收：`make tui-selftest`（新增 `tui-full` 轮，四组）＋ `make p30-check`（新增第 9 场
  `overlay-fullscreen`，真终端里的屏幕几何判据：非全屏顶边 5 行 → `ctrl+f` 后顶边 0 行、
  左右边框 [0, 99]、底边 26 < 面板 27 → `F11` 关回顶边 5 行 → 再全屏、`esc` 关掉后方框消失）。
  **三条防假绿对照实验**（各自单独回退都会让 `tui-full` 红）：
  ① 让 `tui_ov_box_w` 恒返回基准宽（= 全屏不做宽度）→ 红 **5** 条（右边框没到最后一列）；
  ② 把全屏键的路由从「所有形态分派之前」挪到 reader/ask/input 三条 `return` **之后** → 红 **12** 条
  —— 正是「reader/ask/input 各认一次」那三条腿在报「ctrl+f 没有全屏」，证明那个位置是**承重**的
  （放到后面就只有列表型能全屏，看着像「按键时灵时不灵」）；
  ③ 让全屏顺手把面板也吃掉（高度用整个 `rows` 而不是转录区）→ 红 1 条（底边 29 ≠ `panel_top-1` = 26）。
  ⚠ 实验 ③ 第一版是**假绿**：`tui-full` 的 C 段当时只断言「面板那行文字还在」，而帧组装里
  面板是在浮层**之后**补画的 —— 框画过头盖住面板，面板又被盖回来，屏幕上照样看得到那行字。
  补上「底边必须正好在 `panel_top-1`」这条数值判据（放进共用的 `tuis_full_frame_ok`，三种形态
  一起管）当场红。这条教训与踩坑 65 同族：**判据要读事实，不能读「看起来还在」**（详记 §16 踩坑 83）。
  另有两条本轮自测自身踩的坑与一处状态泄漏，都记进 §3（踩坑 83）。
  ⚠ **本轮最大的坑不在功能里，在编译器的容量上**：uya 0.10 的「函数表」是固定容量
  （`FUNCTION_TABLE_SIZE`，写死、无开关），而本仓**已经贴着上限**（main 6756 声明通过 /
  +1 个函数就红）—— 第一版实现净增 12 个函数，增量 `make build` 全绿，
  **清掉 `build/uyacache` 重编**才炸（报错点还在标准库里）。最终把净增函数数压到 **0**
  （几何/全屏态/命令各自合并，外加删掉两个零调用的死转发）。细节与实测边界表见 §16 踩坑 84 ——
  结论是**改完必须 `rm -rf build && make build` 走一遍**，增量绿不算绿。
  编号说明：P49 被并行线 `dsh/session-d7d9b709`（残留 worktree 回收）先占了，按「后到的顺延」
  记成 **P53**，版本串 `p53-full`。
- P48：会话标题**执行中就能改**（`/title` / `set_title` 工具 / 模型自动起标题）。
  三条语义钉在同一处（`agent_title_set_kind`）：清洗到 80 B（码点边界）、`kind=user` 钉住、
  落一条 `session/title` + 写 `index.jsonl` 的 title + OSC 2；`/title clear` 落一条**空标题**的
  user 事件（不落的话 `--resume` 折叠到最后一条旧事件会把标题复活 —— `title-cmd` 轮钉住这条）。
  验收：`make e2e-title-cmd`（语义/措辞/落盘）+ `make e2e-title-auto`（真 PTY：自动起标题真的
  多发一次请求并落 `kind=provider`；`--no-title-auto` 两样都没有）+ `title-cmd` 轮（钉住与
  revision 门控 / `set_title` 工具 / 索引同步）+ `tui-title-input` 轮（输入框排版与编辑 /
  太矮回落 / 运行中 `/title <t>` 当场生效而裸 `/title` 不当场派发）。
  **本轮被自己的验收抓到两条真缺陷**（都记在 §3）：① 自动起标题的请求在飞时读键盘，用户那几秒
  敲的字被半路取走，`/status` 被拼成 `//status` → 「未知命令」（p30-check 的 status-during-compact
  当场红，304 号判据）；② 命令面板的结果被推迟到 step 边界派发时，触发用的那个 `/` 留在输入行里，
  用户接着敲的下一条命令同样被顶成 `//`（同一个现场暴露的**存量**缺陷，修法是把 `/` 的收走
  从「派发时」提前到「accept 时」）。修法见 §16 踩坑 79；`p30-check` 的
  status-during-compact 是本轮最有价值的一条判据。
  收尾时又逮到一条**存量缺陷**（见踩坑 80）：`worktree` 工具带 `message` 的 `finish` 把
  merge commit 的说明写成了「传入的 message + 堆尾巴」（`msg` 是 JSON 解出来的 `Buf`、
  没有 NUL，而 `wt_finish` 按 C 串读它）—— 这次是在**我自己调 `worktree finish` 合并回主干**
  时被落盘的提交说明直接照出来的，随后补了 `worktree-tool-msg` 轮（真工具入口 + 逐字节比对），
  两个修法各自单独回退都会让新轮红。
- P47：**TUI 的 markdown 渲染 + 修「长行静默丢字」**（`tui-md` 轮六段，见上表）。这是本轮
  唯一一处「先量出缺陷再动手」的：动手前先用临时探针（不进仓库）在当前 main 上量到三件事 ——
  * **长行静默丢字符**（根因：折行按 `cols-6`、绘制按 `cols-7`，列表/代码行绘制时再扣 2 列）：

    | 画布 | 100 字符代码行 | 100 字符正文 | 60 个汉字 |
    |---|---|---|---|
    | 60 列 | 97/100 | 99/100 | 58/60 |
    | 80 列 | 97/100 | 99/100 | 59/60 |
    | 100 列 | 97/100 | 99/100 | 59/60 |

    修后同一探针：60/80/100 列下三档全部 `100/100`、`100/100`、`60/60`，且那些行没有 `…`。
  * **滚到代码块中间串样式**：贴尾时 `code-line-23` 样式 = 默认、闭合围栏被当成「开始」、
    之后的正文被染成代码样式；修后上滚 12 行，窗口内的代码行仍是代码样式、闭合围栏不再当开始。
  * **markdown 语法按字面量上屏**：`**粗体**`、`*斜体*`、`~~删除线~~`、`[文字](url)`、`> 引用`、
    `- [x]`、`---`、`| 列A | 列B |` 表格、```` ```uya ```` 语言标签 —— 修后逐项按上表渲染。
  防假绿对照实验四条（每条都实测到红，再改回全绿）：
  ①把绘制侧恢复成旧的「按 `cols-7` 裁剪」重编 → `tui-md` 红 8 条（含「代码块里的 100 个字符
  没有全部上屏」）；②把 `tui_style_from_mdv()` 恒返回默认样式重编 → 红 **12** 条；
  ③把样式改由「帧级标记」决定（进过代码块才染色、且标记不随窗口重置）重编 → 红 8 条，其中
  **「窗口落在代码块中间时代码行掉了样式（旧的帧级围栏状态）」正是本轮要钉的那条**；
  ④表格无视预算直接渲染重编 → 红 3 条（含「有行的显示宽度超过终端列数」与「40 列下 8 列表格
  本该退回普通行，却还是画了框线」）。
  顺带修的：`tui-plan` 的 `│ # 计划标题` 断言改成 `│ 计划标题`（标题已去 `#`）**并**断言没有 `# `；
  `--tui-demo` ②屏的正文换成真实形态的 markdown（标题/强调/列表/引用/带语言标签的代码块/表格），
  脚注只差版本串（`p45-askw` → `p47-md`）。三条**自测自身**踩到的坑都记进 §3：字面量长度手数错
  （`· ` 是 3 字节不是 4）、拿 `bufx_cstr_len` 量裸 malloc 的动态夹具（踩坑 57/67 同款）、
  以及「整屏有 `…`」这种假判据（`…` 还会来自脚注缩略与任务块的「还有 N 行」）。
  收尾按自测纪律做稳健性扫查时，**顺手量到一个更要命的东西并当场修掉**：
  一个几 MiB 的长助手条目进转录之后，**每一帧**都要几秒（贴尾也一样）—— 根因是条目取行
  `tui_entry_line(i, k)` 为取第 k 行从 wrap 头部重新扫一遍，而 draw 循环对每个可见行都调它
  一次（O(条目 × 可见行)）。这与踩坑 68 的 `/sessions` 卡顿是同一族，**条目这条路当时漏了**
  （浮层条目与 reader 正文都挂了行偏移表，只有转录条目没挂）。修法是复用同一张 `TuiLineIdx`：
  折行后就地建表 O(n)，之后每帧取行 O(1)。同夹具 A/B（80×40、12 个条目、12600 折行行）：

  | | 贴尾首帧 | 贴尾缓存帧 | 上翻 20 屏 |
  |---|---|---|---|
  | 修前（线性扫描） | 4774 ms | 4425 ms | 86532 ms |
  | 修后（行偏移表） | 199 ms | **0 ms** | **17 ms** |

  对照实验（防假绿）：把 `tui_entry_line` 强制走线性扫描（`tui_entry_force_scan(true)`）重编 →
  `tui-md` 的 G 段**三条预算全红**（首帧太慢 / 缓存帧太慢 / 上翻 20 屏太慢）；该段还带一条
  **查表 vs 线性扫描的逐行差分**（两条路必须给出同一区间）。另：`--tui-demo` 与修前
  **逐字节相同**（纯性能修复，渲染一个字节没动）；`make selftest` 只剩长路径下既存的
  `tui-diff` 那条环境相关失败。
- P46：`/watch` 的**现役清单选中即跟随** + 把三条「敲了没反应」的静默路一起堵掉（清单 kind、落点码、
  只读命令在泵点当场派发；细节见踩坑 73）。真 PTY + 假网关的两条腿（`make e2e-watch-pick`）实测：
  ①`pick`：裸 `/watch` → 清单（标题带「回车跟随」、游标已在 `sub-1` 那一行、回车后没有「没认出编号」
  的 notice）→ **一次回车** 1.2 s 开跟随浮层，`[step …]` / `▸ bash …` 0.3 s 就上屏；
  ②`running`：假网关把父代理的收尾**按住 12 s**（网关日志 `REQ #2 kind=parent-final` + `HOLD parent-final 12s`），
  期间敲 `/watch sub-1`（面板拦一道 → 提示「再按一次回车」→ 第二次回车派发）→ **1.2 s** 开跟随浮层，
  当时屏幕上还没有 `PARENT-DONE-OK`。对照实验（防假绿）：①旧二进制（`git checkout -- src/` 重编）+
  同一套判据 → `pick` 腿红 6 条（清单标题没提示、选中后没有跟随浮层、连实时事件都看不到）、
  `running` 腿红 2 条（没有「再按一次回车」提示、回合还没收工就是不开浮层）；②把 `watch_line_id` 改成
  恒 `true` 重编 → `watch-pick-parse` 红 8 条且 `SELFTEST FAIL`（这条同时证明「watch-* 轮的返回值真的
  接进了聚合条件」——P42 那两个轮原本**没接**，见踩坑 73 ⑤）；③把假网关的父子判据改回「`WATCH_MARK`
  在不在请求里」→ `running` 腿变成假绿（旧代码也「过」），因为助手那条 `tool_calls` 的参数里会回显提示词。
- 其它：自测幂等（连跑两次都 PASS）；A1–A6 全部通过；技能与 `web_search`、自动压缩、后台任务、文件工具、DSH 零参数启动、跨进程会话恢复（记住 4271）都在真机验收过。

- 踩坑 72（TUI 里能复制文本）：真机（deepin-terminal / qtermwidget，即用户环境）A/B —— 同一块屏幕、同一条拖拽轨迹（`xdotool` 驱动），鼠标上报**开着**时拖选之后 `PRIMARY` 仍是旧值（= 没选中）、TUI 正文一个字符都拿不到；手动发 `?1000l?1006l` 关掉后拖同一段立刻拿到屏幕文本；再发 `?1000h?1006h` 又选不动。屏幕重画不会清掉已选区（选中后等 3 s 仍在），所以与渲染/重绘无关。修法见踩坑 72；`make e2e-mouse` 钉配置来源链（默认 env/cli + CLI 优先 + 滚动模式 `/mouse` 说明），`tui-mouse` 轮钉开关语义、F2 两种编码、字节级四个方向与真 PTY 两个方向。防假绿对照实验四条（`tui_term_enter` 忽略开关 / 删 F2 映射 / `tui_set_mouse` 去掉运行中写序列 / 启动处恒 `true`）都当场红。

> 分阶段验收记录的详细现场（P1–P48 的 before/after 命令与截图、真机对照实验、被自测当场抓住的自身缺陷）已在此压缩，原始描述保留在 §16 踩坑 33–80 与各版本提交说明中。

- P57：**命令弹窗的循环选择 + 已输入文本显示**（`tui-cmd` 轮新增 F 段）。两条症状都很具体：
  ① `↑` 在第一项再按、`↓` 在最后一项再按**没反应** —— 命令面板二三十条，走到头之后再按一下
  不动，会被当成卡住；② 敲进命令面板的字符只进 `g_tui_ov_filter`（过滤**是生效的**），
  但屏幕上**一个字节都不显示**，用户只能盲打盲删。
  改法：`tui_ov_sel_move` 的入参从 `delta` 改成**按键事件** —— `↑`/`↓` 越界回绕，
  `Home`/`End`/`PgUp`/`PgDn` 仍旧夹取（理由与自测判别腿见 §16 踩坑 91）；过滤词画在**标题栏**上
  （`╭─ 命令 › stat▌ ──╮`）：非空才画、长词保尾补 `…`、框太窄整段让位给标题、进帧文本走
  **单行清洗**（与踩坑 81 同一份口径），过滤缓冲本身一字不动（匹配与「无匹配还回输入行」用的是原始字节）。
  验收：`make tui-selftest`（F 段五条腿：循环三向、`Home`/`End`/`PgDn` 夹取、矮框 ±1 步长判别腿、
  已输入文本显示与退格跟随、长词保尾、脏字节清洗，外加 `tuis_overlay_frame_check` 钉方框逐行闭合）。
  **三条防假绿对照实验**（各自单独回退都会红）：① 取消回绕（`wrap = false`）→ 红 **3**；
  ② 改成「按 delta 大小猜循环」→ 红 **3**（正是那条矮框判别腿在报）；③ 不画过滤段 → 红 **4**。
  `--tui-demo` 的七屏不受影响（demo 的浮层没有过滤词，非空才画 ⇒ 逐字节不变，只有脚注版本串那一行变）。

- P54：**退化响应（空回复）的证据 + 同一步重发一次**。真机现场：一轮结束在
  `error: model returned neither content nor tool_calls`，而会话日志里**只剩一条
  `content=""` 的 assistant/message** —— 事后分不清「上游说了 stop」还是「tool_calls 在流里丢了」，
  用户是靠别的旁证凑出来才定的性；而且同一份请求重发一次通常就有正文，这一轮却直接判了回合失败。
  验收：`empty-retry` + `empty-retry-giveup` 两轮（`UYA_SELFTEST_EMPTY_ONLY=1` 单跑，约 0.2 s），
  逐项见 §6 表格；修复后的证据长这样（真跑出来的，不是拼的）：
  ```
  [retry] empty response from upstream (no content, no tool_calls) — resending the same request once [step=1 finish=stop have_finish=1 bad_finish=(none) content=0B reasoning=45B calls=0 usage={in=60 cache_read=40 cache_write=0 out=7 reasoning=3} prompt=23867B/100tok retries=0/1]
  ```
  **六条防假绿对照实验**（每条都先看到红再改回来）：
  ① 关掉重发（`retrying` 恒 `false`）→ 两腿红（41：`agent_run` 返 3 而不是 0，mock 只服务到第 1 轮；
  42：`verdict 63` = 只服务了 1/2 轮，转录里也没有 `retries=1/1` 那一段）；
  ② 只留一句错误、不打印证据也不落事件 → 两腿一共红 14 条（四条转录断言 + 三条日志断言，
  每个证据字段都有对应的断言）；
  ③ 退化那一步也写 `assistant/message`（把检查挪到它之后）→ 两腿红（41 期望恰好一条、42 期望一条都没有）；
  ④ `EMPTY_RETRY_MAX` 改成 2（额度与事实不符）→ 两腿红（`maxRetries` 与 `retries=0/1` 都对不上）；
  ⑤ 重发时把 step 推进一格 → 42 红（转录 `[step=1` 与事件 `step` 字段）；
  ⑥ 重发前往历史里塞一条 `PERTURB` → 两腿红（**verdict 249**：重发的请求体不再逐字节相同）。
  对照实验 ⑥ 还顺手抓到自测自己的一个坑：第一版判定码写成 261…268，`sys_exit` 回来只留低 8 位，
  「264」显示成「8」（见 §16 踩坑 89）。

- P58：**同会话 Goal Round 驱动器**（`goal-round-driver` 对齐，见 §9.5）。本轮填的是 §9.3 那条
  「**自动续跑未实现**」的白纸黑字 —— 修前 `phase=active` / `armed` 只是模型与面板看得见的状态，
  `g.round` 全仓**没有一处 +1**（只有 `--tui-demo` 的假数据），也就是说 schema 文案在说谎：
  模型建了目标、`get_goal` 报 `armed = true`，用户等着它接着干，仓库却什么都不做。
  真机症状很具体：长目标跑完一轮就停在提示符上，用户要一条一条敲「继续」（`/continue` 那条路
  还得自己判断该不该再催）。
  实现对齐 DSH 的三条硬语义：**① 同会话**（每轮是往同一条会话追加一条 `<goal_round>` user 消息，
  不开新 agent、不 fork 历史 —— 与 `deleg.uya` 的 Ralph 那条「每轮全新 agent」明确分开）；
  **② idle 检查点**（挂在主循环真空闲那一支，与自动起标题同一处，但排在它**前面**：续跑优先于
  起标题那个侧路请求）；**③ 授权不跨进程**（换会话/恢复走的 `agent_session_scoped_reset` 把
  进程本地的 `g_goal_armed` 清掉，盘上的 phase / revision 一个字节不动，接着跑要人明确 resume）。
  另外三条是自己补的（都是 DSH 有、本仓必须等价的东西）：轮次用尽 ⇒ 盘上标
  `blocked + round-limit`（终态而非悄悄停下）；**异常不自动重试**（某一轮网络/协议错收场就停，
  否则上游一直 500 会变成主循环一圈一圈地空转刷屏）；记账与投递成对（`round` 只在落盘成功之后
  才算一轮，不许出现「跑了没记账」）。
  **判定与验收**：`goal-cmd` 轮新增 K 段九腿（未授权 / 授权即开 + 正文形状 + 记账 / 轮号递增 /
  complete 停 / 轮次用尽标 blocked+round-limit+收授权 / resume 重开 / pause 收授权 /
  **objective 转义与信封完整性** / 无目标不开）；`tui-turn` 轮新增一条**真端到端**腿（换一份
  mock 脚本：人那一轮 `create_goal` → 主循环空闲后**不注入任何键**，驱动器必须自己开出第二轮 →
  续跑轮用**记账之后**的 revision 标 complete → 授权收掉、且在**请求里**断言 `<goal_round>`
  与 `Round: 1/3` 都在、信封没被目标里的伪标签顶破）。
  **防假绿对照实验**（都先看到红）：① 把 `goal_round_admit` 里的 `jw_str_into` 换成裸
  `buf_append` → K2 当场红（「objective 没有走 JSON 转义」）；② 把驱动器的 `g_goal_armed`
  闸门短路（恒 true）→ K1 红；③ 去掉「异常收场收授权」那一段 → 需真机才稳定复现，故只记在
  §9.5 的判据表里（自测那两腿跑的是一条正常路径，不冒充覆盖）。
  ⚠ **本轮最大的坑不在功能里，在编译器的容量上**：uya 0.10 的顶层**函数表**余量是 **0**
  —— 实测「删 1 个 + 加 1 个」绿、「加 1 个」红（报 `undefined reference to <某个有调用的函数>`，
  报错点还落在**别的文件**上，看起来像链接脚本坏了）。所以净增声明数压到 **≤0**
  （实测声明数 6826 = 基线，函数净 −1）：收驱动器为单个 `goal_round_admit`、收口内联进
  `agent_goal_drive`、内联纯转发的 `agent_goal_reload`，并删掉三个零调用死函数
  （`js_view_to_buf` / `mock_glob_body` / `dg_run2`）与一个恒 `false` 的占位
  `g_tui_quit_flag_pending` —— 它的调用点是 `!tui_has_submit() && !g_tui_quit_flag_pending()`，
  恒真那一项去掉即等价。
  验收：`make build`（干净重编两次，声明数 6826 = 基线）＋ `make selftest` 全绿。
