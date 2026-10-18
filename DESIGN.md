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
| 代码语法高亮、图片在终端里渲染、鼠标拖选 | 终端不渲染图片（只给占位行）；JPEG 的**编解码**已有（`std.image`），渲染仍交给终端自己（见 §15） |
| 改标准库 `lib/tls` | 链校验的缺陷在标准库侧，本项目**不改标准库**，改为在 agent 侧提供四档信任策略（§18） |
| 会话内落盘的 tool 输出 spill（DSH 有） | 只保留内存尾部；记为**已知偏离**（§6.5） |

## 2. 分层与依赖

### 2.1 域划分

| 域 | 装什么 | 判定问句 |
|---|---|---|
| `foundation/` | 零依赖底座：字节缓冲、JSON、YAML | 「它能依赖谁？」—— 只依赖 `libc`/`std` |
| `net/` | 传输与协议：HTTP、流式、SSE、LLM 协议、出站代理与指纹库 | 「它说网络协议吗？」 |
| `web/` | `--web` 的界面侧：服务端终端解释器、HTTP 收口、页面与泵点（5 个文件，见 §11.8） | 「它只在 web 界面里跑吗？」 |
| `term/` | 终端与界面：tty、markdown、转录显示、任务块 | 「它在画屏幕吗？」 |
| `term/tui/` | 全屏 TUI（按依赖序拆成 11 个文件） | 「它是 TUI 的哪一段？」 |
| `tools/` | agent 的工具实现：fs、shell、search、jobs、审批、沙箱 | 「它是模型能调用的一个工具吗？」 |
| `session/` | 会话与运行时：日志、DSH 配置、统计、进程采样、信号 | 「它是进程/会话的生命周期吗？」 |
| `agent/` | agent 主体：主循环、prompt、上下文、todo、plan、goal、子代理；`agent.uya` 只留文件头 + `Config` + `main`，实现按段拆成 `ag_*.uya` 9 片 | 「它决定 agent *怎么想*吗？」 |
| `pm/` | 项目记忆：项目身份、只追加分片存储、确定性摄取、开工包渲染 | 「它在记这个项目的事吗？」 |
| `vcs/` | git：只读跑 git、worktree | 「它跑 git 吗？」 |
| `plugin/` | MCP 插件：配置解析、常驻子进程、公开名归一化、`mcp` 元工具（4 个文件，见 §21） | 「它接的是外部 server 吗？」 |
| `diff/` | 写工具正文的行级 diff + `/diff` 显示层（5 个文件） | 「它是 diff 的哪一段？」 |
| `media/` | 图片附件（`imgx`/`imgz`）、剪贴板三源（`clip` 仲裁 + `clipt` 终端协议 + `clipx` X11 + `cliphelp` 外部工具） | 「它是二进制媒体吗？」 |
| `selftest/` | 自测轮：`selftest.uya` / `tuiselftest.uya` 只留文件头 + 入口（`selftest_main` / `tui_selftest_all`），轮次按段拆成 `st_*.uya` 17 片与 `tuis_*.uya` 8 片（拆分后又长了新轮，见 §19） | 「它只在 `--selftest` 里跑吗？」 |

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

### 2.3 编译器带来的硬约束（三条已修、一条仍在，设计被它们塑形）

这四条**不是风格偏好**，是本仓实测出来的编译期事实（详见 `CODING.md` §1.2.1 与 §6）：

| 约束 | 症状 | 现状 / 对设计的塑造 |
|---|---|---|
| **显式输入文件数上限**（uya 0.10.1 是 64） | 第 65 个文件报「**收集模块依赖失败: <编译器路径>**」，报错指不到根因；到 `uya-0.10.3` 上限是 512，但守卫（512）与写死的 `[i32: 64]` 数组不一致 ⇒ 第 65 个文件**越界写栈** | **已修**（`7c49de57`：输入文件表改为可增长，去掉 64/128/512 三处固定上限）：本仓现用 **113 个**构建文件 —— 三个历史巨文件就是靠这条才拆得动 |
| **文件顺序有意义** | `if c { CONST_A } else { CONST_B }` 里常量所在文件排在后面时，报「期望类型 u8，推断为 void」 | **唯一仍然有效的一条**：`SRC` 里 `term/tui/` 与 `diff/` 两块是**按依赖序**排的，不是字母序（实测：把 `style.uya` 排到使用者之后，三处当场红） |
| **函数表是定长表**（`FUNCTION_TABLE_SIZE`，无开关） | 报「函数表容量不足，请增大 FUNCTION_TABLE_SIZE」，**报错点落在标准库里** | **已修**（`fc577783`：checker 的五张定长表改成通用动态哈希表）：本仓实测「净增 50 个函数 + 清缓存重编」通过 ⇒ 「净增 0」那条纪律**不再需要**（当时的写法：合并语义同族函数、就地展开只调一两处的转发、删零调用死函数） |
| **codegen 的 reachable 函数表**（`C99_MAX_REACHABLE_FUNCTIONS`，0.10.x 是 4096） | 超过 4096 个可达函数时**静默丢函数**：定义与原型都不发射、调用点还在 ⇒ 宿主 C 报 `implicit declaration` + `invalid initializer`，报错点指向调用处 | **已修**（`1267dbc6`：按 checker 的实际条数分配 + 满时 2 倍扩容）；踩这条边界时本仓有 3600+ 个函数（现 2789，口径见 `make lint-size-all`） |

> 编译器在 `/home/winger/uya/uya`（`bin/uya`，`git describe` = `v0.10.3-7-gbb410f82`），本仓
> `Makefile` 的 `UYA` / `UYA_ROOT` 默认就指向它。换/降编译器前请确认上表三条「已修」都还在 ——
> 否则 build 会以看不懂的方式失败：一个是「收集模块依赖失败: **<编译器路径>**」，
> 一个是宿主 C 的 `invalid initializer`（报错点在调用处，根因在可达函数表满）。

`uya 0.10.3` 的 tag 本身**编不过本仓**（`lib/std/thread.uya` 的 `thread_worker_set_nonblock`
定义没被发射而调用点还在，在**未改动的 main** 检出上同样复现）—— 根因就是上表最后一行那条
4096 截断（最小复现：N 个串联私有函数，N=4090 起恰好丢最后一个），`1267dbc6` 修掉后
本仓干净重编通过（实测：`make check` + `rm -rf build && make build` 全过、静态链接审计通过）。
**那个编不过是编译器侧的，与本仓改动无关，别去查自己的代码。**

### 2.4 跨目录的合并命名空间（改代码前必须先懂这条）

Uya 是「目录即模块」，但本仓实测：**跨目录是合并命名空间**。

* 把文件搬进子目录**不需要**改源代码里的 `export` / `use`（实测 `git mv` 后直接编过）；
* 所以「按域分目录」是**纯搬移**，不是重构 —— 三次大拆分（`diff/` 152 个声明、
  `term/tui/` 721 个声明、三个历史巨文件的约 900 个声明）都是逐声明**代码逐行相同**地验的，
  全仓代码行的多重集合与拆分前**完全一致**（本轮：2210 个函数声明，拆分前后**净增 0**；
  三个巨文件 18388/13129/11710 行 → 462/683/141 行，全仓最大文件降到 1949 行
  —— **拆分当时的读数**，后来各片又长了（现状与欠账见 CODING.md §1.3）；
* 于是**名字会撞**：`Conn` 撞 `std.http.types.Conn`、`now_ms` 撞 `std.time.now_ms`、
  `MAX_NESTING`/`ParseState` 让 `std.yaml` 与 `std.json` 无法共存（§5.1 的 YAML 自实现就是这个原因）。

两条纪律由此而来：

1. **不许在仓内写 `use <本地域>.xxx;`** —— 本仓 113 个构建文件之间至今**零本地 `use`**，全靠合并
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
| `g_mc_ready` | `bool` | 进程 | 目录懒加载标志（自测用 `agent_models_reset` 丢掉重读） |
| `g_title_*` | 标题 | 会话 | 终端标题栈 / 钉住 / 自动起标题 revision |
| `g_interactive` | `bool` | 进程 | 交互模式（决定泵点与提示词形态） |
| `g_pump_cfg` / `g_pump_hist` | 泵点上下文 | 回合 | 让**阻塞循环内部**的泵点也能派发命令 |

> **模型选择的身份是 `(provider, model)` 二元组，不是模型名**（P62，踩坑 99）：`settings.yaml` 里
> 两家提供方发布**同一个 id** 是合法的（真机 `DeepSeek-V4.1-Flash` 就挂在 `aigw-local` 与
> `autodl-api` 两家）。所以 `McEntry` 的主键是二元组（`mx_find` 收两个参数），`/model` 浮层的
> **每一行都带提供方**（`✓ <名字> · <提供方>  effort: …`，`✓` 按二元组比），反解也把提供方一起
> 交回（`agent_model_item_parse` 的第三个出参）；文本 / 命令行用 **`提供方/名字`** 指定，且只在
> 「这一对确实在目录里」时才拆（`Qwen/Qwen3-32B` 这类自带 `/` 的 id 不许被误拆）。
> **推论**：任何「用一行文本指定一个模型」的地方，行里必须带够把二元组唯一确定下来的信息 ——
> 缺了它不会报错，只会让另一家的选择**静默失效**（幂等分支在 `announce` 之前 `return 1`）。

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
| 5 | max-tokens 截断（§5.4.1）→ **丢弃所有 `tool_calls`**（半截参数没法用，留着只会让协议错），日志与历史里也不留；正文进历史、收口打 `warning` 而不是 `error`、退出码 `5` |
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

### 3.7 四种运行形态与退出码

| 形态 | 入口 | 说明 |
|---|---|---|
| 一次性 | `run_once` → `agent_run` | 有任务词就走这条 |
| REPL（滚动） | `agent_run_interactive` | 终端 < 32×8、或 TUI 启动失败时**自动退回** |
| 全屏 TUI | `agent_run_tui` → `agent_run_tui_body` | §11；起来后 `tty_sink_on = true` |
| **web 界面** | `web_run`（`--web [ADDR]`） | §11.8；每个会话一个**真 PTY 上的子进程**，服务端把 TUI 的帧字节解成网格推给浏览器。**排在 TUI 之前**：`--web` 是显式的「我要网页界面」，不该因为当前终端够大就被 TUI 抢走；子代理不跑 web（`cfg.is_subagent`） |

退出码（`AGENT_*`）：`0` 成功 · `1` 用法/配置 · `2` 传输（DNS/TCP/TLS/超时）· `3` 模型或协议 ·
`4` 工具/工作区 · `5` **输出到达 token 上限被截断**（§5.4.1：回合跑过步数但没跑到最终答复；
**不是错误** —— 正文与历史都留着，`--continue` 之后发一句「继续」即可接着做）。
内部码：`STEP_CONTINUE = 100`（还有下一步）、`STEP_RETRY = 101`（同一步重发）、
`AGENT_INTERRUPTED = 130`。

> **「步数熔断」为什么只在显式给了 `--max-steps N` 时才体现为退出码 3**：默认
> `--max-steps 0` = **不限**（对齐 DSH：它没有步数上限）。只有调用方**主动**设了上限，
> 「撞上限」才算一种失败；不然「跑到模型给出最终答案」是**正常**收尾。

> **截断为什么单开一个 5 而不是并进 3**：3 的语义是「模型或协议错」，而截断时模型与协议都
> 正常，只是这一轮的**输出预算**用完了。脚本据此分辨「接着做」（`5`）与「真出错了」（`3`）；
> `dsh-headless` 对 `max-tokens` 收尾同样是非 0（`reason.kind === "completed" ? 0 : 1`）。

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
3. `lib/tls` 的链校验在真实站点上**根本**不可用（§18），所以自己接 leaf 指纹钉扎（TOFU / pin）。

**信任策略**：四档 `tofu`（默认）/ `chain` / `pin` / `none`，详见 §18。leaf SHA-256 从
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

**两种缓存方言都要认，且「没明细」必须与「明细说 0」分开**（P72 踩坑 123）：

| 形状 | 含义 |
|---|---|
| `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`（DeepSeek） | 有明细，miss 由提供方给出 |
| `prompt_tokens_details.cached_tokens`（OpenAI 方言） | 有明细，miss = `prompt_tokens − cached` |
| 两者都没有 | **没明细**：`usage_have_cache_split = false`，命中率据此排除该步 |

上游会在两种形状之间**随机切换**（实测 autodl.art 的 DeepSeek-V4.1-Flash：始终带
OpenAI 方言的 `cached_tokens`，但时有时无地省略 DeepSeek 那一对）。因此
`usage_cache_read == 0` **不能**当作「命中 0」用 —— 判据只能是
`usage_have_cache_split`（在**真读到明细字段**时置位，含 `cached_tokens: 0`）。
下游一切「命中率」的分母都要走 `st_hit_rate_billed()`，把未知步排除在外并显示
「未拆分 N 步」。

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
| 0 | persona | preset 的 persona 行（见下面三级来源）；读不到用内置默认值（逐字） | 总是 |
| 50 | plan 策略 | preset 的 `plan-mode.section`，否则内置 | **仅 plan 模式激活时** |
| 100–106 | 工具引导（`SEC_READ`/`SEC_WRITE`/`SEC_EDIT`/`SEC_GLOB`/`SEC_GREP`/`SEC_BASH`/`SEC_JOBS`） | 本仓常量；read/bash 两条与 DSH 原文一致，其余为等价精简表述 | `SEC_BASH`/`SEC_JOBS` **仅 `allow_shell` 时** |
| 107 | 收工纪律（`SEC_FINISH`） | 本仓常量（DSH 没有） | 总是 |

**preset 的「三级来源」**（P73）—— persona 与 plan 段都从它取：

| 级 | 来源 | 何时 | `--print-config` 报 |
|---|---|---|---|
| ① | **磁盘**上的 `agent.cordis.yml`（`--dsh-root` > `$UYA_AGENT_DSH_ROOT` > 常见 npm 全局路径） | 装了就听它的（用户的权不被夺） | `knobs (source: preset)` |
| ② | **编译期内嵌**快照（`prompt.uya` 的 `EMBEDDED_PRESET`，`@embed` 进来的同一份上游文件） | 这台机器**没装 DSH** | `knobs (source: embedded)` |
| ③ | 内置缺省（`DEFAULT_PERSONA`） | 两级都失败（正常编译下到不了） | `knobs (source: defaults)` |

为什么必须有②：plan 策略段**只**在上游那份 preset 里，没有兜底时「拷到别的机器」
会让它**整段消失**（实测 system 4469 B → 2132 B），而写闸门（§7）照样硬拒 write/edit ——
模型被挡住写、又没被告知该调 `exit_plan_mode`。见 §16 踩坑 124。

为什么内嵌**整份**而不是只抄 plan 段那句：旋钮（`maxBytes` / pruner 的 8192/4096/1024 /
`timeoutMs` …）与 persona 都在同一个文件里，只抄一段等于把上游其余部分**冻在代码里**，
两条来源就分叉了。整份内嵌让「内嵌 = 上游的一个快照」，只有一处要跟着上游更新
（`src/agent/assets/agent.cordis.yml`，**改了要重编**）。

**persona 默认文案**（`prompt.uya:35`）：
`"You are a coding agent powered by the {{model}} model. Your working directory is {{cwd}}."`

**Uya 语言速查表**（P63 起**不在**上表里）：它曾经是本项目的补充节，每轮无条件追加在
system 末尾（原文案 467 B）。那段文字只在「模型要写 / 改 Uya 源码」那一步有用，其余回合
是纯粹的前缀开销 —— 现在改成按需的 **`uya_notes` 工具**（文案是 `prompt.uya` 的
`UYA_LANG_NOTES`，工具入口 `uya_notes_tool`）。system 因此少一整节，速查表只在真调用
那一步进对话。`agent_system_prompt` 末尾只再拼 worktree 纪律段（P37，非该模式时为空串）。

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
| `cmp_prune_pressure_gated` | `true` | **P79 压力闸门**：没有压力就不剪（见下） |

**「只在构请求时生效（不动历史）」是刻意的不变量**：① 天然幂等 —— 每一步都重新从原文算，
不会「剪了又剪」；② 会话日志里留的是**原文**，事后能用完整证据复盘；③ `--resume` 后重新
构请求仍得到同一结果。代价是每步都要重算一次（可接受，这是纯字节操作）。

**P79：必须再有「压力达标」这道闸门，否则会自锁**（这条是 4 题头对头测出来的，见 §19.1）。
原来剪枝**每步无条件生效** —— 只要单条工具结果超过 8192 码点就剪。而 DSH 用**同一套数字**
却只在压力达标时才剪（它自己的 README：*"Below-pressure step checks never prune"*）。
缺这道闸门会形成一个**自锁循环**：

| 步 | 动作 | 结果码点 | 后果 |
|---|---|---|---|
| 9 | `read scheduler.py` | 16623 | 中段被剪掉 |
| 10 | 模型为**找回中段**窄读 `offset=100 limit=200` | 8489 | **又被剪** |
| 11 | 再补两次更窄的读 | 4691 / 3280 | 这才拿到 |

实测 taskflow：**29 次 read 里 11 次是这种补救读**，23 步里 21 步在探索，**第 19 步才第一次
写文件**。判定口径是 `cmp_prune_armed(未剪原文字节, context_window)`：
与压缩**同一条触发线** `floor(window × thresholdRatio)`，`context_window <= 0`（未知）时
**保守剪**（宁可丢中段也不撑爆请求）。

**闸门输入刻意不用 `cmp_request_bytes`**：那个函数自己会调剪枝，拿它当闸门输入等于
「剪枝决定要不要剪枝」的循环论证（剪过之后字节变小 ⇒ 压力看起来不达标 ⇒ 不剪 ⇒ 又变大）。
所以单开了 `cmp_raw_tool_bytes`（数**未剪**原文）。

**实测收益**（同题同模型，只加这道闸门）：taskflow 模型调用 **24 → 17 次**，
read **29 → 17 次**，超阈值 read **8 → 5 次**，得分都是 **1.0000**；
`make-ci-green`（源文件全小于阈值）行为不变（11 次 / 1.0000）—— 回归腿。
A/B 对照臂（把阈值从 8192 直接提到 200000，不改代码）是 24 → 13 次，
说明**丢掉的确实是纯浪费**，而不是把剪枝的收益一起丢了。

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

**P88：三道自保闸门（缺任何一道，「历史已经太大」时压缩就失效）** —— 现场见 §19.10：

| 闸门 | 实现点 | 挡的是 |
|---|---|---|
| 摘要请求**只带被遮蔽段** | `agent_summary_input` | 摘要请求原来复制**整份**历史 ⇒ 它和主请求一样大 ⇒ 主请求超窗时摘要也超窗，**压不动** |
| 摘要请求的**预算闸门** | `cmp_summary_budget` + `cmp_fit_start` | 被遮蔽段本身也可能超大：按**保守**口径从新往旧装，装不下的最老段不进摘要（`omittedFrom` 如实记账）。窗口连固定开销都放不下时闸门**让开** —— 那是触发线的语义，不是请求上界 |
| checkpoint **落盘** | `agent_log_checkpoint` + 折叠侧认 `source.kind = "compaction"` | 压缩原来只改**内存** ⇒ `--resume` 折日志时被压掉的段原样回来 ⇒ 每次启动都回到超窗状态 |

恢复那条路另有一道**确定性**兜底：`cmp_fit_history` 在折完日志后量一次，装不下就从头丢
（老日志 —— P88 之前写下的那些 —— 折出来就是超窗的，落盘闸门管不到它们）。

**两套 token 口径不许合并**：调度（`cmp_prune_armed` / `agent_pressure_tokens`）用实测校准的
`bytes / 4`（中位口径，估偏只是早晚一步的事）；安全（`cmp_est_tokens`）用 **2.5 B/tok**
（实测 360 组样本 p05 = 2.90，取 2.5 让最坏情况仍留 16% 余量）—— **低估就是灾难**：
估低了以为装得下，请求发出去换回 400，而那条路上往往没有第二次机会。

#### 5.3.4 上下文窗口的来源链（P81）

上面两条（剪枝的压力闸门、压缩的触发线）都算 `floor(contextWindow × …)` —— 所以
**`contextWindow` 从哪来**决定了它们什么时候生效。四档来源，从高到低：

| 档 | 来源 | 实现点 | `--print-config` 的 source |
|---|---|---|---|
| ① | `--context-window N` | `agent.uya` 的 CLI 解析 | `cli` |
| ② | `UYA_AGENT_CONTEXT_WINDOW=N` | `agent.uya` 的 env 段 | `env` |
| ③ | `settings.yaml` 的 `uya-agent.contextWindows` | `modelx.uya` 的 `mx_read_windows` | `uya-agent` |
| ④ | DSH 模型条目的 `contextWindow` | `agent_apply_dsh` / 模型目录 | `dsh-settings` |

**定稿只有一个地方**：`agent_ctxwin_settle`（启动收尾 + 每次切模型 / 恢复会话都调它）。
这解决了一个具体故障：以前 `--context-window N --model M` 与 `--model M --context-window N`
**结果不同** —— 后解析的 `--model` 会按目录条目把刚定下的窗口盖回去（谁在后面谁赢）。
定稿点放在**所有** CLI 解析之后，于是两种顺序逐字节相同（`e2e-ctxwindow` 用整份
`--print-config` 的 `cmp` 钉这条）。

四条口径（都是「配置不许说谎」）：

| 口径 | 为什么 |
|---|---|
| ①② 是**显式**的，本会话谁也不许覆盖（切模型也不动） | 人是按**这一条路线**给的窗口（autodl 那种纯 env 部署连 DSH 目录都没有）；跟着目录改等于把显式配置降级成猜测 |
| ③ 压过 ④ | 映射就是为「目录里没写 `contextWindow`」的路线准备的；同名模型跨提供方时用 `提供方/名字` 精确指定，裸名字是粗口径（键**整串匹配**，不做前缀） |
| 一条来源都没有 ⇒ **沿用**，来源码退回 `default` | 清成 `-1` 会让压缩**静默**失效（`cmp_pressure_limit(<=0)=0`），与「目录外的模型名只换名字、能力保持不动」同一条理由；退回 `default` 是因为值来自**上一个**模型，照抄上一个模型的来源就是假话（实测：从映射里有的 w-one 切到没有的 w-five 之后仍标 `uya-agent`） |
| 值必须是**纯十进制正整数**（1..999999999） | `yt_get_i64` / `parse_i32_arg` 都「读到第一个非数字为止」：`256K` 静默变 256、`abc` 静默变 0（= 窗口未知）—— 两条都让压缩线跑到谁也不认识的位置。拒绝的粒度分三处：CLI **报错退出**（与 `--permission bogus` 同口径）、env **告警后忽略**、设置里那条**跳过并计数**（`--print-config` 印 `skipped N`，启动另有一行 warning） |

**可证出口两条**：机器侧是 `--print-config` 的 `context_window = N (source: …)` 与
`context_window_map = N model(s)`；人侧是 `/model` 报告里的 `ctx` 行（裸 `/model` 与切完模型
之后都会重画）。`-1`（未知）在 `--print-config` 里印成 `-1 (unknown)` 而**不是** `as usize`
出来的 18446744073709551615 —— 那是同一类「配置在说谎」，顺手一起修了。

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

#### 5.4.1 token 上限截断（`finish_reason=length` / `incomplete`+`max_output_tokens`）：正文进历史 + warning 收口

**判据**：`finish == LLM_FINISH_MAX_TOKENS`（两条协议的映射见 §4.5.1 / §4.5.2）。

**修前的症状**（用户报的就是这一行）：转录里一句
`error: model output was truncated at the token limit (max_tokens); tool calls dropped`
——① 它长得像「模型/协议出错」，其实谁都没出错，只是**这一轮的输出预算用完了**；
② 截断前那段正文**没进历史**，用户按提示回一句「继续」，模型连自己刚写到哪都不知道，
只能从零重来（真机现场：一整轮的工具调用白跑）；③ 日志里那条 `assistant/message`
**带着 tool_calls** —— 而它们一个都没被派发（悬空），`--resume` 折日志时会把那半组当
「未完成一轮」整组丢掉（`hist_trim_incomplete_tail`），连正文一起丢。

**对齐 DSH 的三条**（逐条有出处）：

| 件事 | DSH 怎么做 | 本仓 |
|---|---|---|
| 工具调用 | `BlockAssembler.assembled()` 在 `finish.kind === 'max-tokens'` 时把 **tool-call 块整块滤掉**（参数可能是半截的，派发会得到协议错） | 一个都不派发，**日志与历史里也都不留**（`keep_calls=false`） |
| 正文 | 照样进 `assistant/message`（历史就是会话日志折出来的）——UI 的提示语是「回答被截断，**已有输出保留在对话中**。发送"继续"可让模型接着输出」 | 剪掉断口空白（`agent_trim_trailing_ws`）后压一条 `ROLE_ASSISTANT` 进历史 |
| 收口 | `turn/end` 的 reason 是 `{kind:'max-tokens'}`：不是 `completed`（没走到最终答复），也不是 `error`（谁都没错）；`dsh-headless` 那条腿把正文照打 stdout、退出码按「没跑完」给非 0 | `turn/end` reason = `"max-tokens"`；转录是 `warning:` 一行 + `[max-tokens]` 一行（「丢了什么 + 发「继续」」）；进程退出码 **5** |

**两行文案**（转录里逐字如此，`testdata` 里的 mock 也按这个字面量断言）：

```
warning: 模型输出到达 token 上限（max_tokens）被截断，本回合到此为止（不是错误）
[max-tokens] 1 个工具调用已丢弃（参数可能是半截的，派发只会得到协议错）；已产出的正文留在对话里 —— 直接发「继续」即可让模型接着做
```

`warning:` 前缀同时也是 TUI 的样式选择器（§11 的 `tui_notice_style`：ERR / **WARN** / DIM）。

**为什么不重发**（与 §5.4 的退化响应分得清清楚楚）：请求没变、上限没变，同一发再来一次只会
再截断一次；能改的是**下一轮**（模型看到自己写到哪，或人把 `max_tokens` 调大）。
所以这条路径**不碰** `EMPTY_RETRY_MAX` 的额度，也不留 `llm/degenerate` 事件。

**退出码 5 而不是 3**：`3` 的语义是「模型或协议错」，而截断时模型与协议都正常 —— 共用
`3` 会让脚本分不出「接着做」和「真出错了」。与非交互形态对齐：`dsh-headless` 对
`max-tokens` 收尾也是非 0（`reason.kind === "completed" ? 0 : 1`）。
交互形态（REPL / TUI）**不把截断当「本回合异常结束」**：那两行 warning 已经说清「怎么回事 +
下一步怎么做」，再说一句「异常」只会让人以为出事了。同会话续跑驱动器（§9.5）也照这个口径：
**截断不收授权** —— 目标显然还没做完，而且截断那一轮的正文已经在历史里，下一轮（新预算）
正好接着写；轮次上限兜住空转。

#### 5.4.2 截断的**根因**：不发上限 = 把上限交给网关兜底（P61）

P59 修的是**截断之后**怎么收场（别当错误、正文进历史）。但真机上「过 aigw 后**容易**报错」
这件事的根因不在这条路径里 —— 它只是**症状的出口**。根因是**上限根本没发**：

| 环 | 事实 | 出处 |
|---|---|---|
| 1 | 本仓 `cfg.max_tokens` 默认 `0` = **不发** `max_tokens` / `max_output_tokens`，理由是「对齐 DSH」 | `ag_config.uya` 的 `max_tokens: 0` |
| 2 | 用户 `settings.yaml` 的 `aigw-local` 条目**没有 `maxTokens`**（只有 `contextWindow`）⇒ 一个字节都不发 | `~/.dsh/settings.yaml` |
| 3 | aigw 的 openai-chat provider **替你补** `default_max_output_tokens: 8192` | aigw `internal/providers/openaichat/openaichat.go:474`（`chatReq.MaxTokens == nil && cfg.DefaultMaxOutputTokens > 0`） |
| 4 | 模型**真实能力 65536** —— aigw 自己的 `/v1/models` 就这么公布 | `provider_models.max_output_tokens` / `/v1/models` |
| 5 | 实测反复撞顶：网关日志 `output=8192, reasoning=8192`；`usage_records` 里 `terminated_reason='incomplete'` **只**出现在本仓（`client='unknown'`）的请求上 | `aigw-local.log` / `aigw.db` |

**也就是「不发」≠「不限」，而是「把上限的决定权交给中间那一跳」** —— 而网关并不知道我们
下一秒要写一个多大的文件。推理模型尤其致命：8192 的预算里思考可以先吃掉全部（实测
`reasoning=8192`），正文与工具参数一个 token 都轮不到，于是 P59 只能把半截的工具调用整块丢掉。

**「对齐 DSH」这条理由本身是读了一半**。DSH 确实不把**能力申报**（pi-ai 的 `Model.maxTokens`）
当请求默认 —— 那只是「这个模型最多能出多少」；但它**自己的 deepseek 路线有请求默认**：
`dsh-llm-deepseek` 里 `DEFAULT_MAX_TOKENS = 256e3`，`maxTokens: config.maxTokens ?? 256e3`
经 `defaultMaxTokens` 落进 `resolveCallWithInfo`，**真的会随请求发出去**（pi-ai 那条路线的
兜底同量级：`source.defaultMaxTokens ?? 32768`）。所以「发一个 256000」比「不发」**更**接近
DSH 的实况。

**修法**（P61）：`effective_max_tokens(cfg)` = `--max-tokens` > 目录 `maxTokens` >
`DEFAULT_MAX_OUTPUT_TOKENS`（256000），两个构造器（`build_chat_request` /
`build_responses_request`）**无条件发**；responses 侧仍抬到 `RESP_MSG_MIN_TOKENS`（16，
OpenAI 硬下限，低于它的显式值会被 400 —— 比截断更坏）。`--print-config` 印**线上会发的值**
与来源（以前 `cfg.max_tokens = 0` 时印 `0`，看着像「不发」，与 P56 的 `reasoning_effort`
同一类「配置在说谎」）。

**为什么给大不给小**：上限是**上限不是配额** —— 没有输出就不计费，给大了不多花钱；
给小于真实能力才是真损失（白白截断）。实测**超过**上游能力也不 400：aigw 与 autodl 都照常
返回 200，按各自真实上限截（`max_output_tokens: 999999` 实测 200；aigw 只对 **<16** 报
`max_output_tokens must be >= 16`）。这条实测是「敢给大值」的依据 —— 否则「保守给 8192」
反而会把根因重新引回来。

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

29 个工具按**固定顺序**拼进请求（`tools_json`，`src/agent/ag_tools_schema.uya`）。
顺序**恒定**是关键设计：工具目录跨模式稳定 ⇒ 前缀缓存不会因为「模式变了」而失效。

| 组 | 工具 | 条件 |
|---|---|---|
| 文件 | `read` `write` `edit` `glob` `grep` | 总是 |
| 执行 | `bash` `job_list` `job_output` `job_kill` | **`allow_shell` 时**（否则整组不出现） |
| 会话与交互 | `workspace` `worktree` `set_title` `todo_write` `exit_plan_mode` `ask_user_question` | **总是**（含 plan 模式 —— 工具目录跨模式稳定） |
| 技能与搜索 | `skill` `uya_notes` `web_search` | 总是 |
| 子代理 | `subagent` `subagent_fork` `list_agents` `subagent_output` `send_message` `interrupt_agent` `ralph` | 总是 |
| 目标 | `create_goal` `get_goal` `update_goal` | 总是 |
| 编排 | `workflow` | 总是 |
| 插件（P70） | `mcp`（元工具）；每个 MCP 插件自己报的工具 | **配了 MCP server 时才出现**（没配时工具表逐字节不变，见 §21） |

schema 文本是 `TOOL_*` 常量（`src/agent/ag_tools_schema.uya`），逐字对齐 DSH v0.1.1-rc.2 的
standard preset。**唯二例外**是本仓自有的两个：`uya_notes`（P63，速查表）与 `run_shell`
（死常量，未被 `tools_json` 引用）。

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
| `uya_notes` | — | — | Uya 语言速查表正文（`UYA_LANG_NOTES`，纯文本；只读、无参数 ——
  read-only / plan 模式下照常可用） |
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
| `--tls-verify` | 传输信任策略（§18） | `tofu` |

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

**列表只列有标题的会话**：空标题（`"title":""`）与缺 `title` 字段的索引行在**渲染层**
（`sess_rows_render` 的两趟都套 `sess_cell_has_title`）被整条跳过；数据层
（`sess_index_rows_sorted`）照旧交出全部记录，所以 `--resume <id>` / `sess_find` /
`--continue` 仍能回到没起过名字的会话。三个入口（`/sessions` 浮层、`--list-sessions`、
滚动模式的 `/sessions`）共用这一份；一条有标题的都没有时给 `(没有找到已命名会话)`。

### 8.6 恢复数据流

| 入口 | 行为 |
|---|---|
| `--continue` | `sess_find_last`：读索引，按 `lastActiveAt` 选最大；**`delegationDepth > 0` 的子代理会话不参与**（否则会接到子代理身上）；可按 cwd 过滤 |
| `--resume <id>` | `sess_find`：先看当前 cwd 目录，再扫所有 `--*--` 目录 |
| `/sessions` | 浮层，数据层最新在前、**展示层翻成最新在最后一行**；只列**有标题的**会话（空标题整条不见，`--resume <id>` 仍可直达） |
| `--resume-dsh <前缀>` | 走 `dshsess` 导入（§8.7） |

解析结果写进 `cfg.resume_id`（**绝对路径**）。恢复过程：

```
sess_read_meta      一次读盘拿 header(id/cwd) + 逐行扫最后一条 session/workspace 与 session/model
   ↓  ★ 必须在 agent_hist_from_log 之前定工作区 ★
agent_hist_from_log sess_reader_load 整文件读入、跳 header → sess_next 逐行
   ├─ 每行先 st_fold_line（折叠统计）
   ├─ 按 seq 连续性校验（不连续打印 [session] 警告：seq 不连续）
   ├─ todo/write → todo_from_json（会话级清单，后写覆盖先写；§9.2）
   └─ turn/start → todo_clear（DSH 投影同序：清单是**这一回合**的）
hist_trim_incomplete_tail   丢未完成一轮的尾部
hist_repair_pairing         丢**任何位置**的悬空组（P89：半组不在结尾时上面那条修不好，§19.11）
sess_open_resume            用会话自己的路径 + next_seq 续写
```

> **为什么工作区必须在 `agent_hist_from_log` 之前定**：system prompt 的 `{{cwd}}`、AGENTS.md、
> 技能目录的 5 个根**全都在那里求值**（§3.2）。定晚了整份 prompt 就是上一轮的。

`l.cwd` 传**当前**工作区（索引的工作区列按它写，**header 不动**）。
折叠统计与日志在 resume 时对齐：`st_reset()` + 逐行 `st_fold_line`。

**折出 0 条有两种含义，必须分开**（踩坑 154）：`agent_hist_from_log` 的返回值数的是
**历史消息**，而清单与 `session/title` 不进历史 —— 所以「一条消息都没有」既可能是
**空会话**（日志只有 header，`sess_has_events` 为假），也可能是**日志坏了**。
前者是**恢复成功**：沿用同一个 id 与同一份路径（`sess_open_resume`，`next_seq` 取那份
「迭代到最后一条事件」的值）—— 若照旧降级成「改为新建会话」，会话 id 与目录当场换掉，
落在会话目录里的 `goal.json`（P87：目标属于会话，靠**文件位置**保证）就再也找不到，
表现是「恢复会话之后目标没了」，还会在 `sessions/` 下留一个空壳目录。后者（有事件却
折不出消息）才走「日志无法解析，改为新建会话」。

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

#### 8.8.1 写回：人切完的模型路线落回 `agent-default-model`（P71）

这一层以前**只读不写**：`/model`、`/effort` 只改这次会话的状态、落一条 `session/model`，
下次启动仍然是 `settings.yaml` 里那个默认 —— 于是「我明明切了，重开又是旧的」。
P71 补上写回，对齐 DSH 自己的行为：它的 `selectModel` RPC 会调
`agentDefaultModel.saveSelection()`，由 `dsh-settings-file` 往同一个节做**叶级** diff 写回。

| 项 | 本仓（`session/dshsave.uya`） |
|---|---|
| 触发 | 只有人：滚动模式 `/model <名字>`、`/effort <档位>`、TUI 浮层里选中（三条入口共用 `agent_model_save_default`） |
| 不触发 | `--model` / `--effort`（CLI 一次性，DSH 的 entry-point 同口径）、`--resume` 的会话记录、`--exec-effort` 自动降档 |
| 写什么 | **完整选择**：`provider` + `model` + `reasoningEffort` 一起。理由与 DSH 的注释一致 —— 「下一个模型没有档位时，只有一次完整的选择才能把 effort 清掉」 |
| 改多少 | 只有那个节里的目标行；注释 / `!!js` 行 / 块标量 / 兄弟节**逐字节不变**，行数都不变 |
| 提交 | `<file>.lock` 独占创建（0600）→ **重读** → 改 → `<file>.<pid>-<ms>.tmp` → `rename`；与 DSH 的 `dsh-atomic-write` 同一协议 |

七条不变量（每条都对应一个真踩过或真拦住的形状）：

1. **写回是副作用，不是前提** —— 调用点先切状态、后写盘，所以写失败只影响「下次启动」，
   本次会话的选择一个字都不回滚。有专门的腿钉这条（锁被占 / 只读文件）。
2. **只做叶级替换**，绝不「解析成树再整份重写」：那样会把注释与 `!!js` 行整片丢掉
   （`yamlcfg` 的树只留键值，`!!js` 被中和成标量）。**首版就踩了这个**：打补丁那一步只抄了
   节头那一行，`ui-theme` / `llm-pi-ai` 连同顶层注释一起没了 —— 而写前自检**说没问题**，
   因为它只核对了那三项的值。教训：自检要钉**结构**（这一节还在不在顶层），不能只钉值。
   现在多一条 `dshw_outside_same`：节外两段必须逐字节相同（整节追加那条路则要求原文本是前缀）。
3. **绝不写空值**：`provider` / `model` 为空 ⇒ 那一行**原样不动**（写空串会让 DSH 的
   `z.string().required()` 起不来）；只有 effort 为空才**删**那一行。
4. **写前自检**：补丁后的文本自己 `yt_parse_text` 一遍，核对该节存在、是 map、三项值正确。
5. **只认块状写法**：`agent-default-model: {…}` 一律拒（`DSHW_SHAPE`）并留一行说明 ——
   认不出的形状不猜。
6. **目标文件必须已存在**：不替用户新建一份设置（`DSHW_NOFILE` + 一行说明）。
7. **别人的锁绝不删**：抢不到就让位（`DSHW_BUSY`）。DSH 自己的锁协议也写明「年龄证明不了
   持有者已经死了，孤儿锁是运维动作」。抢锁超时取 **400 ms**（DSH 是 2 s）——这条在交互
   路径上，卡 UI 比「这次没写回」更坏，而且失败可见、下次切换还会再试。

静默只有两种：用户**显式**关掉（`--no-dsh-writeback` / `UYA_AGENT_DSH_WRITEBACK=0` /
`--no-dsh-config`），以及文件里本来就是这份选择（`DSHW_SAME`，连 mtime 都不动）。
其余一律留一行回执 —— 尤其是「目录是显式 `--dsh-home` 给的、里面却没有 `settings.yaml`」：
那多半是路径写错了，静默的话用户只会看到「写回没生效」。为此目标目录的取法是
**读过设置的那一份优先、退回 `--dsh-home`**：读设置失败时 `agent_dsh_home()` 是空的。

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
| **提交落 `todo/write`** | 提交成功的那一版整表写成一条会话事件（`data.todos` 数组，与 DSH 的 `exec.agent.session.append("todo/write", { todos })` 同形）。**只有走到提交那一行的**才写 —— 被任何一档校验拒掉的提交一个字节都不进日志（「日志与实际派发必须一致」，§5.4.1） |
| **恢复时折最后一次** | `agent_hist_from_log` 认 `todo/write`（后写覆盖先写）。**修过的 bug**：原来清单只在内存里（`g_todos`），日志里一个字节都不写 ⇒ `--resume` / `/resume` / `--continue` 之后恒为空（用户报的「恢复会话后 tasks 没了」）。折回来是**全或无**：任一条不合法就一个字节都不改（半截清单比没有清单更难查） |
| **回合开始时清空** | DSH 口径（与投影 `apply: turn/start → null` 同序，折叠侧同一个判据）。**修过的 bug**：那句 `todo_clear` 从前**从来没接线**（只写在注释里）⇒ 上一条回合的清单一直挂着；且它排在 `g_sess.save` 判断**之前**（`--no-save` 同样清） |
| 换会话时也清 | `agent_session_scoped_reset`。**修过的 bug**：原来没人清 ⇒ `/new` 之后清单还挂着上一条会话的「第几步」 |
| **列表不再注入回上下文** | 与 DSH 一致 —— 那是 UI/replay 状态，不是模型输入（**落盘 ≠ 注入**：恢复折的是屏幕/报告上的那份，模型那边一个字节都看不到） |

**plan（`agent/plan.uya`）**：见 §7.4。
状态 `PlanState{active, pending}`，`pending` 是 DSH `set()` 语义的简化（这里只在 step 边界检查，
所以立即改 `active`）。进程级镜像 `g_on` + `tui_set_plan` 同步。
`plan_tool_exit` 要求 plan 非空且**首字符 `#`**；非 plan 模式调用报错。

### 9.3 会话目标（`agent/goal.uya`）

**持久化**：**会话目录**里的 `goal.json` ——
`<agent_home>/sessions/--<规范化 cwd>--/<session-id>/goal.json`（与 `session.jsonl` 同目录；
**手写 JSON**，`O_WRONLY|O_CREAT|O_TRUNC` 权限 420）。
字段：`id` / `revision` / `phase` / `objective` / `round` / `maxRounds` / `blocker` / `armed`。
读文件上限 65536，用 64 KiB arena 解析。

**为什么落在会话目录里（P87）**：goal 是**会话级**的东西，与「这台机器上装了这个 agent」无关。
修前它落在 `<agent_home>/goal.json`，于是同一个 home 下**所有会话共用一份目标**：甲会话建的
目标乙会话一打开就看到（还带着 `armed=true`，甲的目标会被乙那条进程接着续跑），乙想建自己的
目标则被「A goal is already active.」顶回来 —— web 那种一个 home 下并存 8 条子进程会话的形态
症状最重（真机复现：两条 `UYA_AGENT_HOME` 相同的会话，第二条一启动就显示第一条的目标）。
挪进会话目录之后，「属于会话」由**文件位置**保证，跨会话隔离不需要任何额外判断，也天然跟着
会话一起被删/被搬。

`goal_path` 的三条判据（缺一条就退回 `<agent_home>/goal.json`）：① `g_sess.path` 的尾名整段
就是 `/session.jsonl` 且 `g_sess.id` 非空；② 它在**本次 `cfg` 的 agent home** 底下（`g_sess`
是进程级的，而夹具会换 `cfg.agent_home` 去测别的 home）；③ 紧跟 home 的那一段必须是
`/sessions/`（只比前缀的话，`/tmp/ab` 这种兄弟目录会被误判）。退回那条路是**故意留的**：
`--print-config` 之类没开会话的路径上 `/goal` 仍然可用。落盘前先补一次 mkdir
（`goal_dir_ensure`）：`--no-save` 的会话不建目录，而目标照样要存得下。

**不迁移历史文件**：修前留在 home 根上的那份是**孤儿**，不删也不读 —— 猜「哪条会话该继承它」
比留在那儿更坏（与 `/goal clear` 的「删干净」口径一致）。**目标也不跨会话继承**：旧的那份留在
旧会话目录里，回头 `--resume` 那条会话它还在。

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

**人看的正文里，Objective / Blocker 压成一行**（`goal_render_user`）：这两个字段是**外来
文本**（`create_goal` 能塞多行、塞 ESC），而这段正文要么进 TUI 浮层、要么打进转录里的一行
—— 行内的 `'\n'` 会把方框拆坏、让后几行从第 0 列开始（踩坑 81 那一族）。折行直接复用
`tasks_flat_into`（`term/tasks.uya`：`tui_clean_into` + 换行/回车折成空格），与常驻块、
`/tasks` 报告**同源**，不在这里另写一套。键名 `Status:` / `Rounds:` / `Activation:` /
`Commands:` 一个字节都不动（逐字对齐 DSH 的 commands/command-goal）。

**写盘的转义与读盘的反转义必须对称**（`goal_set_unescaped`）：`goal_save` 用 `jw_str_into`
写盘，它把 `"` `\` 与全部控制字节转义；而 `js_obj_get_str` 给的是**零拷贝原始视图**
（转义序列没被解码）。不带反转义就把它当正文用，用户看到的是字面量 `\n`（两个字符）而不是
换行 —— 实测 `/goal A\B` 存盘再读回会变成 `A\\B`，每存读一次多一层反斜杠。这与 `jsonx.uya`
里 `jw_str_into` 那句「改一边就得改另一边」是同一条纪律。

**与主循环的交互点**：派发 create/get/update 后立刻 `tasks_goal_reload`；启动/TUI 建历史时也
reload；**换会话（`/new`、`/resume`）也 reload**（P87：目标跟着会话走，那份投影必须跟着换，
否则屏幕上还挂着上一条会话的目标）—— 两个落点各自在 `tasks_panel_sync` **之前**重读一次
（面板文本是从投影重建的）；内存投影放在 `term/tasks.uya`（`tasks_goal_ref`），面板读它。

**两个 `armed`**：`Goal.armed` 是**盘上**那份（跨进程持久、`get_goal` 报它），`g_goal_armed`
是**进程本地**的续跑授权（驱动器认的是它）。分开的理由见 §9.5 —— 合并的话 `--resume` 会把
上一条会话的授权继承过来。

**TUI 的命令面（P91）：裸 `/goal` 开**动作选择浮层**（`TUI_OVK_GOAL_MENU`），六个动作
一行一个 —— `status / create / edit / pause / resume / clear`。三件事写死在这一层里：

* **游标默认停在 `status`** ⇒「打开就回车」逐字节等于 P29 的裸命令（看状态），老手感不变；
* **六个动作执行完都开原来那张状态浮层**（`TUI_OVK_GOAL`，正文就是 `goal_cmd_run` 的
  输出）—— 措辞与状态机只有一处实现，浮层只负责拼命令与展示；
* `✓` 挂在「**当前续跑态对应的那个动作**」上（对齐 DSH `GoalBar` 的 `commandHint` 口径）：
  `active+armed → pause`、`paused / blocked / active-disarmed → resume`、
  无目标或 `complete → create`。与 `/worktree` 的 `on/off ✓` 是同一套观感。

**⚠ 一条边界（写在这里因为它是本节最容易踩的一格）：`status` / `create` / `edit` 不走
`goal_cmd_run` 的控制词解析**（分别走 `goal_cmd_show` / `goal_cmd_create` / `goal_cmd_edit`）。
那边的控制词只有 `clear/pause/resume/edit`，**其余任何非空后缀都是字面目标** ——
菜单默认游标那一行是 `status`，走解析就会真的建出一个叫 "status" 的目标；输入框里填的
正文是**数据**（填「pause」若走解析就变成了一次暂停）。控制词那条路只属于「人敲的整行」。

**`clear` 不翻二次确认**（与 `/worktree` 的 `finish/discard` 不同）：DSH 的 `GoalBar` 清除
本身就不确认，`/goal clear` 今天也没有；菜单行自带一句「不可撤销」，且游标默认不落在它上面。

**回合运行中的分工**：动作浮层的结果**只在主循环收口**（`create/edit` 要弹 P48 的阻塞式
单行输入框，塞进泵点就是在流式/工具循环的中间阻塞等按键）；泵点只给一次回执（复用面板
那套 `agent_pump_receipt_*` 去重）并把结果**原样留在队列里** —— 与 `/access` `/worktree`
`/sessions` 同一分工。

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
**授权不跨会话**与**目标不跨会话**是两件事（P87）：前者是「这一轮的继续跑由谁授权」，后者是
「目标是哪条会话的」—— 换会话之后目标换成了新会话自己那份（多半是「一个都没有」），
而授权一律收回，两件事各管各的。

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

**状态字形两套值空间别混**：todo 用 `TD_*`、job 用 `JOB_*`、deleg 用 `DELEG_*`（`view_status_glyph` 只认这一套）。

**折叠行的目标段带单位与正文**（用户报的：`目标 3/20` 里那个 `20` 是什么、目标正文在哪）：
形状是 `目标 3/20轮 · <目标正文>`（非 active 时是 `目标 阻塞 · <正文>`）。
`轮` 是单位 —— 分母是**轮次上限**（`/goal` 建的一律 20），分子是已自动续跑的轮数；正文走
`tasks_flat_into` 压成**一行**（与箱体、`/tasks` 报告同一份口径）。展开箱体那行同一形状
（`▸ active · 3/20轮 · <正文>`，`round` 这个词去掉：单位已经写在数字后面）。

**目标段放不下时只裁正文，头不许丢**（`tasks_seg_clip_into`）：折叠行的老规矩是「超宽就从
尾部丢整段」，而目标段是**最后一段、也是唯一带正文的一段** —— 照老规矩加长之后，窄终端上
连 `目标 3/20轮` 都一起消失，而那两个数正是这一行唯一的进度。所以目标段走一条新路：
头保住，正文按显示列裁短补 `…`（头 + 1 列都放不下才认输、退回「丢整段」）。
其余三段（任务 / 后台 / 子代理）的行为**一个字节不改**。

**展开态的消费者有两个，而且必须共用一份实现**（踩坑 114）：`TUI_REQ_TASKS` 由**空闲主循环**
与**泵点**（`agent_pump_block`）各自消费一次 —— 用户跑着 bash / 流式时按 ctrl+t，等主循环
就是「按了没反应」（那是本条踩坑的主因）。两条路都调 `agent_tasks_toggle_apply`（翻显示位 +
重建文本 + 空表时落 notice + 当场出帧），一处改两处生效。

**这条待遇只给 ctrl+t**：它一个字节都不改历史（只翻显示位 + 重建只读文本，TUI 下零 IO）。
tab（plan）/ shift+tab（access）**不能**照搬 —— 那两个会 `hist_push` 一份运行时快照进
**正在被这一回合使用的** History。所以泵点上的取用口是**只认 TASKS** 的
`tui_take_tasks_request()`，不是 `tui_take_request()`（后者会把还挂着的 plan / access /
ctrl+v 一并吃掉）。

**空态屏也画这块**（`tui_draw_tasks_block` 由 home 与 chat 共用，行预算收口在
`tui_tasks_prepare`）：刚启动 / `/new` 之后按 ctrl+t 必须与对话态一个行为。
四张表全空时块文本零字节 ⇒ home 的排版与 P22 之前**逐字节相同**（`make tui-demo` 第 ① 屏是判据）。

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
| **拖选**（按住左键拖） | **选中并复制到剪贴板**（P85，不用按 shift）：选中块反显高亮、松开即写 `CLIPBOARD`；`esc` 清选区 |

### 11.5 内容层：转录条目与 markdown

**转录条目模型**（`term/tui/entry.uya`）：6 种 kind（`USER` / `ASSIST` / `REASON` / `TOOL` /
`NOTICE` / `STEER`），**环形 512 条**，三条量上限（单条 `TUI_ENTRY_MAX = 256 KiB`、
正文总量 `TUI_TEXT_MAX = 4 MiB`、**派生缓冲** `TUI_DERIVED_MAX = 16 MiB`）。

| 上限 | 值 | 理由 |
|---|---|---|
| `TUI_MAX_ENTRIES` | 512 | 条目环形表 |
| `TUI_ENTRY_MAX` | `262144` | 单条 256 KiB（**对「一次整块塞进来」也成立**，见下） |
| `TUI_TEXT_MAX` | `4194304` | 转录**正文**总量 4 MiB（记账必须精确，见下） |
| `TUI_DERIVED_MAX` | `16777216` | 派生缓冲（折行 + 样式 + 行偏移表）总量；**真实驻留的那条线** |
| `TUI_REASON_TAIL` | 4096 | 思考条目只留最新一段 |
| `TUI_NOTICE_MAX` | 512 | **无它则一条 4 KiB 的网关错误体就能把整屏转录冲掉** |
| `TUI_IN_MAX` | 200000 | **与 agent 的 `MSG_CONTENT_MAX` 同值，改一处必须改两处** |

#### 11.5.1 「4 MiB」是**正文**口径：真实驻留是它的 2–3 倍

条目除了 `text` 还挂着三样**派生**缓冲，它们以前不在任何上限里：

| 派生项 | 量 | 说明 |
|---|---|---|
| `wrap` | ≈ 正文大小 | 折行文本（按当前终端宽度算） |
| `md` | **与 wrap 逐字节等长** | markdown 条目的逐字节样式（P46/P47） |
| `wrap_ix` | 折行**行数** × 8 B | 行偏移表（踩坑 78；只有它把每帧取行变成 O(1)） |

实测（`selftest[tui-mem]` 每轮打印，`/tmp` 的机器上）：

| 夹具 | 条目 | 正文 | 派生 | 比值 |
|---|---|---|---|---|
| 正常 markdown（每条 8 KB，灌到正文上限附近） | 512 | 3,624,480 B | 10,857,536 B | **3.0×** |
| 巨缩进长行（`bash` 里的对齐表/嵌套报告形态） | 8 | 786,432 B | 20,456,247 B | **26×** |

所以三件事必须一起看：① 正文上限 4 MiB 那句话是**真话但不是全貌**；
② 派生上限取**正文上限的 4 倍**（16 MiB）：正常内容实测 3.0× ⇒ 留约 30% 余量、
**一条都不会因为它被丢**，而病态输入（缩进 900 列的长行，折行文本比正文大二十几倍）
被挡在 16 MiB 上下；③ 闸门在**新建条目时**看的是上一条的全量值，所以最后留下那一条
可以超出上限一个条目的量（实测 20.4 MB vs 16 MiB）——判据是**有界**，不是「恰好 ≤ 上限」。

**记账必须精确，且两个数都要能与实况对照**：`g_tui_text_total` 曾经**只加不减**
（思考条目每次截尾丢掉的字节不减、单条超限从头部丢掉的字节不减、重折之后旧的派生量
也不减），于是计数器越跑越虚高 —— 转录会比标称的 4 MiB **早得多**开始丢老条目，
用户看到的就是「老内容莫名其妙没了」。现在四处的「减」与两处的「加」都在
`tui_entry_append` / `tui_entry_append_nl` / `tui_entry_ensure_wrap` / `tui_sink_reason`
一处一份，且 `tui_text_bytes()`（现算 Σ）与 `tui_text_accounted()`（记账）**每轮自测复算对照**。

> **丢掉的条目去哪了**：不在内存里了 —— 这是**有损**的环形。全文在会话日志里（§8），
> 溢出且上滚时转录第 0 行会写一行 `^ … 更早的 N 条已省略（全文在会话日志里）`。

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

**放不下的文本滚动显示（P75）**：脚注 cwd 段的窗口固定 **30 显示列**（`TUI_FOOT_WIN`），
装不下就交给跑马灯；同一条纪律也用在状态行、信息行、浮层标题/说明、常驻任务块，
以及「一格一条」的簇里的**选中那一行**（P76，见下一条）。

| 参数 | 值 | 理由 |
|---|---|---|
| `TUI_MQ_STEP_MS` | 400 | 一列/步（≈2.5 列/秒）；用**时间**闸门而不是「每帧一列」——帧率跟着负载走，那样速度会飘 |
| `TUI_MQ_HOLD` | 4 | **只在两端**各停 4 步（≈1.6 s）：头部与尾部都要看得清。中间每步都停会变成 2 秒/列（一条 90 列的 path 要滚 90 秒 ⇒ 用户看到的仍是「不滚」，本轮实测踩过） |
| `TUI_MQ_SLOTS` | 64 | 槽位表（0–23 固定元素、24–63 按行派生）；满了退化成「不滚」，**不影响正确性** |
| `TUI_MQ_PIN_MIN` | 8 | P76：钉住段之后**至少**留给滑动段的窗口。低于它就不钉、整行滑 —— 钉完只剩一个 `…` 的窗口等于把这一行变成死行 |
| `TUI_FOOT_WIN` | 30 | 用户口径。**必须固定**：cwd 是唯一随会话变长的字段，不夹住的话一条 worktree 路径就能把右半区统计行挤没 |

**簇里只有选中项滚，且命令名钉住（P76）** —— 用户报：「命令窗口的命令不要一起滚动」。
现场：命令面板 23 条里 **11 条**放不下（最长那条 `/model [名字|提供方/名字]  …`
101 列，面板正文只有 57 列），P75 把它们全挂上了跑马灯 ⇒ 同一个 400 ms 时钟、同相位
一起左移，**整张面板集体抖**，一条都读不成。

修法是把「一格」分成两类，**规则收在 `tui_marquee_put_row` 一处**（调用点只传一个
`sel`）：

| 形态 | 行为 |
|---|---|
| **单元素**（脚注 cwd / 状态行 / 信息行 / 任务块 / 浮层标题 / 选中项说明 / 确认 prompt） | 照旧：装不下就整段滚（P75 行为，逐字节不动） |
| **簇里的选中行**（列表体 / ask 选项 / reader 动作行） | 滚，但先**钉住第一列**再滑后半段 |
| **簇里的非选中行** | **不滚**：静态截断 + 尾随 `…`（= P75 之前的形态），并停掉槽位 |

* **钉住段 = 第一个「连续 ≥2 个空格」连同这个空白段**：命令表（`/help      显示帮助浮层`）、
  会话表（标题 + 2 空格 + 工作区 + 2 空格 + id）、子代理清单都用这个分列口径。把空白段
  留在钉住段里，滚出来的才是「名字 + 间隔 + `…` + 说明」，而不是名字贴着省略号。
  **钉不出名字就整行滑**（没有这样的分界、或钉完留给滑动的窗口 `< TUI_MQ_PIN_MIN`）。
* **钉住不改变滚动上限**：`maxoff = 总列数 − 窗口宽 + 1` 与钉不钉无关（尾段列数与尾段
  窗口同减 `pin`）—— 所以「滚得到尾」这条判据不受影响。
* **槽位是「一行一项」的**：列表体与选项表一行一项，`基址 + 行号` 就够；reader 的**动作行
  一行能排好几个**动作，所以槽位还要 `+ i` —— 共用槽位时前一个（选中的）刚 `touch` 过、
  后一个未选中的一句 `stop` 就把它停掉，选中的永远不滚。
* 光标移走的那一行会 `stop`（偏移与上限一起清）⇒ 再选中时从头部开始滚，与 P75 的
  「换工作区就复位」同一条口径。

* **推进一步必须自己置脏**（`tui_mark_dirty()`）：`tui_render()` 有**自己的**
  `g_tui_dirty` 闸门，光把返回值交给 `tui_tick` 的 `need` 不够 —— 帧率节流那几关过了
  之后还会在 `!g_tui_dirty` 上早退。漏掉这一句的现场就是用户报的「不会滚动」：
  路径确实夹到 30 列了，但一个字节都不动。
* **偏移集中存在槽位表里**（`g_tui_mq`），不散在各个调用点：`tui_put_clipped` 有几十个
  调用点，各存一份就等于「谁忘了存谁不滚」；同一个格子在不同帧里还会走不同分支
  （浮层开着/关着、选中/未选中），只有把**身份**放进槽位才能跨帧对上。
  槽位是稳定身份不是行号（列表那种用 `基址 + 行号`，文本指纹变了自动归零）。
* **指纹只用头部 16 字节 + FNV**：状态行/任务块的**尾部**每秒都在变（已运行多久），
  把尾部算进去等于每秒归零一次、永远滚不过开头。头部相同 = 还是同一条东西，保留偏移。
* **只推进最近一帧画过的槽位**（`serial == g_tui_mq_serial`）：浮层关了、块收起了的槽位
  不该让屏幕每 400 ms 白脏一次。
* **哪些截断不滚**（各有各的正确语义，刻意排除）：转录与 reader 正文（已按窗口折好行，
  那里的 `tui_put_clipped` 只是安全网）、思考实时行（**尾部锚定**，滚起来就丢了「最新」）、
  输入行（用户正在编辑，光标在哪就得看到哪）、`/diff` 单元格（有**自己的** ←/→ 横向滚动）、
  以及**簇里的非选中行**（P76：一格一条的一组行里只有光标那一行滚，见上一条）。
* **退化规则一个字节不改**：`cwd_budget < 8` 仍整段丢；40/32 列上 cwd 照样整段让位
  （那里窗口 < 8 列，滚动不会把它救回来 —— 这是刻意的：状态字段优先）。

**`cpu` / `内存` 的范围（P24b）**：**本会话进程树**里 comm 相同的进程 —— 本进程 +
它的后代（子代理、workflow 子进程）。**不是**机器上所有 uya-agent：那条老口径
（P18/P24）会把别的终端、别的 worktree 的实例算到用户头上，实测 14 个同名进程合计
338 MB 对着本会话树的 9 MB，一个空闲 agent 显示「内存 300M」（§16 踩坑 104）。
判别分两步、缺一不可：先沿**所有**进程的 ppid 做传递闭包定出树（跨 comm 也要穿过去，
否则 agent → bash → 嵌套 agent 这条链会断），**再**在求和时过滤 comm（工具子进程
bash / node / python 峰值可达 GB 级，不算进来是刻意的）。

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
| 列表 | `TUI_OVK_*`（19 种） | 条目 + 游标 + 过滤词 | 命令面板 / `/sessions` / `/help` / `/model` / `/permission` / `/worktree` / `/goal`（P91 动作选择）/ `/watch` 清单 |
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
3. 统一 `tty_title_clean_into` 清洗截断（**模型侧 3 词 / ≤45 B = 15 个汉字以内**；上屏 ≤80 B，
   用户手填 `/title` 用满 80 B）。

`--continue` 的 `sess_open` 会清空标题。不支持 xterm 标题栈（`CSI 22 t` / `CSI 23 t`）的终端
会忽略压栈/弹栈，退出后保留最后写的标题（**故意不写空标题**）。

**会话标题只有一个来源：模型总结**（P74）。首条人类消息派生出来的那串（前 3 词 / ≤45 B）只是
**备用标题**：不写 `g_sess.title`、不落 `session/title`、不写索引；模型还没起出来之前终端上
显示的是基标题 `uya-agent · <工作目录名>`，模型彻底起不出来时才轮到它上屏。

**执行中改标题（P46）**：`/title`、`set_title` 工具、模型自动起标题。
自动起标题的边界：

| 边界 | 说明 |
|---|---|
| **首发在回合里**（P74） | 待办在回合入口挂，第一次机会是**第一个 step 跑完的 step 边界** —— 不是回合收尾。收尾才发的话，长回合 / 被 esc 中断的回合在网关那边连一条 `call_kind=title` 的行都没有（踩坑 127） |
| 为什么不放在「发第一个请求之前」 | 单线程（踩坑 47 起不了第二条线程），侧路请求是同步的，真网关上一个来回 1.2 s 上下 —— 放在首答之前等于每次首答白等一个往返 |
| **一条会话只起一次** | 首次提示词口径（对齐 DSH 的 `automatic: "first-prompt"`）。之后要改走 `/title`、裸 `/title`、`set_title`。`g_title_auto_done` 同时就是「收尾不更新」的实现 |
| **用户一动键盘就中止自己** | 那一轮标题不更新，而且**不记 revision**（待办留给下一次机会）；回合内那次被打断就由收尾之后空闲那条路补发 |
| 空闲那条路等两段静默 | 「距挂待办与距最后一次敲键都 ≥900 ms」才发 —— 模型一步就答完的单步回合走的是它 |
| 后台请求**不读键** | §4.7 |

要彻底关掉用 `--no-title-auto`。

---

### 11.8 web 界面（P60，`--web [ADDR]`）

这一节回答：**浏览器里那一屏是怎么来的、为什么解释器在服务端、图片怎么显示。**

#### 11.8.1 形态：每个会话 = 真 PTY 上的一个 agent 子进程

```
浏览器                        主进程（--web）                    会话子进程 ×N
┌──────────────┐  GET /       ┌───────────────────┐   fork      ┌─────────────┐
│ HTML/CSS/JS  │ ◄─────────── │ net/httpsrv       │ ──────────► │ agent_run_tui│
│ 顶栏 tabs + ＋│  POST /api/  │ web/webpump  泵    │   真 PTY    │ 备用屏幕     │
│ 网格（按行）  │ ────────────► │ web/webhttp  端点  │ ◄────────── │ 帧 → ESC 字节│
└──────────────┘  GET /api/   │ web/ttyemu   解释器 │             │ 键 ← 原始字节│
                   screen     │ web/webui    页面   │             └─────────────┘
                              └───────────────────┘
```

**子进程跑的就是 `agent_run_tui()`** —— 备用屏幕、帧 diff、浮层、命令面板、markdown
渲染全部照旧，`src/term/**` 一行都不用改。所以「web 端能不能显示浮层」这类问题不需要
单独实现一遍：它本来就是同一份代码。

**会话 id 由服务端预生成**（`sess_new_id`）并经 `UYA_AGENT_FORCE_SESSION_ID` 交给子进程
（复用已有的 `cfg.force_session_id` → `sess_open(..., want_id, …)`）。为什么不能交给子
进程自己生成：`sess_session_path` 把会话按 cwd 归一化分目录，同一个 cwd 下 id 唯一，而
**子进程自由生成会让服务端找不到它**（页面上恢复不了、也读不到标题）。

**子进程 argv 必须显式带 `--tui`**，并在环境里显式 `UYA_AGENT_WEB=0`。为什么两条都要：
父进程若是通过 `UYA_AGENT_WEB=1` 起的，那个变量会被子进程**继承** ⇒ 子进程会再起一个
web 服务器（递归），而不是跑 TUI。实测症状：子进程 fork 出来后立刻退出，页面上一条
会话都没有帧。

**子进程的配置靠环境变量传**（P73，`web_child_env_cfg`）。argv 只带 `--tui`，而
**命令行给的东西不进环境** ⇒ 以前父进程的 CLI 配置一条都传不下去。实测后果（都是
静默的，屏幕上只有一句「请求失败」）：

| 父进程给的 | 子进程实际用的 | 危害 |
|---|---|---|
| `--permission read-only` | `Full access` | **权限被悄悄放宽**（最坏的一条） |
| `--base-url 自建网关` | `api.deepseek.com` | 整轮打不通，页面上报「请求失败（网络或 TLS 校验）」 |
| `--workspace DIR` | 子进程的 cwd | 读写落在错的目录 |
| `--agent-home DIR` | 默认 `~/.uya-agent` | 「同一个 home 下找不到这条会话」 |
| `--tls-verify=pin` | `tofu` | 子进程一律校验失败 |

两条纪律（`websrv.uya` 的 `web_child_env_cfg`）：

* **只在非默认时注入**。父进程什么都没给时不写 —— 否则把默认值钉死在环境里，
  挡住子进程自己去读 `settings.yaml`（那是它的合法来源）。
* **必须用 `env_set_kv`（覆盖语义）**，不能用 `env_add_kv`。环境数组是先继承父进程的
  整份环境再补项的，而 `getenv` 取**先命中的**那个 ——追加的同名项永远读不到。
  实测症状：注入了 `UYA_AGENT_PERMISSION=read-only`，子进程屏幕上还是 `Full access`。

**没有 env 口径的开关不传，但要**说出来**：`--plan` / `--no-dsh-config` / `--quiet` /
`--no-shell` / `--tool-lines` / `--no-save` / `--skill-dir` / `--no-stream` /
`--compat-fold` / `--dry-run` 这几条**没有**环境变量对应（`--plan` 实测确认过），
所以 `--web` 启动时由 `web_warn_unpropagated` 逐条点名。为什么不为它们新造 env：
那会把配置面扩成两套，并与「CLI > env > settings」的既有优先级语义打架
（与踩坑 118/120 同族：**静默是缺陷**，说不出来就先报出来）。

**画布尺寸由页面报、服务端夹**（新建会话的握手，见踩坑 117）：前端 `+` 时把
`measure()` 量到的格子数拼进 `POST /api/sessions?cols=&rows=`，服务端过
`web_size_clamp`（0 = 默认、超上限 = 夹到 `EMU_MAX_*`）之后**同时**喂给 `s.cols` 与
`emu_init`，并 `web_set_winsize` 给 PTY。为什么必须带：不带的话服务端只能按
100×30 起子进程，用户先看到的是一屏按 100 列排的 TUI（右边一片空白/挤在一起），要切
一下标签才被 resize 追上。为什么尺寸要**一个入口**：`s.cols` 与 `emu.cols` 各说一套的话，
服务端按一个宽度发帧、前端按另一个排版，右边框永远对不齐。

#### 11.8.2 为什么解释器在**服务端**（而不是引 xterm.js）

三条理由，按重要性排：

1. **同源判据**。`tui_screen_text()` 存在的全部理由就是「断言与画帧同源，不许另写一份
   排版逻辑」。解释器放在服务端，web 端也能吃这条：`web-emu` 轮断言「`emu` 解出的网格
   文本与 `tui_screen_text()` **逐字节相同**」。换成浏览器端解释，这条判据立刻退化成
   「我们相信上游渲染对了」。
2. **零外部依赖**。xterm.js 要么走 CDN（而 `make selftest` 是完全离线的：靠内置
   mock LLM，CDN 会让 web 轮在离线机器上整片红），要么把几十万行压缩 JS vendored 进仓
   （与 README 第 3 行「只用 Uya 源码实现」的立场冲突，还要在 Makefile 里管它的版本）。
   判据是 `web-page` 轮直接扫整份 HTML 里有没有 `http://` / `https://` / `src="//"`。
3. **工作量被实测限定住了**。`tui_flush`（frame.uya:205-262）一帧只发少数几类序列：
   `ESC[2J/H`、`ESC[<r>;<c>H`、`ESC[2K`、行文本 + SGR、`ESC[?25h/l`，加上
   `tui_term_enter` 的 `ESC[?1049h` / 鼠标上报 / 括起粘贴与 `OSC 2`（终端标题）。
   **没有**滚屏区、tab stop、字符集切换、双宽字符（TUI 正文层是单字节网格，见
   screen.uya:674 的注释）。所以这不是「重写 xterm.js」，是解这几类序列 —— 于是
   `emu_csi_exec` 是一张**白名单**，遇到不认识的 CSI **整条吃掉并丢弃**（绝不把序列
   字节当正文写进网格，那会在屏幕上留下 `[3m` 这种垃圾），`web-emu` 轮还有一条
   「捕获到的 CSI 终字节必须全在白名单内」的断言钉住它。

#### 11.8.3 每帧发什么：只发行差分

`emu_json_frame` 按「行文本**逐字节**比较 + **样式游程**逐字节比较」算差分，只把变化的行
编成 NDJSON（一行一帧）：

```
{"type":"screen","session":"…","cols":100,"rows":30,"full":false,
 "cursor":[17,6,true],
 "rows_changed":[[3,"文本",[[起始码元,长度码元,显示列数,attr,fgMode,fgVal,bgMode,bgVal],…]],…],
 "images":[[row,col,objId,w],…]}
```

* 段表让前端**不必自己 diff 样式**：服务端已经算好了「哪几段是什么样式」。
* 段表里那三个坐标量**各有各的单位，绝不混用**（踩坑 112）：前两个是**前端切片用的
  单位**（JS 字符串是 UTF-16，BMP 外一个字符算 2 个码元），第三个是**显示列数**
  （宽字符占 2 列，只用来排版）。段还要在**宽度类**变化处切开 —— 前端对含宽字符的段
  补 `letter-spacing`（本地字体给 CJK 的字宽与 ASCII 格宽不一定是 2:1），窄宽混在
  一段里就会把窄字也撑开。
* 光标是绝对定位的一个方块，不占字符位（占位会把整行推歪一格）。
* **差分为空时一个字节都不发**（`/api/screen` 是 50 ms 一圈的长连接，空帧流量没有意义）。
  判据是**结构**的（`emu_frame_changed`：行文本 + **行样式** + 光标位置 + 光标可见性 +
  行数），在网格上问、不在拼好的 JSON 里找特征字节 —— 后者错一位就静默翻转（踩坑 106）。
  **样式那份不能省**：浮层里按 ↑/↓ 只换 SGR、一个字符都不改，只比文本就会把那一帧
  当空帧丢掉，页面上的选中高亮永远不动（踩坑 113）。
* **新订阅先补一帧全量**（`WebConn.need_full`）：回放那 4 帧不保证含全量帧，
  只吃差分的话没变过的行永远补不上。同一会话的多个订阅者由 `web_push_session`
  一轮一起发、**发完才 `emu_snapshot`**（差分基准在会话上，见踩坑 106）。
* 传输是 **chunked**（`srv_send_head` + `srv_send_chunk`）。一条实测记录：第一版直接把
  原始帧 `sys_write` 出去，浏览器把畸形块**整条丢弃** —— 症状是「流连上了，一个字节
  都不出来」。

#### 11.8.4 图片：`obj_id` 锚点 + 直传，**不重编码**

**为什么直传原始字节**：浏览器天生会 PNG/JPEG/GIF/WebP —— 正好就是 `imgx` 收的那四种，
而 sixel / kitty 这类图形协议要求服务端**重编码已解码的像素**，服务端不做这件事
（`std.image` 只有 JPEG，生成不了缩略图，见 §13.1.1）。所以最短路是
**把原始图片字节交给浏览器，让浏览器自己解码**，服务端只回答「在哪、多大」。

所以：

* 网格单元里有一个 `obj_id` 字段：`obj_id != 0` 表示「这一格是一个**外部对象的锚点**」。
  它**只承载「在哪、多大、指向哪个对象」，绝不承载字节** —— 这是「图片能不能显示」
  与「网格增量有多大」两件事解耦的关键。
* 锚点打在 `/image` 的那行回执上（`web_annotate_images` 在每次喂完字节后重算一遍：
  30 行的重算是 O(行 × 行宽)，比增量维护「哪一行被改了」简单得多，也不会错）。
* 页面把 `<img src="/api/image?id=<sha>">` 绝对定位**盖**在那个坐标上（不在字符流里，
  所以不会把行推歪）。
* `GET /api/image?id=` 从 `<agent_home>/attachments/<id>.<ext>` **原样直传**，
  `Content-Type` 由 `imgx_sniff` **按字节嗅探**决定（不信扩展名）。
* `id` 必须**只由十六进制字符组成且长度 ≤64**：这是**路径穿越**的唯一入口，校验在拼
  路径**之前**（自测里有一条「带 `../` 与 `/` 的 id 必须被拒」的断言）。

`obj_id` 这条通道不止给图片用：前端要画链接/按钮/图表时，同一套「服务端只给几何、
渲染在前端」的机制直接复用。

#### 11.8.5 标题从哪来（顶栏那一栏）

优先级**三级**，与 TUI 的终端标题同口径（模型侧 3 词 / ≤45 B = 15 字），这样顶栏与终端
标题不会各说一套：

1. 会话日志索引（`<home>/index.jsonl`）里那条 `title` —— 模型 `set_title` / 人手
   `/title` / 自动起标题写进去的；
2. 服务端从**会话日志开头** 64 KiB 派生：首条非注入类人类消息的前 3 个词（会话刚开、
   模型还没起标题时的兜底）；
3. 空串（前端显示「会话 N」）。

**为什么是服务端主动取、不是浏览器轮询**：标题是服务端知道的事（会话日志在服务端），
而前端轮询会把「每秒一次的全量列表请求」变成常态。现在只在 `/api/sessions` 被请求时
读一次索引。

#### 11.8.6 单线程 + 一个 poll

与 §11.2 同一条架构决定（踩坑 47：工具链堆并发分配 8/8 崩 ⇒ 单线程 + 泵点）：
**8 条会话 + 32 条连接全塞进一次 `poll`**（`web_poll_once`），谁就绪处理谁：

| poll 槽 | 就绪时做什么 |
|---|---|
| listen | `srv_accept_nb` 收连接挂进连接表 |
| 会话 master（读） | `web_pty_ready`：有 `POLLIN` 就 `web_read_pty`（最多 16 KiB → `emu_feed` → 重算图片锚点）；**没有 `POLLIN` 而给了 `POLLHUP`/`POLLERR` 就 `web_pty_eof`**（子进程没了 —— 关 master + 回收僵尸 + `alive=false`；见踩坑 105） |
| 会话 master（写） | `web_write_pty`：待发按键字节写进去（非阻塞，写不完留着） |
| 连接（读） | `web_service_conn`：READ 收请求并分派 / STREAM 只可能是对端关了 |
| 连接（写） | `web_flush_conn`：chunked 推帧 |

**顺序有讲究**：先读 PTY（产出数据）再推帧（消费数据），这样「按键 → 屏幕更新」只经
过一圈（50 ms）；反过来会慢一圈。**PTY 读槽内部也有顺序**：先 `POLLIN` 后 `POLLHUP` ——
子进程退出前写出去的那一帧要读干净（踩坑 105）。

**推帧那一支的顺序也是硬要求**：`web_push_session` 先算一次「变了没有」
（`emu_frame_changed`），再把它发给**每个**订阅者，最后才 `emu_snapshot`。差分基准
（`s.emu.prev`）在**会话**上而不是连接上，所以老顺序（「给第一条连接推完就快照」）会让
同一会话的第二条连接永远收不到帧；而「变了没有」必须用**结构判据**（行文本 + 光标位置 +
光标可见性 + 行数），不能拿拼好的 JSON 去找特征字节（见踩坑 106）。

**任何一处阻塞都会冻住全部**（同一个进程里还有 LLM 请求与工具循环），所以读/写一律
非阻塞，等就绪只靠这一次 poll。

**一圈的最后一步是收摊**（`web_sweep_closed`）：把 `close_wanted` 的会话摘掉。为什么
必须放在**最后**、而不是在 `/api/close` 或 `web_pty_eof` 里当场摘：主循环手上有一份
「poll 槽 → 会话下标」的映射（`idx[]`），而 `web_remove_at` 会让后面的条目整体前移 ——
当场摘表，剩下的槽就会读到**错的会话**。收摊顺序也是硬的：**先给订阅者写分块终止块
（`srv_send_end`）→ 关连接 → 再摘表**。终止块不能省：不写它就是一段被截断的分块体，
浏览器那边是 network error，前端就没法把「会话正常结束」与「连接坏了」分开。

#### 11.8.6.1 会话来去：谁决定「标签还在不在」

| 情形 | `close_wanted` | 结果 |
|---|---|---|
| 用户点标签上的 `x`（`POST /api/close`） | 置位（端点上） | 收子进程 + 关订阅连接 + 摘标签 |
| 子进程**正常退出**（`/exit` / ctrl+d，退出码 0） | 置位（`web_pty_eof` 里） | 同上 —— 用户已经说了「不用了」 |
| 子进程**异常没了**（被信号杀 / 非零退出） | 不置位 | **留标签与最后一帧**，屏幕上还看得见它说了什么 |

判据在 `web_reap_child`：wait status 的低 8 位是终止信号、次高 8 位是退出码，**两个都是
0** 才叫正常退出。老实现把 wait status 丢掉了，于是只有「活着 / 不活着」两态 ⇒ 分不出
「用户 /exit 了」与「它崩了」，只能一律留标签（用户报的「exit 之后标签不关」，见踩坑
115）。

**订阅的身份是会话 id，不是表内下标**（`web_conn_wants`）。下标是**位置**：摘表会让后面
的条目前移，于是「连接记的 3」在别人被摘掉之后就指向了另一条会话。这个坑与上面那条收摊
顺序是同一个根（位置被当成身份），实测症状是订阅最后一条会话时关掉第一条，那条长连接
**再也不推帧**（踩坑 114）。

#### 11.8.6.2 输入：两条路，绝不重叠

| 输入 | 通道 | 为什么 |
|---|---|---|
| 控制键 / 功能键（方向、Tab、Enter、Esc、F1–F12…） | `keydown` → `keyBytes` → ESC 序列 | TUI 只认 xterm 的序列；且这些键**必须** `preventDefault` |
| 可打印文本（ASCII / **中文** / 表情） | `#ime` 那个透明 `textarea` 的 `input` / `compositionend` | 中文是**输入法提交**的：`keydown` 里 `e.key` 是 `"Process"`，拿不到字；而 IME 事件只投给**可编辑元素** |
| 粘贴 | 同上（`paste` → 包成括起粘贴 `ESC[200~…ESC[201~`） | TUI 的粘贴态把 CR/LF 当换行而不是提交，粘几行不会提交几次 |
| `ctrl+v` | **放行给浏览器**（`keyBytes` 返回空串） | 终端里的 ctrl+v 读的是**服务端**那侧的 X11 剪贴板，web 服务端没有 X 连接 —— 那条路在网页上永远是空的 |
| `ctrl+c` | **按选区分流**：`selInTerm()` 为真 ⇒ 放行给浏览器（复制）；为假 ⇒ `\u0003`（中断） | 终端里 ctrl+c 是 SIGINT，网页里它同时还是「复制」这个通用手势；二者只能靠「有没有选中文本」区分 |
| 复制 | `copy` 事件里 `preventDefault()` + **只** `setData('text/plain')` | 每行是按样式切的 `<span>`（钉着宽度/颜色/字距），默认复制会序列化出一份 `text/html` —— 粘到别处就是「文字带着一块暗背景和一堆补位空格」 |

三条纪律（缺一条就是中文用户报的那种「打不进字」）：① **可打印字符只走 textarea**
（两边都发会双发一个字符，所以 `keyBytes` 里没有「单字符直接返回」那条兜底）；
② **预编辑期间不发送**（`composing` 或 `inputType === 'insertCompositionText'` ——
拼音字母在候选期间也会触发 `input`，发出去就是输入行里一串拼音）；
③ **键盘事件在预编辑期间整条丢掉**（`composing || e.isComposing || keyCode === 229`）——
不丢的话「回车确认候选词」会被当成交付键，把半截拼音提交出去。

代理框还要**跟着光标走**（`applyFrame` 里钉在光标格上）：IME 候选窗的位置由被编辑元素的
位置决定，钉不住就会飘到屏幕左上角。见踩坑 116。

#### 11.8.6.3 焦点与选区：一对**互斥**的要求

这个页面有两件必须同时成立、方向却相反的事：

* **IME 事件只投给可编辑元素** ⇒ 终端区里必须有东西拿着焦点（那个透明 textarea），
  否则中文一个字都进不来（踩坑 116 那条的根因）；
* **浏览器只认「焦点还在原地」的拖选** ⇒ 拖拽途中一旦移走焦点，它**当场放弃建选区**
  （屏幕上连高亮都不出现）；建好之后再抢走，选区同样作废。

所以「抢焦点」这件事被收成**一个**入口，判据只有一条：

| 状态 | 抢不抢焦点 |
|---|---|
| 鼠标按在终端区里（`dragging`，按下到松开之间） | **不抢** —— 抢了就等于取消这次拖选 |
| 终端区里已有非折叠选区（`selInTerm()`） | **不抢** —— 那是用户正要复制的东西 |
| 只是点一下（松开时选区仍是空的） | 抢（`focusIme()`），否则接下来打字没反应 |
| 人点了标签 / `+`（`focusImeNow()`） | **显式**抢，并顺手清掉残留选区 |

两个实测细节值钱：**a)** 判据必须落在**按下**与**松开**两个时刻上，不能只在按下时判 ——
按下的那一刻选区**必然**还是空的（选区是拖出来的），拿它当条件等于永远不抢；反过来在
按下时就抢，则永远选不中。**b)** `blur` 自愈那条路（焦点丢了自动抢回来）也必须过同一个
判据：拖选本身就会让 textarea 失焦，自愈一跑，选区当场作废。

**残留选区会把键盘输入整个吃掉**：浏览器把「插入字符」重定向到那段选区上（替换它），
于是 `#ime` 的 `input` 事件根本不发、字符进不了 PTY —— 症状是「复制完接着打字没反应」。
所以任何**不带 ctrl/alt** 的键进来时先清选区、把焦点收回代理框（`focusImeNow()`）。
实测这一条与 `dragging` 是同一族的两个坑：**都不是「哪个函数写错了」，而是「谁有权改
焦点」没说清**。见踩坑 125。

#### 11.8.7 退出：与 TUI 用**两套**信号处理

`sigx_on_term` 是 self-contained 的 —— 它立刻 `sys_exit`（那是对的，终端必须马上还
回去）。web 模式**不能**用它：`sys_exit` 会让所有会话子进程变成孤儿（用户会在 `ps` 里
看到一堆残留 agent，而它们的父进程已经没了、PTY master 也关了）。所以 web 模式用
`sigx_install_web`：处理器**只置一个 bool**，主循环看到之后走正常收尾（逐个按进程组
`SIGCONT`+`SIGKILL` 收子进程），然后自己返回。这是「处理器里只做能做的事」那条纪律的
同一个应用。

---

### 11.9 界面后端接缝（P80，`src/ui/`）

这一节回答：**「用哪个界面」这件事为什么不写在执行核里**，以及怎么加一个新界面
（webui / native / robot）而不动 `agent/` 一行。

#### 11.9.1 病根：今天没有分界，而且「决定」写错了地方

P80 之前，执行核（`agent/` `tools/` `net/` `media/` `diff/` `vcs/`）里直接调
`term/` + `web/` 的调用点有 **600 处**、涉及 **154 个不同函数**；更要命的是**决定**
也写在执行核里：

| 位置 | 数量 | 说明 |
|---|---|---|
| `agent/` 里的 `if tui_active()` | 19 处 | 「现在是不是全屏界面」由执行核判断 |
| `agent/` 里的 `tui_overlay_kind()` 派发 | 10 处（5 文件） | 「浮层回来的是哪种结果」由执行核判断 |
| 工具层直呼浮层 | 3 处 | `tools/askuser.uya` 的 `tui_confirm_wait` / `tui_ask_wait`、`agent/plan.uya` 的 `tui_reader_wait` |

所以「加一个 webui」今天的代价不是「写一套绘制」，而是**去改执行核里那 19 + 10 个分支**
—— 每加一个界面就要再改一次，而且改错的分支是**静默走错**（屏幕上没反应，不报错）。

**要抽的不是绘制代码，是「决定与事实」**：

* 执行核只报**事实**（「这一轮开始了」「这个工具跑完了」「这条命令要审批」）——
  画不画、画成什么，由**后端**决定；
* 执行核只收**意图**（批准 / 拒绝 / 用户提交了这句）—— 怎么问（浮层、y/N、HTTP 往返、
  机器人按钮），由**后端**决定。

#### 11.9.2 形状：一个接口 + 注册表 + 端口入口

```
         执行核（agent/ tools/ net/ …）—— 只认 ui_* 端口
                        │
                        ▼
   ┌─────────── src/ui/（端口层，执行核唯一的界面入口）───────────┐
   │  interface UiBackend   ← 契约（7 个方法）                     │
   │  g_reg: [UiBackend: UI_BE_MAX]   ← 注册表                     │
   │  g_ui: UiBackend                 ← 当前后端（运行期可换）      │
   │  ui_text / ui_status / ui_pump / ui_ask / ui_start / ui_stop   │
   └───────────────────────────────────────────────────────────────┘
        │
        ├── be_null.uya    无界面（headless / 子代理 / 管道）：空实现 + fail closed
        ├── be_tui.uya     全屏 TUI（包装 term/tui/ 11 文件）        ← 待落地
        ├── be_scroll.uya  滚动模式（包装 term/tty + term/view）      ← 待落地
        └── be_events.uya  事实流（NDJSON；native / robot 的共同底座）← 待落地
```

**为什么是 `interface` 而不是「`u8` tag + `match`」**（0.10.3 实测）：函数指针类型
`fn(i32) i32` **编译器不支持**（`意外的 token 'fn'`），所以函数指针表那条路走不通；
而 `interface` 是**真 vtable 派发**，还带一条 tag 方案给不了的性质 ——
**漏实现方法是编译期错误**：

```
错误: 结构体 'BadBe' 缺少接口要求的方法: 'text'
```

tag 漏一个分支是**运行期静默走错**分支，接口漏一个是**编译期报错**。这是选它的全部理由。

**三条禁令与一个静默陷阱**（会段错误，不是编译错误；完整版见 CODING.md §1.4）：

```uya
// ✗✗ 能编译、能链接，**运行期 SIGSEGV（实测退出码 139）**：codegen 不构造 {vtable,data} 对
use_ref(&g_tui as &UiBackend, n);
// ✓ 接口值只能由「具体 struct → 接口变量」的赋值构造
var r: UiBackend = g_reg[0];
```

另有：`return <具体struct>` / `out[0] = <具体struct>` / 字面量直接赋接口变量**都编不过**；
运行期索引接口数组要**显式夹取**；`if` 条件里不许写 `as`。

#### 11.9.3 端口只收「效果」，不收「排版」

这是决定「哪些符号进端口」的唯一判据：

| 归类 | 例子 | 去哪 |
|---|---|---|
| **效果**（碰终端 / 会阻塞 / 改屏幕） | `tui_add_notice` `tty_puts` `tui_set_*` `tui_tick` `tui_confirm_wait` | **进端口** |
| **排版数学**（无副作用） | `tty_clip_bytes` `tty_cols_between` `tty_utf8_decode` `tty_char_cols` `mdv_*` `view_render_block` | 留 `term/`，**所有后端共用的共享库**，谁都能直接调 |

把排版也塞进端口是错的方向：那会让「显示宽度」这类**必须逐字节一致**的口径在
每个后端各存一份，与 §11.8.2 的「同源」承诺直接打架。

#### 11.9.4 `ui-audit`：守结构约束，因为「全绿」看不见它们

`make ui-audit`（`testdata/ui_audit.py`）五条硬判据 + 一条欠账计数：

| 判据 | 红意味着 |
|---|---|
| A `&x as &接口` | **踩中静默段错误陷阱**（编译与自测都绿） |
| B 执行层出现 `betui_` 等后端私有前缀 | 绕过了端口，换后端又要改执行核 |
| C `src/ui/**` 出现 `Config` / `agent_` / `g_sess` | 端口层反向依赖执行核，后端换不动、也不能独立自测 |
| D `be_*.uya` 里的 struct 没写 `: UiBackend` | 假后端（漏**方法**会编译报错，整个忘标注不会） |
| E 注册表槽位没填满 | 空槽 vtable = null，`ui_use` 切过去即崩 |
| G `src/ui/**` 把 `chan` 原样喂给 `tui_*`/`tty_*` | **通道编号直通** ⇒ 思考与通知对调（踩坑 148，静默串位） |
| H `ui_use(UI_BE_X)` 的槽里是 `g_null`（`NULL` 除外） | 切到一个**还没落地**的后端 ⇒ 静默丢弃一切输出（不崩，所以最难查） |
| F `tui_active()` / `tui_overlay_kind()` 欠账数 | **进展量**（P80 目标 0）：过渡期只报数不判红 —— 硬红了这条审计在过渡期永远红，那样的审计会被关掉 |

五条硬判据都做了防假绿对照（各装回一次违例 ⇒ 当场红）。

#### 11.9.5 当前进度与后续

**已落地（P80 第一批）**：端口 + 接口 + 注册表 + 空后端（`ui_port` / `be_null` /
`ui_reg`），`make ui-audit`，以及 CODING.md §1.4 的接口规范与陷阱。运行期实测过：
注册表切换、`ui_ask` 的 `error.UiNoChannel`、空后端零字节输出、无段错误。

**已落地（P80 第二批：接口真正生效）**——这一批的关键事实是「第一批建好了但**没人用**」：

| 事实 | 读数 |
|---|---|
| 第一批交付时执行核调 `ui_*` 的次数 | **0**（`ui_text` / `ui_status` / `ui_pump` / `ui_ask` / `ui_use` / `ui_reg_put` 逐个精确匹配全是 0） |
| 同一时刻执行核直呼 `tui_*` / `tty_*` 的次数 | **602**（`agent` 500 / `net` 46 / `tools` 36 / `media` 14 / `diff` 5 / `vcs` 1） |
| `g_reg` 四个槽 | 全填 `g_null`（即「切到任何后端都丢输出」） |
| `ui_port.uya` 文件头声称存在的 `ui_on` | **不存在**（文档与代码分叉） |

所以第二批做的是「把接口接上电」，**不是**搬 600 个调用点：

| 内容 | 落点 |
|---|---|
| `be_tui.uya`：`TuiBe : UiBackend`（第一个真实后端，7 + 1 个方法） | 新增 292 行 |
| `ui_on(what)`：`UI_ON_ACTIVE` / `UI_ON_OVERLAY_OK` 两个**事实**查询 | `ui_port` / `ui_reg` / `be_null` / `be_tui` |
| 接线：`agent_tui_start` 末尾 `ui_use(UI_BE_TUI)`；`agent_tui_stop` **开头** `ui_use(UI_BE_NULL)` | `ag_plan_pump`（两行） |
| `ui-port` 自测轮（5 段：注册表 / fail closed / **通道映射** / status 转发 / `ui_on`） | `tuis_ui_port.uya` |
| `ui-audit` 判据 G / H（见下） | `testdata/ui_audit.py` |

**验收**（全部实测）：`--tui-demo` **逐字节相同**（334 行 / 57765 B，改动前后 `cmp` 通过）；
`make selftest` 185 轮绿；`make lint-size` / `make ui-audit` 通过。

> ⚠ 一个**必须记住的两套通道编号**（`make ui-audit` 判据 G 就是钉它的）：端口的
> `UI_CH_*` 是 MAIN=1 / **REASON=2** / **NOTICE=3**，而 TUI 内部的 `tui_sink_bytes`
> 是 1=正文 / **2=通知** / **3=思考**（`tty_reason_write` 送的就是 3）。三个里错了两个，
> 而错法是**静默串位**（不崩、不报错、编译期看不见，只是思考与通知对调）。所以
> `be_tui.text` 必须过一张显式映射表 `betui_chan_map()`；**任何地方都不许把端口的
> `chan` 直接喂给 `tui_sink_bytes`**。这条的回归腿必须按**条目种类**断言（`uip_chan_check`），
> 不能只断言「屏幕上有字」—— 对调之后两边都「有字」。

**判据 G / H 的理由**（两条都做了防假绿对照：装回违例 ⇒ 退出码 1，改回 ⇒ 0）：

* **G 端口通道号直通**：`src/ui/` 里把 `chan` 原样传给 `tui_*` / `tty_*` = 上面那个对调。
* **H `ui_use` 切到空后端**：判据读的是 `g_reg` 字面量里那一槽**是不是 `g_null`**
  （只看「有没有 `ui_reg_put(UI_BE_X)`」是假绿的 —— `ui_reg_put(UI_BE_X, g_null)` 与
  「没登记」在运行期是同一件事）。`UI_BE_NULL` 是**例外**：它的槽本来就该是空后端，
  `ui_use(UI_BE_NULL)` 是正常收尾。要抓的是「切到一个还没落地的非空后端」——
  那时界面看起来「切过去了」，实际什么都不显示。这正是 §2.4 那条
  「SIGSEGV 陷阱以外还有静默陷阱」的同族：空后端的 vtable **有效**，所以不崩。

**第二批实测抓出的两个真缺陷**（都由新自测轮抓住，改前先看到红）：

| # | 缺陷 | 症状 | 修法 |
|---|---|---|---|
| ① | `be_tui.status` 的 `UI_ST_ACCESS` 分支：非法载荷（非数字）被解析成 0 并**照样设置** | 屏幕上的访问模式显示成「用户降权了」，而策略本身没动 —— **屏幕与事实分叉** | 解析不出来就**保持不动**（显示层是镜像，不是真值源） |
| ② | 自测轮里 `UI_ST_TEXT` 的载荷长度**手数成 13**（实际 14） | 截断后的载荷悄悄变成另一种事实，屏幕上只是少一个字符 | 载荷一律走 `bufx_cstr_len`（这条已写进该文件的头注释不变量④） |

**后续按族推进**（每族独立绿，绝不并行开两族 —— 半迁移态最难查）：

| 阶段 | 内容 | 完成判据 |
|---|---|---|
| 2 | A 族（文本/转录 224 处）过端口 | `--tui-demo` 快照逐字节相同 |
| 3 | B 族（状态 62 处）+ 倒置 `term/tasks.uya` 对 `agent/` 的 122 处反向依赖 | `term/tasks` 不再引用 `agent/` |
| 4 | C 族（泵点/输入 57 处），循环所有权归后端 | `make p30-check` |
| 5 | D 族（提问/浮层 68 处），意图通道 + fail closed | 判据 F 清零（改硬判据） |
| 6 | 收敛成一个会话驱动 + `be_events`（native/robot 底座） | `make e2e-portable` + `make web-selftest` |

**迁移手法**：端口入口**沿用现有符号名**（`tui_add_notice` / `tty_puts`…），TUI 里的实现
改名成后端私有（`betui_*`）。于是 `agent/` 一行不用改就先接上端口，迁移按**符号**推进
（154 个）而不是按调用点推进（600 个）。**同后端内部互调直呼后端私有函数、不许绕端口**
（防「端口里再调端口」的无限递归）。

**阶段 2 的第一片已落地（P80 第三批：离散条目族）**——动手前先解决了一个**词表问题**：

| 结论 | 依据 |
|---|---|
| A 族**不是一族**，是两种**边界语义相反**的输出 | ①**字节流**（`tui_sink_bytes(1/3)`、`tty_write(fd 1/2)`）：要能**续接**，否则一段流式正文会碎成几十条；②**离散条目**（`tui_add_notice` / `add_user` / `add_steer` / `add_tool_block`）：一次调用一条，**不许续接**，否则连续两条回执会粘成一条 |
| 压进一个 `text(chan)` 就会**静默改排版** | `tui_add_notice` 另有「512 B/条上限 + 每次新起条目」的口径，而 chan-2 的 `tui_sink_line` 是「按 `\n` 切 + 续接上一条 NOTICE」。实测把 `add_notice` 改成走 `sink(2)` 后 `--tui-demo` 与 TUI 自测**都照不出来**（它们不覆盖连续两条回执），所以这条只能靠**结构**兜，不能指望现有回归网 |
| 修法：端口加一个**独立方法** `entry(kind, …)` | `UI_ENT_USER` / `UI_ENT_STEER` / `UI_ENT_TOOL` / `UI_ENT_NOTICE` 一张新表。两个方法各自一张词表，**不共用一个 `chan` 号**（共用了就得在运行时猜调用方意图） |
| `ui_text` 当时**零生产调用点** | 所以扩词表是零代价的 —— 这一条让「趁早把形状定对」变得便宜 |

落地内容：`ui_fwd.uya`（**同名转发器**：`tui_add_notice` 等沿用旧名，体内只做 `ui_entry(...)`）、
`term/tui/entry.uya` 的四个实现改名 `betui_*`、`term/` 内的调用点直呼 `betui_*`（不绕端口）、
`be_null` / `be_tui` 各加 `entry`。

**这一批实测抓出的三处真缺陷**（都由既有回归网抓到，改前先看到红）：

| # | 缺陷 | 症状 |
|---|---|---|
| ① | `agent_tui_demo` 从不 `ui_use` | 它只 build 帧、不进备用屏幕，于是端口入口落到**空后端**上：`--tui-demo` 第 50/81 行的「你」与工具块**整片消失** |
| ② | `be_tui.entry` 里仍写着 `tui_add_user` 等旧名 | 定义已改名 `betui_*`，于是链接期 `undefined reference`。**注意：改成不存在的符号编译期不报错**（合并命名空间里它看起来就是个外部函数），只有链接时才炸 —— 所以「改名」这类改动必须真的走一次 `make build` |
| ③ | TUI 自测夹具（`tuis_reset`）从不选后端 | 与①同因：8 条「转录里没有…」的断言当场红 —— 夹具整轮在测 TUI 渲染，却把输出丢进了空后端 |
| ④ | `agent_run_tui` 的 **headless 分支**也不选后端 | 与①同因、但**当时不红**（那条路的既有轮次恰好没有输出经过端口入口）。这是**潜伏**的一处：改动后按「同类现场」主动清查才找到，已补 `ui_use(UI_BE_TUI)` |

> 三条的**共同根因**是同一件事：**「选后端」这个动作原先只发生在 `agent_tui_start` 一处**，
> 而演示屏与自测夹具都绕过它。修法是在各自的复位/入口处显式 `ui_use`。
> 这也是判据 H 的另一面：H 管「别切到空后端」，而这里管「该切的时候要切」。

**验收**（全部实测）：`--tui-demo` 仍**逐字节相同**；TUI 自测 **34 轮全绿**；全量 `make selftest`
**185 轮绿**（唯一失败是既有的 `clip-helper` 夹具缺陷，与本轮无关，`main` 的 `ab68e75` 已修）；
`lint-size` / `ui-audit` / `check` / `build`（真静态）全过。

**阶段 2 的第二片已落地（P80 第四批：事实流后端 `be_events`）**——它是**自研 web / DSH 适配
两条路线的共同底座**（DESIGN §11.8 的 web 路线今天靠「PTY 子进程 + 服务端解释器网格」，
而事实流让前端**不必**解释终端字节：它直接吃结构事实）。

| 内容 | 落点 |
|---|---|
| `be_events.uya`：`EventsBe : UiBackend`，把每条事实写成**一行一条完整 JSON**（NDJSON） | 新增约 330 行 |
| 注册：`EVENTS` 槽从 `g_null` 换成 `g_events_be`（**判据 H 的「别切到空后端」当场有了实效**） | `ui_reg` |
| `ui-events` 自测轮：真写进管道、再读回来逐条解析（线格式 / 判别键 / 转义 / fail closed / 未 start 不写） | `tuis_events.uya` |

**线格式**（`type` 是判别键，消费者**认不出的必须忽略**，这样才能扩）：

```
{"type":"text","chan":1,"data":"…"}     chan = UI_CH_*
{"type":"entry","kind":1,"data":"…"}    kind = UI_ENT_*
{"type":"status","what":1,"data":"…"}   what = UI_ST_*
{"type":"run","state":3,"label":"…"}    state = UI_RUN_*
{"type":"pump","intent":0} / {"type":"start","cols":…,"rows":…} / {"type":"stop","dropped":N}
```

三条设计决定：**① `UI_ST_RUN` 另立 `run` 类型**（它的载荷是「状态码 + 可选标签」两段，
压进 `data` 就得让消费者自己切字符串 —— 那是把端口的编码细节泄漏出去）；
**② `ask` 一律 `UiNoChannel`**（事实流是**单向**的，没有回答回路；要问答得另配输入通道，
那是独立一件事）；**③ 一行拼不完整就整条丢弃并计入 `dropped`**（绝不写半行 —— 半行会让
按行解析的消费者**静默错位**，而错位后的症状是「后面所有事实都串了」，极难查）。

**这一批实测抓出的三处真缺陷**（都由新自测轮或既有回归网抓到）：

| # | 缺陷 | 症状 |
|---|---|---|
| ① | `beev_begin` 少写一个收尾 `"` | 整行变成 `{"type":"start,` —— **一条都解不出来**。手工拼 JSON 最容易漏的就是这种引号，所以自测里有一条**逐字节**钉 `start` 形状的断言 |
| ② | 自测夹具把 fd 1 接到管道后**用完就清 `saved`** | 第二次 `attach` 再也还不回来 ⇒ 管道写端关掉后 fd 1 悬空 ⇒ 下一次写 stdout **SIGPIPE**（实测 141）。**症状极隐蔽**：`make selftest` 在 `san-shell` 之后**静默死掉**，前 125 轮全绿、看不出与本次改动的关系（基线二进制同一轮跑到 179） |
| ③ | 两处测试夹具有裸 `wfd`/未注释函数 | `link`/`doc-cover` 抓到（漏参 + 缺函数头注释）|

> ②的教训值得单记：**测试夹具动 fd 1 时，还原路径必须与「可能出错的所有分支」一样多**。
> 这里第一版把 `saved` 当成「一次性」的（`restore` 里顺手 `close`），而本轮的设计是
> **反复接线**（接上 → 写 → 还回 → 再接）—— 两者的生命周期假设不一致，于是「第二次之后
> 就再也还不回来」。修法是**谁开谁关**：`saved` 只由 `uev_pipe_close` 收，`restore` 只做
> `dup2` 还原。

**验收**（全部实测）：二进制 `--selftest` **181 轮绿**（基线 179 + 本轮 2 轮），退出码与基线
同为 3（唯一失败是既有的 `clip-helper`）；`--tui-demo` 仍**逐字节相同**；`lint-size` /
`doc-cover` / `ui-audit` / `check` / `build`（真静态）全过。

**阶段 2 剩下的部分**（下一批）：字节流那一半（`tui_sink_bytes(1/3)` 与 126 处
`tty_puts(&tty_ui, 2, …)` + 28 处 `tty_write`）。它比离散条目**简单**（转发基本等价，
没有条目边界问题），但两条遗留约束要先解决：

| 约束 | 实测 | 影响 |
|---|---|---|
| **`UI_BE_SCROLL` 槽还没落地** | 该槽是 `g_null`（现在是唯一一个） | 滚动模式下 `agent_tui_start` 不被调用 ⇒ `ui_use` 停在空后端 ⇒ **滚动模式的显示输出会被端口静默丢掉**。所以字节流那一半**必须**和 `be_scroll` 同一批做，或者端口入口保留「无后端时直呼 `term/`」的兜底 |
| **`tty_puts` / `tty_write` 兼作诊断通道** | 它们**本来就是两模式漏斗**（`tty_sink_on` 为真走转录、否则直写 fd） | 转发时要保住「滚动模式直写 fd 2」这条路（`warning:`、`error:` 这类必须始终可见），不能一律当 UI 事实吞掉 |

**一个测试隔离的既有缺口**（本批实测撞上，与代码无关）：`make e2e-tasks` **不设
`UYA_AGENT_HOME`**，于是 `<HOME>/.uya-agent/goal.json` 里若存在一个活跃目标（本会话自己
的 goal 就是），`/tasks` 的空态串就变成「有目标」那一版，`e2e-tasks` 报 `FAIL: 空态串不对`。
判据：把那个文件挪开，同一轮立刻通过（实测）。**修法留给后续**（该目标应当像其它 e2e 那样
用独立的 `UYA_AGENT_HOME`），本轮只记录。

**明确不做**（都是决定，不是遗漏）：

| 不做 | 理由 |
|---|---|
| `dlopen` 式运行时加载后端 | `make link-audit` 钉死真静态链接（无 `PTE_INTERP` / 无 `NEEDED`）。本仓的「插件」= **编译期注册 + 运行期接口选择** |
| 用 `src/cshim/*.h` 定义 C 函数指针 typedef 绕开接口 | 要写 C（违反 §1.1 目标 1），且给所有后端开一个 C ABI 面 |
| 把 `web` 现有的 PTY + `ttyemu` 路线一起换掉 | 会碰掉 `web-emu` 轮的「解释器网格 == `tui_screen_text()` 逐行相同」这条同源判据 —— 必须独立一轮决策（P81 候选） |

#### 11.9.6 通往「DSH webui」的剩余工作（路线图，实测过的约束）

目标形态：**不改 DSH 的 webui**，让 DSH 的浏览器前端（`@deepseek-ai/dsh-web-frontend/dist`，
4.6 MiB / 89 文件）吃**本仓**的事实流。已验证 DSH 自己留了三个正式接缝
（静态 dist、`webserver/index-inject` 注入表、`__DSH_TRANSPORT__` 页全局），所以这是
「当它的宿主」而不是给它打补丁。

| 步 | 内容 | 关键约束（实测） |
|---|---|---|
| ① **形状适配层** | 本仓日志 → DSH 的 `SessionEvent` | DSH 浏览器按 `surfaceOp` 判「这条进不进对话面」：**`user/message` / `assistant/message` / `tool/result` 缺它就不渲染**（三条都缺 ⇒ 界面上一条消息都没有，且**没有报错**）。本仓今天**不写** `surfaceOp`、不写 `message.id`，`assistant.message.content` 是**字符串**而 DSH 要 `ContentBlock[]`、`tool/result` 是扁平 `content`+`callId` 而 DSH 要 `message.content[0].tool-result`。**所以适配层不可省**（这也是本轮 `be_events` 选「结构事实」而不是「终端字节」的理由：适配点天然落在后端里） |
| ② `/api` unary + WS 下行 | DSH 浏览器认 52 个方法（最小可聊天集约 28 个）+ 两条**必须**是 WebSocket 的下行（普通 GET 返 426，**没有 SSE 回落**）。好消息：两条下行**只发不收**，所以纯 Uya 只要握手 + 不掩码的 text 帧编码（`sha1_digest` / `encode_base64` 标准库都有；`std/http/websocket_*.uya` 也在，但它拖 `tls.https`，建议自己写薄的一份） |
| ③ dist 静态服务 + 注入 | 只读服务 DSH 的 dist；**复刻 `bootInjections()`**：内联 queue 脚本 + 两个 parser-blocking preload + `window.__DSH_BOOT__` 全局，插在 `<head>` 开标签之后 |
| ④ 会话模型 | DSH 线协议要「同进程多会话 + 实时事件流」，而本仓 `--web` 今天是「每会话一个真 PTY 子进程 + 服务端解释器网格」。**这是最大的架构分歧**（不是代码量问题） |

两个已知的硬约束，动手前必须先解决：

| 约束 | 实测 | 影响 |
|---|---|---|
| `SRV_REQ_MAX = 8192`（**头 + 体总量**）且不支持 chunked 请求体 | `net/httpsrv.uya` | DSH 的 `session.prompt` 允许 300 MiB 体（内联图片 base64）⇒ **不改就是「发一张图就 413」** |
| DSH wire **没有协议版本字段** | `host.describe` 里没有（DSH 自己的已知限制） | 版本耦合是**结构性**的，只能靠「阶段 0 探针 + 回归轮」兜住，不能靠协商 |

**① 形状适配层已落地（P80 第五批，`src/web/wsess.uya`）**——这是**两条 web 路线
（自研 / DSH 适配）的共同前置**，因为两条都要「结构事实」而不是终端字节。它逐行读本仓
`session.jsonl`、翻译成 DSH 的 `SessionEvent` 形状，**不改本仓日志一个字节**（日志仍是
`--resume` 与 stats 折叠的真值源）。落地内容：

| 翻译 | 本仓形状 | DSH 要的形状 | 为什么不能省 |
|---|---|---|---|
| `user/message` | 有 `role`/`content`/`source`，**没有** `id`、没有 `surfaceOp` | 要 `data.id`（fold 的条目身份）+ **事件级** `surfaceOp` | **缺 `surfaceOp` 这条不渲染**（DSH 的 fold 拿它判「进不进对话面」），而**没有任何报错** |
| `assistant/message` | `message.content` 是**一整段字符串** | `ContentBlock[]` | 字符串直接喂进去，DSH 那边取不到块 |
| `assistant/reasoning` | **独立事件**，正文在 `data.message.reasoning_content` | DSH 的 fold **不认**这个类型名 | 不折进 `assistant/message` 的 `reasoning` 块，思考内容整段消失 |
| `tool/result` | 扁平 `content` + `callId` | `data.message.content[0]` 是 `tool-result` 块、`message.source.callId` 有值 | 否则工具卡片不渲染 |
| `turn/end` | `reason` 是**字符串** | `reason.kind` 是**对象**（`aborted` 还要内层 `{kind:"user"}`） | 错误/截断提示不出现 |
| 其余（`turn/start`、`step/*`、`session/title`、`llm/retry`…） | — | 原样透传 | DSH 的 fold 对未知类型是 `default: return`（宽容），所以本仓私有事件不会把流弄坏 |

**三条实测教训（这一批最贵的部分）**：

| # | 教训 | 现场 |
|---|---|---|
| ① | **子串断言抓不住「JSON 结构坏掉」** | 第一版漏了 `,"data":{` 的收尾引号与花括号（译成 `…"time":1{"role":…`、`"data":{{…`）—— `selftest[wire-adapt]` 的 8 条子串断言**全部通过**，而 8/8 条译文都不是合法 JSON。**只有 DSH 自己的 zod schema 判得红** |
| ② | 所以这条判据**必须有外部 oracle** | 新增 `make wire-schema`（`testdata/wire_schema_check.py`）：跑二进制的 dump，交给 DSH 装的 `sessionEventSchema` 逐条校验。本机没装 DSH 时**跳过**（不是失败）。**防假绿对照**：把 ① 那个 bug 装回去 ⇒ 子串轮仍 `ok`，`wire-schema` 报 **8/8 不合 schema** |
| ③ | **按「我猜的形状」写夹具 = 把缺陷抄成正确** | 第一版夹具是我按印象写的（`assistant/reasoning` 的正文放在 `data.text`、`assistant.message.content` 当成块数组）。改用**真实日志行**逐字节做夹具之后，当场暴露出两处读错字段（正文其实在 `data.message.reasoning_content`、`content` 其实是字符串） |

**当前状态**：`dwire_*` 是**纯函数**（`Buf` 进 `Buf` 出，不认识 `Config`/`g_sess`），
`selftest[wire-adapt]` 8 段（`user` / `assistant` / `reasoning` / `tool` / `turn/end` /
边界 / 确定性 / 转义），`make wire-schema` 把译文交给 DSH 验。二进制 `--selftest`
**183 轮绿**、`--tui-demo` 逐字节相同。

**阶段 0 探针：通过（P80 第六批，`make wire-probe`）** —— 「不改 DSH 的 webui 能不能当
本仓的前端」这句**可证伪的话，答案是能**。四件事全部实测成立：

| # | 判据 | 结果 |
|---|---|---|
| ① | DSH 的 shell 起得来吗 | **起得来**：`data-slot="root"` 挂载，`conversation` / `sidebar.*` 等 23 个 slot 全部注册 |
| ② | 最小 roster（14 包 inject 闭包）全 active 吗 | **全 active**：14 个 `client.js` 全部按次序加载，**零** `did not activate`（DSH 是「全有或全无」，任一 pending/failed 就整页 fail） |
| ③ | 本仓会话进得了侧栏吗 | **进得了**：`session.list` + `workspace.list` 之后工作区标题与分组都画出来了 |
| ④ | 消息渲染得出吗 | **渲染得出**：正文里读到 `探针会话（本仓适配层）` 与 `PROBE-ASSISTANT-OK`，还带 `1 turns · 1 steps` 统计行 |

**探针做了什么**（`testdata/wire_probe_host.py` + `wire_probe_drive.mjs`，`make wire-probe`
一条命令）：只读服务 DSH 自己那份 `dist`（**一个字节都不改**）、复刻它的 `bootInjections()`
（内联 queue 脚本 + 两个 parser-blocking preload + `window.__DSH_BOOT__`）、按最小 roster
服务 `/plugins/<id>/client.js`、把 `/api/*` 接到一份离线会话数据上（两条下行是真 WebSocket，
**只发不收**）。然后用 headless chromium + CDP 驱动，断言只可能来自我们事件流的两条文本。

**这一批实测到的四件事**（三条是坑）：

| # | 事实 | 为什么值得记 |
|---|---|---|
| ① | **`surfaceOp` 就是那道门，实测可证伪** | 防假绿对照：把合成事件里的 `surfaceOp` 去掉 ⇒ 探针**退出码 1**，日志是「shell 挂载 PASS、标题可见 true、**正文可见 false**」。即：host 完全正常、DSH 也认这条事件，**只是不渲染** —— 与第一轮从 bundle 里读出来的结论逐字吻合 |
| ② | **shell 要的是 `session.create`，不是「列出来让我挑」** | 第一版只实现了 `session.list`，页面上只有 hero 空态、**看起来像我们的数据没送到**；真正的证据在**浏览器控制台**：`initial workspace selection failed: SessionCreateError: … probe: session.create not implemented`。只跑 `--dump-dom` 永远查不到这条 —— **要读 console 与异常**（`Page.navigate` + `Runtime.consoleAPICalled`） |
| ③ | **`workspace.list` 返回空 ⇒ 会话在 `session.list` 里有、侧栏却一行不显示** | 侧栏是**按工作区分组**画的（`ui-workspace` 的 `Ungrouped` 回退）。形状还要按真 schema 来：是 `items[]`（不是 `workspaces[]`），且每个 `WorkspaceView` 带 `workspaceId/path/title/sessionIds/createdAt/updatedAt`（两个时间都是 **ISO-8601 字符串**） |
| ④ | **本机 chromium 的 DevTools 端只绑 IPv6 回环** | 用 `127.0.0.1` 连 CDP 是 `ECONNREFUSED`，`localhost` 就通 —— 症状是「detached 起能连、`subprocess.Popen` 起连不上」这种**假象**（其实与启动方式无关，只与地址族有关） |

**判据教训（延续第五批那条）**：②③两条都是「**页面上只是空**、代码零报错」的形态，
子串断言与 `--dump-dom` 都抓不住；能抓住它们的是**浏览器控制台的告警**与**真 schema
校验**。所以这一批的三条判据各有各的 oracle，缺一条都会留下一个静默的洞。

**同批又证成了「真日志」那一腿（`make wire-probe-real`）**：探针默认喂合成事件，而这条
把它换成**一份真的本仓 `session.jsonl`** —— 由**产品里那份适配层**（`web/wsess.uya`，
经新出口 `UYA_SELFTEST_WIRE_FILE`）逐行翻译，再走同一个宿主与同一套断言。实测：

| 判据 | 结果 |
|---|---|
| 真日志能从头翻到尾 | **16 条事件**（一份 `p30_suite_intr` 的会话），含本仓那些 DSH **不认识**的私有事件（`assistant/first-token` / `step/*` / `turn/start`）—— 它们原样透传，没有把流弄断 |
| 每条译文都合 DSH 的 schema | **16/16 通过**（同一份 zod oracle） |
| 真日志在真浏览器里渲染得出 | **渲染得出**：`第一个长任务`（用户）/ `Think` + `第 1/1 段思考…`（思考块）/ `SELFTEST_OK`（助手）/ `2 turns · 2 steps | LLM 4.1s`（统计行） |

> 为什么这条值得单列：前一条（合成数据）**证明的是「形状对」**，这一条证明的是
> **「一整份真会话的形状都对」** —— 包括那些我们没为它写过翻译分支的事件。
> 两者的夹具来源不同（手写 vs 产品输出），所以能各自抓到对方抓不到的缺陷
> （第五批的教训③就是这个道理）。

**第八批：宿主进了产品（`src/web/whost.uya`，`--dsh-web`）** —— 上面那两条是 python
探针证的；这一批把同一套东西**搬进产品二进制**，于是「不改 DSH 的 webui」不再只是
一个可行性结论，而是**本仓的一个运行形态**：

```
./build/uya-agent --dsh-web 127.0.0.1:8790
[dsh-web] DSH 前端（只读它的 dist，不改一个字节）：http://127.0.0.1:8790/ （ctrl+c 退出）
```

一条命令自证：`make dsh-web-check`（起产品二进制 + headless chromium + CDP 断言；
没装 DSH / 没 chromium 时**跳过**）。实测**连续 6/6 通过**。

产品宿主做了四件事（与探针一一对应，但都不是 python 了）：
只读服务 DSH 那份 `dist`；复刻 `bootInjections()`（内联 queue 脚本 + 两个
parser-blocking preload + `window.__DSH_BOOT__`）；按最小 roster 服务
`/plugins/<id>/client.js`；`/api` 接 `web/wsess.uya` 的译文（两条下行是真 WebSocket）。

**搬进产品才暴露出来的六个坑**（探针那份是 python，单线程模型不同，所以这些
**只有真产品跑起来才会遇到**；每个都记在这里，因为它们的症状都**离原因很远**）：

| # | 坑 | 症状 | 根因 |
|---|---|---|---|
| 1 | **C 串语义**：`sys_open` 要 NUL 结尾，而 `buf_append_cstr` 只按长度追加 | 「路径明明对，却打不开」；roster 里**前 3 个包 ok、其余 11 个 FAIL**（新分配的缓冲恰好是零页就成功） | 忘了补 NUL。三处（bundle 路径 / index 路径 / 事件源路径） |
| 2 | **`dist` + `rel` 之间少一个 `/`** | 拼出 `distfavicon.svg`，而症状是「文件明明在、`/assets/*` 全 404」 | 拼路径时只去掉了开头的 `/`，没补分隔符 |
| 3 | **不要「按文本回搜结构」** | 在 entries 的 JSON 文本里搜 `{"id":"<pkg>","url":"…` 恒回 -1（同样的文本、同样的子串，纯函数轮却过） | 改成**装 entries 时顺手攒** preload 片段，彻底绕开搜索 —— 那本来也是脆的（JSON 一改格式就断） |
| 4 | **`if` 表达式赋 `const` 会生成坏 C** | 编译期过、`cc` 报 `assignment of read-only variable __uya_ifexpr_N` | 本仓已知形态（第五批踩过）；改 `var` + `if` |
| 5 | **非阻塞 fd 上 `read < 0` 不是断开** | `[web-runtime] connection lost` 反复重连、shell 卡在最早两步 | `srv_accept_nb` 设了 `O_NONBLOCK`：`-1` 常常只是 EAGAIN。要回「再等等」而不是掐连接 |
| 6 | **单线程里同步写 450KB 会饿死下行** | 同上（也是「连接丢失」），且**间歇**发生 —— 最难查的一类假红 | 一个 bundle 450KB、14 个约 3MB。分块写 + 每圈只处理一个就绪者，poll 间隔就回到毫秒级 |

还有两条是**判据**层面的（`dwh_rpc_err` 用 `bufx_cstr_len` 读一个没 NUL 的缓冲 ⇒
错误消息里混进了 HTTP 响应头；`host.describe` 给 `/` ⇒ shell 只发 2 个 API 就停）。

**为什么值得记**：六个坑里 **5 个的症状都是「页面空着 / 连接丢失」**，而原因分别在
字符串长度、路径拼接、文本搜索、codegen、fd 语义、调度上。它们**没有一个**能在
`make check`（类型检查）里被抓住 —— 能抓住它们的是「真起一个浏览器、读它的控制台」。

#### 11.9.7 适配 DSH 0.2.0 + 资源获取（设计，先于代码）

上面的第八批是照 **DSH 0.1.1-rc.2** 写的。把全局 DSH 升到 **0.2.0-rc.2** 之后，
`make dsh-web-check` **当场就坏**（一行报错，见下表）。本节定下适配方案与
「DSH 的资源从哪来」，**在动代码之前**把契约钉死。

##### 一、病根：0.2.0 改了五处契约（都是实测，不是读文档猜的）

| # | 契约 | 0.1.1（我照它写的） | 0.2.0（实测） | 症状 |
|---|---|---|---|---|
| ① | boot 图 | `{rev, entries}` | **`{rev, entries, batches}`** | `client-modules: boot manifest batches must be an array` |
| ② | parser preload | 两个：`dsh-client-modules` + `dsh-client-runtime` | **一个**：只有 `dsh-client-modules` | `dsh-client-runtime` **这个包已不存在** |
| ③ | 页面包数 | 43 个声明 `dsh.client` | **71 个**（roster 里 65 个） | 我只发 14 个 ⇒ DSH 原生面板全缺 |
| ④ | `/api` 方法名 | 点号（`session.list`…） | **点号 0 个**，全是**斜杠**（`session/list`，134 个） | 我的 `/api/session.list` 在 0.2.0 下**根本不会被调用** |
| ⑤ | 鉴权 | 无 | **token + cookie**：不带 token `401`，带 token `303` 并种 cookie | 我的宿主没有这套 |

**权威来源不是我的阅读，是「真 DSH 跑起来 + 浏览器里读页面状态」**：
起 `dsh --profile web --port 7711`，用 CDP 读 `globalThis.__DSH_BOOT__`、
记它发出的 `/api` 调用、抓它注入的 `<head>`。下表全部来自那一次观测。

##### 二、实测到的 0.2.0 契约（适配的判据）

**boot 图**（65 entries / 3 batches）：

```json
{"rev":"a04c4ccd2abe",
 "entries":[{"id":"@deepseek-ai/dsh-client-ui-open-in-app",
             "url":"plugins/??@deepseek-ai/dsh-client-ui-open-in-app/client.js&rev=d692006e2822",
             "rev":"d692006e2822",
             "inject":["@deepseek-ai/dsh-api-gateway", …]}, …],
 "batches":[{"phase":"bootstrap",   "rev":"bb9cf61bc9b8","entries":[1 个]},
            {"phase":"application", "rev":"0b42dc805a0c","entries":[58 个]},
            {"phase":"application", "rev":"5ffeed26951f","entries":[6 个]}]}
```

`entries[]` 每行可有 `inject` / `external` / `immediately`；`batches[]` 的
`phase` 只有 `bootstrap` / `application` 两种。**校验规则**（读 `parseBootManifest`）：

- `rev` 字符串；`entries`、`batches` 都必须是数组
- entry：`id`/`url`/`rev` 三个字符串，`id` 不得重复
- batch：`phase` ∈ {bootstrap, application}、`url`/`rev` 字符串、
  `entries` **非空**字符串数组、每个 id **只能属于一个 batch**
- 每个 entry **必须**属于某个 batch（否则报 "belongs to no initial-load batch"）

**批为什么要切**：combo URL 有 **3072 字节**上限（`MAX_COMBO_URL_BYTES`），
超了就分片 —— 所以 58 + 6 那两个 application 批是**因为 URL 太长而切开**的。
单包 URL 只有几十字节，**不会触发分片**。

**注入行**（真 DSH 的 `<head>`，34083 字节）：

| 顺序 | 行 | 说明 |
|---|---|---|
| 1 | `globalThis["__DSH_CONTACT_CONFIG__"] = …` | 可选配置全局 |
| 2 | 内联 queue 脚本 | `window.__ModuleLoader__` 的 queue 模式 |
| 3 | `<link rel="preload" as="script" href="plugins/??…">` ×2 | application 批 |
| 4 | `<script src="plugins/??@deepseek-ai/dsh-client-modules/client.js&rev=…">` | **唯一的** parser-blocking bootstrap |
| 5 | `globalThis["__DSH_BOOT__"] = {…}` | 图本身 |
| 6 | 4 个可选配置全局 | `__DSH_SHORTCUTS_CONFIG__` 等 |

那 4 个配置全局**都有兜底**（如 `?? {}`、`resolveConnectionConfig(undefined)`），
所以缺了不致命 —— 但**发出去更省事**（页面少走降级路径）。

**`/api` 面**：0.2.0 启动只打 **11 个**斜杠调用：
`agentPresets/list`、`commands/list`、`credentials/describe`、
`dynamicCordisRunner/inventory`、`dynamicCordisRunner/syncInspectManifest`、
`permissionPresets/catalog`、`session/create`、`session/list`、
`session/modelCatalog`、`settings/describe`、`skills/list`。

##### 三、设计：三件事，各自独立

**① boot 图：产 `batches`，但**不实现 combo 服务**。

校验器只要求 `url` 是**字符串**，不校验它长什么样。所以每个包发一个 batch、
`url` 用我现有的单包形态 `/plugins/<id>/client.js?rev=<sha1前12>` 即可 ——
**绕开 combo 解析**（那是 3072 字节分片 + `??` 逗号表 + 合并 sourcemap，
本仓不需要为它写代码）。这条是本次设计里最省的一刀。

**② roster：删掉硬编码，改成扫描。**

`DWH_ROSTER`（14 个写死的包名）删除，改成扫 DSH 树里所有
`package.json` 含 `dsh.client` 的包（0.2.0 实测 71 个，roster 里 65 个）。
`DWH_PRELOAD`（写死的两个）也删除 —— bootstrap 批只放 `dsh-client-modules`。

**③ 资源获取：从 npm 取，不从 GitHub 取。**（详见下一节）

##### 四、资源获取：为什么必须走 npm 而不是源码仓库（实测）

要求是「从源码仓库取最新的构建物」。**这条走不通**，三条实测证据：

| 证据 | 结果 |
|---|---|
| `GET /repos/deepseek-ai/deepseek-harness/contents/packages/client/ui-conversation` | 只有 `src/`、`tests/`、`package.json` —— **没有 `lib/client.js`** |
| `GET …/contents/apps/web` | 有 `web/` 目录，**没有 `dist/`** |
| `GET …/releases`（5 个 release） | **assets = 0**（一个构建物附件都没有） |

即：**源码仓库里只有源码**，`dist` 与 `lib/client.js` 都是构建产物，
不进版本库。而 `npm` 上发布的包**自带**它们（实测 `npm pack`）：

| 包 | tgz | 内容 |
|---|---|---|
| `@deepseek-ai/dsh-web-frontend@0.2.0-rc.2` | 1.70 MiB | `package/dist/`（**130 个文件**，含 index.html / assets / fonts / langs） |
| `@deepseek-ai/dsh-client-ui-conversation@0.2.0-rc.2` | 0.25 MiB | `package/lib/client.js` + `lib/index.js` |

取件很快（3 个包 3.1 秒），0.2.0 全量资源约 **16.9 MiB**
（71 个 bundle 11.4 MiB + dist 5.8 MiB）。

**设计**：`--dsh-assets-repo` 默认指向 npm registry（**能真取到构建物**的那一个）；
显式给 GitHub 地址时**报错说明**「该仓库不含构建物」，而不是静默失败或下回源码让用户
自己 build（本仓是纯 Uya、无 Node 工具链，build 不出 dist）。

##### 五、资源定位链（运行期只读）

```
① --dsh-assets DIR      （新：仓库/本地缓存里那份）
② --dsh-root   DIR      （已有：本机装的 DSH 树）
③ 常见位置             （已有：~/.npm-global/… / ~/.local/…）
```

给不存在的目录要**明确报错**，不静默跳到下一级（否则「以为在用缓存、其实在用全局」
这种假象会浪费排查时间）。

##### 六、工作项（顺序即依赖）

| # | 内容 | 判据 | 状态 |
|---|---|---|---|
| 1 | boot 图加 `batches`（每包一批 + bootstrap 只放 `dsh-client-modules`） | 0.2.0 的 `parseBootManifest` 逐条自查通过 | **已做**（第九批） |
| 2 | 删 `DWH_ROSTER` / `DWH_PRELOAD`，改扫描 + 读 `dsh.client.inject` | 页面上出现 25 个 `data-slot` | **已做**（第九批） |
| 3 | `/api` 方法名改斜杠（`session/list` 等） | 真 DSH 的 11 个调用不再回 `bad-request` | **已做**（第九批） |
| 4 | `/api/remote.mux`（0.2.0 唯一的下行） | 三条流的 `open` 都收到 `item` | **已做**（第十批） |
| 5 | 消息渲染（`data.stream` + end-seed 位置 + cursor） | `make dsh-web-check` 通过 | **已做**（第十八批，3/3 稳定） |
| 6 | `dynamicCordisRunner/{inventory,syncInspectManifest}`、`session/modelCatalog` | 控制台零告警 | **已做**（第十二批） |
| 7 | 资源定位链 + `--dsh-assets` | DSH 树零写入 | **已做**（第十九批） |
| 8 | `--dsh-assets-install` 取件（`src/web/dshget.uya`） | 装出来的那份能渲染 | **已做**（第二十批） |
| 9 | 访问令牌（`src/web/dshauth.uya`） | 不带令牌 401 / 带令牌 303+cookie / 带 cookie 200 | **已做**（第二十一批） |
| 10 | 用户报的「页面坏了」两条（快照逗号 + 四个设置页签） | 第二腿（零事件源）+ `selftest[web-panel]` | **已做**（第二十二批） |
| 11 | **活会话**：零参数起一条真会话（子进程 + 输入帧 + 日志 tail） | 打字 ⇒ 答复渲染进页面（`dsh-web-check` 第三腿） | **已做**（第二十三批） |
| 12 | **模型选择**：目录现读 + `selectModel` 落两处 | 切模型 ⇒ 请求打到另一家（第四腿） | **已做**（第二十三批） |

##### 七、第十批实测：`/api/remote.mux` 的精确契约

0.2.0 把下行从「两条只发的 WS」换成「**一条双向的流多路复用**」。实测真 DSH
全量启动只开 **一个** WebSocket，8 帧里三条流：

```
C→S {"type":"open","streamId":"<uuid>","endpoint":"workspace/follow","payload":{"args":{}}}
S→C {"type":"item","streamId":"<uuid>","value":{"type":"baseline","value":{"items":[…]}}}
C→S {"type":"open","streamId":"<uuid>","endpoint":"$events","payload":{"args":{}}}
S→C {"type":"item","streamId":"<uuid>","value":{"type":"ready","clientId":"<uuid>","host":{"home":"/home/winger"}}}
```

`$events` 的 `ready` 是**连接就绪的判据**：不回它，客户端报
`generation is still not ready after 3000ms` → `connection was not ready within
15000ms` → `connection lost, retry #N`，每 3 秒一轮。

**四个只在真浏览器里才暴露的坑**（裸 socket 测试全绿，所以它们都是「假绿」的
反例；每条都记在 `whost.uya` 的注释里）：

| # | 坑 | 症状 | 根因 |
|---|---|---|---|
| 1 | 掩码键偏移**跟着长度形态走** | 300 字节的 `open` 解成乱码、那条流无响应 | 7 位长度时掩码在 2、16 位时在 4；写死 `frame[2+(k&3)]` |
| 2 | **`exactKeys`**：帧的字段数必须精确 | 每条帧被拒、整条连接判死并重连 | 客户端用 `exactKeys(value, […])` 校验；多一个 `sessionId` 就非法。**它的表现是「连接坏了」而不是「这条流没数据」** |
| 3 | 一次 read 里**可能有多条帧** | `$events` 永远收不到 `ready`（客户端把三条 `open` 连着写） | 早先只解第一条、其余整段丢掉 |
| 4 | `dwh_remote_frame` **漏写 `return consumed`** | 与 ③ 一模一样 | 隐式返回 0 ⇒ 上面那个循环第一圈就 `break` |

> ③④ 同症状不同因，这正是「症状离原因很远」的形态：两者都表现为「只解第一条」。
> 如果只修 ③ 就收工，④ 会让它看起来**没修好**。

##### 八、第十三~十四批：会话流接通了，消息渲染还差一步

第十一批修掉「帧少一个 `}`」之后，连接不再重连。第十三、十四批继续推进，
把页面从「白屏 + 选工作区」推到「**完整的聊天界面挂载、会话被选中**」，
控制台**零错误零告警**、37 个 slot（`conversation.*` 全套）、entries 65
（与真 DSH 逐数相同）。**但消息正文仍没折进对话区**（`make dsh-web-check`
那条仍红）。这一节把**做成了什么**与**排除过什么**都钉住。

**做成的（都是实测）**：

| # | 缺陷 | 症状 | 根因 |
|---|---|---|---|
| 1 | `workspace/follow` 与 `workspace.list` 不一致 | 页面停在 `Choose workspace`、**从不开 `session/follow`** | follow 的 baseline 回 `items: []` 而 unary 回一个工作区 ⇒ 客户端「从流里」看到零个工作区。**单看任一条都对，只有不一致才出问题** ⇒ 现在共用 `dwh_workspace_item` |
| 2 | `dwh_remote_item` 的 `extra` 当 C 串量长度 | 帧里混进**上次用过的缓冲残留**（`…"]ace","@deepseek-ai/…`）⇒ JSON 坏 ⇒ `close(4002)` | `extra` 常是另一个 `Buf`（无 NUL），`bufx_cstr_len` 读进相邻内存。改成显式长度 |
| 3 | `dwh_remote_item` 缓冲写死 2048 | 几千字节的 snapshot 被**截断**（浏览器收到 462 字节，裸 socket 3141）⇒ 4002 | 改成按 `extra` 长度算 |
| 4 | snapshot 缺 `assistantStream` | 客户端拿到 snapshot 第一句就 `throw`（"omitted its opted-in opening baseline"）⇒ 整条流不折 | 补 `{revision:0}`（形状取自真 DSH） |
| 5 | `session/list` 的 `projections` 缺 `kind` | `unreachable variant in session list projection block kind: undefined` | 客户端是判别联合，补 `"kind":"sequenced"` |
| 6 | roster 按「有 bundle」而不是 profile 名单 | `voice-input` 拿不到 speech catalog ⇒ `conversation.input.activity` slot **整块崩掉** | 差集 5 个包（2 个 experimental + schedule + 2 个 directory-picker）；后者由 host 侧运行期按平台启用 |

**`blank` 必须是 true**：客户端只在 `blank && cwd === workspace.path &&
workspace.sessionIds.includes(id)` 三者全成立时才**复用**会话，否则转
`sessions.create`（本仓没有可建的会话）。

**排除过的（负面结果，免得重走）**：

| 假设 | 怎么排除的 |
|---|---|
| `isSeeded` 该给 true | 试过 true/false 两种，结果一样（客户端不报错、`conversation.session` 仍空） |
| 缺 `session/end-seed` seed 事件 | 补了真 DSH 的四条 seed（permission/preset / sandbox/mode / approval/policy / session/end-seed），**仍空** |
| sessionId 格式要 UUID | 换成真 DSH 的 UUID 形态，**仍空**（已回退） |
| 帧字段被 `assertSessionWireEvent` 拒 | 逐条核对：我的 event 键（type/seq/time/data/surfaceOp）全在白名单、`data` 里有 `turn`/`step`、`SURFACE_EVENT_TYPES` 五个类型全对 |
| 客户端报错被吞 | 控制台**零输出**（连 warning 都没有）—— 说明是「状态没被填充」而不是「渲染失败」 |

**下一步的入口（本轮缩小到的位置）**：客户端**选中会话**的链路。
`session/create` 从未被调用 ⇒ workspace 的 `restoreSelection` 没走到
`connectWorkspace`。而它要求 `watchNavigation` 的 reconcile 里
`workspace.phase === "ready" && sessions.phase === "ready"`。已实测两条流
（`workspace/follow` 带工作区、`session/follow` 开得起来）都在，
所以嫌疑落在 **`mainReference` 是否已被别处设过**（若已设，reconcile 直接
`initial = "done"` 返回）或 `clearArchivedCurrent()` 的早退。下一轮直接从
读 `selection` store 的初值与 `mainReference` 的赋值点入手。

##### 八之三、第十八批：**消息渲染通过** —— `make dsh-web-check` 绿了（3/3 稳定）

    PASS shell 挂载
    会话标题可见：true
    消息正文可见：true
    PASS 消息渲染
    dsh-web-check: 通过 —— 产品二进制 --dsh-web 把本仓会话渲染进了 DSH 的 webui

**根因**：`assistant/message` 的 `data` 里缺 **`stream`**（chunk 级回放：
`block-start` / `block-end` / `finish`）。客户端的 fold 靠它建消息节点 ——
`message.content` 虽然在场也折不出节点，而**控制台一句抱怨都没有**。

**方法论（这一段比结论更值得复用）**：

| 步 | 做法 | 得到什么 |
|---|---|---|
| ① | `dsh --profile headless "回答两个字：收到"` 造一个**真有消息**的会话 | 一份可对照的**权威样本** |
| ② | 用它的 `dsh-auth` cookie 直连 `/api/remote.mux`，发 `session/follow`，解 WS 帧 | 22 records 的 snapshot（31KB） |
| ③ | **把样本的 22 条事件当夹具喂给我的宿主** | **渲染出来了** ⇒ 宿主代码没问题，差别在数据 |
| ④ | 二分数据：`content` 同形、`surfaceOp` 同形、seq/cursor 都对 | 唯一差别 = `data.stream` |
| ⑤ | 手工在夹具里补 `stream` 验证 | 假设成立，再回产品代码实现 |

> 前十七批我一直在**读客户端源码猜形状**，走了很多弯路（`isSeeded`、seed 事件、
> sessionId 格式、字段白名单 —— 全是负面结果）。**一旦有了权威样本，二分只花了
> 几步。** 教训：缺参照物时先造参照物，别继续猜。

**这一批顺带修掉的真缺陷**：

| # | 缺陷 | 症状 |
|---|---|---|
| 1 | `session/end-seed` **位置错**（我放在开头 seed 里，真 DSH 在**最后一条**） | 我的夹具不渲染、真夹具渲染得出来 —— 两者数据几乎一样，只有它位置不同 |
| 2 | `cursor` 与末条 seq **差一** | `did not end at its requested cursor` |
| 3 | `dwh_seq_of` 按连写 `"seq":` 找，真日志是 `"seq": 8`（**冒号后有空格**） | seq 读成 0 ⇒ cursor 恒 0 |

**实现**：`dwh_is_assistant_msg` / `dwh_assistant_with_stream` / `dwh_stream_of` /
`dwh_one_block` —— 由译文自己的 `"content":[…]` **原文**按顶层逗号切块，
逐块造 `block-start` + `block-end`，末尾补 `finish`。不做 JSON 重序列化
（`std.json` 的视图指向原缓冲、转义未解码，重序列化只是多一个出错点）。

##### 八之二、第十五~十六批：会话真正选中（`blank` / `cursor` / `seq` 三处）

这三处是「会话选中 + 历史加载」的最后一组卡点，**判据相互矛盾**是它们最坑的地方：

| # | 字段 | 客户端要的值 | 坑在哪 |
|---|---|---|---|
| 1 | `session/list` 的 `blank` | **`false`** | 客户端**两处判据相反**：`reuseOrCreateBlank`（自动复用空会话）要 `blank === true`，而 `restoreSelection`（把会话设成主视图）是 `if (!summary.blank) replaceMain(...)` —— 只有 `false` 才**直接选中**。给 `true` 时它转去 `sessions.create`（本仓没有可建的会话）⇒ 永久停在 hero。**两处都读同一份 `session/list`，所以只能满足后者**（前者只是「复用」的优化） |
| 2 | snapshot 的 `cursor` | 末条记录的 `seq`（**不加一**） | `assertPageThrough` 拿 `tailCursor(page) === through` 判，加一恒不等 ⇒ `page did not end at its requested cursor`（显示在对话区**正文位置**，看着像消息加载失败） |
| 3 | 译文记录的 `seq` | 从 seed 之后**接着排** | seed 占了 0..3、译文也从 0 起头 ⇒ 连续性检查判 `page contains discontinuous entries`。新增 `dwh_shift_seq` 把 `"seq":N` 改写成 `N+4` |

另外补了 `session/list` 的 **`agentAvailable`**（真 DSH 每条 item 都有，实测 380 条
逐字段核过：`sessionId/updatedAt/agentAvailable/running/blank/cwd/projections`）。

**实测进展**（真 chromium + CDP，真会话日志 16 条事件）：
- 侧栏出现「本仓工作区 / 本仓会话」两级；**会话被选中**（header = 本仓会话）
- 对话区**不再报错**（此前是红字 `Failed to load history: …`）
- composer 活着；snapshot 的 seq **0..19 连续**、`cursor === 末条 seq`（逐条核过）

**仍未完成**：消息正文没进 `conversation.session`（该 slot 的 innerHTML 仍为空）。
**一条重要的空白**：我至今**没有一份「真 DSH 带消息的 snapshot」**作对照 ——
实测抓到的真 DSH 会话都是空的（records 只有 4 条 seed）。所以「有消息时客户端
到底怎么折」这件事，我手上没有权威样本，只有自己的形状推导。下一轮第一件事
应当是**造一个带消息的真 DSH 会话来抓样本**（`dsh --profile headless "…"` 跑一轮），
再拿它逐字段对照 —— 那比我再猜一轮划算得多。

##### 八之四、第二十批：取件（工作项⑧）—— 解压交给系统工具

    uya-agent --dsh-assets-install --dsh-assets-dir DIR --dsh-web …
    [dsh-assets] 取件中（npm install DIR）…
    [dsh-assets] 装好了：DIR

于是**本机没装 DSH 也能用** `--dsh-web`。

**核心取舍：解压一律交给系统工具。** 一条
`npm install --prefix DIR --no-audit --no-fund --no-save @deepseek-ai/dsh`
把「取件 + 解 tgz + 摊平布局」全做完 ⇒ 本仓**不需要 tar/gzip/xz 的任何代码**。
不这么做的话要自己写 inflate（几百行、纯负债），而格式解压没有一种该由本仓实现；
取件本身（网络、缓存、校验、镜像）也早被 npm 做透了。**本仓只做编排。**

放在 `src/web/dshget.uya`（不碰 `whost` 的服务逻辑）：扫 PATH 找可执行文件、
fork/exec/收集输出（与 `gitx_run` 同形，但可执行文件由调用方给）。

| # | 纪律 | 为什么 |
|---|---|---|
| ① | **只写 `--dsh-assets-dir` 底下** | 已装的那份 DSH 一个字节都不碰（「只读 DSH」的纪律在安装这条路上同样适用） |
| ② | **不静默降级** | 任何一步失败就整条失败，不留半份资源让 `--dsh-assets` 指向它 |
| ③ | **文案指向那一步** | 失败分档（缺工具 / npm 取件 / 产出布局），并把**那一步的 stderr 原样带出来** —— 取件失败的主因是网络与权限，线索只在 stderr 里 |

实测三条路径：
- **成功**：289 个包 / 71 个带 bundle / dist 齐 ⇒ 布局校验通过；再用
  `--dsh-assets DIR` 起宿主 + 真浏览器 ⇒ **消息渲染出来**
- **坏源**：`registry=http://127.0.0.1:1/` ⇒
  `error: 取件失败（npm 取件：网络 / 权限 / 包名）→ DIR` + 原样 `E502 …`
  + 「换源用 `--dsh-assets-repo`，换落点用 `--dsh-assets-dir`」
- **缺工具**：PATH 里没有 npm ⇒ 「装一个 Node.js 再来」

##### 八之五、第二十一批：访问令牌（工作项⑨）—— 九个工作项全做完

新增 `src/web/dshauth.uya`，闸门接在 `dwh_do_http` 的**一切服务之前**
（未通过时连 index 与静态资源都不给，与真 DSH 同口径）。

**默认不启用**：绑回环不校验（本机看页面是最常见的用法，要令牌只会碍事）；
显式 `--dsh-token T` 才校验。**绑非回环而没给令牌时自动生成并打出来** ——
把服务暴露到局域网却毫无门槛是明确的安全缺陷，而「打出来」让正常用法
（把 URL 发给同事）仍然一步到位。

行为逐条对齐真 DSH（实测）：

| 请求 | 响应 |
|---|---|
| 无令牌 / 错令牌 | **401** |
| 对令牌（URL） | **303** + `Location: ./` + `Cache-Control: no-store` + `Set-Cookie: dsh-auth-<tok>=1; Path=/; Max-Age=2592000; HttpOnly; SameSite=Strict` |
| 对令牌（Cookie）/ 多 cookie 里含对的 | **200** |

两条取舍：**比较是定长常数时间**（逐字节 XOR 累加 —— 令牌不该因为「第几位不匹配」
泄露前缀；本地服务里不算高危，但这条比提前返回还便宜）；**令牌只从两处来**
（URL 查询串 / Cookie），不从 `Referer`、不从自定义头。

**三个坑**：

| # | 坑 | 症状 |
|---|---|---|
| 1 | `srv_url_split` 的 `q_off` 是**相对 url 起点**的偏移，我当绝对下标用 | 读的是路径那段字节 ⇒「带对令牌也被判 401」 |
| 2 | Cookie 是 `name=value`，我要求「整段等于 `dsh-auth-<tok>`」 | 恒不匹配；改成「以它开头且紧跟 `=`」—— 那个 `=` 不能省（否则 `…<tok>EXTRA` 也放行） |
| 3 | `SRV_ST_401`/`SRV_ST_303` 原本不存在；`dwh_auth_gate` 要改 `conns[ci].st` | 编译错两处；补状态常量 + 形参改可变引用 |

实测（真浏览器）：带令牌进页面 → 303 → cookie → **会话消息完整渲染**。

##### 八之六、第二十二批：用户报的两条「页面坏了」—— 逗号与四个页签

用户实测报了两条：**「一直加载会话历史失败」**与**「设置界面、模型加载供应商也失败」**。
两条都不是崩溃、也不是我自己那条 `make dsh-web-check` 能看见的（它对这两条**全绿**），
所以先复现、再定根因。两条的根因**毫无关系**，各自记在下面。

**① 「加载会话历史失败」= 快照 `records[]` 的逗号，而它是两面的缺陷**

用户跑的是**零参数** `./build/uya-agent --dsh-web`（没有 `UYA_AGENT_DSH_WEB_EVENTS`
事件源）—— 而 `dsh-web-check` 那条判据**总是**先喂一份译文，所以它从来没走过这条路。

现场（真 chromium + CDP 抓的 DOM/控制台）：

```
T+4s  本仓会话 | Loading history… | Message or run a task, …
T+8s  本仓会话 | Failed to load history: api gateway: invalid Remote
      stream frame (gateway/internal) | …
控制台  warning: [connection] connection lost, retry #1…#9（每 3 秒一轮）
```

`invalid Remote stream frame` 是客户端 `stream-client.js` 的 `receive()`：帧过不了
`parseRemoteStreamServerMessage` 就 `close(4002)` 并整条重连（**不是**「这条流没数据」）。
根因在快照的 `records[]` —— `dwh_seed_records` 把**收尾逗号焊死在字面量尾部**：

| 情形 | 从前发出的字节 | 结果 |
|---|---|---|
| 零事件源（用户现场） | `…"never"}}}` + `,` + `,{"type":…end-seed` ⇒ `},,{` | 非法 JSON |
| 有译文（`dsh-web-check` 那条） | seed 的收尾逗号**正好**是它该要的那个 | 合法 ⇒ 假绿 |

`},,{` 的每个**片段**都在，所以子串断言全中 —— 与 §11.9.7 第五批「子串抓不住结构坏掉」
是同一个教训。修法是**一个真值源**：seed / 译文 / end-seed 三段共用一个 `first`
（`dwh_record_sep`），谁都不许自带逗号。改完当场还暴露了**反方向**的半成品
（seed 写了逗号却没翻 `first` ⇒ 后一段不写 ⇒ `}}{`）—— 两个方向的症状**一模一样**，
这正是「纪律必须落在一处」的理由。

同一帧还修掉一个**判据不一致**：零事件源时 `cursor` 算成 0 而 `end-seed` 写 3
（两处各算一次）。客户端的 `assertPageThrough` 拿 `tailCursor(page) === through` 判，
不等就报 `page did not end at its requested cursor`（显示在对话区**正文位置**，
看着像消息加载失败）。现在 `last` 只算一次，`cursor` 与 `end-seed` 都用它。

**② 「设置/模型供应商加载失败」= 四个页签各调了一族本仓没实现的方法**

设置对话框四个页签各自把整片渲染成一句「未实现」（实测逐页点过）：

| 页签 | 调的方法 | 用户看到的 |
|---|---|---|
| General | `permissionPresets/catalog` | `Permission` 一行 `internal: not implemented: …`，整块 `Unavailable` |
| Models | `llm/listProviders`、`llm/listConfigurableProviders` | `Loading the provider directory failed: not implemented: llm/listProviders` + `Retry` |
| Built-in plugins | `pluginInventory/list` | `Plugins are temporarily unavailable.` |
| Agent presets | `agentPresets/list` | `not implemented: agentPresets/list` |

新增 `dwh_unary_settings`（六个方法，形状**逐个从真 DSH 的 typert host 抄**
`z.object` 的键名与可选性，不按印象写）。这一簇是**只读元信息**，本仓没有可写的设置
文档 ⇒ 中性值语义正确（`settings.describe` 已经如实给 `writable:false`）。

顺带修掉一个**投影缺陷**（它是这次才暴露的：`permissionPresets/catalog` 一旦有值，
客户端就走到了从前没人走的那条路）：快照的 `projections.values.permissions` 给 `{}`
是错的 —— 它的**视图**是 `{currentValue}`，客户端拿 `currentValue` 去
`catalog.options` 里找，找不到就回落成「把 `undefined` 当名字」⇒
`displayPresetName` 里 `name.split` 抛 `TypeError` ⇒ slot
`conversation.input.permission` **整块崩掉**（实测：控制台两条 error）。
给 `{"currentValue":"danger-full-access"}` 之后那一行正常显示 `Full access`。

**判据（这一批的三条腿，各有各的 oracle）**：

| # | 判据 | oracle | 防假绿对照 |
|---|---|---|---|
| ① | `selftest[web-snapshot]`：两种事件源下快照都是**合法 JSON**，且 `cursor == 末条 seq` | 本仓的 JSON 解析器（`js_parse`）—— 子串对 `},,{` 是瞎的 | 把收尾逗号装回 seed ⇒ 四条断言全红 |
| ② | `selftest[web-panel]`：六个方法**都实现了** + 回值合法 + **形状类型对**（该数组的给数组） | 本仓解析器 + 首字符判类型 | 删掉 `llm.listProviders` 分支 ⇒ 当场红 |
| ③ | `make dsh-web-check` 的**第二腿**：用户那个**零参数**形态 —— 合成器活着 + 红字不在 + `connection lost` **0 次** | 真 chromium + CDP（读 DOM 与控制台） | 把收尾逗号装回 ⇒ 这条腿红（而**第一腿照样绿**，正是它当初漏掉用户现场的原因） |

> 教训与第五批同族，但换了个面：**判据覆盖的是「我想到的那条路」**。
> `dsh-web-check` 一直绿，是因为它永远先喂一份译文；用户跑的是没有译文的那条。
> 所以这一批给那条命令加了第二腿 —— **同一份代码的两条输入路径，各要一条判据**。

##### 八之七、第二十三批：`--dsh-web` 真正能聊天（活会话 + 模型选择）

用户报的两条：「模型选择器空的」与「打不了字」。两条都不是崩溃 —— 页面能开、
历史能画，只是**选择器里一个模型都没有**、**在输入框里打字没有任何反应**。
根因是 `--dsh-web` 当时是一条**只读**链路（事件源是启动前用 `--selftest` 翻好的
一份**静态译文**，页面里没有任何活着的 agent），加上 `session/modelCatalog` 回的
是写死的 `groups:[]`。

**设计（四条决定）**

| 决定 | 理由 |
|---|---|
| 活会话 = **一个子进程 + 他的会话日志当事件源** | 日志已经是本仓的**真值源**（`dwire_line` 的产物被 `make wire-schema` 验过）；父进程用 `UYA_AGENT_FORCE_SESSION_ID` 预生成 id，于是 `sess_session_path` 算得出那份日志，`sys_read` 追它即可 —— **不另开父子协议** |
| 输入走 **JSON 帧**（`UYA_AGENT_STDIN_FRAMES=1`） | 裸行口径下「一条消息」与「一行传输」是同一个东西，而浏览器 textarea 里的一条消息**可以有换行**（shift+enter）—— 帧口径把两者解耦 |
| 模型目录从 `settings.yaml` 现读（`mx_*`），选择落**两处**（子进程的 `/model` + 宿主投影） | 只落一处就是「界面变了、请求没变」或反过来 |
| 两种模式由 `UYA_AGENT_DSH_WEB_EVENTS` 明确分开 | 给了译文 = 只读演示（老行为一字不改）；没给 = 活会话（用户零参数的形态） |

**这一批挖出来的七个真缺陷**（每一个都实测定位，且都不是「报错」而是「静默」）：

| # | 缺陷 | 症状 |
|---|---|---|
| 1 | **`turn/end` 的 `reason` 拼成了非法联合成员** | DSH 的 `reason` 是判别联合（`completed` / `aborted`+**嵌套** `reason` / `error`+`error` 对象），旧实现把三个分支拼在**同一层** ⇒ 客户端 `assertSessionWireEvent` 拒帧 ⇒ `close(4002)` ⇒ **整个会话的历史都封住了**（页面「Failed to load history」+ 每 3 秒重连） |
| 2 | **快照在活会话模式下重复位移 seq** | 译文已被 tail 后移 `DWH_LIVE_SHIFT`（3 条 seed + 收口 1），快照又移了一次 `DWH_SEED_SEQS` ⇒ 快照末条比第一条活事件**大 3** ⇒ 客户端判 `discontinuous` 并永久重连（实测一次加载 84 次重连） |
| 3 | **子进程的 stdout/stderr 指到了会话日志** | 会话日志是宿主的事件源；把 fd 1/2 指过去时，任何普通文本都**追加进日志**并与相邻 JSONL 粘成一行（实测 `PROV-A-ANSWER{"type":"assistant/first-token",…}`）⇒ 译文不再是合法 JSON。现在两者都指 `child.log`，**日志只由 `sess_*` 那条 fd 写** |
| 4 | **子进程与父进程共享文件偏移** | `dup2` 复制的是**同一个 open file description**：父进程在读日志（tail）会推进共享偏移，子进程下一次写就**打在读游标处**（实测覆写成 `PROV-A-ANSWER/message","seq":0,…`）。子进程自己 `open(O_APPEND)` 才有独立偏移 |
| 5 | **一条连接只记一个 streamId** | 0.2.0 把三条流**多路复用**在同一条 WebSocket 上，而客户端对同一条流会**开好几次**（实测一次加载 3 条 `session/follow`）；只记「最后一条」时推出去的事件带着旧 id ⇒ 被丢弃。改成按 endpoint 记**清单**、逐条推 |
| 6 | **`dwh_sweep` 被 `return` 跳过** | 收摊只发生在圈末，而 `dwh_accept` / 活会话写端就绪那两条分支都直接 `return` ⇒ 完成态的连接永远不回收（32 个槽）⇒ 连接被占满后新连接直接关掉 ⇒ 客户端「连上就断、每 3 秒重连」（实测 382 次 `open`、87 次重连）。**外加**：连接关掉时没把它的 streamId 从推送清单里摘掉（`dwh_fd_of_stream` 找到**死**连接就跳过 ⇒ 真正活着的那条一个事件都收不到：实测浏览器 374 帧里 0 条 event） |
| 7 | **`turn/end` 之外还有一条 0.1.1 的基线段** | 升级成 `remote.mux` 之后仍在发 `{"type":"server-request",…}`（0.1.1 的订阅基线）⇒ 客户端对**每一条**收到的帧做 `exactKeys` 校验 ⇒ 拒帧、整条重连。0.2.0 的「基线」是**客户端 `open` 之后**我们按流回的那一条 |

**两处执行核的修复**（都在这一批里暴露）：

* `dsh_home_resolve` 的入参是 **C 串**，而 `cfg.dsh_home` 是**没有 NUL 的 `Buf`** ——
  直接传指针会读到相邻内存，拼出的路径多带一个字节（实测 `/tmp/lp2/dsh4`），
  于是「读不到 settings.yaml、模型选择器空的」。两个调用点都改成先补 NUL；
* `web_child_env_cfg` 把 `BASE_URL` / 密钥**无条件**钉进子进程环境 —— 而它们的
  来源可能是 DSH 设置（`src == 1`），钉进去等于给子进程装了一个「**env 显式来源**」，
  而切模型时显式来源**不许被覆盖**（P37 的 `agent_route_apply`）⇒ `/model 别家/名字`
  只换了名字、**端点留在老提供方**（实测假网关收到 `model=model-b` 打在 A 口）。
  现在只有 `src == 2/3`（人显式给过）才注入。

**判据（五条腿 + 三轮自测，各有各的 oracle）**：

| # | 判据 | oracle | 覆盖的缺陷 |
|---|---|---|---|
| ① | `selftest[web-models]`：目录是合法 JSON、四个顶层键齐、`default` **在 groups 里**、档位只列公布的、同名跨提供方**两条** | 本仓 JSON 解析器 | 「选择器空的」那族 |
| ② | `selftest[web-chat]`：输入帧转义**闭环**（引号/反斜杠/换行/中文）、多行不被拆开、快照位移 +3 / 活事件位移 +4 | 解析器 + 逐字节比对 | 静默的「一条消息被拆成几回合」与 seq 断流 |
| ③ | `selftest[web-err-env]`：业务错必须是**合法 JSON** 且能拆成 `ok:false` | 解析器 | 缺陷 ① 的同族（本条**当场抓住了 `dwh_rpc_owned_err` 少一个 `}`**：它让每个业务错都变成 `ok:true`+垃圾值） |
| ④ | `make dsh-web-check` 第三、四腿：**真键盘打字** ⇒ 答复渲染；切模型 ⇒ 请求真的打到另一家 | 真 chromium + CDP；**假网关收到的 model/端口**（不是页面显示的名字） | 「打不了字」「选择器点了没反应」 |
| ⑤ | `make dsh-web-check` 第五腿：会话日志**每一行**都是合法 JSON | 逐行 `json.loads` | 缺陷 ③④（诊断混进日志）——它**不会**让前四腿变红，所以必须单列 |

**工具面新增**（都在 `testdata/`，不进产品）：`mock_gateway_answer.py`（当场答一句的
假网关 —— `mock_gateway_route.py` 那个会先要一条慢 bash，对这两腿太间接）、
`dsh_web_live_home.py`（造两个提供方的模型目录夹具）、`dsh_web_log_check.py`（日志
逐行 JSON 判据）、`dsh_web_chat_drive.mjs` / `dsh_web_model_drive.mjs`（CDP 驱动，
**内含按客户端 `exactKeys` 规则逐帧自检**的那一段 —— 它是定位缺陷 ①⑦ 的入口）。

**这一批最贵的一条方法论**：`make dsh-web-check` 前四腿全绿时页面**仍然是坏的**，
因为「帧发出去了」与「客户端接受了」是两件事。真正定位到根因的那一步是
**把客户端判据抄成断言**（`exactKeys` 那一段）与**解客户端 close 帧里的
code/reason**（`dwh_log_close`，`invalid Remote stream frame`）—— 两者都在
「症状之外」的地方取证。

##### 九、历史记录：`connection lost` 的排查（第十一批已解）

第十批之后，`generation is still not ready` 那条告警**消失了**（说明 `$events`
的 `ready` 已被接受），但页面仍每 3 秒重连。**已排除的**（都是实测）：

| 排除项 | 怎么排的 |
|---|---|
| 我的帧不合法 | 客户端的 `parseRemoteStreamServerMessage` 用 `exactKeys` 校验；我的三条流都按它发（`ready` 只 `type/clientId/host`，`baseline` 只 `type/value`），且浏览器里**没有** `invalid Remote stream frame` / `4002` 关闭事件 |
| 我的宿主关连接 | 裸 socket 挂 25 秒：**无 EOF、无 close 帧**；两个并发连接（`workspace/follow` + `$events`）互不影响 |
| 多帧一段 / 漏 return | 修前修后都是「三帧一次写能收到三条响应」（裸 socket 验证） |
| 缺配置全局 | 真 DSH 有 6 个 `__DSH_*` 全局，我只发 `__DSH_BOOT__`；但读客户端源码：`__DSH_TRANSPORT__` 是 `?.`（有 `document.baseURI` 回落）、`__DSH_CONNECTION_RECOVERY__` 经 `resolveConnectionConfig()` 补默认值 ⇒ **都不必需** |

**剩下的线索**：`dsh-client-connection` 的 `ConnectionController` 只在它的
`source`（= gateway 的 `pumpEvents`）**结束或抛错**时才 `connection lost`。
而 `pumpEvents` 的 `for await` 只在 `openStream` 的迭代器结束/抛错时退出，
`StreamInbox.next()` 本身是**无限阻塞**的。所以嫌疑集中在
「`openStream` 返回的那个迭代器为什么结束」—— 下一轮从
`dsh-client-connection` 的 `source` 参数怎么接上 `pumpEvents` 入手
（这是本轮唯一没走完的一跳）。

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

**为什么不「把图片直接丢给模型」**：因为两条线协议里**没有这条通道** —— 它们收的都是
内联形状（completions 的 `{"type":"image_url","image_url":{"url":"data:…"}}`、responses 的
`{"type":"input_image","detail":"auto","image_url":"data:…"}`，见 `agent_emit_images_json`），
全仓**没有**上传端点，也没有 `file_id` 这条路。字节既然一定要进请求体，下面这几件事
就躲不掉 —— 而且每一件都对应一个**实测过的失败模式**：

| 动作 | 不做会怎样 |
|---|---|
| 嗅探类型（`imgx_sniff`，只读文件头） | 认不出的类型发出去只会得到网关 **400** |
| 读宽高（PNG IHDR / JPEG 段链 / GIF / WebP） | 像素预算判不了；且**不能靠解码**得宽高（理由见下） |
| 两道预算（8 MiB + 640000 像素） | 超了发不出去 —— 可缩的 JPEG 先走 §13.1.1，其余明确拒 |
| 内容寻址落盘、历史只存**路径 + 元数据** | 几十条消息各带几 MB ⇒ 内存与请求缓冲一起顶爆 |
| 构请求按 4/3 膨胀留缓冲（`request_bytes_needed`） | `jw_overflow` **静默**截断请求体（挂了图，发出去却没有） |
| 查模型目录的 `input` 有没有 `image`（`cfg.input_image`） | 在不吃图的模型上收下来，请求照样 400 |

**收图能力位的口径是「默认支持」（P84）**：出厂 `true`，只有**明确说不支持**才关 ——
① `--no-input-image`（cli）② `UYA_AGENT_INPUT_IMAGE=0`（env）③ 目录条目写了 `input:`
但**不含** `image`（如 `[text]`）⇒ 关。**信息不足一律当支持**：条目**没写** `input:`、
目录里没这个名字、`--no-dsh-config` —— 全部沿用现状。原因见下面那张表与 §16 踩坑 143。

**与 DSH 的差别在能力，不在流程**：这四个问题 DSH 也要回答，只是它手上有 zlib 与图片库，
任意格式都能重编码到预算内，看上去像「顺手就做了」；纯 Uya 只有 JPEG 编解码器
（`std.image`），PNG/GIF/WebP 超预算**只能拒**。web 端同理：**直传原始字节、让浏览器
自己解码**（§11.8.4）—— sixel / kitty 要求服务端重编码**已解码的像素**，而我们生成
不了缩略图。

**今天仍成立的硬约束（纯 Uya 的现实）**：stdlib **没有 zlib/deflate** ⇒ PNG 重压不了；
GIF/WebP 也没有编码器 ⇒ **只有 JPEG 能缩**（链路与拒绝话术见 §13.1.1）。超预算时：
JPEG 先缩，其余只能「**接受原图**」或「**明确拒绝**」—— 拒绝时说清超了多少。

> **「只做判定、不做变换」是分层，不是「做不到」**（P72 起）。尺寸解析**只读文件头**；
> 读不出来（畸形/截断）一律当「不认识的图片」**拒绝**，**绝不猜一个尺寸往下走**；
> 「超预算能不能变小」那是 `media/imgz.uya` 的事 —— 判定要能在图进来的一瞬间回答
> 「收不收」，不该顺手解码一张几十 MB 的图。

| 预算 | 值 | 来历 |
|---|---|---|
| `IMGX_DEF_MAX_BYTES` | `8*1024*1024` | 取 DSH 请求层的 **8 MiB**（更严的那个）—— 它是「发得出去」的硬门槛；可缩的 JPEG 会先走 `imgz_shrink` 缩进来 |
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

### 13.1.1 压缩（`media/imgz.uya`，P72）

**为什么单开一个文件**：`imgx` 是**判定层**（读文件头、纯函数、零堆），压缩是**变换层**
（要解码、要分配、要重编码）。两者失败语义不同 —— `imgx` 说「收不收」，`imgz` 说「能不能
变小」。混在一起会让 `imgx` 的头注释（「只做判定、不做变换」）直接失守。

**链路**：超预算的 **JPEG** → `jpeg_decode` → **整数倍**盒式下采样（1/2、1/4、1/8、1/16）
→ `jpeg_encode_q`（质量 80）→ 用**同一个** `imgx_check` 判两道预算。像素没超时先试
「同尺寸重压」（不丢分辨率 —— 超预算常常只是编码太肥），像素超了才从 1/2 起缩。

**只认 JPEG**：`std.image` 只有 JPEG 编解码器（PNG 要 zlib/deflate，GIF/WebP 也没有
编码器）。别的格式超预算**还是拒**，且话术要写清「只有 JPEG 能缩」。

**五条不变量**（改这里之前先读）：

1. **只在真能缩小时才换掉原图**。解码失败、重编码失败、缩完还超、缩完反而更大 ——
   任一情形都保留原字节与原 `ImgInfo`，让调用方走原来的拒绝路径。绝不返回半张图。
2. **失败时 `raw`/`info` 一字不动**。所以「替换」是最后一步，且先拷进新 `Buf` 再换。
3. **两道预算都要过**，且用与调用方同一个 `imgx_check`（口径不会漂）。
4. **下采样只做整数倍**（不做插值重采样，避免引入额外精度问题），且每档只算一次。
5. **重压可能反而变大**（原图已经压得很狠）—— 那时不换（`n >= raw.len` 就放弃这一档）。

**拒绝话术要带数字**（三条分支，`agent_image_attach_bytes` 里）：

| 情形 | 话术 |
|---|---|
| 缩过但还是超 | 「已自动缩到 1/N（WxH）还是超，请自己再压一下」 |
| 是 JPEG 但缩不动 | 「自动压缩没成功（可能是渐进式/畸形 JPEG），请自己压一下再来」 |
| 不是 JPEG | 「纯 Uya 只能压 JPEG，这种格式请自己先转成 JPEG 或压小」 |

**自测**：`img-sniff` 轮里加了两条 —— 真 JPEG（64x48）+ 紧凑预算（2048 像素）逼出缩小
路径并断言「更小、过预算、仍是合法 JPEG」，以及**不变量**（PNG 进来必须 `ok = false`
且字节与 info 一字不动）。**用紧凑预算而不是嵌一张几 MB 的大图**：代码路径相同，
而夹具小到能进源码。

### 13.2 剪贴板（`media/clip.uya` + 三个来源）

**先说结论：粘贴不是「一条路」，是三条路按优先级试**（P83）。`ctrl+v` / `/paste` 一律
经过 `media/clip.uya` 的 `clip_paste`，它按下面的顺序试，**第一个拿到非空结果的赢**：

| 顺序 | 来源 | 文件 | 什么时候命中 | 为什么在这个位置 |
|---|---|---|---|---|
| 1 | **终端协议（OSC 5522）** | `media/clipt.uya` | stdin 是终端且探测（DECRQM）通过 | **唯一能读到「用户眼前那块」剪贴板的路** —— SSH 下也成立 |
| 2 | X11 协议 | `media/clipx.uya` | `DISPLAY` 可用且连得上 | 本机 X11（deepin-terminal 这类不支持 5522 的终端）今天就能用的那条，行为不变 |
| 3 | 外部 helper | `media/cliphelp.uya` | PATH 里有 `wl-paste`/`xclip`/`xsel`/`pbpaste` | Wayland（wl-paste）与 macOS（pbpaste/pngpaste）的落点 |

**为什么终端协议排第一**（本轮的核心设计决定，也是「没有 X11 也能用 / SSH 也能用」的答案）：

X11 客户端与外部 helper 读的都是**跑着我们的那台机器**的剪贴板。SSH 到远端时，用户的
截图在**自己笔记本**上，远端那块剪贴板是空的 —— 于是「粘一张图给多模态模型」在 SSH 下
**永远失败**，而且失败得很难查（它看起来就像「剪贴板里没东西」）。终端协议把请求发给
**终端模拟器**，由它去读**本地**剪贴板、再把数据经同一条 tty 送回来。这条路与本机/远端、
X11/Wayland/macOS 都无关，是唯一能穿过 SSH 的通道。所以它必须排第一：**在 SSH 下若让
X11 先答，就会拿到远端那块空板子并把「没有图片也没有文本」当成结论。**

协议用 kitty 的 **OSC 5522**（`sw.kovidgoyal.net/kitty/clipboard/`；ghostty 也实现了
同一条 —— 它的 `terminal/osc.zig` 里有 `kitty_clipboard_protocol`）。线格式（逐字节）：

```
查询  ESC ] 5 5 2 2 ; type=read[:id=<id>] ; <base64("image/png image/jpeg …")> BEL
探测  ESC [ ? 5 5 2 2 $ p                       （DECRQM）
应答  ESC ] 5 5 2 2 ; type=read:status=OK[:id=<id>] BEL
      ESC ] 5 5 2 2 ; type=read:status=DATA[:id=<id>]:mime=<base64> ; <base64 分块> BEL
      ESC ] 5 5 2 2 ; type=read:status=DONE[:id=<id>] BEL
      ESC ] 5 5 2 2 ; type=read:status=<ENOSYS|EPERM|EBUSY>[:id=<id>] BEL
探测答 ESC [ ? 5 5 2 2 ; <Ps> $ y                （Ps 0/4 = 不支持）
```

| 上限 | 值 | 理由 |
|---|---|---|
| `CLIPT_MAX_BYTES` / `CLIPH_MAX_BYTES` / `CLIPX_MAX_BYTES` | `24*1024*1024` | 一张 4K 截图 PNG 通常 2–8 MiB；超过**明确拒绝、不静默截断** —— 半个 PNG 发给模型只会得到坏请求 |
| `CLIPT_PROBE_MS` | 250 | 探测是**每次粘贴都要付**的成本：短 —— 没人应答就是「不支持」 |
| `CLIPT_READ_MS` | 10000 | 读是**人在点**的：kitty 首次读会弹授权框，点一下要时间 |
| `CLIPH_TIMEOUT_MS` | 4000 | helper 是本地进程，超了就是卡住了（按进程组收） |
| `OSCIN_CAP_MAX` | 64 KiB | 单帧捕获上限：OSC 5522 的 DATA 块编码前 ≤ 4096 B（base64 后 ≈ 5.5 KiB），64 KiB 是「远超任何合法帧」 |
| `OSCIN_STALE_MS` | 50 | 半截前缀攥多久算「这不是我们的帧」（好把 `esc` 让给用户） |

**`term/oscin.uya`：终端应答与按键走同一条 fd 0，必须拦。** 这是本轮最要紧的一层。
终端对我们查询的应答从 **fd 0** 回来，和用户按键是**同一个字节流** —— 不拦的话
`ESC ] 5 5 2 2 ; …` 会被键解码器当成「ESC + 一串普通字符」**打进输入行**（屏幕上多出
一坨 base64，而真正要等的那帧数据反而不见了）。`oscin_feed` 是个纯字节状态机，认两种帧
（OSC 5522 与 DECRPM），其余字节**逐字节原样**透传；完整帧摘走、半截的**整段吐回**
（不变量 ③，绝不永久吞掉用户按键）。

**没 armed 时一个字节都不攥**：键盘路径上「什么都不做」是唯一不会引入回归的行为。
反过来（每个 `ESC` 都开捕获）会把**裸 ESC / 方向键**攥在手里 —— 行编辑器等的那个 `ESC`
永远不来，实测 `tty-editor` 轮 16 条断言当场全红。这条是设计里最贵的一格取舍。

**armed 期间 fd 0 归等待方**（`oscin_borrowed`）：`tui_poll_keys` 一开头就早退，
由等待方自己 `read`、把**透传**部分喂回 `tui_keys_feed`（所以按键一个都不丢）。
不这样做的话两边都去 `read`，先跑的把应答吃掉 —— 症状是「能力探测永远超时」，
看起来只是「这个终端不支持」。等待方读完之后才 `tui_poll_tick()`（推 spinner/尺寸/心跳）。

**一次只交付一帧**（不变量 ⑥）：一次 `read` 里常常是 `OK`+`DATA`(多块)+`DONE` 连着到。
`oscin_feed` 交付一帧就把剩下的存进**挂起段**、提前收手；等待方取走这一帧后再喂一个
空批，接着解下一帧。不做这一步的话，收到第一帧之后就永远等在那里。

**结果并入 agent**（`agent_clip_paste`，只做 UI 分流）：`CLIP_IMAGE` →
`agent_image_attach_bytes(..., from_clip = true, cfg.input_image)`（能力位的口径与来源链见
§13.1 与 §19.7：**默认支持**）；`CLIP_TEXT` → TUI
插进输入行（**不提交**，可以接着编辑）/ 滚动模式直接打；其余 → notice
「粘贴失败：`<clip_reason>`」。**回执必须指名来源**，且 SSH 下标出「**远端**」——
那条路上拿到的不是用户眼前的板子，不标出来就是在骗人。

**`--clip` / `UYA_AGENT_CLIP`**：`auto`（默认）| `term` | `x11` | `helper` | `off`。
四档确定性入口的用处：自测要能只走一条腿（否则 PTY 轮里只能赌超时），用户也要一个
关掉整条线的开关。**web 形态不走终端腿**（`cfg.web`）：web 子进程的 stdin 是服务端自己
持有的 PTY，没有「用户的终端」，发出去的询问没人会答。

**外部 helper（`media/cliphelp.uya`）** 按环境挑候选（`WAYLAND_DISPLAY` → wl-paste、
`DISPLAY` → xclip/xsel、无条件 → pbpaste/pngpaste），命令形状每种都不同：
wl-paste 走 `--list-types` + `--type <mime>`、xclip 走 `-t TARGETS -o` + `-t <atom> -o`、
xsel 只能取文本、pngpaste 直接吐 PNG。子进程一律 `sigx_reset_for_child()` +
`sh_child_detach_stdio()`（**绝不碰用户的终端**），超时/取消**按进程组**收。

**X11 客户端（`media/clipx.uya`）** 的协议细节（那五个「差一格」）保留在 §16 踩坑 85；
本轮只把它从「唯一来源」改成「来源之二」，**语义一字未动**。

#### 13.2.1 写方向：拖选复制（P85，`media/clipw.uya`）

读方向有**三条来源**，写方向只有**一条**：**自己当 X11 选区所有者**。为什么不借终端协议
（先把它排掉是本轮的第一件事，见踩坑 146）：真机实测用户这台终端（deepin-terminal /
QTermWidget）对 `ESC[?5522$p`（DECRQM）**零应答**，OSC 52 写 `c`/`p` 两块板子**一个字节
都不变**（同机 DSR 探针对照有应答 ⇒ 不是「读不到」的假阴性）。**外部 helper 也不做**：
本机 `wl-copy`/`xclip`/`xsel` 一个都没装，而它们会自己 daemonize 去持有选区，超时按
进程组收有把刚起来的持有者一起杀掉的风险。

写方向的流程（`clipw_copy`）：

| 步 | 请求 | 要点 |
|---|---|---|
| 1 | `CreateWindow`（InputOnly）+ Sync | 与读方向同一手法：用 root 当 owner 会被拒；`CreateWindow` 无应答，紧跟一条有应答请求把错误带出来 |
| 2 | `InternAtom` × 5 | `CLIPBOARD` / `PRIMARY` / `TARGETS` / `UTF8_STRING` / `STRING` |
| 3 | `SetSelectionOwner`(`CLIPBOARD`，CurrentTime) | **主目标**（`Ctrl+V`）；`PRIMARY` 是**尽力**（拖完立刻中键粘贴用） |
| 4 | 守 `CLIPW_HOLD_MS`（1.5 s） | poll 连接 → 应答 `SelectionRequest`（`ChangeProperty` + `SendEvent` 回 `SelectionNotify`）；期间 `tui_poll_tick()` 泵界面、`esc` 可取消 |
| 5 | 收工 | 真数据被取走后**再守 `CLIPW_LINGER_MS`（250 ms）**让管理器落盘，然后撒手 |

三条实测约束（写进实现，不是照规范抄的）：

* **`TARGETS` 必须应答**：不答它时对端（Qt 一档）拿不到内容，读回来的是**上一次**的旧值。
* **`ChangeProperty` 的 `items` 是「元素个数」不是字节数**：`format=32` 时服务端会按
  `items × 4` 读，填错就会多读一截垃圾（请求体是 20 字节头 + 数据，那 4 字节 `items`
  在头里 —— 我第一版连自测的期望值都按 16 字节头写了，见踩坑 146）。
* **退出后 CLIPBOARD 仍有效**：桌面剪贴板管理器会**主动来取**并由它持久化（实测持有
  0.6 s 就够、退出后 `Ctrl+V` 拿得到原文）；`PRIMARY` 则由它清掉 —— 这符合 X11 惯例，
  也是我们只把 CLIPBOARD 当主目标的原因。

**SSH 下写的是远端剪贴板**（与读方向同构）：回执必须标「**远端**」，否则用户在笔记本上
`Ctrl+V` 拿不到东西却不知道原因。没有 X11 会话时回 `CLIPW_NO_X11` + 一句明确的人话
（并提示 `/mouse off` 可以交回终端），**绝不静默**。

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
| httpc | `HC_RESOLV_MAX` | 16384 | 解析器文件（resolv.conf）**整份读**的上限；撞上限置 `hc_resolv_trunc` 并报出来，不静默当「没有」（踩坑 133；标准库那边的窗口是 512 字节，正是那条坑） |
| httpc | `HC_DNS_SERVER_MAX` / `HC_TARGET_MAX` | 64 / 256 | 解析器串（`a.b.c.d[:端口]`）/ 诊断里记的「最近一次连接目标」主机名 |
| llm | `LLM_MAX_CALLS` | 16 | `calls` 固定数组容量；槽位用尽 `llm_slot` 返回 -1 |
| llm | `LLM_EVENT_ARENA` | `262144` | 每事件 parse 的 arena；逐事件 reset |
| llm | `LLM_ERR_HEAD` | 240 | `err_text` 只留坏 payload / 错误体的**头部** |
| agent | `MSG_CONTENT_MAX` | `200000` | 单条消息入史上限（**与 `TUI_IN_MAX` 同值，改一处要改两处**） |
| agent | `HIST_TRUNC_MARK` | — | 超限裁剪的标记；head 预算 = `max - mark - 16384` |
| agent | `EMPTY_RETRY_MAX` | 1 | 退化响应每步重发额度 |
| agent | `request_bytes_needed` | `h.bytes*2 + 8192 + 8192 + model.len*2 + img_extra` | 请求缓冲预算 |
| agent | `TOOL_FLAT_STRIP` | 31 字节 | Responses 形状的 schema 前缀，去掉即 flat |
| modelx | `MX_MAX` / `MX_LEVELS` | 256 / 7 | 模型目录条目上限 / DSH 的七个推理档位 |
| modelx | `MX_WIN_MAX` / `MX_WIN_MAX_VALUE` | 32 / `999999999` | `uya-agent.contextWindows` 的条目上限 / 窗口值上限（**9 位十进制**——定死位数，解析才不会溢出，同时挡住 `1000000000` 这类误写） |
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
| TUI | `TUI_MAX_ENTRIES` / `ENTRY_MAX` / `TEXT_MAX` | 512 / `256 KiB` / `4 MiB` | 条目环形表 / 单条 / **正文**总量 |
| TUI | `TUI_DERIVED_MAX` | `16 MiB` | 派生缓冲（折行 + 样式 + 行表）总量，见 §11.5.1 |
| TUI | `TUI_REASON_TAIL` | 4096 | 思考条目只留最新一段 |
| TUI | `TUI_NOTICE_MAX` | 512 | 无它则一条 4 KiB 的网关错误体就能把整屏转录冲掉 |
| TUI | `TUI_IN_MAX` / `TUI_IN_MAX_TEXT` | `200000` / 4096 | 输入行上限（与 `MSG_CONTENT_MAX` 同值）/ 单行输入（标题 ≤80 B，防手滑粘贴） |
| TUI | `TUI_EVQ_MAX` / `HIST_MAX` / `WHEEL_STEP` | 512 / 32 / 5 | 事件队列 / 历史 / 滚轮一步 |
| TUI | `TUI_ASK_MAX_OPT` / `MIN_W` / `CHROME_W` / `EDGE_W` | 16 / 34 / 6 / 6 | DSH 的提问一般 2–4 个；最多 9 个数字直选键 |
| TUI | `TUI_OV_READER_MAX_H` / `W` / `MIN_PANEL_TOP` / `BODY_MAX` | 20 / 78 / 6 / `131072` | 框高 / 期望宽 / 再矮就别开 / 正文上限 |
| TUI | `TUI_OV_LIST_W` / `BOX_W_MIN` | 60 / 24 | 列表型默认宽 / 下限 |
| TUI | `TUI_DIFF_COLS_MIN` / `ROWS_MIN` / `GUTTER` / `MARK` / `HL_MAX` | 60 / 11 / 6 / 2 / 4096 | |
| TUI | `TUI_THINK_TAIL` | 1024 | 状态区实时行只留最新一段 |
| TUI | `TUI_MQ_STEP_MS` / `HOLD` / `SLOTS` | 400 / 4 / 64 | P75 跑马灯：一列/步、两端停留步数、槽位表容量（见 §11.5） |
| TUI | `TUI_MQ_PIN_MIN` | 8 | P76 簇里选中行：钉住段之后至少留给滑动段的窗口（低于它就不钉、整行滑，见 §11.5） |
| TUI | `TUI_FOOT_WIN` | 30 | P75 脚注 cwd 段的固定窗口（显示列）；装不下交给跑马灯 |
| TUI | `TUI_LOGO_H` / `W` / `PAD` | 5 / 61 / 1 | 9 字形 × 7 列 − 2 |
| TUI | `TUI_SGR16_LEN` | 192 | = `TUI_ST_COUNT * 8`；每样式 8 个 SGR 参数槽（P36 从 4 扩到 8：256 色「亮前景+显式背景」是 6 个参数，4 槽会被**静默截断**） |
| tasks | `TASKS_BLOCK_MAX_ROWS` / `TASKS_*` | 12 / 20, 6, 10, 24, 8000, 262144 | 常驻块上限 / 进度条格数, 清单行, 标签列, 最小宽, tty 与 TUI 字节预算 |
| mdview | `MDV_MAX_COLS` / `MAX_LEVEL` / `URL_MAX` / `INLINE_DEPTH` / `INDENT` | 8 / 3 / 48 / 3 / 2 | 表格列 / 嵌套层 / 链接列 / 行内递归 / 缩进 |
| tty | `TTY_LINE_MAX` / `HIST_MAX` / `EVQ_MAX` / `BLOCK_TEXT_MAX` | 8192 / 32 / 16 / 8192 | |
| tty | `TTY_TITLE_MAX_BYTES` / `FALLBACK_WORDS` / `FALLBACK_BYTES` | 80 / 5 / 40 | 对齐 DSH preset |
| view | `VIEW_LINE_FALLBACK` / `AG_MAX` / `AG_INNER_MIN` / `AG_MSG_MAX` / `THINK_MS` | 80 / 4 / 30 / 320 / 80 | 面板与思考节流 |
| watch | `WATCH_BUF_MAX` / `WATCH_PREVIEW_MAX` | `262144` / 320 | 跟随缓冲 / 单行预览 |
| media | `IMGX_DEF_MAX_BYTES` / `MAX_PIXELS` / `MAX_PER_MSG` | `8 MiB` / 640000 / 8 | 见 §13.1 |
| media | `CLIPX_MAX_BYTES` / `TIMEOUT_MS` / `POLL_MS` | `24 MiB` / 2500 / 20 | 见 §13.2（X11 那一路；三源的上限（`CLIPT_`/`CLIPH_`/`OSCIN_`）在同一节） |
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
| 字符串里不许出现**非法 UTF-8** 字节（截断的半个字符、WTF-8 代理项、过长编码） | 同一个 400，换了个马甲：`invalid unicode code point`（踩坑 156） |
| 非法 UTF-8 的替身只能是 U+FFFD，且请求体/会话日志**两侧同一个替身** | `--resume` 把坏字节喂回来 ⇒ 重启也救不回来 |
| UTF-8 合法性规则表只有 `bufx_utf8_seq_len` 一份（`bufx_utf8_valid` 也走它） | 自测说合法、网关说非法（宽松校验只查续字节位） |
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
| 改标准库 `lib/tls` | 见 §18 —— 缺陷在标准库侧，本项目在 agent 侧提供四档策略 |
| 换到 `uya 0.11` | `tls/https.uya`、`std/json/*`、`x509/verify.uya` 与 0.10 逐字节相同，但 `libc/syscall.uya`、`std/runtime/runtime.uya`、`tls/ssl/context.uya` 有差异，需重新验证 |

### 15.2 会话与界面

| 边界 | 说明 |
|---|---|
| **换会话只换「当前会话的」那段屏幕**（P39） | TUI 里 `/new`、`/resume <id>` 把转录清成「只剩新会话」（`/resume` 再回放历史）；但**滚动模式（`--no-tui`）不重画** —— 那边的正文是终端自己滚出去的。回放复用启动时那一份口径（最近 200 条 + 一条「更早的会话记录已省略」提示，注入类消息不回放） |
| **子代理面板里那条「最新消息」是父进程发给它的那句话**（P40） | 预览取 `Deleg.prompt`（首行、空白折叠、超长贴尾）；子代理 stdout 按 P11 口径**只在跑完时**才回传管道，所以「它刚说了什么」得等终态或 `subagent_output`（面板那个 `· N` 是已收输出行数，运行中通常是 0）。贴尾只收窄**显示**，`Deleg.prompt` 本身一个字节不动 |
| **`/watch` 的实时粒度是「事件」不是 token 级**（P42） | 见 §9.1；且 `/watch` 是**进程状态**（`--resume` 不回填）；被跟随的子代理跑完或槽位回收时跟随自动结束 |
| **浮层高上限 16 行**（非全屏） | `↑/↓`、`pgup/pgdn`、`home/end` 滚，标题栏 `↑`/`↓` 是溢出指示 |
| **浮层全屏只吃转录区** | 不做「盖住整屏」的真全屏，不做鼠标拖拽缩放/点击边框，不做「每个形态各自记住全屏偏好」 |
| **TUI 做的鼠标交互只有两种**：滚轮翻转录 + **拖选复制**（P85）；**不做**鼠标点击浮层条目/点边框/拖拽缩放、可折叠卡片、分屏、主题切换 UI | 拖选复制是**终端协议逼出来的**：终端把鼠标交给我们之后它自己的拖选就没了（踩坑 72），而真机实测常见终端**既不认 OSC 5522 也不认 OSC 52**（见 §13.2 与踩坑 144）——于是只能自己记选区 + 自己当 X11 选区所有者（`term/tui/sel.uya` + `media/clipw.uya`） |
| **web 页面里的拖选与复制自己实现** | 浏览器默认给的那套在终端网格上有两个坑（抢焦点毁选区、默认复制带 `text/html`），所以：焦点只在「没在拖、也没选中」时才抢；`copy` 接管后只写 `text/plain`；`ctrl+c` 按选区分流（有选区 = 复制，没选区 = 中断）。见 §11.8.6.2/§11.8.6.3 与踩坑 125 |
| **终端里不渲染图片** | 屏幕上只有一行占位（这就是「挂上了」的全部证据）；**超预算的 JPEG 会自动缩小**（`imgz`，P72），PNG/GIF/WebP 仍只能拒 |
| **「选中文字复制」TUI 自己做**（P85） | 拖鼠标 = 选中并复制到 `CLIPBOARD`（不按 shift）；高亮逐格反显，esc 清选区。`F2` / `/mouse off` 仍可把鼠标交回终端（那时用终端自己的选区），`--no-mouse` 同效。没有 X11 会话时复制会**明确报错**（不静默）；SSH 下写进去的是**远端**剪贴板，回执会标出来 |
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
| **会话身份照发**（与「不发 prompt_cache_key」是两件事） | 每个请求都带 `x-deepseek-harness-session-id` + `Session-Id` 两个头，正文带 `client_metadata.session_id`（responses）/ `metadata.session_id`（chat）；运行时上下文带 `session workspace: "<JSON 路径>"`。口径对齐 DSH，`~/ai-gateway` 据此按会话归组、取工作区、识别标题行 |
| **客户身份靠 User-Agent，机读句报归类键**（P71） | 网关的客户端词表是**封闭**的 `dsh / codex / console / unknown`（`internal/responses/dimensions.go`），正文规则要求首条 system 逐字是 DSH 的 persona —— 我们不改自己的 persona（那是冒充，还会改模型行为），所以**唯一接缝是 UA**：发 `uya-agent/0.1 (deepseek-harness-compatible)`，命中它的 `deepseek-harness` 子串 ⇒ `client=dsh`。认不出客户端时网关**连 `workspace` 也一起丢**（那条维度只在 dsh/codex 两个分支里取），所以这不只是「客户端列好不好看」的问题。同时 `session workspace:` 报的是**归类键**（`pm_main_worktree_into`：linked worktree 折回主工作区，普通仓库的子目录原样），人读的 `Current workspace:` 仍是字面路径 —— 否则每个会话一条唯一 worktree 路径，工作区维度会退化成会话维度。已知边界：普通仓库的子目录按字面归；历史行不回填 |
| **起标题提示词与 DSH 逐字同形** | system 段 `Create a concise title for an AI coding-assistant session …`、user 段 `Generate the session title from this JSON array of human messages:\n<JSON 数组>`，并带同一会话 id（网关照这两个前缀认 `call_kind=title`）。**唯一偏离**：system 段第三句（词数句）改成本项目口径「15 字以内 / 约 3 词」（DSH 原句 5 词 / 40 CJK 字符 —— 它的 40 B 只放得下 13 个汉字）—— 网关只匹配前两条前缀，这条可自定；硬约束另由 `tty_title_fallback_into`（3 词 / 45 B）收口 |
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

### 15.4.1 插件（P70）明确不做的事

| 不做 | 理由 |
|---|---|
| **进程内 cordis/TS 插件**（`@deepseek-ai/dsh-tool-*` 这类） | 那要求宿主是 Node —— 插件要的是**进程内可调用对象**（`ctx.subprocess` / `ctx.fs`）与同进程状态同步（`sessionProjections.register`），跨进程给不了。如实记为「不追」，`--list-plugins` 会报 `unsupported` 并说明原因 |
| `streamable-http` transport | 只做 stdio（字段留着、解析照做，只是不实现连接） |
| MCP 的 `resources` / `sampling` / `roots` | 只做 tools + prompts；本仓没有对应的消费面 |
| `notifications/tools/list_changed` 热更新 | 用 `mcp` 元工具的 `reload` 手动刷（自动热更新要处理「注册表正在被读时被换掉」） |
| MCP 的 task / permission 扩展词表 | 与 §7 的三级模式重复，两套权限语义会漂移 |
| waterfall 的**链式**语义 | 只能单点否决/整体替换（见 §21.2 的表） |
| 插件市场 / 自动下载安装 | 插件的获取是用户的事；本仓只负责「装好了怎么用」 |

### 15.5 平台

目标平台是 **Linux x86-64**（代码里的 syscall / 常量按这个平台写）。

剪贴板分三条来源（见 §13.2）。各自的平台边界：

* **终端协议（首选）** 只支持 kitty 的 **OSC 5522**（ghostty 同款）。**不做** OSC 52 的
  读取（只带文本，且多数终端出于安全默认关闭）、**不做** 5522 的 paste-event 模式
  （`DECSET 5522`，会引入**非用户主动**的授权弹窗，与「按一下才读一次」冲突）、
  **不做** tmux/screen 的 DCS 透传（那取决于它们，不支持就靠探测失败回落）。
* **X11** 只支持 unix socket（不做 TCP 转发）。**写方向（P85 的拖选复制）也走 X11**：
  我们自己当 CLIPBOARD/PRIMARY 的**选区所有者**（`SetSelectionOwner` + 应答
  `SelectionRequest`），持有窗口有硬上限（`CLIPW_HOLD_MS`），期间 `tui_poll_tick` 泵界面，
  `esc` 可取消。**不做**写方向的 OSC 52（真机实测 deepin-terminal/QTermWidget **不认**它：
  发 `c`/`p` 两块板子一个字节都不变）与 OSC 5522 的 `type=write`（同一台终端对
  `ESC[?5522$p` 零应答；协议形状也与读方向相反 —— 分块 base64 要**拼接后**才是 4 的倍数）。
* **外部 helper** 只在 PATH 里真有 `wl-paste`/`xclip`/`xsel`/`pbpaste` 时可用。
  **写方向不做 helper**（`wl-copy`/`xclip -i`）：本机一个都没装，且它们会自己 daemonize
  去持有选区，超时按进程组收有把刚起来的持有者一起杀掉的风险。

**SSH 下能用的只有第一条**：另两条读的是**远端**那台机器的剪贴板。终端不支持 5522
时，SSH 会话里就**贴不了** —— 这一句会如实出现在失败回执里（而不是含糊的「失败」）。

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
    **P78 补两个「同一个坑的另一半」——它们都过类型检查、过编译（甚至过 `codegen-audit`），只在运行时坏**：
    ① 形参是**裸指针** `&const byte` 时，`f(&"example.com"[0: 11])` 传进去的是描述符的**地址**，
    被调方按 `const uint8_t*` 读，拿到的是描述符头 8 字节（那 8 字节是**指针值本身**）——
    实测字符串内容变成 `"BA"` / `"OA"` / `"NA"` 这种两字节碎片，而所有检查全绿。
    形参是**切片** `&[byte]` 时，同一句写法生成的是正确的描述符**值** ⇒
    `buf_append(&body, &"x"[0: 1], 1)` 这种看起来一模一样的写法能过，纯属巧合。
    **判据**：把字面量喂给裸指针形参时，写成 `const S: &const byte = "lit" as &const byte;`
    （本仓既有写法，见 `net/httpc.uya` 的 `HC_USER_AGENT`）。
    ② `const X: &[byte] = &"lit"[0: n];` 这类**切片常量**根本编不过：codegen 生成
    `const uint8_t * const X = (struct uya_slice_uint8_t){...}`（描述符去初始化裸指针），
    宿主 C 报 `invalid initializer`。
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
39. **终端标题 OSC 三件事钉死**：只写给真 TTY（`tty_title_begin()` 门控）；直接 `sys_write` 不能走 `tty_write`（sink 会吞成乱码）；统一 `tty_title_clean_into` 清洗截断（模型侧 3 词/45 B = 15 字以内，上屏 80 B）。`--continue` 的 `sess_open` 会清空标题。
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

84. **超预算的图先试着缩，缩不动才拒**（P51 立、**P72 改**）：P51 当时的结论是「纯 Uya
  没有图片编码器 ⇒ 只能接受原图或拒绝」。**P72 把这条推翻了一半**：`std.image` 现在有纯 Uya
  的基线 JPEG 编解码器（零 libm、全整数），于是 `media/imgz.uya` 能把超预算的 **JPEG** 解码 →
  整数倍下采样 → 重编码到预算内。仍然不行的：PNG（没有 zlib/deflate 写不出来）、GIF/WebP
  （没有编码器）—— 这些格式超预算还是只能拒，且**话术要说清「只有 JPEG 能缩」**，不能笼统
  说「缩不小」。
  两条与当时一致、仍然成立的部分：① 预算判定必须发生在**读取之后、构请求之前**
  （`imgx_check`）；② 两个协议的内联形状（completions 的 `image_url` 对象 / responses 的
  `input_image` + `detail`）要用**抓包**核对，不能照抄文档（实测网关两种都收，但形状不同）。
  分层也保留：`imgx` 仍然只做**判定**（读文件头、纯函数、零堆），**变换**在 `imgz` ——
  判定要能在图进来的一瞬间回答「收不收」，不该顺手解码一张几十 MB 的图。

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
 96. **「模型切了，请求却没换路线」——一条链路只搬了一半**（P37，本轮修复，用户报的「中途切换不了模型」）：
    症状是切换**看起来成功**（信息行、`/model` 报告、`session/model` 事件全都变了），但请求
    **继续发往启动时那条路线**：换了提供方也一样。实测（两个假网关各自记账，见 `make e2e-model-route`）：
    切到 prov-b 之后，prov-a 的网关**仍然收到全部请求**（`model=a-one`、`Authorization: Bearer
    <prov-a 的 key>`），prov-b 一个请求都没收到 —— 用户看到的就是「切了没反应 / 401 /
    回答还是旧模型的」。根因：`agent_model_apply` 只搬**能力**（contextWindow / maxTokens /
    input / compat，`agent_model_adopt_caps`），从不重解析 `base_url` / `api_key` / `api_style`；
    而模型目录**故意不存 baseURL**（存了就要把凭据链 `<DSH_HOME>/.credentials.yaml` / `.env` /
    进程环境复制成第二份）⇒「provider 换了」与「请求打到哪」是两件事，只有重走一遍
    `dsh_cfg_load` 才能把后者对齐。修法：`dsh_cfg_load` 加 `provider_override` 一支（跳过
    `agent-default-model`、复用同一份 provider 定义与凭据链解析），收口成 `agent_route_apply`，
    由 `agent_model_apply`（仅 provider 真变了时）与 `agent_session_model_pick`（`--resume` 跟随）
    调用。三条附带的边界，每条都是「不这么写就会静默说谎」：
    * **显式优先**：env / CLI 给过的 base_url / api_key / api_style 一律不动 —— 为此给
      `--base-url` / `--api-key` 与对应的 env 补了来源码（以前 CLI 给的值被印成 `default`，
      而且没有依据判「这是人钉住的」）。
    * **密钥不跨提供方**：新提供方声明了 `apiKeyEnv` 却解析不出凭据 ⇒ **清空** key 并告警。
      把 A 的密钥发到 B 的主机是一条凭据泄露路径，比 401 更坏。
    * **没声明 `baseURL`** ⇒ 一个字节不改，只留一行说明（静默清空端点比「没跟上」更坏）。
    **孪生坑（同一个「只做了一半」的形状）**：请求头 `hdrs` 在 `agent_turn_loop_inner` 里
    **整回合只建一次**，而 `url` 是每个 step 重算的 ⇒ 路线变了之后 URL 会跟上、**`Authorization`
    不会**（带着旧提供方的密钥打新端点）。修法是把 `buf_reset(&hdrs)` + `build_headers` 挪到
    step 循环里、紧挨 `api_url_into`（两者必须描述同一条路线）。
    **第二个独立故障：运行中敲的 `/model <名字>` 被当成给模型的文本**。安全集
    `agent_tui_cmd_safe` 只拿得到**命令名**、按整行相等比 `/model`，于是带参那行匹配不上 ⇒
    被推进 steer 收件箱、在下一个 step 边界又被判不安全 ⇒ 当 user 消息发给模型（实测网关收到的
    请求体里赫然有 `/model b-two` 这一行）。修法：`agent_steer_line` 改用**整行**版判定
    `agent_tui_cmd_safe_steer`，并在那里补 `/model <名字>` / `/effort <档位>`（要求参数段非空白，
    与既有的 `/title <新标题>` 同一支）；两条路（流式泵点 / step 边界）从此共用一份判定。
    **第三个：浮层选完要等回合结束才生效**。`agent_tui_poll_pending_cmd` 只认
    `PALETTE`/`WATCH_LIST` 两种 kind，其余一律 `agent_pump_receipt_clear()` 丢掉 ⇒
    「回合运行中选完模型」要等最后一轮工具跑完（实测回车 t=8.0、生效 t=14.1）。修法是给泵点
    补 `TUI_OVK_MODEL` / `TUI_OVK_EFFORT` 两支（只改状态 + 落一条 `session/model`，不碰历史、
    不发请求，与 `/watch` 现役清单同一条分工）。
    防假绿对照实验：① 新 e2e 在**改动前**的二进制上必须红（实测 `VERDICT: FAIL`、网关记账里
    prov-a 收到全部请求）；② 把泵点那两支注释掉重编 ⇒ `tui-model` 轮当场红两条
    （「泵点没有当场收下模型选择」+「结果还挂着」）；③ selftest 的 `model-apply` 轮同时钉
    「跟随」与「显式钉住不许被覆盖」两个方向。教训与踩坑 71/93 同族：**配置项改了一半时，
    「看起来生效」与「真的生效」差着一条网络路径**；这类改动必须有一条读**事实**（打到哪个
    端点、带了哪把密钥）的判据，不能只断言内存里的字段变了。
    本轮为腾函数表额度**内联掉一个只转发的函数**（`agent_watch_ended_name` → 直接调
    `deleg_status_name`）：本仓顶层函数表已满，净增一个**可达**函数就编不过，而删掉**零调用**
    的死函数（`env_or_src`）并不释放额度（它本来就不在 reachable 集合里）——
    这条正是踩坑 87/91 的续集。

96. **日志说「有 `tool_calls`」、实际一条都没派发 —— 这条谎会在 `--resume` 时把正文一起吃掉**（P59，本轮发现）：
   截断（`finish_reason=length`）那一支**丢弃所有工具调用**是对的（参数可能是半截的，派发只会得到
   协议错），但旧实现是**先**写 `assistant/message`（`agent_log_assistant` 只要 `o.ncalls > 0` 就把
   `tool_calls` 一并写进去）**再**判断截断 —— 于是日志里留下一条「有 `tool_calls`、零 `tool/result`」
   的悬空记录，两个后果都很难查：
   ① 事后复盘时，它与「工具真派发过、结果丢了」**长得一模一样**（这正是 §5.4 里那条「日志里只剩一条
   `content=""` 的 assistant 消息」的同一族问题：日志不足以区分两种现实）；
   ② 更要命的是 `--resume`：`agent_hist_from_log` 见到 `tool_calls` 就折成 `ROLE_ASSISTANT_CALLS`，
   紧接着 `agent_session_open` 跑 `hist_trim_incomplete_tail`，而它对「零应答的 assistant」的做法是
   **整条丢掉**（`hist-repair` 轮第 3 腿钉的就是这条判据）—— 截断前那段正文跟着一起没了，用户看到的
   是「恢复会话后模型完全不记得上一轮写过什么」。
   修法是把「记什么」与「派发什么」绑成**同一个事实**：`agent_log_assistant` 收一个 `keep_calls`，
   截断那一步传 `false`，日志与历史两条腿都只留正文。DSH 的 `BlockAssembler.assembled()` 注释是同一句话：
   "Emitted blocks and replay metadata both derive from this result, so they cannot disagree"。
   教训属于「写下的事实必须与实际副作用一致」那一族（与踩坑 92 的「配置必须落到线上字节」同源）：
   **日志是事后排障的唯一物证 —— 它只要比现实多一句，就会把人带到反方向去。**

97. **自测夹具自己缺一个尾 NUL：老编译器「碰运气绿」，换编译器当场红六轮**（本轮，不占阶段号）：
   现场：0.10.3 + 90 文件树上整轮 selftest，`tui-pty` / `tui-approve` / `tui-plan` / `tui-ask` /
   `tui-quit` / `tui-p30` 六轮真 PTY 回合全红，症状统一是「首屏没有输入面板占位文案 / 没有进备用屏幕」，
   pty 捕获 **0 字节**，而 TUI 子进程退出码是 **9**。
   根因：`tuis_open_pty` 拼从设备路径用的是 `buf_append_cstr` + `buf_append_u64` —— **没有尾 NUL**，
   而这条路径要**直接喂子进程的 `sys_open`**（FFI）。`buf_new(64)` 只是 `malloc`（**不置零**），
   于是路径后面黏着堆里的残留字节 ⇒ `ENOENT` ⇒ 子进程 `sys_exit(9)`（退出码 9 是这条路上唯一的出口）。
   判据（三条对照，缺一条都不能定案）：① 同一棵树拷到 `/tmp` 平路径上同样红 ⇒ 排除 worktree 路径；
   ② 单跑 `UYA_SELFTEST_TUI_ONLY=1` 也红、且 6 轮全红 ⇒ 不是轮序偶发；③ 只补一个字节后，
   **同一棵树、同一个编译器、31 轮全绿**；④ 对照腿：**拆分前的旧树 + 0.10.1 同一组回合全绿**
   ⇒ 代码没坏，是「堆恰好是零页」的运气没了。
   修法：`tuis_open_pty` 补 `buf_append_byte(slave_path, 0)`，并在 `tui-pty` 轮钉一条
   **`bufx_cstr_len(ptr) + 1 == len`** 的断言 —— 补错/漏补都当场红，不用等下一次换编译器。
   **教训**：这是**踩坑 57 的第二个实例**（那边是 `wt_residue_slug`），而 `bufx.uya` 里
   `buf_append_cstr_z` 的注释早就把话写死了（「传给系统调用的必须用这个」）。
   **「一直绿」不等于「写对了」，只等于「碰巧」。**换编译器时最先炸的就是这一类。

98. **跨轮残留的键盘时钟：`title-cmd` 在整轮里恒红、单跑恒绿**（本轮，不占阶段号）：
   现场：整轮 selftest 里 `title-cmd` 连红三轮（「待办消费之后标志应当清掉」「消费待办时没有记
   revision」），而 `UYA_SELFTEST_TITLE_ONLY=1` 单跑是绿的。
   根因：`agent_title_auto_idle_ok()` 除了 arm 窗口，还看**键盘静默窗口**（`TITLE_AUTO_QUIET_MS`
   = 900 ms，读 `g_tui_last_key_ms`）。`title-cmd` 在整轮顺序里紧跟 tui-* 那一串，那些轮刚注入过
   按键 ⇒ 时钟是热的 ⇒ 待办被 idle 门挡下 ⇒ 标志留着、revision 不记。单跑时时钟是冷的，所以
   单跑与整轮**两个结论**——而这一轮的注释恰好写着「非 TUI 时 tui_last_key_ms 恒 0」，
   那条假设只在单跑时成立。
   修法：这一轮里显式 `g_tui_last_key_ms = 0`（与它本来就有的 `g_title_auto_arm_ms = 1` 并列），
   把隐含假设换成显式归零。
   教训与 P53 那条「真 TUI 子进程的 agent home 必须独立」同族：自测轮共享同一个进程时，
   **「我这一轮看到的初值」必须自己摆好**，别引用别的轮留下的现场。

99. **`buf_new(0)` 不是「空缓冲」，`buf_valid()` 会判它无效**（P60，本轮踩到）：
   `buf_valid` 的判据是 `ptr != null && cap > 0`，而 `buf_new(0)` 只返回一个
   `cap = 0` 的空描述符。web 的连接初始化里用 `buf_new(0)` 建 `out`，于是
   `web_conn_init` 对**每一个**新连接都返回 false ⇒ 连接被当场关掉。
   症状极具误导性：`strace` 里只有 `accept(5) = 7`，**后面没有任何 read**，
   客户端看到的就是「连上了，然后连接被重置」。
   正确形状有两种，按用途分：**要写进去**的缓冲给非零容量（`buf_new(4096)`）；
   **只当容器、由 `buf_append` 自己长**的（如帧缓冲、回放槽）用 `buf_new(0)` 但
   **不要拿 `buf_valid` 去判它**。踩坑 92 是同一族的另一面（出参缓冲必须是
   `buf_empty()`），两条合起来的教训：**别把「没有分配」与「分配失败」混成一个判据**。

100. **`web_handle` 的返回值被当成「写成功」⇒ 一次请求分派两次**（P60，本轮踩到）：
    `web_handle` 的语义是**「要不要留着这个连接」**（true 只给 `/api/screen` 那条长
    连接）。第一版把各端点函数的返回值（其实是 `srv_send_response` 的「写成功」）
    直接 `return` 了出去 ⇒ 每个 JSON 端点都「留着连接」⇒ 下一圈 poll 又报可读、而
    `c.rx` 里还留着同一份请求原文（`srv_recv_request` 是**累积**式的）⇒ **端点执行
    两次**。浏览器的症状是「点一次 `+` 冒出两条会话」，服务端日志上是同一个 fd 连着
    两次 `RX_OK`（第二次的 `rxlen` 正是那份旧请求）。
    修法：非长连接一律 `_ = <端点>(…); return false;`，并把这条写进文件头不变量。
    自测补了 `web-dispatch` 轮（socketpair/管道当连接，判 `GET /` 与
    `POST /api/sessions` 都返回 false），**并做了防假绿对照**：把 `GET /` 改回
    `return web_ep_index(c);` 重编 ⇒ 当场红。同族教训：**返回值的语义要在调用点写清**
    （本仓已经在踩坑 44 上栽过一次「返回值被丢掉」，这次是「返回值被误解」）。

101. **端口字节序读反：请求 8791、监听 22306**（P60，本轮踩到）：
    `srv_sockaddr` 把端口按**网络序**写进 `out[2]`/`out[3]`（大端，与内核的
    `sin_port` 布局一致），而 `srv_port_of` 第一版按**小端**读回来
    （`(addr[3] << 8) | addr[2]`）。8791（0x2257）的字节交换正是 22306（0x5722）——
    这个数字本身就是判据。症状是「服务起来了、`ss` 里也在听，但浏览器打不开你输的
    那个端口」（`--web 127.0.0.1:8791` 实际听在 22306）。
    教训：**写与读必须互为逆运算**，而且这种错不会崩、只会静默地听在别处 ——
    所以自测里有一条直接断 `web_addr_parse("127.0.0.1:8791")` 解析出 8791。

102. **服务端解释器有两处「看起来等价、实际不等价」的细节**（P60，本轮自测抓出）：
    ① **宽字符要标续格**。CJK 占两列，`emu_put` 写完首格后把光标推 2，第二格的
    `ch` 天生是 0；而 `emu_row_text` 按「`ch == 0` ⇒ 补一个空格」导出文本 ⇒
    **每遇到一个汉字就凭空多一个空格**（实测与 `tui_screen_text` 差 7 字节，
    全是汉字之间多出来的）。修法是单元格加 `wide` 标记（1 = 首格、2 = 续格），
    导出文本时续格**跳过**而不是补空格；行尾判定也要把续格当非空白。
    ② **UTF-8 序列会被 feed 切开**。PTY 一次读 16 KiB，但管道/TCP 边界任意，
    一个汉字（3 字节）完全可能跨两次 `emu_feed`；不暂存前半个就会解成两个 U+FFFD，
    而且**不可恢复**（字节已经吃掉了）。修法是留一个 ≤4 字节的 `pend`，下一次 feed
    先拼接再解。
    这两条都是**自测抓出来的**，判据就是那句最贵的不变量：网格文本必须与
    `tui_screen_text()` **逐字节相同**（且「逐字节分片喂」也要得到同样的结果）。

103. **子进程继承环境会把「我自己」变成「再来一个我」**（P60，本轮踩到）：
    web 会话的子进程由父进程 fork + execve 出来跑 TUI，argv 第一版只给了可执行文件
    路径（没有 flag）。于是子进程的 `main` 里，**继承来的** `UYA_AGENT_WEB=1` 又把它
    送进 `web_run` ⇒ 递归起 web 服务器；而它还继承了父进程的 PTY 相关 fd 与
    `--no-save`…… 症状是「fork 出来的子进程立刻退出，页面上一条会话都没有帧」
    （`strace` 里能看到它探了一下 bwrap 就没了）。
    修法：子进程 argv **显式带 `--tui`**，环境里再显式 `UYA_AGENT_WEB=0`
    （CLI 优先级本来就高于 env，两条都给是双保险）。
    同族：`cfg.uya_bin` 是 `uya` **编译器**（workflow 跑 `.ush` 脚本用的），
    不是本进程自己 —— 子进程要 exec 的是 `/proc/self/exe`（内核给的绝对真身，
    比 `get_argv(0)` 可靠：后者可能是相对路径或软链，而 execve 时的 cwd 已经变了，
    且 execve 不查 PATH）。

104. **脚注的「内存」用机器级同名口径 ⇒ 把别人的会话算到用户头上**（P24b，用户报的）：
    用户报「状态栏内存显示 300M，为什么这么大」。查下来不是泄漏也不是算错，是**口径**：
    `procx_scan` 原先枚举整个 `/proc`，凡是 comm 等于 `uya-agent` 的一律累加，
    于是**别的终端、别的 worktree、别的 `--web` 服务端**全算进这一条会话的数字里。
    实测同一台机器上 14 个同名进程 PSS 合计 338 MB，而本会话的进程树只有 9 MB ——
    一个**空闲**的 agent 显示「内存 300M」。这不是显示 bug：数字与它声称的口径一致，
    但那个口径对「我这条会话占了多少」这个问题是错的。
    修法：范围改成「本进程 + 它的后代里 comm 相同的那批」。两个细节值钱：
    ① **树判别必须沿所有进程的 ppid 走，comm 只在最后求和时过滤** —— 合成一个
    bool 就会切断 agent → `bash`（工具子进程，comm 不同）→ 嵌套 agent 这条真实存在的
    链（`bash` 里再跑一个 agent 是 workflow / selftest 的常规形态）；
    ② **`/proc` 的 readdir 不是拓扑序**，子进程可能排在父进程前面，所以标记要用
    不动点反复扫（一趟扫会漏链路中段，症状是数字偶尔偏小、复现不了）。
    判据：`cpu-live` 那条断言从「进程数涨」收紧成**严格相等**（`base + 1`）——
    写成 `>=` 的话，把全机同名都算进来这个老口径照样绿，而那正是这条 bug 的来源。

105. **「EOF 只认 `read == 0`」+ 水平触发的 `POLLHUP` = 主循环空转，页面上表现为「打不进字」**（P69，用户报的「web 页面不能输入」）：
    现场：用户开着三台 `--web`（8834/8836/8837），每台 **CPU 99.8%**、`/proc/<pid>/io`
    的 `syscr` 各 **20 亿**次而 `syscw` 只有 5～9（纯忙等），每台底下各躺一个
    `<defunct>` 僵尸子进程（退出码 130/143 = 128+sig，是 sigx 那条「128+信号」的路）。
    页面上：`POST /api/input` 照旧回 `{"ok":true}`（我用 CDP 抓过，浏览器**确实**发了
    `['h','e','l','l','o']` 五个请求），但屏幕一个字都不动 —— 看着连着，就是打不进字。
    根因是两件各自都成立的事叠在一起：
    ① **子进程死后 PTY master 上的 `read` 返回 `EIO`（errno 5），不是 0**。而
    `web_read_pty` 当初只把 `n == 0` 当 EOF，`n < 0` 一律当「EAGAIN，留着下一圈」
    （那条注释本身是对的：非阻塞 fd 上 poll 说可读之后 read 仍可能 EAGAIN）——
    于是死掉的会话**永远收不掉**。
    ② **PTY 从设备关了之后，master 上的 `POLLHUP` 是水平触发的**（实测 1 秒 62 万次
    `poll` 立刻返回），而 `master` 永不关闭 ⇒ 这个槽每圈都「就绪」⇒ `web_poll_once`
    空转：`read` 白读一次（EIO）、`web_push_all` 没有变化可推。用户看到的「打不进字」，
    只是这条忙等链的末端现象（帧的差分源 `emu` 再没被喂过新字节）。
    修法（`src/web/webpump.uya`）：把「PTY 读槽就绪」抽成 `web_pty_ready(t, i, revents)`：
    **先判 `POLLIN` 读干净，再判 `POLLHUP`/`POLLERR` 走 `web_pty_eof`**（关 master +
    `web_reap_child` 回收僵尸 + 清 `pid` + `alive=false`）。顺序不能反 —— 子进程退出前
    写出去的字节会让 poll 同时给 `POLLIN|POLLHUP`，读空之后才只剩 `POLLHUP`（实测），
    反了就会丢掉最后一帧。
    收到之后**必须把 `pid` 清零**：`web_pty_close`（退出收尾）会 `kill(-pid)`/`kill(pid)`，
    而 pid 已被内核回收、可能被复用 ⇒ 留着它就是**误杀别人**（`web_reap_child` 因此
    返回「这次真收到了没有」，只有真收到才清）。收不到（子进程还活着、只是关了 tty）
    才留着 pid —— 那种情况 kill 才是唯一能收干净的路。
    判据：`web-pty` 轮（`make web-selftest`）真 fork + 真 PTY 走一遍主循环用的那一支，
    断四条 —— ① 退出前那一段输出在网格里（钉顺序）② 收口（`alive=false`、`master=-1`、
    `pid` 清零、子进程不再是僵尸）③ **循环有限圈内结束**（不忙等）④ 幂等。
    防假绿对照：把 HUP 那一支摘掉重编 ⇒ 当场红五条（`循环圈数=64 master=5`），
    这正是用户那三台实例的状态。
    同族：`shellx.uya:357` / `gitx.uya:363` / `search.uya:89` / `jobs.uya:163` 本来就是
    「`POLLIN` 或 `POLLHUP` 或 `POLLERR`」三条一起认的，只有 web 这条漏了 HUP。
    教训：**「非阻塞读返回负数」有两个完全不同的原因（EAGAIN / 对端没了），
    只认 `read == 0` 收不到第二种** —— 判死要靠 `poll` 的 `POLLHUP`/`POLLERR`，
    而不是靠 `read` 的返回值。

106. **「空帧判据」的字面量长度写错一位 ⇒ `srv_find` 恒命中 ⇒ 首帧之后一帧都不推**
    （用户报的「web 页面不会实时刷新」）：
    现场：页面能打开、首屏能出来（标签、输入行、脚注都在），之后**再也不动** ——
    打字没有回声、跑起来的输出不出现、`+` 新建的会话也是一屏空白。
    `strace -f` 把这条链钉到了很具体的一步：`POST /api/input` 照旧回 `{"ok":true}`、
    父进程也把按键**真的写进了 PTY**（`write(6, "H", 1)`）、子进程也**真的重画了那一行**
    （`write(6, "\33[18;1H\33[2K …Z …")`）、父进程也**真的读到了**
    （`read(6, …) = 165`）—— 但父进程**再没有往连接 fd 写过一个字节**
    （`/proc/<pid>/io` 的 `syscw` 停在首帧那一次）。帧算出来了，只是被丢了。
    根因是 `web_push_frame` 里那个「空帧判据」：
    ```uya
    srv_find(frame, "\"rows_changed\":[]" as &const byte, 16) >= 0
    ```
    那个字面量是 **17 字节**（`"rows_changed":[` 占 16，再加 `]`），而传进去的长度是
    **16**。`srv_find` 拿「17 字节的样式」去比帧里前 16 个字节：真正的 `[]` 永远比不中
    （第 17 个字节没参与），却在 `"rows_changed":[` 这种**前缀**处命中 —— 而每一帧里
    都有它 ⇒ **判据恒为真** ⇒ `!full && emu_frame_is_empty(&frame)` 把**每一帧**都
    当空帧丢掉。首帧 `full = true` 所以发得出去，之后就再也没有第二帧，症状与现场完全对上。
    修法不是「把 16 改成 17」（那仍然脆弱：判据是**在拼好的字节里找特征**，而特征是自己
    拼的、格式一改就再一次静默失效），而是**换成结构判据**：`emu_frame_changed(g, scratch)`
    直接比「行文本 / 光标位置（行 + 显示列）/ 光标可见性 / 行数 有没有变」，
    `web_push_frame` 只在它返回 true 时组帧。三个附带的东西一起修：
    * **光标必须参与「变了没有」**：在输入行里按 ←/→ 只改光标、**一行文本都不改**
      （实测子进程那侧只写 `ESC[18;8H ESC[?25h`，没有任何一行重画）。老判据只看行文本，
      这种帧本来就该发（页面上那个光标块不动，用户同样会读成「卡住了」）。
    * **`emu_snapshot` 必须等所有订阅者都发完再调**：差分基准（`s.emu.prev`）在**会话**上，
      老顺序是「给第一条连接推完就 `emu_snapshot`」⇒ 同一会话的**第二条**连接（同一个页面
      开两个、或刷新后旧连接还没断）永远算成「没变」，一个字节都收不到。现在是
      `web_push_session`：本轮先算一次 `changed` → 发给每个订阅者 → 最后快照。
    * **新订阅要先补一帧全量**（`WebConn.need_full`）：回放的那 4 帧是「最近的帧」，
      **不保证含全量帧**；只吃差分的话，从上一帧起没变过的那些行永远补不上
      （刷新页面后只有零星几行）。
    判据：`web-frame` 轮（`make web-selftest`，管道当连接、不 fork）走生产代码真用的
    `web_push_session` / `web_push_frame`，断五条 —— ① 首帧是全量且给所有订阅者
    ② 文本变了要推且帧里有那一行 ③ **只动光标也要推** ④ **真没变一个字节都不推**
    ⑤ 两条订阅者都拿到。防假绿对照：把老判据（16 字节那版 `srv_find`）装回去重编 ⇒
    当场红三条（②③⑤），正是用户那个现场。
    教训（与踩坑 105 同一个形状）：**「在输出字节里找特征」当判据 = 判据的正确性绑在
    拼串格式与那个手写长度上，错一位就静默翻转**。结构上能问的问题（网格变了没有）就去
    问结构；`srv_find` 只该用在「找的是对端给的、我们控制不了的字节」上。
    同类自查：`grep -n 'as &const byte, [0-9]*'` 把长度与字面量逐个人工对一遍 ——
    本仓还有几处这样的手写长度（如 `imgx.uya` 的 `.jpeg` 那两行）。
107. **编译器的「固定容量表」又撞了两次 —— 报错点在别的文件里，根因是表满了**（P70）：
    这一轮加 4 个插件文件（+ 1 个自测文件）时连撞两条容量上限。它们本来就有
    （§2.3 那张表记的是「已修」的那几条），但**余量在这轮被吃穿**了：

    | 表 | 常量 | 基线用量 | 症状 |
    |---|---|---|---|
    | 顶层函数 **call edge** 表 | `MAX_FN_CALL_EDGES = 16384` | **16336**（余 48 条） | 报「顶层函数 call edge 容量已满」，报错点在**标准库**（`std/http/uyagin.uya` 等） |
    | 顶层变量**类型查找**的降级路径 | `C99_MAX_GLOBAL_VARS = 512`（**缓存**，满了不登记是设计） | 顶层全局 771 → 783 | 报 `'struct uya_slice_int32_t' has no member named 'ptr'`，报错点在**与改动毫无关系**的 `agent/ag_tui_sessions.uya` 的 `sess_cell_has_title` |

    第一条的实测边界（`uya build` + 清缓存）：加 48 条边通过、64 条红。
    修法：`fn_call_edge_from/to` 改成 `&(&ASTNode)` 指针表 + `fn_call_edge_capacity`，
    满了按 2 倍扩（`checker_grow_call_edges`）—— 与 `c99_grow_reachable_functions`
    （提交 `1267dbc6`）逐条对齐；`MAX_FN_CALL_EDGES` 降级为「**初始**容量」。

    第二条更阴：`c99_emit_global_variable` 的注释写着「这张表是缓存，满了降级，
    按名查找会退回 `program_decls` 线性扫描」—— 但**只有「名字」查找有那条兜底，
    「类型」查找（`lookup_identifier_type_c_impl`）没有**。于是表满之后
    `get_identifier_type_c` 返回 `null`、`get_slice_struct_type_c` 落到默认的
    `uya_slice_int32_t`，而**切字符串字面量不受影响**（走 `AST_STRING` 分支，不查表）
    —— 全仓只有一处「切一个具名常量」：
    `find_sub(line, &SESS_TITLE_KEY[0: n], 0)`。改那一行就绿，但那是在应用层绕过编译器，
    换个地方这么写还会再踩；正确修法是把缺的那条降级补齐（提交 `15899366`）。

    **两条教训**：
    ① 「报错点与自己无关」现在有两个家族 —— 一是**函数/可达集合**类（§16 踩坑 87），
    二是**表满之后的类型推断退化**（本轮）。两者的共同判据是：**报错文件里没有你的改动**
    且 `make check` 与增量编译全绿、只有清缓存重编（或加了文件之后）才炸。
    ② 修的时候要问「这张表该是缓存还是该是上限」：call edge 表**是**上限（丢边=可达集合
    静默变小，症状是链接期 undefined reference，比报错难查得多）⇒ 扩容；
    顶层变量表**是**缓存（满了降级是设计）⇒ 补降级路径，不动 `C99_MAX_GLOBAL_VARS`
    （试过把它抬到 4096/2048，结果是编译器**自己**编不过 ——
    同一个洞在 `src/checker/symbols.uya` 的缓存比较里又露一次）。

108. **自测夹具用相对路径 ⇒ 单跑绿、整轮红**（P70，本轮被 `make selftest` 当场抓住）：
    MCP 那三条腿单跑（`UYA_SELFTEST_MCP_ONLY=1`）全绿，`make selftest` 整轮里却全红，
    报的是「夹具 server 写不出来」。根因：夹具落在**相对路径** `build/selftest_mcp/`，
    而整轮 selftest 里**前面好几轮会真的 chdir**（工作区那几轮、worktree 那几轮），
    轮到这条线时 cwd 早不是仓库根了。纯函数那条腿（`mcp-name`）仍然绿 ——
    正好说明红的确实是「夹具落盘」这一步，而不是实现本身。

    这条教训本仓**早就写着**（`st_pm.uya` 的 `pms_root`、`st_goal_worktree.uya` 的
    `wt_ws_pid` 都注明「用绝对路径，因为前面几轮会 chdir」），我第一版没照办。
    改法：夹具根改成运行期算出的 `/tmp/selftest_mcp_<pid>`，收尾 `pm_rm_rf` 清掉
    （与 st_pm 收它的 /tmp 根同一条口径）。

    教训：**改自测时，单跑绿不算绿** —— 与「净增函数要清缓存重编」（踩坑 87）同族：
    凡是「只在完整流程里才暴露」的环境依赖（cwd、环境变量、上一轮留下的全局状态、
    构建缓存），都必须用**整轮**验证。本轮 `make selftest` 连跑两次都 PASS 才算数。

109. **「回合结束了没有」不能拿「屏幕上有 `轮 ·`、且没有 `运行中`」当判据**（既有 flake，本轮修）：
    `make e2e-model-route` 的尾判（「这一轮是不是 prov-b 答的」）原来这样等回合收工，
    实测**约 5% 假红**（基线 overlay 腿 104 次里 5 次；text 腿 32 次全绿 —— 同一个脚本，
    差别只在 `--mode`，正是「概率取决于赛跑」的样子）。

    根因是这条**否定式代理判据**在回合**半途**就成立，它的两半都如此：
    ① 脚注里的 `轮 · ` 是**回合一开始**就在的（第一轮就是 `1 轮 · 1 步`）；
    ② 状态区的词是「思考中 / 输出中 / 运行中 」（`term/tui/screen.uya` 的
    `tui_draw_status_block`）——**前两个都不含「运行中」**，而慢 bash 那条工具跑完之后
    状态正好回到「思考中」（在等第二条请求回来）。于是循环在答案上屏**之前**跳出，
    取样到一张还写着「思考中」的屏 ⇒ 报「不是 prov-b 答的」。

    **网关记账当场反证这是假红**：那 5 次里 prov-b 都收到了请求、带的也都是
    `Bearer key-of-prov-b`（`A=1 B=1`，只是 B 的第 2 条还没落地）。216 次运行里
    prov-a 收到请求的次数**每一次都是 1** —— 产品侧一个字节都没错，是判据取样太早。

    实测窗口（探针 64 次）：代理判据比答案早 **10.1 s** 成立
    （`t_heuristic=7654 t_answer=17742`）。修法：等**正面事实** `PROV-B-ANSWER`
    （它只可能由新提供方那条答复产生，正是这条腿要断言的语义）。修后 overlay 104 次
    + text 24 次全绿；**防假绿对照**（把切到 `b-two` 的两下 `↓` + 回车摘掉 ⇒ 请求留在
    prov-a）新判据 **4/4 照红**，说明它没被架空。顺带让失败时自动打屏：flake 的现场
    （那一刻屏幕上是什么）以前只有 `PTY_DUMP=1` 才有，定位一次要手工重跑好几轮。

    教训：**「没有 X」式判据要先问「X 不在的时候，还有谁会在」** —— 这里「运行中」不在，
    是因为状态行换用了同义的另一档词（思考中 / 输出中），不是因为回合结束了。
    要判「A 发生了」就等 A 本身（与踩坑 86「判据要读事实」、踩坑 96 同族：
    凡是靠**否定**或**代理**成立的判据，都要能说出「它成立时事实一定是什么」）。
110. **两条并行线各自取「下一个空号」⇒ 键事件码静默撞号，靠前的分支吃掉靠后的绑定**（修复，不占阶段号）：
    用户报「ctrl+v 变成全屏切换」。根因一行：`keys.uya` 里 `TUI_K_CTRL_V` 与
    `TUI_K_FULLSCREEN` **都是 30**，而分派是 if 链、全屏那条写在前面 ——
    ```uya
    if ev == TUI_K_FULLSCREEN { tui_overlay_full(-1); return; }   // 先命中
    if ev == TUI_K_CTRL_V    { g_tui_req = TUI_REQ_PASTE; }       // 永远到不了
    ```
    于是 ctrl+v（字节 0x16）命中的是全屏分支：有浮层就翻全屏，没浮层就落一条
    「现在没有浮层 —— 先开一个」的 notice。`tui_ov_key`（浮层内那条链）顺序相同，
    所以两种形态都错。**形状**：ctrl+v 的键语义是对的、透传也对，坏的是「事件码」这一格。

    **来历**（并行线静默合并）：`22dceaa`（P49 浮层全屏）分配 `FULLSCREEN = 30`；
    `5ef9053`（P51 ctrl+v）在**另一条并行线**上独立地也取了「下一个空号」30 ——
    两者都不是彼此的祖先（`git merge-base --is-ancestor` 两个方向都为假），
    合并时没有任何东西比对数值。原注释还写着「这里不会与既有绑定冲突（ctrl+v = 0x16
    走另一条）」：**字节不同不构成冲突，事件码也必须不同**，那句把两者当成了一回事。

    **为什么此前全绿**：撞码没有任何编译期信号（两个 `const i32` 同值完全合法），
    而 `tui-full` 的 B 段测的是 `ctrl+f`（0x06）与 `F11`，`tui-keys` 里**根本没有
    ctrl+v 的腿** —— P51 那条线加键时没补自测，两侧就都没覆盖到。与踩坑 94 同族：
    **「全绿」只覆盖被断言过的东西**。

    **修法**：`TUI_K_CTRL_V` 改成 **31**（移孤立的那一项，保住 `WHEEL_UP/DOWN/
    MOUSE_TOGGLE/FULLSCREEN` = 27/28/29/30 那条连续段；31 紧接其后不留空洞）。
    改前逐项确认过**没有任何地方依赖数值**：全仓没有序列化、没有按码索引的数组、
    没有 `ev >= / ev <=` 范围比较、`ev` 一律是 `i32`（不是 `byte`），
    所以改号的影响面只有它自己。

    **钉子三条**（`tui-keys` 轮）：①无浮层时 `"\x16"` ⇒ `tui_take_request()` 必须是
    `TUI_REQ_PASTE`；②浮层开着时按它**不许**动全屏态（直接复现用户症状）；
    ③**根因哨兵** —— 把全部 31 个 `TUI_K_*` 装进数组做 O(n²) 两两比对，撞号就报出
    两个下标与码值。第三条才是针对根因的：并行线再撞号时当场红，不必等用户来报。
    防假绿对照实验：只加测试不改常量 ⇒ 三条腿全红（哨兵报「下标 30/31 码值 30」，
    正好指到 `FULLSCREEN`/`CTRL_V`）；改回 31 ⇒ 全绿。

    顺带补了 `/help` 文案：此前**一个字节都没提** ctrl+v（ctrl+p / ctrl+t / F2 都在），
    键修好了却没人知道它存在；并按「改了 help 文案就要钉子」的惯例加了断言。
111. **网关认不出本仓客户端，于是「工作区」一列永远是空的**（P71，用户报的「不能识别
    uya-agent 客户端 / 不能识别工作区」）：
    现场（只读查 `aigw.db`）：`client='unknown'` **2118** 行 vs `dsh` **10** 行，而
    `workspace` 列**全库为空**。那 10 行 `dsh` 全是本仓的**标题**调用 —— 网关有一条
    「标题调用就是 DSH 调用」的兜底，把我们的标题行认成了 DSH（8 个 session id 逐个
    核对：6 个属 `~/.uya-agent`，另 2 个属真 DSH）。也就是说**唯一被认出来的那些行，
    认的也是错的**。

    根因有两层，第二层才是要命的那个：

    | 环 | 事实 |
    |---|---|
    | 1 | 网关的客户端词表**封闭**：`dsh / codex / console / unknown`（`internal/responses/dimensions.go`）。判定顺序是「正文结构优先，User-Agent 仅兜底」 |
    | 2 | 正文那条路要求首条 system 逐字以 `You are an AI agent powered by DeepSeek Harness.` 开头；我们的 persona 是自己的文案（`DEFAULT_PERSONA` / preset），**永远匹配不上** |
    | 3 | UA 兜底认的是 `deepseek-harness` / `dsh/` 子串，我们发的是 `uya-agent/0.1`（写死在 `net/httpc.uya` 的 `build_request` 里）⇒ 落 `unknown` |
    | 4 | **`workspace` 只在 `ClientCodex` / `ClientDSH` 两个分支里被赋值**（`dimensions.go` 的 switch）。走 `unknown` 就整段跳过 ⇒ 工作区维度恒空 |

    第 4 环是关键：它不是「少显示一列」，而是**一条请求被认成谁，决定了它的工作区还
    记不记得下来**。所以修「工作区识别」这件事，入口在「客户端识别」。

    第二半是工作区本身的**口径**：本机 `agent-presets.default: git-worktree`，顶层会话
    的 cwd 是 `<主仓>/.git/dsh-worktrees/session-<id>`（本会话实测：`previous=/home/winger/
    uya-agent` → `workspace=…/.git/dsh-worktrees/session-0f6f924a-…`）。每个会话一条唯一
    路径 ⇒ 工作区维度退化成会话维度（一桶一行）。要的是**归类到 git 主工作区**。

    修法（两条，都在本仓；网关侧一个字节不动）：
    * UA 改成 `uya-agent/0.1 (deepseek-harness-compatible)` ⇒ 命中 `deepseek-harness`；
    * `session workspace:` 机读句改报**归类键**（`pm_main_worktree_into`：linked worktree
      折回主工作区，普通仓库的子目录原样），人读的 `Current workspace:` 仍是字面路径。

    为什么不改 persona 去冒充 DSH：那是**假话**（我们不是 DSH），而且 persona 会进
    system prompt 影响模型行为 —— 为了一列统计去改模型看到的东西，代价与收益不成比例。
    UA 那条也刻意写成 `compatible` 而不是冒充：我们报的是「同方言」，不是「我就是它」。

    两条教训：
    * **「客户端认不出」与「工作区为空」是同一个 bug**：维度之间可能有这种隐式依赖
      （一个维度为空，是因为另一个维度没认出来）。查这类现场要先问「这条维度在代码里
      是哪几个分支里赋值的」，而不是先怀疑采集。
    * **UA 这类「线上字节」必须有断言**：它写死在 `httpc.uya` 里，改前全仓**没有任何
      测试看得见它** —— 与踩坑 94（`=======` 残留）/「净增函数」（踩坑 87）同族：
      没有断言的产物，全绿不代表它对。本轮补了 `mock_mode 25` 的 UA 断言（先验红：
      改回旧 UA ⇒ `verdict 204` + `SELFTEST FAIL`）。

112. **布尔的能力申报装不下「只认三档」—— 网关说 `reasoning: true`，模型却拒收一半档位**（真机，本轮踩到）：
    本轮给本机网关照单加两个 AutoDL 模型（`GLM-5.3-flash` / `hy4-preview`，改动在
    `~/ai-gateway` 与本仓文档，见 §19 的验收记录）。实测 `GLM-5.3-flash` 时撞到这条：
    它对 `reasoning_effort` **只认 `low` / `high` / `max`** —— `none` / `minimal` /
    `medium` / `xhigh` 一律 `400 param=reasoning_effort`（每档重复 3 次一致），
    并且**拒绝** `{"thinking":{"type":"disabled"}}`（「该模型始终思考，不支持关闭思考」）。

    **形状**：网关（以及本仓的目录）的能力申报是**布尔**的 —— `capabilities.reasoning: true`、
    `reasoningEfforts` 是一个「档位集合」。而「支持思考」与「支持哪些档位」是两件事，
    前者装不下后者。于是任何「照抄全集」的档位表都会让用户选中一个**必然 400** 的档位：
    网关侧 `degradation: strip` 只标记不剥离，请求照样带出去，错误原样透出。
    这不是网关的 bug（它没有表达力去说「只认三档」），是**「能力申报只有布尔」与
    「档位是一张表」之间的口径缺口**。

    **本仓的处境与处置**：不发明档位这条规则（见 `session/modelx.uya` 文件头与
    README「模型选择」一节）本来就要求**按模型公布的档位选**，而 DSH 的
    `settings.yaml` 里那个 `reasoningEfforts:` 映射**恰好是逐模型写的** —— 也就是说
    表达力在本仓这边是够的，缺的只是「照抄全集」这个坏习惯。所以处置是**文档口径**：
    README 的模型一节写明「档位表必须按上游实测填」，并在真机 `aigw-local` 条目里
    给这个模型只写 `{low, high, max}` 三档。

    **同族的另一条观察**：同一批里 `hy4-preview` **任何请求都 402**（腾讯侧免费额度用尽、
    未开后付费），三条路都一样，连参数校验都到不了 —— 于是能力**一个都测不出来**。
    这时「申报为空」与「申报成 text-only」的区别就是本条的另一种形态：网关把空能力读作
    **未知 → 不拦**，而写死一个猜测等于替上游下一个它没被要求做的决定。所以那一行的
    `capabilities` 留空，等能真发出请求再补。两条合起来是同一个教训：
    **申报的粒度不够时，宁可留白也不要填一个自己没测过的值**。

    **本条自己又踩了一次踩坑 110**：它最初写的是 **111**，而并行线（P71）也取了 111，
    合并后 §16 里出现两个 111（`git log` 里三条同标题提交就是那次合并的形状）。
    这与 110 是**同一个机制**：两条线各自取「下一个空号」，没有任何东西比对数值；
    区别只是 110 的代价是运行时行为（键码撞号），这条的代价是文档编号。
    处置沿用本仓已有的先例：**后落地的让号**（`da36d61`「main 已占 109，本线的撞号条
    记成 110」、`bf396f7`「并行线已占 109/110，本线顺延为 111」、`fd0e81e`「81 被 main
    的提问弹窗线占了，本线改为 82」—— 同一个动作在本仓已经做过至少三次）。
    本线改成 **112**，三处交叉引用一并改掉。
    顺带一提：`make lint-size` / `doc-audit` 都看不见这件事 —— 编号撞号没有任何检查器，
    与 110 的「两个 `const i32` 同值完全合法」是同一类盲区。

112. **同一份坐标被当成三种单位用（格 / 码点 / 显示列）⇒ 浮窗右边框逐行参差、样式贴到错字上**
    （本轮，用户报的「窗口的右边没有对齐」+「命令列表显示的输入文本也不正确」）：
    现场：web 页面上的命令面板，右边框**逐行参差**（实测右边框 x 坐标从 96.86 到 101.95，
    spread **5.08 格**，而服务器画的是一个矩形）；长中文过滤词那一行，`命令 › <过滤词>▌`
    里**只有头三个字**带着过滤样式，后面的字、插入点 `▌`、右边框全掉成默认色。

    根因是段表 `[起始列, 列数, …]` 里那个「列」**三种单位都不是**，是第四种：
    `emu_seg_bounds` 按**格子**走，`emu_cols_span` 又把每格的宽度累加一遍 ——
    一个汉字占「首格(宽 2) + 续格(ch=0，被数成 1)」= **3**，于是整行列数比真实显示宽度
    **多出「汉字个数」**。实测 100 列的屏：row4 段列数合计 **170**，真实 **151**，差 19 = 该行汉字数。
    前端拿这两个数去 `text.slice()`（JS 的**码元**下标）⇒ 两件事同时坏：
    ① 样式贴到错字上（实测一次抓包里 18 个边框字没拿到 accent 色、44 个码点样式不符）；
    ② 每行多算几列 ⇒ 右边框逐行参差。

    同族的第三处：`emu_cursor_col` 也把续格算了一列。实测输入 `ab中文cd`，帧里报 `col=16`
    而真实是 **14** —— 插入点比字右偏 2 列。

    **修法**（`src/web/ttyemu.uya`）：段表改成三个量分开 ——
    `[起始码元, 长度码元, 显示列数, attr, …]`。前两个是**前端切片用的单位**
    （JS 字符串是 UTF-16，BMP 外算 2 —— 实测输入框里真会出现 `😀`，按码点算会切出半个
    代理对，浏览器显示 `�`），第三个是**显示列数**（只用来排版）。段在**宽度类**变化处切开，
    前端对含宽字符的段钉死宽度并补 `letter-spacing`。

    判据是 `web-seg` 轮（纯服务端，不依赖浏览器）：段首尾相接、**整行段列数合计 == 该行
    真实列宽 == cols**、每段只含一个宽度类、段边界落在字符边界上（切不出半个代理对），
    并且**真实捕获的 TUI 帧**也满足同一组（同源）。
    **防假绿对照**：把 `emu_cols_span` 改回「续格也数一列」重编 ⇒ 当场红
    （「段的显示列数与它切出来的文本不符」）。

    教训：**凡是「一个整数 + 一个单位」传到另一个进程的地方，都要把单位写进字段名**
    —— 这条链上有三处各算各的（格子 / 码点 / 显示列），而它们在 ASCII 行上**数值恰好相同**，
    所以只测纯英文永远发现不了。判据必须**喂宽字符**。

113. **高亮画不出来是两个坑叠出来的：`filter:invert` 在透明底上等于不可见 + 差分判据看不见纯样式变化**
    （本轮，用户报的「弹窗里的列表按键选择后没有高亮」）：
    这个症状要**两个**根因同时具备才成立，各自都够隐蔽：

    ① **画不出来**。CSS 是 `.rv{filter:invert(1)}`。`filter` 只反色**元素自己画出来的
    像素**，而那个高亮块的背景是透明的 —— 暗底没被画上去，反色后就是「暗字 + 暗底」。
    实测：`.rv` 的 rect 里 15180 个像素**只有 52 个**与背景不同、**0 个**接近反色后的
    底色；单独做的对照页里 `.rv` 行的文字像素 **0**，而普通行 1075。反显（SGR 7）在终端里
    就是「亮底暗字」，照那个语义写成 `background:var(--fg);color:var(--bg)` 即可
    （它必须排在那 32 个颜色类**之后** —— 同权重下后写的赢）。

    ② **推不动**。空帧判据 `emu_row_diff` **只比行文本**，而浮层里按 ↑/↓ 只换 SGR、
    **一个字符都不改** ⇒ 判成「没变」⇒ 不推帧。实测：长连接上连按 3 次 ↓，推出去的三帧里
    `rows_changed` **只有光标那一行**，没有任何一行带反显属性 ⇒ 已连着的页面高亮**永远停在
    原处**（刷新一下就好 —— 因为新连接走 `need_full` 全量帧，这也正是「刷新能好」的原因，
    是最容易把①漏掉的那种现象）。

    修法②：`EmuGrid` 加一份 `prev_st`（样式游程基准），`emu_row_diff` 文本与样式**两份都比**。
    为什么不是哈希：哈希碰撞只会少推一帧，而且是个静默判据；逐游程字节串是精确的。
    为什么不做「样式版本号」：那要每次写格子都维护，多了个能忘掉的状态。

    判据：`web-frame` 轮加第 ⑥ 条 —— **同一段文本重画一遍、只加 `ESC[7m`** ⇒ 必须推帧，
    且帧里那一行**真的带 `attr=16`**（只断「推出了字节」会退化成「只要推了就算对」；
    判据走**解 JSON** 逐段看 attr 位，不在字节里找特征串 —— 踩坑 106 就是那么翻车的）。
    再加 ⑥b：样式也没变 ⇒ 仍然一个字节都不推（样式基准要跟着收）。
    `web-page` 轮钉住「页面里不许有 `filter:invert`、必须有反显规则」。
    **防假绿对照**：把 `emu_row_diff` 改回只比文本 ⇒ 当场红（「只改样式就一帧都不推」）。

    教训：**「屏幕上变了没有」这个问题，答案是「渲染出来的东西变了没有」** ——
    文本只是它的一部分。判据漏掉哪个维度，那个维度上的变化就变成静默失效。
    同族要注意的还有：`web_t_frame_has_reverse` 第一版拿**整段**管道数据去 `js_parse`，
    而读端可能停在上一帧的半截上（实测帧前面残留着 `ae`）—— 逐行解才是对的。
114. **ctrl+t 没有反应：三条各自独立的静默路，症状一模一样**（修复，不占阶段号；
    用户报的「ctrl+t 没有反应」）：
    真 PTY（main 的二进制 + 假网关）逐场景按键复现出**三条**路，屏幕上的表现完全相同 ——
    「按了 ctrl+t，一个字节都不动」：

    | # | 现场 | 实测 | 根因 |
    |---|---|---|---|
    | ① | **回合运行中**按（bash / 流式 / 等响应头跑着时） | 3 s + 3 s 两次按键后屏幕**零变化**；esc 中断回合之后箱体才出现 —— 两次按键被压成一次 | 键层只置 `TUI_REQ_TASKS`，而**全仓唯一的消费者**是空闲主循环：回合期间主循环整段不跑 |
    | ② | **空态屏**（刚启动 / `/new` 之后）按 | 即使目标 / 清单非空也零变化 | `tui_build_home` 里一行恒零（`g_tui_tasks_n = 0`），块根本不画 |
    | ③ | **四张表全空**时按 | 永远静默：不画东西，也没有一句回话 | 块文本零字节，展开与收起在屏幕上没有可观察差别 |

    ①是主因，形状与踩坑 44 / 73 同族：**键语义、透传、消费者三截里坏的是「谁去消费」那一格**。
    回合里确实在读键（`agent_pump_block` → `tui_abort_check` → `tui_tick` → `tui_poll_keys`
    → `tui_handle_keys`，请求被老老实实置上了），但那条路上**没有一个人看 `g_tui_req`** ——
    与踩坑 44 的「键收下来了但没人看」是同一个形状。修法也沿用本仓既定套路：**在泵点当场消费**
    （`agent_pump_block` 里取一次）。

    **为什么只有 ctrl+t 能享受泵点待遇**（这条边界比修法本身更重要）：它**一个字节都不改历史** ——
    只翻一个显示位 + 重建一张只读文本（`tasks_panel_sync` 在 TUI 下只 mark dirty，零 IO）。
    tab（plan）/ shift+tab（access）**不行**：那两个会 `hist_push` 一份运行时快照进**正在被这一
    回合使用的** History。所以泵点上的取用口必须是**只认 TASKS**的那一个（`tui_take_tasks_request`），
    不能图省事写 `tui_take_request() == TUI_REQ_TASKS` —— 那个出口会把**任何**请求一并取走，
    等于把还挂着的 plan / access / ctrl+v 悄悄吃掉（钉子直接钉住这条：泵点跑完，
    `tui_take_request()` 还得能取到 `TUI_REQ_PLAN_ON`）。

    ②的修法是把 chat 里画块那一段**原样抽成** `tui_draw_tasks_block`，home 与 chat 共用；
    行预算也收口成 `tui_tasks_prepare`（两个屏的块高算法只留一份，否则迟早漂移）。
    ③补一句 notice（「四张表都空 —— 展开也没有内容可看」）：**绝不静默**是踩坑 73 定下的口径，
    一个什么都不画的按键最容易被当成坏了。

    **钉子四条**（`tui-tasks` 轮新增 E 段 + `make p30-check` 第 10 场）：
    ①帧级 —— 运行中只调 `agent_pump_block()`，展开态必须当场翻转、请求被消费掉，重画后箱体在屏上；
    ②帧级 —— 无转录时块照样画、按得动，且面板不被顶掉、整屏仍铺满 rows 行；
    ③帧级 —— 四表全空时必须多出一条 notice（`tui_entries_count` + 文案扫屏）；
    ④真 PTY —— 回合运行中按 ctrl+t，`┌─ tasks ` ≤1.5 s 上屏**且那一刻 `SELFTEST_OK` 还没到**
    （＝不是「回合跑完才补画」，实测 101 ms），再按一次收回折叠行。

    **防假绿对照实验**（三条各自单独回退都当场红）：①摘掉泵点那次消费 ⇒ 帧级①与 PTY 腿红；
    ②把 home 的 `g_tui_tasks_n = 0` 改回去 ⇒ 帧级②红；③去掉空文本 notice ⇒ 帧级③红。
    既有判据一条不动：`--tui-demo` 七屏与修前**逐字节相同**（四张表全空时 home 排版零漂移，
    这条本身就是「没有回归」的机器判据；`tui-frame` 的空态居中、`tui-switch` 的 D 段也全绿）。

    教训：**「按了没反应」要先问「这个键的消费者是谁、他在不在跑」**。同一个键在三处可用性
    不同的现场（空闲 / 运行中 / 空态）表现可以完全一致，而根因是三件互不相干的事 ——
    只修主因的话，用户下次在空态屏上按同一个键，报的还是同一句话。

114. **表内下标被当成会话身份 ⇒ 关掉前面一条，后面的订阅者永久冻死**（本轮，用户报的
    「点 x 关掉一条会话之后别的标签就不动了」）：
    现场：浏览器里开着 5 条会话，订阅最后一条；`POST /api/close` 关掉**第一条**之后，
    那条长连接**再也不出一帧**（实测：关之前 `frames 5 -> 6`，关之后 `6 -> 6`，而给
    被观察的会话发输入、服务端网格确实变了）。页面表现为**永久冻死**，刷新一下才好
    （因为新连接重新记了下标）。

    根因是**同一个东西被当成两种东西用**：`WebConn.sess` 存的是**表内下标**，而
    `web_remove_at` 会让被摘条目**后面的所有条目整体前移** ⇒ 「连接记的 4」在关掉下标 0
    之后就指向了另一条会话（原来的 3）。推帧照旧推，只是推给了错的那条；真正在看的这条
    因为「没变」而一个字节都收不到。

    这是一个**形状**问题，不是某处的笔误：位置（下标）会随任何一次删除漂移，而身份
    （会话 id）不会。修法：
    * `web_conn_wants(c, s)` —— 订阅匹配一律比 `c.sid` 与 `s.id`（id 是服务端预生成、
      且同一个 cwd 下唯一的，见 §11.8.1），`WebConn.sess` 字段**直接删掉**（不留第二份
      身份状态，否则迟早又有人去读它）；
    * **摘表只发生在一圈就绪 fd 全部处理完之后**（`web_sweep_closed`）：主循环手上的
      `idx[]`（poll 槽 → 会话下标）也是移动前的旧下标，处理途中摘表会让剩下的槽读到错的
      会话。`POST /api/close` 因此只打 `close_wanted` 标记，真正摘表交给那一圈的末尾。

    判据：`web-frame` 轮第 ⑦ 条（订阅 B、`web_remove_at` 摘掉前面的 A ⇒ B 前移到下标 0，
    此后「没变不推、改了 B 必须推到」两条都要成立）。**防假绿对照**：把匹配改回按下标
    （或让 `sid` 写一个永不匹配的串）⇒ 当场红两条。

    教训：**凡是要「以后还能找到它」的东西，存身份不要存位置**。同族的还有：`c.sess`
    这种「缓存下来的下标」在同一个结构体里与 `sid` 并存时，两个字段迟早会各说一套。

115. **只记「活着 / 不活着」两态 ⇒ 分不出「用户 /exit 了」与「它崩了」**（本轮，用户报的
    「exit 之后标签不关」）：
    现场：TUI 里打 `/exit`（或 ctrl+d、命令面板里选中 `/exit`），页面上那条标签**还在**，
    只是点它没反应 —— 想关只能手点 `x`。老实现的口径是「子进程死了就留着标签看最后一帧」
    （那条口径本身是对的：崩掉的会话，用户得能看见它最后说了什么）。

    根因：`web_reap_child` 把 `sys_waitpid` 的 **wait status 丢掉了**，于是上层只知道
    「收到了」，不知道「它自己退的（exit 0）还是被信号杀的」。两态装不下三种意思
    （还在跑 / 用户退了 / 崩了）。

    修法：把 wait status 交出来（低 8 位是终止信号、次高 8 位是退出码，**两个都是 0** 才叫
    正常退出；实测 `/exit`、ctrl+d、面板选中 `/exit` 三条路都是 exit code 0），
    `WebSession.close_wanted` 只对**正常退出**置位，由 `web_sweep_closed` 摘标签；异常
    照旧留标签与最后一帧。收摊时还要**先给订阅者写分块终止块**（`srv_send_end`）——
    不写就是一段被截断的分块体，浏览器那边报 network error，前端就没法把「会话结束」与
    「连接坏了」分开。

    判据：`web-exit` 轮两条腿（正常退出 ⇒ `close_wanted` + 表里没有 + 订阅连接关掉 +
    管道里有 `0\r\n\r\n`；被 SIGKILL ⇒ 不置位 + 表里仍在）。**防假绿对照**：把
    「正常退出才置位」改回「一律不置位」⇒ 当场红四条。

    教训：**系统调用给的信息，别在包装层就丢掉**。`waitpid` 的 status 是唯一能回答
    「怎么没的」的东西，丢一次就再也补不回来。

116. **`keydown` 是唯一输入通道 ⇒ 浏览器里一个字的中文都进不来**（本轮，用户报的
    「web 不能输入中文」）：
    现场：页面能打 ASCII、能按方向键，但**中文一个都进不去**（连拼音字母都不出现）。
    实测：页面里 `document.activeElement === BODY`、没有任何可编辑元素；
    `Input.insertText('你好世界')`（= IME 提交的真实路径）走完全程，PTY 那一侧
    **一个字节都没收到**。

    根因是**通道选错了**：中文不是按键 —— 输入法在浏览器里走标准 IME 流程，候选词提交时
    给的是 `compositionend` / `input` 事件（`e.data` 才是真文本），而 `keydown` 看到的只有
    `"Process"`（或候选期间那几个拼音字母）。而 IME 事件**只投给可编辑元素** —— 一个只
    监听 `keydown` 的 `<div>` 永远收不到。

    修法：在终端区里放一个**真 textarea** 当代理（透明、1px、`caret-color:transparent`、
    钉在光标格上让候选窗跟着光标），输入分两条路且绝不重叠：控制键/功能键走
    `keydown` + `keyBytes`（ESC 序列），可打印文本（含中文、表情）走 textarea 的
    `input` / `compositionend`。三条纪律缺一条就是新的 bug：
    ① 可打印字符**只走一条**（`keyBytes` 里删掉「单字符直接返回」那条兜底 —— 留着就双发，
       一个 `a` 变成两个）；
    ② 预编辑期间**不发送**（`composing` 或 `inputType === 'insertCompositionText'` ——
       拼音字母在候选期间也触发 `input`，发出去就是输入行里一串拼音）；
    ③ 键盘事件在预编辑期间**整条丢掉**（`composing || e.isComposing || keyCode === 229`）——
       不丢的话「回车确认候选词」会被当成交付键，把半截拼音提交出去。

    顺带把粘贴接上：`paste` 包成括起粘贴 `ESC[200~…ESC[201~`（TUI 侧已有粘贴态，
    粘几行不会提交几次）；`ctrl+v` **放行给浏览器** —— 终端里的 ctrl+v 读的是服务端那侧的
    X11 剪贴板，web 服务端没有 X 连接，那条路在网页上永远是空的。

    判据：`web-page` 轮四条字节判据（有 `id="ime"`、有 `compositionend`、有
    `insertCompositionText`、**不许**再有 `e.key.length===1` 那条兜底）；
    **防假绿对照**：把单字符兜底装回去 ⇒ 当场红一条。真机侧用 headless chromium 的
    `Input.imeSetComposition` + `Input.insertText` 走一遍，看中文是否出现在 TUI 输入行。

    教训：**「输入」在浏览器里不是一个概念，是三个**（按键 / 文本提交 / 粘贴）。
    只接一个通道，就意味着某类用户（这里是非拉丁语系）**完全不能用**。

117. **新建会话不带尺寸 ⇒ 新标签先按默认画布起，而且页面根本不会去订阅它**（本轮，用户报的
    「新建会话没有 tty / 宽度不对」）：
    现场：页面上量到 176×48，点 `+` 建出来的会话服务端记的是 **100×30**，新标签的屏幕
    **一片空白**；要切到别的标签再切回来才出画面（那时才被 `/api/resize` 追上）。
    两个独立根因**叠在一条路上**：

    ① **尺寸没传**：`web_ep_session_new` 恒定把 `EMU_DEF_COLS/ROWS` 交给
       `web_session_new`（那个函数的注释还写着「用请求体里给的尺寸」，而代码根本没读）。
       于是子进程按 100×30 起了 TUI，先给用户看一屏错宽度的画面。
    ② **页面不会去订阅新会话**：`refresh()` 里的条件是 `(!es || es.signal.aborted)` ——
       `+` 之后 `cur` 已经指向新会话，而**旧的长连接还活着**（`es` 非 aborted）⇒ 判据为假
       ⇒ 既不建流也不报尺寸。于是新标签永远空白，直到用户手点一下标签（那条路才
       `subscribe()`）。

    修法：前端 `+` 时把 `measure()` 的格子数拼进 `POST /api/sessions?cols=&rows=`（服务端
    过 `web_size_clamp` 统一夹取，与 `emu_init` 同源），并在 `+` 之后立刻
    `cur=j.id; esid=null; refresh()` 强制重订阅；判据从「有没有流」改成「**流订的是不是
    `cur`**」（新增 `esid`）。

    判据：`web-size` 轮（报 150×40 ⇒ 会话记 150×40 且 **PTY 窗口也是** 150×40；不报用
    默认；超上限夹到 `EMU_MAX_*` 且与网格一致）+ `web-dispatch` 轮那条带
    `?cols=150&rows=40` 的真分派 + `web-page` 轮钉 `esid`。**防假绿对照**：① 端点不读
    query ⇒ `web-dispatch`/`web-size` 当场红；② `web_session_new` 忽略参数 ⇒ `web-size`
    红三条（含 PTY 那条）。

    教训：**「错的首屏」与「根本没有首屏」是两个 bug，别把后者当成前者的后果**。这里修了
    尺寸只解决第一个：第二个（不订阅）与尺寸无关，是拿「流在不在」当了「订阅对不对」的
    判据 —— 与踩坑 114 同一个形状（用错的东西当身份）。
     教训：**断言必须只有一条路径能满足它**。写「A 应当被拒」时先问一句：除了 A 之外，
     还有谁会拒绝？有第二道闸门挡着的时候，第一道闸门是死是活测不出来。

118. **`SO_REUSEADDR` 的常量抄成了 BSD 值 ⇒ Linux 上一个选项都没设上，而失败被
    `catch {}` 吞掉**（本轮，用户报的「运行 web 后 ctrl+c 报的错」）：
    用户的原话是「运行 web 后，ctrl+c 后报的错」：
    ```
    uya-agent --web
    error: web 监听失败（端口被占用？换个端口：--web 127.0.0.1:0）
    ```
    第一直觉是「有谁还占着端口」，但 `ss -ltnp` 里那个端口**一个监听者都没有** ——
    真正占着它的是两条 `TIME_WAIT`（`127.0.0.1:8787 -> 127.0.0.1:xxxxx`，服务端那一半）。

    根因在 `src/net/httpsrv.uya` 两条手写常量：
    ```uya
    const SRV_SOL_SOCKET: i32 = 0xFFFF;     // ← BSD/macOS 的值
    const SRV_SO_REUSEADDR: i32 = 0x0004;   // ← 也是 BSD 的值
    ```
    Linux 是 `SOL_SOCKET = 1` / `SO_REUSEADDR = 2`（`asm-generic/socket.h`；libc 的
    `libc.syscall` 里本来就按目标平台分好了叉，本仓**偏偏手抄了一份**）。用错值时
    `setsockopt(fd, 65535, 4, …)` 以 `ENOPROTOOPT`（Protocol not available）失败，而
    `srv_listen` 的调用点是 `catch {}`（那条 `catch {}` 本身是对的：没有这个选项最坏
    只是「重启要等 TIME_WAIT」，不该阻断监听）—— **于是监听套接字一个选项都没设上，
    而且没有任何人知道**。

    复现与对照（**同一个二进制、只改这两行常量重编**，各 4/4 次）：

    | 场景 | 现状 | 改常量后 |
    |---|---|---|
    | 开一次页面 + 一条 `/api/screen`，ctrl+c 后 TIME_WAIT 条数 | 2 | 2 |
    | 紧接着用**同一个端口**再跑 `--web` | **监听失败**（4/4） | 打开成功（4/4） |

    为什么「只有 ctrl+c 之后才炸」：`TIME_WAIT` 是**先关连接的那一侧**留下的，而 web
    服务端每响应一个请求就 `Connection: close`（httpsrv 不变量 ①）⇒ 每个请求都在监听
    端口这一侧留一条 `TIME_WAIT`，浏览器开着页面时它们不断累积；进程活着时无所谓
    （监听套接字还在），**进程一退，那些 TIME_WAIT 就成了端口的新占用人**。用户提示
    里的「换个端口」能绕过（换了端口就没有 TIME_WAIT），这正是它看起来像「端口被占用」
    的原因 —— 而 `SO_REUSEADDR` 存在的全部理由就是绑回一个只剩 TIME_WAIT 的端口。

    修法三条（缺一条都会再静默一次）：
    ① 常量改成取 libc 的 `SOL_SOCKET` / `SO_REUSEADDR`（跨平台的分叉在 libc 里，
       本仓不该有第二份）；
    ② 加 `srv_reuseaddr_ok(fd)`：`getsockopt` 把选项**读回来断言 == 1**。常量写错时
       它同样失败 ⇒ 「设上了没有」从不可判变成可判；
    ③ `web_run` 启动时问一句，没设上就打一行警告（别让它变成「用一会儿才炸」）。

    判据：`web-listen` 轮两条腿（① 选项真读得回来 ② 真复现现场：服务端先关留
    TIME_WAIT、立刻同端口重启）。**防假绿对照**：把两条常量改回 `0xFFFF` / `0x0004`
    重编 ⇒ 两条腿都红。

    教训与本仓踩坑 103 同族但不同层：**「抄一份本该由平台分叉决定的东西」= 换平台
    静默失效**。这里更毒的地方是 **`catch {}` 让失效完全无声** —— 一个「失败不该阻断
    主流程」的正当写法，顺手把「失败」也藏了。所以这类 `catch {}` 旁边要么留一个可判
    的观测口（`srv_reuseaddr_ok` 就是），要么在启动时问一次。

120. **「写前自检只核对值、不核对结构」= 把整份设置削成一个节还报绿**（P71，本轮实现里
     自己踩的，被手工烟测当场抓住）：写回的补丁是「按行复制 + 就地替换」，而首版那一句
     抄的起点写成了**节头那一行**（`buf_append(out, &t.ptr[hs], hend - hs)`）而不是从文件
     头抄到节头。于是补丁结果里 `ui-theme` / `llm-pi-ai` 连同顶层注释**整片消失**，
     文件只剩 `agent-default-model` 与它后面那点内容 —— 而写前自检（`dshw_verify`）
     **说没问题**：它只核对了「这一节读出来是不是那三个值」，位置对不对它不问
     （值确实对，节也确实读得出来）。真机上这就是「用户的模型表与权限预设被静默删掉」。
     修法两条，缺一不可：①抄写起点改成从**第 0 字节**抄到节头；
     ②自检补一条**结构**判据 `dshw_outside_same`（节头之前 + 节体之后两段必须逐字节相同；
     整节追加那条路则要求原文本是补丁结果的**前缀** —— 追加只许往后长）。
     判据本身也要能被证伪：把 ① 改回去重编，`dsh-writeback` 轮当场红 7 条。

     教训：**「值对了」不等于「改对了」** —— 凡是对整份文件做「读-改-写」的地方，
     自检必须同时钉「我改的那几处对了」与「我没碰的地方一个字节没变」。前半句是本轮写
     自检时的第一反应，后半句才是这条命的来源；与踩坑 94（冲突标记没有任何测试看得见）
     同族：**没有断言的那一半，坏了也不会有人报**。

121. **自测断言自己也会「假绿」：夹具的值与被写值不同时，判据停掉照样绿**（P71，同轮）：
     flow 节（`agent-default-model: {…}`）那条腿要钉「认不出的形状一律拒绝」。首版夹具写的是
     `{provider: alpha, model: a-one}`，而要写进去的是 `beta/b-think` —— 判据被停掉（改成恒
     `false`）之后，补丁会在 flow 行**后面**追加出重复的 `provider:` / `model:` 键，随后被
     写前自检挡下，于是断言「返回 `DSHW_SHAPE` 且文件不变」**依然成立**：红的是自检，不是
     那条判据。对照实验（把 `if shape != 0` 改成 `if false` 重编）证明了这个假绿 —— 一条都不红。
     改成「夹具里的 flow 节**已经就是**要写的那两个值」之后，判据一停，追加就会真的写下去，
     腿立刻红 2 条。

122. **`p[a: k]` 第三次咬人：这次咬在 MCP 的 env 上，症状是「配了 server 却 0 个工具」**
     （本轮，用户问「怎么接 aigw 的 MCP」时现场查出来的）：
     用户按 README 的 `--mcp-server "name=command args…"` 形状接本机 aigw，
     `--list-plugins` 却报 `aigw: no tools (MCP server exited or closed the pipe)`。
     链路是三层叠出来的：
     ① `mcpcfg.uya` 的 `mcp_cfg_cli_one` 把 `K=V` token 归到 env 时写的是
     `line[as0: k]` —— 第二个参数是**从 as0 起的字节数**（踩坑 51/54 那条语义），
     而 `k` 是 token 的**终点下标**，于是每个 env token 都从自己的首字节起多读
     `as0` 字节：越过后面的参数，最后越到堆尾的脏字节；
     ② 多读的尾巴里恰好混进堆尾残留（现场是 `\276\255\336`），子进程拿到的 env 变成
     `GW_DATABASE_PATH=/…/aigw.db\276\255\336`；
     ③ aigw 于是按这个名字**新建了一个乱码文件名的库**（现场在部署目录里真出现了
     `aigw.db\276\255\336`），里面没有账户 ⇒ `account not found` ⇒ 握手失败。
     为什么难查：`command` 路径长 + `K=V` 值长才露头（`as0` 要够大才读得出界，短 spec
     读到的是同一行的其他参数，反而「看着像对的」）；而 `--list-plugins` 只给一句
     「exited or closed the pipe」，真正的原因（子进程的 stderr）不在这一行里。
     修法：`line[as0: k - as0]`（与 `yamlcfg.uya` 的 `seg.ptr[a: b - a]` 同一写法）。
     自测补一条**判据换形状**的腿：旧断言 `bufx_contains(env, "FOO=bar")` 抓不住它
     —— 多读的字节接在 `FOO=bar` **后面**，子串照样命中、腿照样绿。新腿按**长度**
     钉（env 恰好 7 字节且逐字节相等），并故意在前面放长命令路径把 `as0` 撑大。
     防假绿对照：把 `k - as0` 改回 `k` 重编 ⇒ `mcp-cfg` 当场红
     （`env 长度不是 7（多读了字节…）`）。

     教训：**「子串命中」不是「值正确」** —— 断言一个缓冲的内容时，
     能被「尾巴上多挂东西」骗过的判据等于没判据（与踩坑 121 同族：判据得能证伪）。
     同族第三次了（51/54 是前两次），凡写非零起点切片，第二参一律先写成 `end - start`。
123. **「上游没给读数」被当成「读数说 0」⇒ 缓存命中率看板凭空掉三成，账单按最贵档多算**
     （P72，用户问「为什么最近缓存命中率变低了」时查出来的）：
     用户报「缓存命中率变低了」。查下来**缓存一点没坏**：按天看客户端账本，
     只看「提供方真给了缓存明细」的步，10-07 的命中率是 **99.3%**（10-04/05/06 是
     99.4 / 98.6 / 99.1）；掉到 88.7% 完全是另一类行拉低的 —— 那些行的
     `cacheReadTokens = 0` 且 `inputTokens` 等于**整个 prompt**（当天 315 行 / 90.8M
     token，而 10-02～10-06 合计只有 85 行）。
     链路是**两处各自独立、症状一样**的静默路叠出来的：

     ① **上游间歇换方言**（真机直连实测，autodl.art 的 DeepSeek-V4.1-Flash）：
     它**始终**回 `prompt_tokens_details.cached_tokens`（值是真的：冷启动 0、
     暖前缀 14968/19968），但会**时有时无地省略** DeepSeek 方言的
     `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`。网关 `~/ai-gateway` 的
     `ChatUsageToDimensions` 只认后者 ⇒ 落进 `else` 分支
     `dims["input"] = prompt_tokens`，**整段已缓存的 prompt 记成未命中**。
     ② 网关再往下游（responses 出口）发 usage 时，原来的 `UsageToWire` 是
     `if cached > 0 { 发 input_tokens_details }` —— 于是「上游没发明细」与
     「上游说命中 0」在客户端**发成同一个形状**（都没有 details）。本仓只读得到
     后一种，把两种都当成了 0。

     为什么难查：**没有任何一层报错**，而症状（0% 命中）与一次真实的缓存崩塌
     长得一模一样。正面证据是「同会话后续步仍在读同一份前缀」：取每个无明细行，
     在后续 5 步内找 `cacheReadTokens ≥ 90% × 该 prompt` 的请求 —— 154 行里 136 行
     （88%）找到了，中间 prompt 只增长中位数 610 token。**前缀是热的，只是那一次
     没把读数带回来。** 对照面也吻合：同一网关下游的真 DSH、真 Codex 当天同样中招
     （11.8% / 8.9%），所以这不是本仓引起的。

     代价（网关 `usage_records`，当天 DeepSeek 流量）：89.2M token 被按未命中价计费，
     ￥88.38 vs 命中价 ￥1.77 ⇒ **多算 ￥86.61（≈$12.99）**，其中本仓客户端占 ￥46.63。
     网关侧另有 1740 条 `usage was priced through a fallback rate` 的 WARN 是同一件事
     的记账面（10-05/06 合计只有 267 条）。

     修法（两侧都改，判据都落在「明细在不在」而不在数值上）：
     * **网关**：`ChatUsage` 同时建模两种方言，取值优先级
       DeepSeek 对 → `prompt_tokens_details.cached_tokens`（miss 由
       `prompt_tokens - cached` 推出并钳 0）→ 裸 `input`；`UsageToWire` 改成
       **按维度存在性**发 `input_tokens_details`（`cached_tokens: 0` 照发）；
       请求日志与维度统计加 `cache_split_known`，控制台把「未拆分」与「0%」分开显示
       （汇总行混有未拆分时改口径，不把兜底 0 加进去）。
     * **本仓**：`ChatOut` 加 `usage_have_cache_split`（两个解析器在**真读到明细字段**
       时置位）；`st_assistant_message` 收一个 `split_known`，命中率分母改用
       `st_hit_rate_billed()`（只含有明细的步），未知步另计并显示「未拆分 N 步」；
       `--show-usage` 缺明细时打 `cache_read=?(未回明细)`；`cmp_cache_burst` 前面加
       `cmp_cache_unknown`，缺明细只记 `cache/unknown`、**不再误报 `cache/evicted`**
       （实测 771 条事件里 375 条是这个假警报）。
       压力口径（`last_pressure`）**不动**：压缩要的是真实 prompt 大小，与读数拆没拆开无关。

     两个当场抓到的坑，都是自测挣来的：
     * 「日志里写 `"cacheSplitKnown":false`」曾经是错的 —— 日志读回走
       `sess_json_i64`，它**只认数字**：`true` 与 `false` 都没有数字位，两者都回 `-1`，
       于是「明确未知」与「老日志没这个键」混成同一个值。改成 **1/0 数字**后才有三态
       （`0` 未知 / `1` 有明细 / `-1` 老日志按有明细）。**自测（stats-fold）当场抓住的**，
       若只跑实时路径永远看不见。
     * 判据必须**两个方向都钉**：同一组数字（`miss == prompt`）在「有明细」时
       **仍然要**被判成突发 —— 否则这次修法就把真正的淘汰一起静音了。
       `cache-burst` 轮为此加了反向断言。

     教训：**「没读数」必须与「读数是 0」在每一层都保持可区分** —— 从上游字段、
     网关维度、日志字段、一直到屏幕上的百分比。任何一层把它们合并，都会在下游
     变成一个看起来像"事实"的假数字，而假数字比缺数字贵得多（这里贵 50 倍）。

124. **功能由「这台机器上有没有那个文件」决定 ⇒ 拷到别的机器上静默降级**（P73，用户报的
     「复制到其他机器上就能直接跑完整功能，包括 web」）：两处同族的坑，都是**没有报错**
     的那种坏法。

     **① plan 策略段整段消失。** 它只在上游 DSH preset（`agent.cordis.yml` 的
     `plan-mode.section`）里，而那一节要**从磁盘读**。实测同一个二进制、同一个 `--plan`，
     只改「能不能找到 DSH 安装」：system prompt **4469 B → 2132 B**，plan 段一个字节都不剩。
     最坏的搭配是：写闸门（§7 P26）是**编译进二进制**的、照样硬拒 write/edit ——
     于是模型被挡住写、又没被告知该调 `exit_plan_mode`，现场只剩「它怎么不干活」。
     顺带查出的孪生 bug：`preset_path()` 的 HOME 兜底用 `buf_append_cstr` 拼候选路径后
     **直接喂 `sys_open`** —— 它**不补 NUL**（踩坑 2 的原话），`buf_new` 也不清零，于是
     路径尾巴粘上那块内存里的残留字节。实测：**同一个二进制**，`cwd=/tmp` 读得到 preset、
     `cwd` 是个长路径就读不到（strace 里它去
     `open("…/@deepseek-ai/dsh-6e03-496b-9881-81544214")`，尾巴正是 cwd 的残留）。
     修法：整份上游 preset 用 `@embed` 进二进制做**第二级来源**（磁盘 → 内嵌 → 内置缺省），
     外加路径判定前补 NUL。

     **② web 会话子进程丢掉父进程的整份命令行配置。** 会话子进程是 fork + execve 出来的，
     argv **只带 `--tui`**，而**命令行给的东西不进环境** —— 于是父进程 `--permission
     read-only`，浏览器里那个标签页是 `Full access`；父进程 `--base-url` 指自建网关，
     子进程去打 `api.deepseek.com`（页面上只有一句「请求失败（网络或 TLS 校验）」）；
     会话日志落到默认 home（`--agent-home` 白给）。**权限被悄悄放宽**是其中最坏的一条。
     修法：spawn 前把父进程**已生效**的值注入子进程环境。

     教训：**「装在哪、从哪读」这类前提，一旦由运行时的机器状态决定，就要问「这台机器上
     没有它时会怎样」** —— 而答案不能是「静默少一段」。与踩坑 118/120 同族（静默是缺陷），
     与踩坑 108 也有亲缘（都是「换个环境就变样」）。本轮把这条做成了机器判据：
     `make e2e-portable` 在 `$HOME` 是空目录、没有 DSH、没有仓库的「新机器」上跑，
     并且**判据串只存在于上游 preset 里**（全仓与编译器树 0 命中）⇒ 它不可能假绿。

     两个实现细节值钱（都是实测撞出来的）：**a)** 注入必须用「覆盖」语义而不是「追加」——
     环境数组是先继承父进程整份环境再补项的，而 `getenv` 取**先命中的**那个，追加的同名项
     永远读不到（症状：明明注入了 `UYA_AGENT_PERMISSION=read-only`，屏幕上还是
     `Full access`）；**b)** 只在父进程**非默认**时注入，否则把默认值钉死在环境里，
     挡住子进程自己去读 `settings.yaml`（那是它的合法来源）。

125. **web 页面「复制不了文本」是两件事叠加：抢焦点毁选区 + 默认复制带一份 text/html**
     （用户报的「web 界面不能复制文本」，接着报「复制出来的文本还带有背景」）。两个根因
     各自独立、各自都能单独让「复制」失败，而且第 ① 个**没有任何报错**。

     **① 拖选根本建不起来 —— 焦点被 `mousedown` 抢走。** `#ime` 那个透明 textarea 是
     IME 的唯一入口（踩坑 116），所以页面在 `mousedown` 里 `setTimeout(focusIme,0)`
     把焦点抢回来。但浏览器**只认「焦点还在原地」的拖选**：拖拽途中焦点一移走，它当场
     放弃建选区。headless chromium 用**真鼠标事件**（`Input.dispatchMouseEvent` 的
     pressed/moved/released，不是合成 DOM 事件）复现：同一行、同一条轨迹，现状下
     `getSelection()` 是空串、`document.activeElement` 是 `ime`；把「抢焦点」从
     `mousedown` 挪到 `mouseup`，同一个轨迹立刻选出 **16 个字符**。A/B 的另一个方向
     同样干净：**只**把 `focusIme` 换成 noop，选区也照样出得来（`active=BODY`）——
     这一对对照就是根因的判据，与渲染、与帧重画都无关（实测选区建好之后 4 秒仍在，
     `drawRow` 重写别行、甚至整屏重建都不动它）。

     **② 复制出来带背景，是因为默认复制会序列化一份 `text/html`。** 每行是「按样式切段」
     的 `<span>`（段上钉着显式宽度、颜色、字距 —— 那是宽字符排版要的，踩坑 112），
     浏览器默认把这些全部序列化进剪贴板：实测 `text/html` 里每段都带
     `background-color: rgb(27,27,31)`、`width: 15.6562px`、`letter-spacing: 2.65312px`。
     粘到邮件/文档里就是「文字带着那块暗背景和一堆补位空格」。修法是接管 `copy`：
     `preventDefault()` 之后**只** `setData('text/plain')`（实测剪贴板里 flavor 就只剩
     `text/plain` 一个），顺带洗掉行尾填充空格与末尾空行。

     **③ 顺带挖出来的第三条：`ctrl+c` 在网页里是一键两义。** 终端里它是 SIGINT，网页里
     它同时还是「复制」这个通用手势。老代码一律发 `0x03`，于是选中文本按 ctrl+c 既复制
     不了、又把会话打断了（实测 `copy` 事件次数 **0**、发往 PTY 的字节是 `"\u0003"`；
     放行之后 `copy` 事件 **1** 次、PTY 零字节）。分流判据只能是选区：`selInTerm()`
     为真 ⇒ 放行，为假 ⇒ 照旧 `0x03`（实测没选区时仍是 `["\u0003"]`）。

     **④ 修的过程中撞出来的第四条：残留选区会把键盘输入整个吃掉。** 浏览器把「插入字符」
     重定向到那段选区上（替换它），于是 `#ime` 的 `input` 事件根本不发 —— 症状是
     「复制完接着打字没反应」（实测：有残留选区时敲 `x` 是 `input 事件 0 / PTY []`；
     清掉之后是 `1 / ["x"]`）。所以任何**不带 ctrl/alt** 的键进来时先清选区、把焦点
     收回代理框。三个候选（清+blur/focus 同步、清+重设 value+setSelectionRange、
     清+延迟聚焦）实测都能救回来，选了最简单的第一条。

     **⑤ 选中高亮也得明写**：默认 `::selection` 是半透明覆盖，压过彩色文字后只剩两档灰
     （实测选中块 10800 个像素全变，主色是 `#57575a` / `#6c6c6e`）—— 拖选是这个页面
     唯一的选取手段，看不出选到哪等于不能用。给 `#term ::selection` 定一个不透明的
     强调色（实测选中块 2075 个像素是 `--accent` 的 `95,158,230`）。

     **形状**：这五条里没有一条是「哪个函数写错了」，全都是**「谁有权改焦点」没说清**。
     所以修法是把它收成**一个**入口：`focusIme()` 带判据（`dragging || selInTerm()`
     ⇒ 不抢），`focusImeNow()` 是显式路径（点标签/点 `+`，顺手清残留选区）。两个实测
     细节值钱：**a)** 判据必须同时落在**按下**与**松开**两个时刻 —— 按下那一刻选区
     **必然**还是空的（选区是拖出来的），只在按下时判等于永远不抢；在按下时就抢则永远
     选不中。**b)** `blur` 自愈（焦点丢了自动抢回来）必须过**同一个**判据：拖选本身就会
     让 textarea 失焦，自愈一跑选区当场作废。

     判据落在 `web-page` 轮**五条**（`dragging` 在 / `selInTerm` 在 / `copy` 只写
     `text/plain` 且**不许**写 `text/html` / `ctrl+c` 按选区分流 / 非修饰键先清残留选区 /
     `::selection` 定了色），**防假绿对照当场验过**：把 `setData('text/plain')` 改成也塞
     一份 `text/html` 重编 ⇒ `web-page` 立刻红（`copy 往剪贴板塞了 text/html（背景又
     回来了）`）+ `SELFTEST WEB FAIL`。真机侧（headless chromium + 真鼠标事件）另有一轮
     端到端验收：拖选有选区、`ctrl+c` 出纯文本且 PTY 零字节、复制后打字进得了 PTY、
     单击焦点回 `#ime`、无选区 ctrl+c 仍是 `0x03`、跨行复制行尾无空格、高亮像素命中
     `--accent` —— 13 条全绿（`rgba(0,0,0,0)` 那条 `getComputedStyle(el,'::selection')`
     在 Chrome 139 上已返回透明，改用截图逐像素比色）。

     教训：**「页面能选文本」不是浏览器的默认保证，是三条独立纪律的合取** ——
     焦点别乱抢、复制别带样式、按键别把选区当空气。三条里坏任何一条，用户的结论都是
     同一句话：「这里复制不了」。

126. **同一句结论散落在十三处，改行为时改了九处 ⇒ 剩下四处开始说反话**（P72 漏、本轮
     文档审计抓出来）：P51 给图片定的规则是「纯 Uya 没有 zlib/deflate、没有 JPEG 编解码
     ⇒ 超预算只能接受原图或拒绝」，这句话当时被抄进 **13 处、跨 5 个文件**（`c825ade^`
     上 grep 实测）：`imgx.uya` 文件头 4 处（不变量① / 第 3 问 / 硬约束段 / 预算来历）、
     `DESIGN` 6 处（§1.2 能力表 / §11.8.4 段首 / §13.1 硬约束段 / §13.1 预算表 / §15 边界
     表 / §16 踩坑 84）、`README` §7、`webhttp.uya` 文件头 ④、`ag_interactive_tasks`
     的拒绝话术。

     P72 把行为改成「超预算的 JPEG 先自动缩」，动手时改了 **9 处**（`imgx.uya` 那 4 处、
     §1.2 表、§13.1 预算表、§15 表、踩坑 84、拒绝话术），**漏了 4 处**：`README` §7、
     `DESIGN` §11.8.4 段首、§13.1 硬约束段、`webhttp.uya` 文件头 ④。于是同一份仓里
     §15 说「超预算的 JPEG 会自动缩小」、§13.1 说「没法缩放或重压」，两处相隔 300 行
     **互相矛盾**，而构建、自测与各条审计全绿。

     危险的不是这几句话本身，而是**后来者会照旧前提做决定**：`webhttp` 那条注释
     （「纯 Uya 没有 zlib/JPEG 编解码 ⇒ 浏览器自己解码是唯一可行的路」）若被当成事实，
     下一个想「在服务端生成缩略图省带宽」的人会当场否掉一个**其实做得到**（对 JPEG）的方案。
     与踩坑 94（冲突标记没有任何测试看得见）同族 —— 只是这次的产物是**散文**，没有任何
     构建步骤会读它；而且**改的人自己就是漏的那一个**，记忆在这里不可信。

     修法两步：①先 `grep` 那句话的**全部落点**（`没有 zlib` / `没有 JPEG 编解码` /
     `只能接受原图` / `没有编码器`），不靠记忆点名；②每处按**今天**的事实重写，并让
     「做不到」的范围**限定到具体格式**（PNG/GIF/WebP）而不是笼统说「我们缩不了」。
     教训：**一句话被抄成 N 份时，「改行为」的验收对象是那 N 处里的每一处** ——
     说明性文字的过期不会红任何一条命令，只能靠改的人自己把落点数清。

127. **标题请求卡在「成功收尾」那一条路上 ⇒ 网关的会话标题列永远是空的**（P74，用户报的
     「aigw 显示不出标题」）：现场是**三个症状一个根因**，而且每一个单独看都「像没问题」。

     **① 触发点只有一个，还带条件。** `agent_title_auto_schedule` 的唯一调用点是
     `if rc == AGENT_OK { … }` —— 于是**只有成功收尾的回合**才可能起标题：

     | 回合收场 | provider 标题 | 网关 `call_kind=title` 行 |
     |---|---|---|
     | `completed` | 有 | 有 |
     | `aborted`（esc） | **没有** | **没有** |
     | 还在跑 | **没有** | **没有** |

     而真正发请求还要等空闲主循环（回合里主循环整段不跑）—— **长回合跑着的整段时间里，
     网关那边连一条 title 行都没有**。控制台的「请求日志 → 分组=会话」那张表标题列取的是
     `MAX(title)`，而标题只写在 `call_kind=title` 的行上（网关的既定口径：别的行没产出过它），
     于是那一列就是空的。

     **② 屏幕上那个「标题」根本不是模型写的。** 首条消息落下 `source.kind = "fallback"`
     的派生值（前 3 词）时它**同时**写进了 `g_sess.title`、日志、索引 —— 看起来已经有标题了，
     其实是把一个「取前几个词」的结果当成会话标题在用。

     **③ 上限是 10 个汉字（30 B），不是用户要的 15 字。** 现场那条首条消息
     「实现标题15字以内的总结」（12 汉字 / 36 B）被切成 `实现标题15字以内的总` ——
     30 B 正好截在词中间。用户原话「标题15字以内」说的就是这件事。

     **修法（三条一起）**：① 待办在**回合入口**挂，第一次机会是**第一个 step 跑完的 step
     边界**（用户已经拿到第一批输出，标题在同一个回合里落地）；收尾那条路撤掉 ——
     **收尾不更新标题**。② 会话标题**只有一个来源：模型总结**；派生值降级成「备用标题」，
     模型没起出来之前显示基标题 `uya-agent · <目录>`。③ 模型侧收口 3 词 / **45 B = 15 汉字**。

     **为什么首发不放在「发第一个请求之前」**（DSH 是 JS 异步并发，它两边能同时发）：
     本仓单线程（踩坑 47 起不了第二条线程），侧路请求是**同步**的 —— 实测真网关上这一个来回
     **1.18–1.36 s**（连测三发）。放在首答之前等于用户的每一次首答都白等一个往返；
     放在第一个 step 之后，aigw 不用等回合结束就能有标题。**代价**：被打断在「第一个 step
     边界之前」的回合要等收尾之后空闲那条路补发（那一条带两段 900 ms 静默）。

     **一条会话只自动起一次**（对齐 DSH 的 `automatic: "first-prompt"`）：`g_title_auto_done`
     既是首次闩、也就是「收尾不更新」的实现 —— 之后要改标题走 `/title`、裸 `/title`、`set_title`。

     **查这件事的顺序值得记下来**（三条判据，缺一条都会得出错的结论）：① 网关上**逐字相同**的
     提示词打一发 ⇒ 记成 `call_kind=title` 且抓到标题（证明网关侧没问题，缺的是我们没发）；
     ② 真 PTY 驱动真二进制 + 真网关，**回合还在跑的时候**查 `request_logs` ⇒ 标题行出现在
     两次 `agent` 请求**之间**（22:43:16 → **22:43:18 title** → 22:43:19）；③ 会话日志里
     `turn/end` 的时间戳晚于标题事件（22:43:18 标题、**22:43:22** `turn/end`）⇒ 确实不是收尾发的。

     **防假绿对照（都做过，都先看到红）**：把 step 边界那次调用去掉 ⇒ `tui-pty` /
     `tty-title-pty` 当场红（模型标题没上屏 + 派生词串反而上了屏）；把 `!g_title_auto_done`
     去掉 ⇒ `title-cmd` 红三条（首次闩 / revision 门控）；把 `agent_title_derive` 改回写
     `g_sess.title` ⇒ 红在「派生值不许被当成会话标题」；把待办改回只在 `rc == AGENT_OK` 挂
     ⇒ `make e2e-title-auto` 的 C 腿（esc 中断）红。

     **顺带修的自测机制**：mock 是按**轮号**断言请求形状的，而标题请求会出现在**任何**
     跑得出一个回合的轮次里 —— 不认它就会把侧路请求当成「第 N 轮」，整套断言集体错位。
     所以四处自建 mock 共用 `mock_serve_title`（回一个模型标题、**不占轮次**）。计数不能放
     全局量里：mock 跑在 fork 出来的子进程，父进程读不到 —— 首发时机改按**屏幕字节的先后**
     判（模型标题的 OSC 2 必须早于 mock 的最终答案），round == 0 那一半由 mock 就地断言。

128. **「Buf 当 C 串用」在好的堆布局下是隐形的 —— 换一段堆就炸**（P75，被新自测轮连带抓出）：
     现场症状是 `tui-model` 轮的写回腿红（`dshw_save` 返回 `DSHW_FAIL`），而**同一份 main
     上它是绿的** —— 我的改动只是新增了一轮自测，看上去与写回毫无关系。

     根因在 `dshw_save` 拼临时文件名那几行：`suffix` 是 `Buf` 里拼出来的（`buf_append_cstr`
     + `buf_append_i64` + `buf_append_u64`），**没有 NUL 结尾**；而 `dshw_path_z` 的形参是
     `&const byte`、内部用 `buf_append_cstr`（按 NUL 量长度）—— 于是那块缓冲**后面的堆字节**
     被一起拼进了路径。实测抓到的路径是
     `…/settings.yaml.529444-1791699063388.tmp.git/dsh-worktreeP`
     —— 尾巴 `git/dsh-worktreeP` 是**别的**缓冲的残留（本仓 worktree 路径的片段）。
     `sys_open(O_EXCL)` 于是失败，整个写回退成 `DSHW_FAIL`。

     这是 CODING.md 反模式 4（「`buf_append_cstr` 之后直接当路径/argv 用」）的又一个现场，
     但**比一般情形更隐蔽**：`Buf` 的容量按 2× 增长，新分配/未写过的堆页多数时候恰好是 0，
     于是拼出来的路径**正好**是期望值 —— 只在某些堆布局下才带上残留。**这就是它一直没被
     抓住的原因**：既有自测的堆布局碰巧是「干净」的那一种。我新增的一轮（F 段里
     `procx_tick` 扫 `/proc`）扰动堆之后残留变成非零字节，它当场炸了 —— 也就是说这**不是**
     新引入的缺陷，是**既有缺陷被新判据照亮**。

     修法：新增 `dshw_path_exact(base, suffix, sn, out)`（按**长度**拼、末尾补 NUL），
     临时文件名走它；`dshw_path_z` 保留给真正的字面量后缀（`/settings.yaml`、`...lock`）。
     文件头不变量加了第 ⑧ 条钉这条。教训与踩坑 121 同族（判据要在**只有那一行代码能救**的
     形态上测）；反过来也成立：**新判据会照亮别处的既有缺陷**，那时先分清「是谁的账」——
     本轮这条是既有的，但它让「写回偶发失败」有了稳定复现路径，所以一并修掉。

129. **「记忆一直不失效」的真身是「记忆从来没写进去过」—— 151 轮自测全绿，因为唯一会跑的
     那条接线恰好是唯一没被覆盖的**（用户报的，本轮修复，不占阶段号）：

     现场：用户报「看看为什么记忆不失效」。第一反应是去读 `pm_verify` 的锚点比对 ——
     那条路**是对的**。真正的现场是 `find $HOME/.uya-agent -path '*memory*'` **一个字节都没有**：
     跨会话记忆的摄取整条死在接线层，于是「失效」这件事根本没有机会发生。

     两处**各自独立**的缺陷叠加（第二处只在第一处修好之后才暴露）：
     ① `agent_pm_set_sid` 排在 `agent_pm_begin` **之前**（`agent_session_open` → … →
        `agent_hist_init` 的顺序里，会话 id 早就有了，**身份还没有**）⇒ 那时
        `g_pm.ready == false`、`g_pm.dir.len == 0` ⇒ 绑定被拒 ⇒ `g_pm_ing.enabled`
        **恒为 false** ⇒ `agent_pm_note_tool` 在守卫处直接 `return`。它**静默**（这正是
        「记忆是旁路、失败不打断回合」的设计），所以盘上什么都没留下、也没有任何报错。
        恢复会话那条分支更彻底：它连一次 `agent_pm_set_sid` 都没有（新建分支有）。
     ② 两处调用点传的是 `&res.ptr` / `&res.len`（**字段的地址**）而不是 `res.ptr` /
        `res.len`（值）⇒ 被调方拿到野指针 + 天文数字长度（插桩实测 `result_len` ≈ 1.4e14）⇒
        `find_sub` 读越界 ⇒ **整个 agent 段错误**（退出码 139）。绑在「好的堆布局」上时
        也可能不炸而是静默抽错 —— 属于踩坑 128 的同一族（野指针在好布局下隐形）。

     **为什么 151 轮自测 + 6 轮 `pm-selftest` 全绿**：`pm-ingest` / `pm-e2e` 这些轮全部
     **直接调** `pm_ingest_tool(&ing, …)` 与 `agent_pm_note_tool(…, rres.ptr, rres.len)`，
     参数是自测手写的**正确值**。它们证明的是「摄取函数本身对」，而生产代码里那两处坏调用点
     一条都没被碰到 —— 换句话说，**测试覆盖率 100% 地绕开了唯一会执行的那条路**。
     症状因此被读成「记忆不失效」，而真相是「记忆不存在」。

     修法与判据：① 绑定挪到 `agent_pm_begin` **之后**（两处：新建分支 + 恢复分支）；
     ② 传值改回 `res.ptr` / `res.len`；③ 新增 `make e2e-memory-live` —— 跑**真二进制**，
     用假网关喂 `read` / `bash`，断言**盘上分片带真 stat 锚点**、跨会话注入、改→`STALE`、
     删→`GONE`、`--no-memory` 不落盘。三条防假绿对照实验全部当场红（详见 §20.8）。

     纪律（本节最值钱的一条）：**纯函数自测只能证明函数对，证明不了接线对。**
     凡是「A 模块调 B 模块」的接缝，判据必须落在**真二进制 + 真产物**上 ——
     这一条与本轮 `--no-memory` 的「连目录都不碰」是同一个问题的两面：**旁路机制的失败
     一律静默，所以它们只能靠端到端产物来验**，函数级断言在这里天然是假绿的温床。

     附带查实的两个**设计层面**的「不失效」（不是 bug，但都没写清，已补进 §20.7）：
     `state` / `command` 类事实的锚点恒为 0，而 `pm_verify` 把「锚点全 0」判成**不可校验**
     （0 = 一致，**不是**过期）⇒ 这两类事实无论过多久都以干净的样子注入，唯一的提醒是
     分区标题那句「Last known state (verify before relying on it)」。

130. **开工包被 commands 一节吃光 —— 而那一节里大半是「跑不起来」和「下次不存在的路径」**
     （本轮，用户问「为什么记忆命令」，不占阶段号）：

     现场：用户问「为什么记忆命令呢？」—— 听起来像「为什么要记命令」，实际暴露的是
     **记进来的命令有问题**。拿本仓真记忆目录（3 个分片 / 574 行）+ **3882 份真会话日志
     里的 64906 条真 bash 调用**逐条量了一遍：

     | 症状 | 实测 | 后果 |
     |---|---|---|
     | commands 挤占预算 | 3072 B 里占 **2869 B（99%）** | conventions / layout / state **一条都进不来** |
     | 带 `cd <worktree> && ` 前缀 | **56%**（28661/51531） | 路径**下次会话就不存在**；同一条命令在每个 worktree 里都是新 key ⇒ 跨会话 `n` 几乎恒为 1（本仓 470 个命令 key 里 468 个 n == 1） |
     | 多行 / heredoc | **19%**（12643 条） | `pm_ing_norm_cmd` 把它**折成一行**存下来 —— 重跑不等价（heredoc 正文被压平、`for … done` 的换行没了），存的是**跑不通的命令** |
     | 归一化触 512 上限 | **14%**（9195 条） | 硬截断，存进去的是「到半个 token 就断掉」的命令，既跑不起来又白占预算 |
     | 验证命令识别漏 | `cd X && make …` **1040 条**现行口径不认 | `state`（上次绿/红）那条腿几乎恒空 |

     **三条修法**（每条都配一条能单独变红的断言，见 §20.8）：
     ① `pm_ingest_bash` 加**两道摄取闸门**：`pm_ing_single_line`（多行拒）+
        `pm_ing_truncated`（触上限拒）—— 「宁可少记，不可记错」是同一条纪律的延伸：
        记忆的全部价值在「照着重跑一遍」，存一条重跑不起来的比不存**更糟**（把模型引向死路）。
     ② `pm_ing_cd_drop` 剥掉**恒真**的 `cd <本会话工作区> && ` 前缀 —— 判据只看「目标是否
        **恰好**等于本会话 workspace」（bash 本来就跑在那儿，剥掉对重跑零影响）。实测其余
        **29370 条** `cd X && …` 的 X 是别处（`/tmp`、另一个仓、另一个 worktree），剥掉就改
        语义，**一律不剥**。剥完 `cd X && make …` 也能被 `pm_ing_is_verify` 认出，state 那条
        腿多认 240 条。
     ③ `pm_digest` 加**单节份额封顶**（正文的 1/2）：「截断顺序」只在**预算不够**时起作用，
        而 commands 的条数天然远多于另外三节（每次成功的 bash 都记一条）—— 不限份额就是
        「谁先写满谁赢」，等于让最易膨胀的那一节独占预算。份额只改**分配**，不改顺序。

     **为什么之前没发现**：`pm-ingest` 轮只喂**手写的单行短命令**，四条断言全绿；
     真机那 19% 多行 / 14% 超限 / 56% 带前缀**一条都没进过自测**。与踩坑 129 同族 ——
     **自测喂的输入形状，决定了它能照亮的缺陷种类**：纯函数轮用「理想输入」写，
     就只能证明「理想输入下对」。

131. **换宿主编译器（GCC 14+）把四类「以前只是 warning」的账一次收走 —— 报错全在
    编译器生成的 C 里，可改的只有 uya 侧与 Makefile**（本轮；本机 cc = GCC 15.2，
    `make check` 全绿、`make build` 成片失败）：

    ① **无体 `extern "libc" fn` 不发射 C 原型 ⇒ 隐式函数声明**。codegen 是**故意**不生成
    这类声明的（`uya/src/codegen/c99/function.uya`：它假定宿主系统头已声明过），而 split-C
    的每个 `.c` 只 include `uya_*.h`、从不 include 系统头 ⇒ `setsid`（websrv / shellx /
    mcprun 三处）与 `sigaction`（sigx）的调用点在 C 里都是隐式声明。
    **修法**：`src/cshim/uya_agent_libc_protos.h` 补原型，Makefile 用
    `CFLAGS=… -include <那个头>` 注入。原型必须落在**出错的那个 TU** 里 ——
    单放一个 `.c` 里（`@c_import`）没用，那只是另一个翻译单元。
    那个头**绝不能 include 系统头**：生成的 `uya_part1_types.h` 自带 `int64_t` / `size_t`，
    再拉进 glibc 的 `<sys/types.h>` 就是满屏 conflicting types（所以它只用 C 内置类型 +
    前向声明 `struct SigxAction`）。

    ② **指针类型对不上**（这一族最多，且每处都改得动）：自造同布局结构体传给 libc 指针
    （`GxTimeVal` / `TuiTimeVal` vs `TimeVal` ⇒ 用 libc 的 `TimeVal` —— 同布局**不等于**
    同一个 C 类型）；uya 侧收 `&byte`、实参是 `&const byte`（`jw_str` / `js_parse` /
    `cstr_len` / `arg_starts_with` / `buf_from_cstr` ⇒ 入参收 `&const byte`，只在边界上
    显式 `as &byte` 转一次，让 const 只在一处被抹掉）；`&g_watch_cfg` 而它**自己就是**
    `&const Config`（取址成了 `Config**`）；`&fds`（`int(*)[2]`）当 `&i32` 用（⇒ `&fds[0]`）。

    ③ **`{0}` 套在标量上**：`History.items` 是 `&Msg`（裸指针）不是切片，写 `items: []`
    时 codegen 发出 `.items = {0}` ⇒ braces around scalar initializer
    （⇒ 写 `items: null`）。

    ④ **生成物里有裸方向控制符**：`escape_string_for_c` 只转义 `\n \t \r \\ "`，其余字节
    原样吐进 C 字面量；夹具里的 U+202E（RLO）/ U+200B 于是变成生成物里的裸字节 ⇒ 宿主
    的 `-Wbidi-chars` 报「源码里有方向控制符」（源码侧本来是转义写法）。⇒ 夹具改**按字节**喂。

    **CFLAGS 怎么注入（同一条已经踩过两次）**：driver 按
    `make -C <cache> CC=… CFLAGS=… …` 调它生成的 `build/uyacache/Makefile`，
    **命令行变量压过里面的 `CFLAGS ?=`** —— 所以真生效的是 `make build` 那条命令上写的
    `CFLAGS=`（`AGENT_CFLAGS`），生成 Makefile 里那行
    `-std=c99 -Wall -Wextra -pedantic -I.` 对本路径**从不生效**（它只管「有人手跑
    make -C build/uyacache」那一路）。写就写**全**：漏 `-std=c99` 会让
    `typedef _Bool bool` 当场报错；**别**照抄那行「看着像基线」的档位 —— 落在生成代码上
    实测从 **0 条**刷到 **1.8 万条**告警，而那些一条都不归本仓修，只会把真告警淹掉。
    注入用**行内赋值**、不用 `export`（同踩坑 90：`export` 会漏进 `make selftest` 里
    agent 自己发起的构建，等于把本仓的原型头强加给别人的编译）。手工编译按
    `$(make -s print-cflags)` 带上。

    **顺带揪出两处真 bug** —— 宿主 C 的报错只是把「uya checker 没拦住」显形：
    `agent_effort_apply` 把 C 串传给了收 `&const Buf` 的 `sv_eq_cstr`（P55 那条「人手动
    改过档位就别再自动降档」的判定一直在读错内存）；`agent_pm_note_tool` 的 (指针, 长度)
    传的是 `&res_f.ptr, &res_f.len`（**取字段地址**当内容与长度 ⇒ 记进项目记忆的是错内存 +
    一个巨大的长度）。

    教训：**「只是 warning」不是可以欠的账，它只是把到期日推给下一次换编译器**。
    这条链上没有任何判据看得见它（`make check` 只查 uya 类型，生成物里的 C 它不看），
    所以「GCC 版本升到 14+」这件事本身要当成一次**全量重编 + 逐个收账**的时机。
    同族：`make lint-size` / `doc-audit` 也看不见 C 侧的 const 与原型。
132. **默认档在真实站点上必然失败 ⇒ 新机器第一次跑就是「请求失败（网络或 TLS 校验）」**
     （P78，用户报的：Ubuntu 26 那台 `uya-agent hi` 直接报这个）。
     三条独立缺陷叠在一起，**每一条单独都不致命，合起来让默认配置完全不可用**：

     ① **`chain` 是默认档，而它必然失败**：§18 节旧版写的「`example.com` 恰好能过」是**错的**
     （实测同样失败）。真身是 `ssl_capture_peer_chain_from_server_flight` 按「带 record 头」
     的缓冲扫 `server_flight_msg`，而那个字段存的是**不含 record 头**的握手消息流 ⇒
     `ctx.peer_leaf` 恒 NULL。新机器没有 `~/.dsh/settings.yaml`（落默认档），于是第一次连接
     就撞在这上面。**旧文档把「实现细节不可用」写成了「真实站点通常失败」，而「通常」这个词
     把「必然」的严重性掩盖了** —— 与踩坑 126 同族：结论散落多处时，措辞的软硬会跟着漂。
     ② **`pin` / `none` 被无谓地绑在系统根证书库上**：`tls_open` 里 `trust_store_load_system`
     失败就 `HcTlsUnsupported`，与档位无关。实测：把 `/etc/ssl` 挂空之后，`pin` 档**拿着正确
     的指纹**也连不上。判据（leaf 指纹）与体检报告（CA 库）本该无关。
     ③ **流式路径把观测到的指纹丢掉了**：`llm_stream_style` 里那个 `TlsConn` 是**它的局部
     变量**，agent 侧的 `tc` 从来没传进去 ⇒ `tc.observed_len` 恒 0 ⇒ 错误分支永远走不到
     「打印指纹」那一支。**最需要指纹的那条路上，指纹被丢掉了** —— 用户只看到
     「检查 base-url / 网络」，而答案就在指头上。

     **修法**：默认档改 `tofu`（首次记录 leaf 指纹、之后强制相符，存
     `<agent home>/tls_pins`）；`pin`/`tofu`/`none` 不再加载 CA 库；chain 的失败原因拆成
     `HcTlsNoChain`/`HcTlsNoAnchors`/`HcTlsNoLeaf` 三个可指路的错误码；观测指纹走
     `hc_last_leaf_ptr()` 全局（流式路径拿不到 TlsConn，别再指望传对象进去）。
     验收：`tls-pin` + `tls-tofu` 两轮自测（离线），**防假绿对照两处都做过** ——
     把 `tp_trusts` 改成忽略指纹比对 ⇒ 3 条当场红；把「首次落盘」那行删掉 ⇒ 5 条当场红。

     **连带抓出的一条自测纪律**：`tls-tofu` 轮第一版是「照着 `tls_tofu_decide` 的形状再写
     一遍」——它收 `&TlsConn`（离线造不出来），所以我当初复刻了判据。结果是**把产品里
     「首次落盘」删掉，自测全绿**（上面那个对照实验）：覆盖的是**测试自己的复刻品**。
     修法是把判据本体摘成不收 TlsConn 的 `tls_tofu_verdict`，自测直接调它。
     与踩坑 121 同族：**判据只要不是产品代码本身，就会在某个时刻只证明「复刻品是对的」**。

133. **名字解析的「读窗口」比文件短 ⇒ 名字永远解不开，而报的是「TLS 校验」**（P80，用户报的：
     同一条 `uya-agent hi` 在新的那台机器上换成这个症状）。现场与判定过程：

     * **症状**：`./autodl.art; uya-agent hi` ⇒ `error: 请求失败（网络或 TLS 校验）。`（退出码 2）。
     * **反证三条**（**先证伪「是 TLS」再往下走**，这一步省不得）：① `--probe --tls-verify=none`
       报 `HcConnectFailed` —— 连握手都没进；② 同一轮的 `strace` 里**一次 `socket` 都没有**，
       只有 `open("/etc/resolv.conf")` + `read(fd, …, 512)`；③ base-url 换成 IP 直连
       （`https://101.126.37.23/api/v1`）时同一份代码 TCP + TLS + HTTP 全通，`curl` 同 key 打
       `/v1/responses` 也是 200。⇒ **是名字解析，不是 TLS**。
     * **根因**：`std.net.dns` 的 `dns_parse_resolv_conf_first_nameserver` **只读
       `/etc/resolv.conf` 的前 512 字节**，就在这 512 字节里找 `nameserver`。而本机那份是
       systemd 的 stub-resolv.conf：**920 字节、`nameserver 127.0.0.53` 在偏移 866** ——
       正好在窗口之外 ⇒ `DnsNoNameserver` ⇒ 被 `tcp_connect` 糊成 `HcConnectFailed` ⇒
       顶层那句「网络或 TLS 校验」。静态链接下不能用 `getaddrinfo`（NSS 要 `dlopen`，见 §16），
       所以这一步只能自己做对。
     * **和 P78 是同一条线**：P78 修的是「默认档在真实站点上必然 TLS 失败」（TOFU），
       这台机器上下一个症状就是这条 —— 都是「**读窗口太小，就当文件里没有**」：
       信任库读前 64 KiB（`DigiCert Global Root G2` 在偏移 75389，见 §18）与这里读前 512 字节
       是同一个坑的两个实例。判据也一样：**窗口外的东西不会被报出来，只会被当成不存在**。

     **修法**（不改标准库 —— §18 的既定立场：改了它，用户在新机器上 `clone` 本仓仍然坏）：
     `src/net/httpc.uya` 自己**整份读**解析器文件（`hc_resolv_read`，上限 16 KiB、撞上限置
     `hc_resolv_trunc` 而**不是**静默当成「没有」），按行扫描摘第一个可用 IPv4 的 `nameserver`
     （`hc_resolv_scan`，纯函数、离线可测），再把结果喂给 `dns_client_init`；
     `$UYA_AGENT_DNS`（`a.b.c.d[:端口]`）可以用一个环境变量直接指定解析器，**排障不必改文件、
     也不必 root**。失败的**口径也分开了**：名字解析失败报 `HcDnsFailed`、TCP 连不上报
     `HcConnectFailed`、TLS 握手谈崩报新的 `HcHandshakeFailed` —— 以前三种共用一个码，
     用户只能看到「检查 base-url / 网络」，而真话（没解开名字、换哪台 DNS）就在手上。
     显示层的档位映射 `agent_net_fail_kind` **两条路共用**：流式与非流式以前各写一份，
     非流式那份只认 5 个 TLS 码 ⇒ `--no-stream` 下 DNS 失败永远落回那句兜底话。

     **自测**（离线，`dns-resolv` 轮 + `make e2e-dns`）：扫描轮的夹具**特意造出** >512 字节的
     注释头（并断言 `ns_off > 512`，判据的形状钉在断言里），真文件轮写一份同样形状的临时
     `resolv.conf`、把路径钉进去、断言产品给出的解析器串**逐字节**是 `127.0.0.53`；
     `e2e-dns` 用假 DNS（`testdata/mock_dns.py`）+ `.invalid` 域名（RFC 2606 保留域，
     **真解析器必然解不出来** ⇒ 跑绿只可能来自自家解析器）跑通一轮，再用一个没人听的端口
     验「DNS 失败必须说成人话、且不许提 TLS」（流式与非流式各一条腿）。
     **防假绿对照两处（都真做过）**：
     ① 把整份读退回 `buf_new(512)`（老口径）⇒ **真文件轮 4 条红**（「临时文件里有 nameserver
     却说没有」等）。注意**扫描轮那两条不红** —— 它们直接喂文本、不走读文件，这正是
     「回归腿要打在**接线**上，不是打在纯函数上」的现场：纯函数对、接线错，一样是坏。
     这条对照还顺带红了覆盖轮的 2 条断言，翻出来产品里一个真问题：**原因记账没有优先级** ——
     读窗口一变，`TRUNC` 就把「`$UYA_AGENT_DNS` 值非法」覆盖掉了。判据没变，是记账顺序错了
     （见 `hc_dns_err_rank`）。
     ② 把关键字匹配改回「老实现那类写法」（在**整行**里按前缀找 `nameserver`、参数取它后面
     那个 token、不认注释）⇒ **扫描轮 3 条红**（注释行被当真 / `nameserverX` 被当真 /
     `;` 注释与 tab 分隔没被认）。⇒ 两条对照都落在**不同**的段上，说明判据不是同一件事
     的数次复述。
134. **自带 agent home 的真 PTY 轮：夹具不清就是两路残留，而症状指着产品**（P80，收 P76
     那笔记成「既有失败」的账）。`tui-paste` 的真 PTY 腿用一个专用 home
     `build/selftest_agent_home_paste`，而它**从不清理** —— 而这一轮自己就是污染源，
     因为它真跑一整轮（mock LLM 让它 `bash echo …` 与 `write note.txt`）：

     * **路 A（日志目录堆积）**：每跑一次多一个 `sessions/<cwd>/<id>/session.jsonl`。
       而定位日志的 `tui_paste_first_dir` 取的是 `readdir` 的**第一个**条目 —— ext4 按
       目录项哈希返回，**不是最新那条**。取到旧的那份 ⇒ 报「会话日志里没有那条三行合一的
       user 消息」。症状随目录数量/哈希序漂移（实测 1 次跑红、再跑又绿）。
     * **路 B（记忆开工包被当用户消息回放）**：**绿的那一次**会把
       `echo SELFTEST-SHELL-OK; pwd` 摄进 `memory/<repo-key>/obs/*.jsonl`。下一次
       `agent_pm_inject`（`ag_pm.uya`）把 `<pm-memory>…</pm-memory>` 作为 **`ROLE_USER`**
       消息压进历史，TUI 照用户条目的样子画出 `▎ 你`。于是「粘贴**不许**提交」那条断言
       （判据本来就是「屏幕上没有 `▎ 你`」）**命中的是注入的开工包**，报成
       「粘贴里的 CR 被当成了回车提交（踩坑 83 的原始症状）」—— 一句把人指向粘贴状态机、
       而真身是夹具残留的文案。同一份残留还让紧随其后的
       `tuis_drain_until(… "▎ 你" …)` **立刻返回真**（标记早就在捕获里）：一次**假绿**，
       父进程在提交落盘前就把子进程杀了 ⇒ 路 A 的「没有那条消息」也被它连带解释。

     **这个形状值得单独记**：**绿灯自己种下下一次的红**，而红又长得像产品缺陷。
     P76 那轮撞上时按纪律记成「既有失败、不追」，代价是它又以同样的名义活过了几轮
     （§16 那条「既有失败」现在改成了指向这里）。

     **修法**（`tuis_tail.uya`）：轮次开头 `pm_rm_rf(phome, …)` **整棵删掉**再 `sys_mkdir`
     —— 只清 `sessions/` 不够，路 B 在 `memory/` 下，**两路都得清**。另加一条**绊线**：
     fork 后第一次 drain 的**启动屏**上不许有 `▎ 你`；它只会是绊线不会假红（子进程画得慢
     就什么标记都没有），一旦出现，失败文案自己指出「夹具 home 有残留」，不必再让人从
     粘贴状态机反推。

     **对照实验**（在 `/tmp` 里对着被污染的目录做，仓库文件不动）：

     | 埋的残留 | 无修法（控制） | 有修法 |
     |---|---|---|
     | 只有记忆事实（路 B） | 红 **3/3** | 绿 **3/3** |
     | 只有 12 个旧 session 目录（路 A） | 红 **2/3**（随 readdir 序） | 绿 **3/3** |
     | 两路都埋 | 红 **3/3** | 绿 **3/3** |

     去掉 `pm_rm_rf` 那一行重编、埋着残留跑 ⇒ 当场红，且**绊线先报**出真根因
     （「启动屏上就有用户条目」而不是「CR 被当成了回车提交」）—— 「修的是残留」这条
     才算验过。**没做这个对照就等于没验过修法**。

     **没顺手做的两件事**（各有自己的范围）：① 没把 `<pm-memory>` 加进
     `agent_tui_is_injected` —— 那会改 `--resume` 的回放行为，是产品级决定，得单独一轮 +
     自己的对照；② 没动其它共用 `build/selftest_agent_home` 的真 PTY 轮
     （`tui-pty`/`tui-quit`/`tui-access`…）—— 同族风险在，但不在本轮范围。

135. **终端应答与用户按键走同一条 fd 0**（P83）：手写 OSC 5522 客户端时，最要命的一格不是
   协议本身，而是**回帧的入口**。终端把 `ESC ] 5 5 2 2 ; …` 应答写在**同一个 fd 0** 上，
   键解码器看到的就是「ESC + 一串普通字符」—— 它会把这串 base64 **打进输入行**。所以
   必须有 `term/oscin.uya` 这一层拦。**反过来的教训更贵**：第一版让扫描器「每个 ESC 都开
   捕获」，结果把**裸 ESC / 方向键**攥在手里，行编辑器等的那个 `ESC` 永远不来 ——
   `tty-editor` 轮 16 条断言当场全红。修法是**没 armed 时一个字节都不攥**（逐字节原样透传）。

136. **DECRQM 少一个 `$` 就是另一条 CSI**（P83）：能力探测的字节是
   `ESC [ ? 5 5 2 2 $ p`（**9** 字节）。第一版写成 8 字节数组、末位放 `'p'`，把 `$` 覆盖掉了
   —— 发出去的是 `ESC[?5522p`（DECSET 家族的形状），终端要么忽略要么改状态，而**应答永远
   不会来**。症状是「探测超时、每次粘贴白等 250 ms」，看起来只是「这个终端不支持」。
   **顺带一条测试教训**：纯函数轮最初自己抄了一份「正确的字节」去比对，被测的那份写错了
   它照样绿 —— 只有真 PTY 轮（假终端不应答）才看得见。修法：探针字节**只留一份实现**
   （`clipt_probe_into`），写 fd 与自测断言共用。

137. **等待方必须在 armed 期间独占 fd 0**（P83）：`clip_paste` 自己 `read`，但等待循环里
   还会调 `tui_poll_tick()` —— 而 tick 内部的 `tui_poll_keys` 也读 fd 0，它**先一步**把
   应答当成按键吃掉了。扫描器于是一个字节都看不到，症状**与 136 一模一样**（探测永远超时）。
   修法：`oscin_borrowed()` 让 `tui_poll_keys` 一开头早退，透传字节由等待方喂回
   `tui_keys_feed`（按键一个都不丢）。**顺序也有讲究**：先自己 `read`，再 tick。
   **判据教训**（同 136）：夹具的应答一次 `write` 装得下 512 字节时这条不变量**测不出来**
   —— 必须把 PNG 夹具撑过分片边界，让应答必然分两批到。

138. **一次 read 里连着来三帧，而扫描器一次只交付一帧**（P83）：`OK` + `DATA`(多块) +
   `DONE` 常常在同一批字节里。若交付第一帧后**丢掉**剩下的，就永远等在那里 —— 症状是
   「读请求发出一遍又一遍、数据就是收不回来」，而代码看起来完全正确。修法：交付一帧后
   把尾巴存进**挂起段**并提前收手，等待方取走这一帧后喂一个**空批**接着解下一帧。

139. **逐块 base64 解码是硬要求，自测也必须走生产路径**（P83）：OSC 5522 规定每个 `DATA`
   分块**自带 padding**（kitty 的块大小是编码前 4096 B）。把整串拼起来再解会当场坏，
   而症状只是「图片坏了」，与协议错长得一样。**测试上的坑**：自测最初自己写了个
   「逐块解码再拼接」的循环去断言，被测的那份改成「整串拼接后解码」照样绿 —— 假绿。
   修法：加 `clipt_take_data_debug`，让自测走**同一份**装配实现。

140. **`CLIPT_IMAGE` 那一档有四个 mime 公用一个码，只看码分不出优先级**（P83）：
   「收了 png 之后又来 jpeg」与「收了图片之后又来文本」在 `code` 上**同形**。第一版的守卫
   写成了 `code != NONE && code != IMAGE`，于是**低优先级的文本块把已经收好的图片覆盖了**
   （粘出来的「图」其实是一坨文本）。修法：用 `clipt_want` 的**下标**记「已经收下第几优先」，
   `slot > 已收` 丢弃、`slot < 已收` 作废重收、相等则继续拼接（大图本来就要多块）。
   这条是**自测先红**（「低优先级的文本块覆盖了已经收好的图片」），不是真机上发现的。

141. **假 helper 的 `PATH` 不能在夹具函数里 `defer` 还原**（P83）：`defer` 在夹具**返回**时
   就生效，而后面几个子函数还要用改过的 `PATH` 去探测 —— 症状是「前置进 PATH 的假
   wl-paste 没被探测到」，指向的是探测逻辑而不是夹具。修法：存进进程级缓冲，由**轮次**
   在收尾时统一 `cliph_old_path_restore()`。

142. **`bufx_eq_cstr` 的第三个参数是「字面量」，不是另一个 Buf**（P83）：比协议里的 `id`
   时写成了 `bufx_eq_cstr(buf.ptr, buf.len, id)` —— 而那个函数内部是
   `bufx_cstr_len(lit)`，**一路扫到 0**。`id` 是调用方的 `Buf`（**不保证 NUL 结尾**），
   于是它读到缓冲区后面的垃圾 ⇒ 长度对不上 ⇒ **永远判「不是这一轮」**。
   **症状**：读请求发出一遍又一遍、一个 DATA 都收不回来；`clip-term` 却全绿
   （进程堆恰好是零页）—— 又是「纯函数绿、真路径红」。**修法**：比两个长度已知的字节段
   一律用 `bufx_mem_eq(p, q, n)`；`bufx_eq_cstr` 只用于「Buf vs **字面量**」。
   **判据教训**：这条只能靠**直接钉 `clipt_frame_status`**（同一 id ⇒ 1、别的 id ⇒ 0）
   才抓得住 —— 假终端那个夹具的 id 恰好也是 `u1`，扫描器那几轮根本碰不到这条比较。
143. **能力位只在 `true` 方向被写过一次 ⇒ 切模型永不清零，env 路线也永远拿不到它**（P84）：
    `cfg.input_image` 出厂 `false`，全仓只有两处写它（`agent_apply_dsh` 那条路线解出来的
    模型条目、`agent_model_adopt_caps` 里命中目录条目的模型），**两处都是
    `if e.input_image { cfg.input_image = true; }`** —— 没有一处能写成 `false`。两个症状：
    * **切到不吃图的模型照收图**：`--model a-vision`（目录说吃图）之后再 `--model a-plain`
      （目录明写 `input: [text]`），`input_image` 仍是 `true`；用户挂上图、请求带出去，
      网关回 **400** —— 而本地那句「当前模型不吃图」的拒绝反而**再也**不会出现。
    * **env 给的模型拿不到能力**：`UYA_AGENT_MODEL=a-vision` **不查目录**（只有 `--model` /
      `/model` 走 `agent_model_apply`），于是目录里写着 `input: [text, image]` 也照样
      `input_image = false` —— 纯 env 部署（autodl 那类连 DSH 目录都没有）**永远挂不上图**；
      而 `--print-config` 只印一个 `false`，看不出是「目录说了不支持」还是「这条路没查目录」。
    **根因是两件事被压成了一个 bool**：「声明了不支持」与「根本没声明」分不开，于是
    「清零」这个动作无处安放、「没有信息」也无处表达。**修法**：能力位改**三态**
    （`MX_IMG_UNSET` / `MX_IMG_YES` / `MX_IMG_NO`；`modelx` 与 `dshcfg` 两份解析器同一套口径）
    + 一个**定稿点** `agent_vision_settle`（与 `agent_ctxwin_settle` 同形：启动收尾、切模型、
    恢复会话各调一次），口径收成「**默认支持** + 三个明确的关法」，并给它一对可证出口
    （`--print-config` 的 `input_image = … (source: …)` 与 `/model` 的 `image` 行）。
    **判据教训**：只调 `agent_vision_settle` 的自测腿**抓不住「调用点漏了」** ——
    把 `agent_model_apply` 里那一次 settle 删掉再跑，九条腿**一条不红**（实测）；
    必须有一条腿**走真入口**（`agent_model_apply`）才算数，见 §19.7。

144. **夹具目录没人建，而失败文案指着夹具内容**（P83 交付后修复，见 §19.6 末）：
    `clip-helper` 轮往 `build/selftest_clip_helper/` 里写假 helper 脚本，而那个目录
    **从来没有人建**（`sys_open(O_CREAT)` 只建文件、不建父目录）⇒ 干净树上第一次跑必红，
    报出来的是「**写假 wl-paste 失败**」。**为什么它能活过整轮验收**：脚本写入失败只影响
    这一轮，而**前一次跑到过这一步**（目录留着）就绿 —— 于是「rm -rf build 之后重跑」
    才第一次红，而那句话把人指向脚本内容（`printf '\\211PNG…'` 那几行），真身是少了一个
    `mkdir`。**修法**：夹具第一步 `sess_mkdir_p(dir)`，失败文案改成「建不出夹具目录
    （假 helper 没地方落盘）」—— 让文案指向目录而不是脚本内容。**对照**：删掉目录跑
    ⇒ 红（同一条文案）；补上 `mkdir` 跑 ⇒ 绿；再跑一次（目录已被上一次留下）⇒ 仍绿。
    同族现场见踩坑 134（夹具残留让症状指着产品）—— 两条合起来是一句话：
    **夹具的「有没有」必须由夹具自己保证，不能靠上一次跑剩下的**。

145. **`clips_fail(…, &ok)`：`ok` 本身就是 `&bool`，再取一次地址就写错了地方**
    （P83 交付后修复）：`clips_term_ids` 的签名是 `ok: &bool`，里面五处却写成
    `clips_fail(tag, …, &ok)` —— 传进去的是 `bool **`，而 `clips_fail` 收的是 `&bool`。
    Uya 的 `&T` 是裸指针，**编译期不报错、运行期也不崩**：`ok[0] = false` 落在那只
    **指针变量自己的存储**上（第一次写把它的低字节清成 0，此后 `ok` 已是野指针，
    后面几次 `clips_fail` 是在往一个垃圾地址写 —— 本轮实测没崩，纯属侥幸），
    而**轮次真正的 `ok` 一个字节都没被碰过**。后果：这一组断言**只打印，不判红**。
    **实测（把两个版本都跑过）**：先把踩坑 142 的原始 bug 放回去 ——

    | 版本 | 屏幕上 | 退出码 |
    |---|---|---|
    | 修前（`&ok`） | 4 条 `FAIL: …` 照常打印 | **0**（`SELFTEST CLIP PASS`） |
    | 修后（`ok`） | 同样 4 条 | **3**（`SELFTEST CLIP FAIL`） |

    ⇒ **§19.6 对照 F 那一行「`clip-term` 红 4 条」是照抄的屏幕文本**，而作为**对照实验**
    它是假绿：对照的判据是「改动让这一轮变红」，而当时它只是**打印**了 4 条 FAIL、
    轮次照样 PASS。**这条恰好守住踩坑 142 的钉子**（id 必须按长度已知的字节段比），
    所以那枚钉子当时其实**没有被任何东西钉住**。
    **唯一的机器信号是编译器的 `-Wincompatible-pointer-types` 警告**（五条，落在生成的
    `st_clip.c` 上）：`make build` 不因它失败（本仓不把警告当错误）、整轮 selftest 也不
    —— 而它正好把这五行一个不落地指了出来。修法是删掉那个多余的 `&`（五处）。
    **判据教训**：自测里「**判红的那条通道**」本身没人测 —— `*_fail(tag, what, ok)` 传错
    一格，整组就退化成「只打日志的绿色」，而**屏幕上看起来完全正常**（FAIL 都打了）。
    凡是自定义 `*_fail` 的轮次，至少要有一条断言**真把轮次判红过一次**才算验过；
    顺带一条便宜的兜底：**编译警告里的 `-Wincompatible-pointer-types` 要真看一眼** ——
    这是本仓唯一能自动化看见这类错误的信号。

146. **「拖选复制」在终端里没有任何现成通道可借**（P85，本轮）。用户报的是「拖鼠标要按
   shift 才能选」。真机逐条排掉（deepin-terminal 6.5.21 / QTermWidget，X11；每条都有对照）：
   ① `ESC[?5522$p`（DECRQM）**零字节应答**，而同机 `ESC[6n`（DSR）回 `ESC[1;1R` —— 探针
   本身有效，不是「读不到」的假阴性 ⇒ 这台终端**不认 5522**；② OSC 52 写 `c` 与 `p` 两块
   板子发下去，剪贴板**一个字节都不变**（BEL / ST / 8 位 C1-ST 三种终结符都试过）
   ⇒ **不认 OSC 52**。所以「拖选即复制」只能自己实现，而 **X11 选区所有者是唯一走得通的
   复制通道**（真机 A/B：`SetSelectionOwner` + 应答 `SelectionRequest` 之后，桌面剪贴板
   管理器 `dde-clipboard` 会来取并**在我们退出后继续持有** —— 实测持有 0.6 s 就够，
   退出后 `Ctrl+V` 仍拿得到原文）。**另一头的根因**在键层：`tui_mouse_finish` 只吃
   `b >= 64` 的滚轮，按下/拖动（`b` 的 bit5）/抬起**一律丢弃** —— 拖选期间屏幕上什么都
   不动。**修法**：键层把左键三态折成事件（坐标跟着事件走），`term/tui/sel.uya` 记选区 +
   按显示列取文本，`media/clipw.uya` 当 X11 选区所有者。**三个实测约束**写进了实现：
   ① 拖动事件**不需要** `?1002h`（只开 `?1000h` 就收得到 `ESC[<32;x;yM`，所以那 16 字节的
   开/关序列一个字节都没动，三个自测轮钉着它们）；② 终端把「按下+拖动+抬起」**一次 write**
   送来（45 字节一条）⇒ 坐标必须**与事件配对入队**，只留「最近一次坐标」会让三个事件读到
   同一个点（选区退化成一个点，屏幕上什么都不高亮）；③ `TARGETS` **必须应答** —— 不答它
   时对端（Qt 一档）拿不到内容，读回来的是**上一次**的旧值。**自测踩的两个自己的坑**：
   ① 断言「解出来是什么事件」不能用 `tui_keys_inject`（解码 + 当场派发 ⇒ 队列被取空，
   断言只看得到 `TUI_K_NONE`），要用 `tui_key_feed`；断言「选区状态变了」则**必须**用
   inject（状态机在 `tui_handle_one` 里）—— 两条各测一半，别合并；
   ② `ChangeProperty` 的请求体是 **20 字节头**（window 4 + property 4 + type 4 +
   format 1 + pad 3 + **items 4**）＋数据，我第一版按 16 字节头写期望值，于是断言红在
   生产代码其实是对的那一侧 —— **测试自己的期望值也要按规范核**。

147. **「会话目标」落在 home 级文件里 ⇒ 同一台机器的所有会话共用一份目标**（P87，用户报的
   「goal 不是回话级别的」）。真机现场：甲会话 `/goal 基于uibackend 接入dsh web ui…` 建了目标，
   乙会话（另起一个进程、全新会话、**同一个 `UYA_AGENT_HOME`**）一启动 `/goal` 就看到**甲的目标**
   而且 `armed=true`；乙想建自己的目标则被 `A goal is already active. Use /goal edit …` 顶回来。
   最重的形态是 web：`WEB_MAX_SESSIONS` = 8 条会话是 8 个子进程，服务端把**同一个**
   `UYA_AGENT_HOME` 传给它们 —— 8 条会话抢一份目标，且甲的目标会被**任何一个**乙的进程自动续跑。
   **根因不是「谁忘了清」，而是落点选错了层**：`goal_path` 拿 `agent_default_home(cfg)` 拼
   `<agent_home>/goal.json`，而 `agent_home` 表达的是「这台机器上 agent 装在哪」，与
   `session.jsonl` 那条会话身份（`<home>/sessions/--<cwd>--/<id>/`）**毫无关系** ——
   名字叫「会话目标」，实际是「home 级单例」。**修法**：把 `goal.json` 挪进**会话目录**
   （与 `session.jsonl` 同目录），「属于会话」由**文件位置**保证，隔离不需要任何额外判断。
   **三条判据缺一不可**（`goal_session_dir`）：① 尾名整段是 `/session.jsonl` 且会话 id 非空；
   ② 它在**本次 `cfg` 的 home** 底下 —— `g_sess` 是**进程级**的，而夹具会换 `cfg.agent_home`
   去测别的 home（不判这条就会往夹具没准备的地方写）；③ 紧跟 home 的是 `/sessions/` 而不是
   只比前缀（`/tmp/ab` 与 `/tmp/abc` 差一个字符，只比前缀会误判）。**退回分支是故意留的**：
   拿不到会话时仍落 `<agent_home>/goal.json`（`--print-config` 那条路径上 `/goal` 照样可用）。
   孪生一条（**换了落点还得换投影**）：目标那份内存投影（`tasks_goal_ref`）是**推**出来的，
   `/new`、`/resume` 两个落点光清清单不够 —— 不重读的话屏幕上还挂着上一条会话的目标，
   而新会话本该一个都没有；重读必须在 `tasks_panel_sync` **之前**（面板文本从投影重建）。
   **判据教训**：「状态该属于哪一层」要看**它被谁消费**：goal 由「同一个会话续跑」的驱动器
   消费（§9.5），那就必须与会话同生命周期 —— 落在 home 上等于把「会话级」写成了「进程级」，
   而它**编译期、类型检查、原有自测全都看不见**（旧自测恰好钉的是「目标不该被清」，方向相反）。
   修法验证：新增 `goal-sess` 轮（两条真会话 + 一条 `--no-save` 会话），先做**对照实验** ——
   把 `goal_path` 的会话目录分支短路回修前行为 → 9 条断言当场红（含「乙看到了甲的目标」），
   改回即绿。
148. **两套通道编号：三个里错了两个，而错法是静默串位**（P80 第二批）：界面后端接缝的
    `UiBackend.text(chan)` 里，端口的 `UI_CH_*` 是 **MAIN=1 / REASON=2 / NOTICE=3**；而
    TUI 内部的 `tui_sink_bytes(chan)` 是 **1=正文 / 2=通知（按 `\n` 切行）/ 3=思考**
    （`tty_reason_write` 送的就是 3，`tty_write` 把 fd 1→1、fd 2→2）。于是最自然的写法
    `tui_sink_bytes(chan, p, n)`（原样转发）会把**思考与通知对调** —— 不崩、不报错、
    编译期看不见、`--tui-demo` 也照不出来（它只喂 1/2 两个通道），只是用户看到的
    「思考」区里出现命令回执、回执区里出现推理过程。
    **修法**：转发必须过一张显式映射表（`betui_chan_map`），并且 `make ui-audit` 加一条
    硬判据 G（`src/ui/` 里把 `chan` 原样喂给 `tui_*`/`tty_*` 即红）。
    **判据教训（与 143 同族）**：「屏幕上有没有字」抓不住对调 —— 对调之后两边都有字；
    必须按**条目种类**数（`tui_entry_kind` == `TUI_E_REASON` / `TUI_E_NOTICE`）。
    同类还有一个**静默陷阱**：未登记的后端槽里是 `g_null`，它的 vtable **有效**，
    所以 `ui_use` 切过去**不崩**，只是从此丢弃一切输出 —— 判据 H 兜它，而判据必须读
    `g_reg` 字面量里那一槽是不是 `g_null`（只看「有没有 `ui_reg_put`」是假绿的）。

149. **「选后端」原先只发生在一个地方，而演示屏与自测夹具都绕过它**（P80 第三批）：
    `ui_use(UI_BE_TUI)` 只写在 `agent_tui_start` 里。改名接端口之后，凡是**不调它**却
    又要渲染 TUI 的路径全都会落到空后端上，症状一律是「整片内容变空」而**没有任何报错**：
    * `--tui-demo`（只 build 帧、不进备用屏幕）⇒ 第 50/81 行的「你」与工具块整片消失；
    * TUI 自测夹具（`tuis_reset`）⇒ 8 条「转录里没有…」的断言当场红 —— 夹具整轮在测
      TUI 渲染，却把输出丢进了空后端。
    **教训**：把「谁有权决定界面」搬进端口时，**「选择」这个动作本身也是要被搬的东西** ——
    只搬「输出接口」不搬「选择时机」，就会得到「接口对了、后端没选上」这种**静默全空**。
    判据 H 管的是「别切到空后端」，管不了「该切的时候没切」；后者只能靠每条渲染路径
    自己显式 `ui_use`（演示屏、自测夹具、**以及 headless 分支**各一处 —— 前三处是红色的
    现场，第四处是按同类清查出来的**潜伏**现场，见 §11.9.5 的缺陷表④）。
    **孪生一条（改名类改动的通用陷阱）**：定义改名成 `betui_*` 之后，`be_tui.uya` 里的
    调用点漏改**编译期不报错** —— 合并命名空间里 `tui_add_user` 看起来就是个外部函数，
    只有 `make build` 链接时才炸 `undefined reference`。所以「改名」不能只跑 `make check`。

150. **「判据覆盖的是我想到的那条路」：一条命令绿了，而用户跑的是它的另一条输入路径**
    （P80 第二十二批，用户报的）。用户报两条「页面坏了」，而 `make dsh-web-check`
    对**两条都绿**。第一条的现场：零参数 `./build/uya-agent --dsh-web`（没有事件源）
    ⇒ 页面 `Failed to load history: api gateway: invalid Remote stream frame`，
    控制台每 3 秒一轮 `connection lost, retry`。`dsh-web-check` 之所以看不见：
    它**总是**先拿 `--selftest` 把一份真日志翻成译文再起宿主（那条路是**有**译文的）。
    根因是快照 `records[]` 的逗号 —— `dwh_seed_records` 把收尾逗号**焊在字面量尾部**：

    | 输入路径 | 从前发出的字节 | 结果 |
    |---|---|---|
    | 零事件源（**用户跑的**） | `…"never"}}},` + `,{…end-seed…` ⇒ `},,{` | 非法 JSON ⇒ 拒帧、4002、重连 |
    | 有译文（**判据跑的**） | seed 的收尾逗号正好是它该要的那个 | 合法 ⇒ **绿** |

    **两件事值得记**：① `},,{` 的每个**片段**都在（`user/message`、`end-seed`、
    `"seq":3` …），所以子串断言全中 —— 与 §11.9.7 第五批「子串抓不住结构坏掉」同族，
    这次换了个面；② 修的时候当场又写出**反方向**的半成品（seed 写了逗号却没翻
    `first` ⇒ 后一段以为自己是第一条、不写 ⇒ `}}{`），而**两个方向的页面症状一模一样**
    ⇒ 逗号纪律必须落在**一处**（`dwh_record_sep` + 共用的 `first`），不能三段各写各的。
    **判据修法**：给同一条命令加**第二腿**（同一份代码的**另一条输入路径**），
    并用本仓的 JSON 解析器当 oracle（`selftest[web-snapshot]`）——
    子串对「结构坏掉」是瞎的。**通用教训**：一条命令的判据要按**输入路径**清点，
    而不是按「我实现的分支」清点；`--dsh-web` 有事件源与零事件源两条，就欠一条判据。

151. **「设置面板」那一族错误是「红字」而不是崩溃 ⇒ 只有把每个页签都点一遍才看得见**
    （P80 第二十二批，用户报的，与 150 同批但根因无关）。用户在设置界面看到
    「模型加载供应商也失败」。四个页签各自把整片渲染成一句「未实现」（实测逐个点过）：
    General → `permissionPresets/catalog`、Models → `llm/listProviders` +
    `llm/listConfigurableProviders`、Built-in plugins → `pluginInventory/list`、
    Agent presets → `agentPresets/list`。**这是最容易被判成「那个功能本来就没有」的形态**：
    不崩、不白屏，只是一片写着 `internal: not implemented: <方法名>` 的区域。
    **修法**：`dwh_unary_settings` 六个方法，形状**逐个从真 DSH 的 typert host 抄**
    （`z.object` 的键名与可选性）—— 猜形状的代价比「未实现」更高：
    `settings.describe` 那次把 `namespaces` 给成对象（客户端对它 `.find()`）让设置面板
    **整片塌掉**，症状与「没实现」完全不同。
    **同批暴露的投影缺陷**（这次才走到那条路）：快照的
    `projections.values.permissions` 给 `{}` 是错的 —— 它的**视图**是 `{currentValue}`，
    客户端拿它去 `catalog.options` 里找，找不到就回落成「把 `undefined` 当名字」⇒
    `displayPresetName` 里 `name.split` 抛 `TypeError` ⇒ slot
    `conversation.input.permission` **整块崩掉**。**教训**：给「投影」填中性值时，
    要按**客户端的视图 schema**（`{currentValue}`）而不是按「这里大概是个对象」——
    `{}` 不是「空值」，它是「一个所有键都 undefined 的值」。

152. **「出参先 `buf_new`」这个老习惯在 `pm_fact_decode` 里 ⇒ 记忆攒得越多、空闲 agent 的
    RSS 越大**（用户报的「内存进来就 56M」）：
    现场：一个刚起、**一步都没走**的 agent 报 57 MB；而 `--no-memory`、空 agent home、
    别的 cwd 全是 10 MB —— 数字完全跟着**本仓的记忆分片**走，与 `pm-memory` 那段注入
    文本的大小无关（预算 3072 B 固定）。
    逐层二分（同一份真机记忆目录，`--no-save` 直接 EOF 退出）：全目录 57 MB →
    只留小分片 31 MB → 只留一个 502 KB 分片 15 MB → 空 11 MB；把行数按
    1000/2000/4000/8000 铺开是 11/19/35/62 MB，**线性于行数**（≈4096 B/行）；
    把 `value` 写长写短都不影响 ⇒ 是**每条一次固定开销**，不是数据本身。
    根因：`pm_fact_decode` 的三个出参写成了 `var key: Buf = buf_new(PM_KEY_MAX)` 这种形状
    （key 256 + value 2048 + src 256），而 `js_obj_get_str_unescaped` 内部走
    `sv_unescape_to_buf` —— 那是 `out[0] = buf_new(s.len + 8)`，**直接覆盖出参指针**，
    原来那三块永不 free。每解析一行泄漏 2560 B，加上堆头与 16 B 对齐正好对上 4096 B/行。
    踩坑 92 的「孪生一条」当时只改了 `ag_request_stream` 那一处，`pm_store` 这处漏了 ——
    同一个 API 的同一个语义坑踩了第二次，而且这次的量级是**静态**的：
    一次载入 6931 行 = 17 MB 净漏，随分片累积单调变大。
    修法：三处初值改 `buf_empty()`（既有的 `defer { buf_free(...) }` 不用动）。
    判据（实测，`--no-save` + stdin EOF 采 `/proc/<pid>/statm` 峰值）：
    修前 57～62 MB → 修后 **4～5 MB**，同一份输入重复跑一致；
    语义侧由 `make pm-selftest` 的 `pm-roundtrip` 覆盖（它照样走 decode 路径）。
    **内存量级本身没有自测**，量它的办法就是这条：拿真机 `~/.uya-agent/memory/<key>/obs/`
    当输入，两版二进制各采一次峰值。
    教训：**「出参给一个已分配的 Buf」在 Uya 里不是优化，是 bug** —— 只要被调用方以
    `out[0] = buf_new(...)` 开头，那句预分配就是纯泄漏。仓里正确形状一律是
    `buf_empty()` + `defer { buf_free(&…) }`（`buf_reserve` 的「按需扩容」语义与这种
    「整体替换」语义不是一回事，别混）。自查：
    `grep -rn -B2 'js_obj_get_str_unescaped' src | grep 'buf_new('` —— 现在应该 0 命中。

153. **转录的「4 MiB 上限」是正文口径 ⇒ 真实驻留是它的 3 倍，而且计数器只加不减**
    （本轮，用户问的「长期运行的 agent 内存优化，很老的转录能不能不放在内存里」）：
    先说结论：**转录本来就只保留一部分**（环形 512 条 / 正文 4 MiB / 单条 256 KiB，
    最老的条目直接 `buf_free`），所以「老的不放内存」这件事已经做了。查下来真正的
    毛病是四条，全都在**记账与上限口径**上：
    ① `g_tui_text_total` **只加不减** —— 思考条目每次超 `TUI_REASON_TAIL` 就从头部丢一段
    （`tui_sink_reason`）、单条超 `TUI_ENTRY_MAX` 也从头部丢（`tui_entry_append`），
    两处丢掉的字节一个都不减；此外 `tui_entry_append` 累加的是**请求长度 n** 而不是
    实际接受的字节数。于是一个 `REASONING_EFFORT=max` 的长会话会把计数器推到远超
    真实占用 —— 转录**比标称的 4 MiB 早得多**开始丢老条目。这就是「很老的数据没了」
    的真正原因（不是上限太小，是账算虚了）。
    ② **上限只管 `text`**：`wrap`（折行文本，≈正文大小）、`md`（markdown 逐字节样式，
    与 wrap 等长）、`wrap_ix`（折行行数 × 8 B）都不在 `TUI_TEXT_MAX` 里 ——
    实测正常内容真实驻留 ≈ **3.0× 正文**，病态输入（深缩进长行，折行文本比正文大
    二十几倍）没有上界。
    ③ `tui_transcript_clear()` 把 `tui_lineidx_reset(&wrap_ix)` 写在 `if buf_valid(&md)`
    **里面**，而 `md` 只有 ASSIST 条目才分配 ⇒ TOOL / USER / NOTICE 的行偏移表
    **每次换会话（`/new` / `/resume`）漏一块**，且屏幕上完全看不出来。
    ④ 单条上限对「一次整块塞进来」不成立：`tui_entry_append` 先按上限从头部丢旧字节、
    再 `buf_append(p, n)` **整块**写进去 —— 一条 1 MiB 的工具结果就让那条条目长到 1 MiB。
    修法：记账的「加」收成两处、「减」补齐四处（丢条目 / 单条截断 / 思考截尾 / 重折），
    并给出 `tui_text_bytes()`（现算）与 `tui_text_accounted()`（记账）供**复算对照**；
    新增 `TUI_DERIVED_MAX`（= 4× 正文上限）只挡病态派生增长；clamp 落在
    `tui_entry_append` 一处（连补换行也走它 —— 否则会长到 `TUI_ENTRY_MAX + 1`，实测 262145）；
    行偏移表的释放移出 `md` 分支。**可证出口**：溢出且上滚时转录第 0 行写
    `^ … 更早的 N 条已省略（全文在会话日志里）`（以前 `g_tui_dropped` 只写不读，
    注释里那句「顶部会写一行」根本没实现）。
    **这一轮的判据全是数值、屏幕上看不见**，所以单开一轮 `selftest[tui-mem]`（四段），
    并做了四次防假绿对照（各自单独回退都要当场红）：① 删掉思考截尾的减账 → 恒等式红；
    ② 把 `tui_lineidx_reset` 挪回 `md` 分支 → 存活分配 ≠ 0 红；③ 删掉 clamp → 单条红；
    ④ 删掉派生闸门 → 派生 54.5 MB（有闸门 20.4 MB）红。
    其中**③ 第一次写成了假绿**（判据用「正文总量」而夹具不以 `✓ ` 起头 ⇒ 被 NOTICE
    的 512 B 上限吃掉），改成「最后一条条目的 `text.len`」+ 工具头夹具才抓住 ——
    与踩坑 150 同族：**判据要按输入路径清点，而不是按我实现的分支清点**。
    **同批的另一条通道**：`view_think_delta` → `tty_reason_write` 不受 `--show-reasoning`
    开关管（那个开关只管「转录里的思考条目」是否显示），于是**默认配置**下每个思考
    增量都会进转录；好在这条路每个增量只送「最新一行」，`tui_sink_reason` 又把条目
    钉在 `TUI_REASON_TAIL` —— 所以它不是内存增长源，但值得知道：转录里**有**思考。

154. **会话身份被一次「静默降级」换掉 ⇒ 会话级状态（目标）跟着换目录，看起来像「丢了」**
    （本轮，用户报的「恢复会话后 goal、tasks 没有恢复」的**前半条**）：
    现场可复现 —— `/goal 把测试跑绿` 之后 `--resume <同一 id>`，屏幕上打
    `[session] 日志为空或无法解析，改为新建会话`，紧接着 `/goal` 报
    `No goal is currently set.`，而**老会话目录里的 `goal.json` 一个字节都没动**。
    根因不是「没读盘」，是**「折出几条消息」被当成了「恢复成不成功」**：
    `agent_hist_from_log` 处理一条**只有 header** 的日志时结构上完全成功（推了 system +
    上下文注入段），但 `added` 是 0（清单与 `session/title` 都不算历史消息）⇒
    `agent_session_open` 判 `n > 0` 失败 ⇒ 落到 `sess_open` 新建分支 ⇒ **id 与目录当场
    换掉**。而 P87 之后「目标属于会话」是**文件位置**保证的
    （`<home>/sessions/--<cwd>--/<id>/goal.json`）——位置一换，目标就「没了」。
    孪生症状：每恢复一次就在 `sessions/` 下多一个空壳目录（现网真机 2809 个
    goal/空日志目录，一堆 `lines=1`），而它**完全静默**（那句回执说的是「日志为空」，
    没人会把它读成「我换了你的会话 id」）。
    修法：判据挪到会话层 —— 新增 `sess_has_events`（读到过一条**完整事件行**），
    折出 0 条时用它分开「空会话」（复原会话身份，`sess_open_resume` 沿用原 id/路径）
    与「日志坏了」（才走新建）。**这类缺陷的通用形状**：一个「失败」被降级成一个
    「成功的另一种结果」时，凡是**按文件位置/名字**绑定的状态都会静默改指 ——
    降级点必须自己证明「我确实该降级」，不能只看上游那个数字。
    验收与对照实验见 §19.13（`goal-sess` D 段四条判据；E 组对照把降级改回去 ⇒ 红 4 条）。

155. **注释里写着「回合开始时清空」，而那句调用**从来没接线** —— 清单跨回合一直挂着**
    （同轮的另一半；与 154 是**两条**根因，别混）：`todo.uya` 的文件头与
    `agent_log_turn_start` 的注释都写着「回合开始清空（DSH 口径）」，DSH 那边也确实是
    `apply: turn/start → null`；而本仓 `todo_clear` 的调用点**只有**
    `agent_session_scoped_reset`（换会话那一处）—— 于是「上一回合的清单」会一直挂在
    常驻块与 `/tasks` 里，直到模型自己再写一次 `todo_write`。修法是把那一句补在
    `agent_log_turn_start` 里（并排在 `g_sess.save` 判断**之前**：`--no-save` 也要清）。
    **教训**：「注释写着的口径」与「真被调用到的口径」是两件事，而 `doc-cover` 只查
    注释在不在 —— 一条只活在注释里的不变量，在任何验收里都不会红。
    对照实验 D（把那一句拿掉 ⇒ 只有「回合开始清空」那条测红）见 §19.13。

156. **请求体里混进非法 UTF-8 ⇒ 网关 400，且那条结果永久留在历史里**（P93，用户直接撞上）：
    现场只有一行：
        model endpoint returned HTTP 400
        body: Failed to parse the request body as JSON:
              input[165].output: invalid unicode code point at line 1 column 312757
    然后界面写「本回合异常结束（可直接输入继续）」。**注意它是「继续」不是「修好」**：
    `input[165]` 是历史里一条 `function_call_output`，坏字节（或它的转义）**每轮都重发**，
    所以后面每一轮都 400 —— 这正是踩坑 27（NUL 让网关 400）的同一形状，只是坏的东西不是
    控制字节，而是**半个汉字**。两种来源，都能在历史里复活：
    ① **按字节截断**：`bash` 的输出原样进结果缓冲，`max_tool_out` 是字节数 ——
       `—`(E2 80 94) 被截成只剩 `E2`、`本`(E6 9C AC) 被截成 `E6 9C`；
    ② **`\uXXXX` 反转义**：响应里单独出现的 `\uD83D`（没有低位代理）被 `append_utf8`
       按 WTF-8 编成 `ED A0 BD` —— 那本身就不是合法 UTF-8。
    而 `jw_str` 当年只挡 `0x00…0x1f`（踩坑 27 的修法），`≥ 0x20` 的字节**一律原样过**，
    于是这两个字节串真的一字不改地进了 `input[].output`；网关那侧是严格 UTF-8 解码器，
    于是整条请求被拒。`make check` / 自测全绿——它们不看「产物是不是合法 UTF-8」。
    修法（四层，缺一层就还能复现）：
    * **规则表只有一份**：`bufx_utf8_seq_len`（严进：过长编码 / 代理项 / > U+10FFFF /
      截断的半个字符 / 裸续字节都返回 0），`bufx_utf8_valid` 也改走它 ——
      旧的那份宽松校验（只看续字节位）会把 `ED A0 BD` 判成合法，正是它让「自测说合法、
      网关说非法」成立；
    * **写请求体那一侧**：`jw_str` 遇非法字节写一个 U+FFFD（EF BF BD）并前进 1 字节，
      合法多字节序列仍整段原样搬（中文正文性能不变）；`jw_str_esc_len` 同步改（+3），
      否则 `calls_json_need` 的预算算少（踩坑 35 的形状）；
    * **写会话日志那一侧**：`session.uya::jw_str_into` 同一套规则 —— 日志是 `--resume`
      的唯一来源，只挡请求体等于「重启又把坏字节喂回来」；
    * **反转义那一侧**：`append_utf8` 对代理项/超范围码点写 U+FFFD，不再编 WTF-8。
    判据（`jsonesc_round` 的 `jsonesc_utf8` 段，`make selftest` 里的 `json-escape`）：
    截断前导字节 / 截断的 3 字节 / WTF-8 代理项 / 过长编码 / 裸续字节各变一个 U+FFFD；
    合法中文与 emoji **原样保留**；产物本身过 `bufx_utf8_valid`；`jw_str_esc_len` 与
    实际写出**逐字节等长**；`jw_str_into` 写出**同一串**；`\uD83D` → U+FFFD，
    而 `\uD83D\uDE00` → 一个 4 字节 emoji。
    **教训**：「转义」的验收不能只问「JSON 还能不能解析」，还要问「字节是不是合法 UTF-8」
    —— RFC 8259 允许 `\uXXXX` 逃逸，但**不允许**把非法字节直接塞进字符串字面量，
    而这两件事在本地看起来一模一样。

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

99. **「模型」被当成一个名字，而它其实是一个二元组 —— 同名跨提供方时另一家永远选不中**（P62，用户报的）：
   现场：`settings.yaml` 里 `aigw-local` 与 `autodl-api` **都**发布了 `id: DeepSeek-V4.1-Flash`
   （默认路线是 `autodl-api`）。用户在 `/model` 浮层里选中另一家的那一行按回车，**屏幕上什么都不
   发生** —— 信息行不变、也没有任何提示，看上去像「按键没生效」。
   根因是**同一条链上有三处都把「模型」当成一个名字**，于是同名时每一处都各丢一半：
   ① **显示层**：`agent_model_items_into` 每行只写模型名，`✓` 判据也只比 `cfg.model` ⇒ 同名两行
   **都挂 ✓**，屏幕上分不出哪一行才是当前路线；
   ② **选择层**：`agent_model_item_parse` 只反解出模型名，`agent_tui_model_handle` 于是只能拿
   **当前** `cfg.provider` 去 `agent_model_apply` ⇒ 选另一家的同名行时 `mx_find(当前, 名字)` 命中的
   还是**当前**那一条；
   ③ **幂等分支**：`agent_model_apply` 判出「同一个 (provider, model)」就 `return 1`，而它在
   `announce` **之前**返回 ⇒ 连一条 notice 都没有 ⇒ 「选不中」被伪装成「什么都没发生」。
   `--model` / `/model <名字>` 这两条只给名字的路同样够不到第二家（`mx_find` 的跨提供方回退取
   **第一个**匹配）。真机对照：`/status` 与 `--print-config` 一切正常，只有「选另一家」这一下是死的
   —— 因为前两者读的是 `cfg`，而故障发生在「从一行文本回到二元组」这一步。
   **修法**（把二元组一路带到底，且**绝不猜**）：
   * 浮层每行写成 `✓|  <名字> · <提供方>  effort: …`（提供方紧跟名字，不放行尾：行尾会被框宽裁掉，
     而档位清单随时能顶到框外）；`✓` 按 `(provider, model)` 比；
   * 反解把提供方一起交出来（没有 ` · ` 标记的老格式交回空串，调用方退回当前提供方）；
   * `agent_model_apply` 收 **`提供方/名字`** 写法，且**只在「这一对确实在目录里」时才拆**
     （`Qwen/Qwen3-32B` 这类 id 自带 `/`：拆错会把请求发到别的路线，比「名字换了能力没跟上」更坏）；
   * 幂等命中时补一条可见回执（`已经就是这个模型：<提供方>/<名字>`）—— 静默的 no-op 是最难查的形态；
     回车落在**分组标题**（`# <提供方>`）上也给一条说明（那一行不是模型；同名模型恰好就夹在这些
     标题之间，多按一下 ↑/↓ 再回车正是「什么都没发生」的经典现场）；
   * 同名别家存在时，回执追加「另有提供方发布同名模型：…；要指定用 `提供方/名字`」；
   * `--provider` 也**当场解析路线**（端点/凭据/协议），并在 `--model` 已给过时照新提供方重收口一次
     —— 否则 `--provider P` 只改了个名字，`--provider P --model M` 还会把 P 的模型名打到旧端点上
     （踩坑 96 的孪生形态）；两条参数顺序因此结果相同；
   * **显式优先，且不许跨提供方回退把它吃掉**：`agent_model_apply` 在「指定提供方下查不到」时会按
     名字**跨提供方**回退（那是 `/model <名字>` 的语义），拿它处理显式声明会把用户点的 P 悄悄换成
     别家（症状：`--provider beta --model m` 打出来 `provider = alpha`）。所以显式给过 `--provider`
     时先问一次目录：这一对在 P 下存在才收口，否则按「目录外」的老口径（只换名字 + 解析 P 的路线）。
   教训：**凡是「用户用一行文本指定一个实体」的地方，行里必须带够把那个实体唯一确定下来的字段**。
   判据写得再细也救不了「行里根本没这个信息」——而缺的那一半不会报错，只会让另一家的选择**静默失效**。

100. **「浮层开着就藏光标」这条不变量，在「自带插入点的浮层」上是错的**（P66，用户报的）：
   现场：`ask_user_question` 的提问弹窗里，自定义回答行（`✎ …`）明明能打字（`tui_ask_type`
   追加、`tui_ask_backspace` 退格），屏幕上却**看不见任何插入点** —— 用户报的就是
   「提问窗口里输入行没有光标」。
   根因是两条各自都对的规则叠在一起：
   ① `tui_cursor_place` 的口径是「`run == IDLE` 或**没有浮层**时显示真光标」（踩坑 66 定的：
   浮层开着时键全被浮层吃掉，插入点不在输入行上，露出来只会误导）——而 ask 弹窗恰恰是在
   **回合运行中**（`TUI_RUN_TOOL`）打开的，于是真光标被藏；
   ② ask 的自定义回答行**只画文本、不画插入点那一格**。同族的 P48 input 型浮层是画了的
   （`ask.uya` 里用 `TUI_ST_SEL` 反显光标那一格），ask 这条路当年漏了。
   两条单独看都成立，合起来就是「能打字却看不见光标」。
   **修法**：在 ask 的自定义回答行**固定留一格**画 `TUI_ST_SEL`（对齐 P48 的既有做法，
   不动光标可见性那三条不变量）；文本预算从 `body_w - 2` 收到 `body_w - 3`，右侧补空格，
   于是**整行显示列一个字节不变**（`│ ` + `✎ ` + 文本 + 插入点 + 补齐 + `│` = `w`，
   `tuis_scan_rows` 的逐行宽度断言因此原样通过）。框宽预算同步加 1 列 —— 否则窄框上占位
   会被多裁一格、白白早降一档。非打字态也画：那句话本来就落在这里。
   教训：**「这个表面不需要光标」是个需要逐个表面验证的判断，不是一条可以整体套用的不变量**
   —— 凡是「键落在这里、文本也写在这里」的浮层，都得自己把插入点画出来（真光标被藏时它是
   唯一的可见反馈）。自测补三条腿（初始态 / 打字态 / 0 选项态），判据是「含 `✎ ` 的那一行里
   存在一个 `TUI_ST_SEL` 段」，不写死列号（插入点跟着文本长度走）。

---

## 18. TLS 信任策略（重要，和标准库现状有关）

`lib/tls` 是**真 TLS 1.2 客户端**（SNI、ECDHE-P256、PRF、Finished、系统信任库），实测对
`api.deepseek.com` 能完成握手并拿到 `HTTP/1.1 401`。但它的**链校验在真实站点上根本不可用** ——
下面每条都是本轮逐条实测的（不是从标准库源码猜的）：

* **`ctx.peer_leaf` 恒为 NULL**（这条是致命的）：`ssl_capture_peer_chain_from_server_flight`
  按「**带 record 头**」的缓冲扫 `server_flight_msg`（它先读 `data[record_pos] != 22` 就
  `return`），而 `hdr.server_flight_msg` 存的恰恰是**不含 record 头**的握手消息流
  （类型 1 + 长度 3 + 内容，见 `hs_parse_*` 里那段保存循环）。于是它对真实站点**一个证书都
  解析不出来**。自测证据：`--probe --tls-verify=chain` 对 `www.autodl.art`、`example.com`、
  `api.deepseek.com` **一律** `HcTlsUnsupported`，打点显示 `peer_leaf=NULL`。
  ⇒ **`chain` 档在真实站点上是必然失败，不是「通常失败」**（本节旧版写的
  「`example.com` 恰好能过」是错的，实测它同样失败）。
* **`verify_chain_rsa` 要求「服务端发来的链顶公钥 == 某个信任锚」**：真实站点不发根证书，
  所以就算把链解析出来也过不去。
* **`mpi_mul` 装不下 RSA-2048**：`MPI_MAX_LIMBS = 32`（32×64 = 2048 **位**），而
  `mpi_mul` 的守卫是 `a.n + b.n > MPI_MAX_LIMBS` ⇒ 两个 2048 位数相乘需要 64 个 limb，
  直接 `TlsBadInput`。实测：agent 侧自己把 leaf 的 tbs/sig/公钥字段全解对之后调
  `rsa_verify_pkcs1_v15_sha256`，仍然 `TlsCryptoFailure`。
  ⇒ **在现有标准库上「自己补一条链校验」也做不到**，不是接错线的问题。
* **信任库只读前 64 KiB**：`TRUST_STORE_READ_BUF_SIZE = 65536`，而 Debian/Deepin 的
  `ca-certificates.crt` 是 224449 字节 / 150 张证书 ⇒ 只装进**前 44 张**。实测
  `DigiCert Global Root G2`（`www.autodl.art` 的链顶）在偏移 75389 —— **在读窗口之外**。
* **`ssl_set_peer_identity` 把 `peer_san/peer_cn` 设成我们自己传进去的期望域名**，
  所以标准库那一步「主机名校验」实际是拿期望值和期望值比，等于没校验。

因此本项目**不改标准库**，而是在 agent 侧提供**四档**策略：

| 模式 | 行为 |
|---|---|
| `--tls-verify=tofu`（默认） | **首次使用即信任**：第一次连某主机就把 leaf SHA-256 记进指纹库（`<agent home>/tls_pins`），之后每次都必须逐字节相符，不符即拒（`HcPinMismatch`）；**唯一的例外是 P92**：没记过的那张证书若链能验到系统根，就学进库并放行（`--no-tls-tofu-learn` 关掉，见 §19.17）。不需要 CA 库、不需要人手抄指纹 ⇒ 新机器开箱可用，且强于 `none` |
| `--tls-verify=chain` | 握手后调用导出的 `verify_chain_rsa`。**真实站点上必然失败**（理由见上），保留它是为了「中间人告警」这条路：真有中间人时它落在签名/CA 约束那一支，而不是 `peer_leaf=NULL` 那一支 |
| `--tls-verify=pin` | 直接校验**服务端 leaf 证书 DER 的 SHA-256** 是否等于 `--tls-pin`。指纹从 `HandshakeCtx.server_flight_msg` 自己解析出来（不依赖 `cert_parse` 的 RSA 前提），实测与 `openssl s_client \| openssl x509 -outform DER \| sha256sum` 完全一致 |
| `--tls-verify=none` | 不校验，仅打印观测到的 leaf SHA-256 与告警 |

**为什么默认档是 `tofu` 而不是 `chain`**：`chain` 在真实站点上**必然**失败，而新机器
（没有 `~/.dsh/settings.yaml` ⇒ 落默认档）第一次跑 `uya-agent hi` 就会看到
「请求失败（网络或 TLS 校验）」—— 这正是用户报的那个症状（Ubuntu 26 那台）。`tofu` 是唯一
既能当默认、又不放弃防护的档位（`none` 无防护；`pin` 要人手抄指纹）。

**指纹库**（P78）：`<agent home>/tls_pins`，一行一条 `<host> <64 位小写 hex>`，`#` 注释与空行
忽略，同一主机可有多条（站点轮换证书/多机房是常态，命中任意一条即通过）。主机名与指纹比对
都做大小写折叠。`$UYA_AGENT_TLS_PINS` 可整条覆盖路径；`--print-config` 的 `tls_pins` 打的就是它。
**多条怎么来的**（P92）：除了人手往里加，`tofu` 档会在「新证书过了发证机构校验」时**自己追加
一行**（每台主机最多 4 条，到上限就不再追加、也不淘汰）；链校验用本仓自己实现的
`net/rsav` + `net/x509min` + `net/cachain`（不走 lib/tls，理由见 §18 的三条死路，细节见 §19.17）。
**只有 chain 档加载系统根证书库** —— `pin` / `tofu` / `none` 的判据是 leaf 指纹，与 CA 库无关
（实测：把 `/etc/ssl` 挂空之后，旧代码里 `pin` 档**拿着正确的指纹**也报 `HcTlsUnsupported`）。

推荐用法：默认档什么都不用配就能连上；要更强的保证就钉死指纹：

```bash
./build/uya-agent --probe --tls-verify=none                 # 记下 leaf_sha256
DEEPSEEK_API_KEY=sk-xxx ./build/uya-agent \
  --tls-verify=pin --tls-pin 30d82529d19c5da6175a80db1c5522ac3ba5b42589212405cdc8783a1bf047fa \
  "创建 hello.uya，编译并运行它"
```

本地明文端点（ollama / llama.cpp 的 OpenAI 兼容接口）不走 TLS，直接
`--base-url http://127.0.0.1:11434/v1` 即可。

**失败时的诊断**：四档的失败原因各有各的修法，所以错误码是分开的
（`HcTlsNoChain` / `HcTlsNoAnchors` / `HcTlsNoLeaf` / `HcPinMismatch`），不是一律
「检查 base-url / 网络」。观测到的 leaf 指纹从 `hc_last_leaf_ptr()` 取 —— 流式路径**拿不到
`TlsConn`**（`llm_stream_style` 里那个是它的局部变量），旧代码因此在这条最需要指纹的路上
把指纹丢掉了（踩坑 132）。

**「连不上」的口径从 P80 起再分三档**（踩坑 133）：`HcDnsFailed`（名字没解开 —— 看解析器
与 `$UYA_AGENT_DNS`）、`HcConnectFailed`（TCP 没连上 —— 看网络/代理/端口）、
`HcHandshakeFailed`（TCP 已连上、握手谈崩 —— 看证书/中间设备）。这一档与上面那四档
**不是同一件事**：前者是「信任判定不通过」（连接已经建立，是我们拒了它），
后者是「连接压根没建立」。两族共用一个出口 `agent_net_fail_report(cfg, kind)`
（`kind` 6/7/8 是新三档），第一行话术也分开了，所以 `uya-agent hi` 在 DNS 坏掉的机器上
**不会再假装是 TLS 问题** —— 那正是这次用户看到的那句谎话。

> 后续可做的（本项目**没做**）：给 `lib/tls` 补一条真正的链构建（用 issuer/签名关系从 leaf 走到
> 信任锚、支持 SHA-384）、把 `MPI_MAX_LIMBS` 提到 RSA-2048 需要的大小、把信任库改成读全文件、
> 并把 leaf 的 SAN 真正解析出来做主机名校验。**这四件事做完之前 `chain` 档都不可能对云端可用**
> —— 只做「链构建」那一件是不够的（`mpi_mul` 那一关就过不去）。

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
| `tui-marquee` | P75 放不下的文本滚动显示六段：**A** 装得下时逐字节不变（短路径 11 列、无 `…`、tick 恒 false 不置脏）；**B** 200 列下 cwd 段仍只占 30 列、尾段不在屏上、带尾随 `…`（旧行为整条放出来 ⇒ 红 3 条）；**C** 时间闸门（同一毫秒连推 5 次不动）、一列一步、滚到尾后尾段与分支上屏、端点停满 4 步、第 5 步归零重来；**D** 复位 —— 夹具用**兄弟路径**（真 worktree 形态：同长、前 16 字节相同）⇒ 只有 `tui_set_cwd` 里那次显式复位能救，`tui_reset_all` 同理；**E** 不变量：滚动中整行 ≤ cols、右半区仍右对齐 `cols-3`、40 列仍整段让位；**F** 心跳置脏（推进了必须有帧待画）；**G** **真 PTY** 端到端：长工作区起真 TUI、**不按键**只收帧，路径后段必须自己滚上来 —— F/G 两段都是**假绿**逼出来的（headless 的 `tui_flush` 因 `out_fd < 0` 早退 ⇒ 脏位永远清不掉 ⇒ 任何脏位判据在 headless 里恒真，见 §19 P75） |
| `tui-marquee-row` | P76 一格一条的簇里**只有选中项滚**四段：**A** 120 列真命令表面板（两条长命令同屏）—— 推进 8 拍后**方框之内除选中那一行外逐行逐字节不变**、选中行真在动、且它仍以 `/model [名字\|提供方/名字] ` 开头（钉住）；**B** 一路滚到尾段（`管推理强度）`）上屏且命令名仍在同一行 ⇒「只滑说明」；换选之后原行回到静态截断（尾串消失 + 尾随 `…`）、再选回来从头部开始；**C** 另两条簇同一条纪律（ask 选项 / reader 动作行；动作行一行多项但共用槽位是安全的，见下方对照实验④）+ **没有分列空格时长行整行滑**（钉不出名字就不该钉）；**D** **真 PTY** 端到端：真 TUI 喂 `/model` 开面板，**不按键**只收帧，用 `web/ttyemu` 解成网格逐行差分 —— 方框内只有选中那一行在变、命令名仍在。判据只认**方框之内**（脚注 cpu/ctx/时钟、状态区本来就每拍在变；算进来等于恒红，P75 的 F 段正是被这类噪声盖住才假绿） |
| `tui-keys` | UTF-8 逐字符编辑、切开的 `ESC [ D`、Ctrl-J、↑历史、tab plan、面板、Ctrl-D/Ctrl-C、`tui_abort_state()` 三档；**ctrl+v 贴剪贴板（踩坑 110）：无浮层时给出 `TUI_REQ_PASTE`、浮层开着时不动全屏态、全部 `TUI_K_*` 事件码两两不同的哨兵、help 文案里有那一条** |
| `tui-turn` | headless 端到端：用户条目、`✓ Write`/`✓ Bash(`、最终答案、状态区收掉无残影；脚注含 `1 轮 · `；**P58 续跑腿**（换一份 mock 重跑：`create_goal` 之后主循环空闲即自开第二轮 → 续跑轮用记账后的 revision 标 complete → 授权收掉、转录里不出现 `<goal_round>` 用户条目） |
| `tui-status` | 常驻状态区 + 思考实时行：铺满后仍钉住、只显示 `latestLine`、空闲 0 行、窄终端退化 |
| `tui-caret` | 踩坑 66：运行中（思考/输出/工具）输入行有光标（标志位 + 字节级 1×`?25h`/0×`?25l`）；空闲与「空闲+浮层」两格不变；运行中开浮层仍隐藏（1×`?25l`/0×`?25h`） |
| `tui-p30` | 泵点当场派发只读命令、`/new` 立刻回执、`/compact` 留 step 边界；真 PTY `/status` ≤800 ms（`mock_mode=40`） |
| `tui-p31` | 派发后同一次调用帧数 +1、结果留给主循环；真 PTY ≤800/≤150/≤300 ms |
| `tui-cmd` | 面板 ↔ `/status` 浮层：输入行不留 `/`、标题逐字节、正文层无 NUL、运行中 step 边界派发；**F 段（P57）**：循环选择（`↑` 顶→底 / `↓` 底→顶、中间项仍逐格走、`Home`/`End`/`PgUp`/`PgDn` 仍夹取、矮框里步长同为 ±1 时 `PgDn` 夹取而 `↓` 回绕的判别腿）+ 已输入文本画在标题栏（非空才画、退格跟随变短、长词保尾补 `…`、脏字节单行清洗、方框仍逐行闭合） |
| `tui-scroll` | P32：2400 行条目 PgUp 到 `LONG-ROW-1`、`ESC[1;5H` 尾巴不漏、SGR 滚轮、鼠标上报开关 |
| `stats-format` | 纯函数：duration/tokens/tok-s/缓存命中取整（12.5%→13%）与除零保护 |
| `stats-line` | 整行逐字节（DSH 截图那行）+ 四种判据 + **P72**：缺明细的步不进命中率分母（真值 90% 不许被打成 0%）、全无明细时不报百分比、明细说 0 要照报 0% |
| `stats-fold` | 实时喂与日志回放 11 字段逐字节相同；重复 callId 取最后一次；**P72**：`cacheSplitKnown` 三态（1 有明细 / 0 未知 / 缺键=老日志按有明细）两条路一致 |
| `stats-context` | 占用率/`projectedTokens`/`~已用 / 容量`/20 格分段条逐字节 |
| `stats-usage` | 端到端一轮（只给这轮开 usage），回合正常结束 |
| `stats-log` | `step/start`↔`step/end` 成对、回放与实时逐字节相同 |
| `cache-burst` | P28 突发未命中判据（4 组真数据要标记 / 5 组不标记 + payload 形状）；**P72 反向**：缺明细判成 `unknown` 而**不是**突发，有明细的整段未命中**仍要**报突发（少一半判据就会把真淘汰一起静音） |
| `procx-parse` | `/proc/<pid>/stat`：comm 取首 `(` 到末 `)`、ppid 第 2 字段、utime/stime 第 12/13 字段、坏行必须失败 |
| `procx-percent` | `Δticks × 1000 / Δms`：0/37/100/250、`Δms=0` 不可算、钳 999、`USER_HZ=100` |
| `procx-tree` | P24b 进程树判别（纯函数合成数据）：root/子/孙、**行序打乱**（子先于父）、**跨 comm 桥接**（agent→bash→agent）、20 层链、父不在表里、root 不在表里、自环与 `ppid=0` 不卡死、空表 |
| `procx-mem` | `Pss:`/`VmRSS:` 解析与显示（`0K`…`65.7G`，`-1` 不写字节） |
| `cpu-live` | 忙循环子进程：进程数**恰好** +1（严格相等 —— 老的全机口径会让这条红）、`cpu ≥ 25`、内存 ≥ 1 MiB；只建基线不给百分比 |
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
| `model-catalog` | provider 级 compat 继承、档位集合、`reasoningEfforts: false` 不公布、`none`==`off`；**P62**：同名 a-two 跨提供方在目录里是**两条**且二元组查得开（能力各是各的） |
| `model-apply` | 切换跟随能力、旧档位回落 `off`、幂等返回 1、目录外不动能力；**P62**：同名 a-two 用 `提供方/名字` **双向**指定（alpha↔delta：provider/contextWindow/端点都跟着换）、目录里查不到的左半段不被误拆（`Qwen/Qwen3-32B` 整串当模型名）；**P37 修复**：换提供方时 `base_url` 与 `api_style` **双向**跟随（beta→alpha→beta 都断言）、跟随来的来源码落 `dsh-settings`、**显式 `--base-url`/`--api-key` 不被覆盖**、提供方**没声明 `baseURL`** 时端点一个字节不动、**解析不出凭据**时清空 key（旧密钥绝不跨提供方）（踩坑 96） |
| `effort-apply` | 公布的收、同值幂等返回 1、未公布拒 2、透传但 `effort_set=false` |
| `model-log` | `session/model` 三字段取最后一条 |
| `ctxwin` | P81 上下文窗口的来源链（离线、纯函数 + 假目录）：映射**压过**目录条目（目录 111000 / 映射 555000 ⇒ 555000）、`提供方/名字` 压过裸名字（裸 222000 / 精确 666000 ⇒ 666000，夹具里**裸那条写在前面** ⇒ 「先命中的赢」的错误实现会红）、同名模型跨提供方各自成条（beta/c-three ⇒ 777000）、只给裸名字那条腿、映射没写⇒目录条目兜底（123000 src 1）、**目录里根本没有**这个模型也照映射走（888000 src 5 —— autodl 那种纯 env 部署的形态）、一条来源都没有⇒**沿用**且来源码退回 0、**键是整串匹配**（`c-fi` 不许吃掉 `c-five` / 模型 `c-f` 不许被 `c-fi` 匹配）、显式（src 2/3）切模型也不被动、`--no-dsh-config` 不读映射、非法值**跳过并计数**（`c-four: 256K` 不许被截断成 256）。**防假绿对照 4 次**（每次先看到红再改回）：①去掉显式守卫 + 映射不参与 ⇒ 红 8 条；②键匹配改「键以查询开头」⇒ `c-f` 那条红；③键匹配改「查询以键开头」⇒ `c-five` 那条红（**②③ 是补出来的**：原计划的「目录外沿用原值」那条腿**抓不住**前缀匹配，见下面 §19.3）；④env 入口整段变死代码 ⇒ `e2e-ctxwindow` 的 env 腿红 |
| `vision` | P84 收图能力位的来源链（离线、纯函数 + 假目录）：`vision_flag_parse` 八个词逐值 + 非法值（`maybe`/`2`/空/`TRUE`）**判 -1 不许静默当开**、出厂默认是「开 + src 0」（**默认支持**）、`input: [text, image]` ⇒ on(src 1)、**`input: [text]` ⇒ off(src 1)**（本轮修掉的那个洞）、**整键没写 ⇒ 沿用 on(src 0)**（「没声明」不是「不支持」）、同名跨提供方时 beta 那份没写 ⇒ 沿用（不许拿 alpha 那条来填）、目录外名字 ⇒ 沿用 + src 退回 0、显式（src 2/3）钉住、`--no-dsh-config` 不动、**两条走真入口**（`agent_model_apply`：切到不支持要真关、切回要真开 —— 调用点漏了 settle 时只调函数的腿全绿，见踩坑 143）。**防假绿对照 5 次**（每次先看到红再改回）：①去掉切模型时那次 settle ⇒ 红 2 条（**最初全绿**，补了真入口腿才抓住）；②去掉显式守卫 ⇒ 红 2 条；③出厂值改回 false ⇒ 本轮回红 2 条 + `e2e-inputimage` 红；④去掉 print-config 的 source ⇒ e2e 红；⑤去掉 web 注入 ⇒ `web-childcfg` 红 |
| `dsh-writeback` | P71 写回（`session/dshsave.uya`）：叶级替换（注释/兄弟节**逐字节**保留、行数不变）/ 幂等（`DSHW_SAME`，连 mtime 都不动）/ effort 清档 / 缺键追加节尾 / 整节缺失追加文末 / 空 provider 不写空值（那一行原样留）/ 需要引号的值（空格与 `#`）/ 控制字节拒写且文件不变 / flow 节拒（不猜、不整份重写）/ 锁被占让位（`DSHW_BUSY`）且**不删别人的锁** / 缺 `settings.yaml` 不新建 / 回执表（`SAME` 与 `SKIP` 一个字节不加）。**防假绿对照**：①把「从第 0 字节照抄」改回「只抄节头那一行」⇒ 红 7 条；②抢锁恒成功 ⇒ 红 3 条；③flow 判据停掉 ⇒ 红 2 条（这条首版是**假绿**：夹具值与被写值不同时，追加会被写前自检挡下，判据停掉照样绿 —— 夹具改成「已经就是那两个值」之后才真的钉住它） |
| `worktree` | 真 git：建 worktree + `dsh/<slug>`、闸门、`wt_finish` 合并且目录消失 |
| `worktree-discard` | `wt_discard` 不合并；非仓库 `wt_provision` 判 `SKIPPED` |
| `worktree-tool-msg` | 踩坑 80：走**真工具入口**带 `message` 的 finish —— `git log -1 --pretty=%s` 读回来的提交说明**逐字节**等于传入的 marker（`wt_finish` 把 `msg` 当 C 串，JSON 解出来的 Buf 没有 NUL 时会读到堆尾巴） |
| `worktree-reclaim` | P49 残留回收（真 git，逐条对照）：**干净 + 零提交**的清了（目录与分支都没了）；**有未提交改动**的留、**有未合并提交**的留、**有活进程 cwd 在里面**的留（真 `fork`+`chdir`+`exec sleep` 当占用者，杀掉之后同一份扫描又能清掉它 —— 证明判据 ③ 真在判「活着」而不是碰巧被别的原因挡着）；**孤儿分支**（目录已没、`worktree list` 列不到）零提交的清掉、有提交的留（这一条钉的是判据自己：断言查报告里**没有** `kept branch …(git refused)`，否则会被 git 的第二道闸门兜成假绿 —— 第一版就漏在这儿）；`wt_reclaim_own` 清掉自己的空 worktree 后 `phase=DISCARDED` |
| `tui-model` | `/model` 与 `/effort` 浮层：分组标题、`✓` 只在当前行、只列公布档位；**P62**：同名 a-two 两行里 `✓` **只挂当前那一家**、反解带出提供方（老格式交回空串）、键盘走到另一家的同名行回车**真的换过去**（provider/能力/端点三样）、`提供方/名字` 写法、同名歧义有可见提示 |
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
| `tasks-render` | 进度条/百分比/体量、空态零字节、箱体 11 行逐行等宽；**§19.12**：折叠行的目标段带 `轮` 单位与正文、正文带换行压成一行、放不下时**只裁正文不丢头**（26..78 逐档扫描 + 两条前缀等值） |
| `tasks-scroll` | `--no-tui`：折叠行与 agents 箱体进面板；展开后每行 98 列 |
| `tui-tasks` | 常驻任务块层序、`ctrl+t` 只置 `TUI_REQ_TASKS`、矮/窄退化；折叠行的 `目标 N/M轮` 与目标正文真在屏幕上（§19.12）；P29 `/goal` 浮层、**P91 动作选择框**（六动作 + ✓ 挪位 + 打开就回车 = 看状态且不建 status 目标 + pause/resume/clear 真翻盘 + 泵点只回执不执行）；**E 段（踩坑 114）**：泵点消费 ctrl+t（运行中当场翻转 + 请求被消费 + 泵点只认 TASKS，tab 的请求原样留给主循环）、空态屏照样画块并按得动、四表全空时落 notice |
| `skills-web-search` | 目录型技能注入 + `skill` 工具；Anthropic 形状 `web_search` 鉴权与去重 |
| `compact-prune` | 20000 字符输出 → 剪枝标记、完整中段消失 |
| `compact-auto` | 窗口 200 触发：摘要请求 → `automatically generated checkpoint` |
| `history-long` | 40 轮 × 2（≈124 条）配对完整、最后一轮 80 条工具结果不少 |
| `hist-repair` | 完整组不丢、缺应答整组丢、`hist_pairing_ok` 复核 |
| `hist-pairing` | **P89**：悬空组**在中间**（后面跟着 user）—— 尾部修复对它瞎，全段修复整组丢且不误伤后面的消息；孤儿 tool 在中间；全合法的历史一条不动 |
| `pair-recover` | **P89 端到端**：合成「悬空 tool_calls + user」的日志 → `--resume` → 假网关断言**请求体里没有那个悬空的 id**（判据落在线上字节上；删掉接线这一轮就红，见 §19.11） |
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
| `tasks-e2e` | `make e2e-tasks`：`/tasks`、`open`/`toggle`、非法参数报错；`make e2e-tasks-resume`：**跨进程**恢复（进程 A 写清单 → 进程 B `--resume` 后 `/tasks` 还在，§19.13） |
| `goal-cmd` | P29 `/goal` 纯函数：控制词独占整行、状态块四段、`clear` 幂等；**§19.12**：`Objective:`/`Blocker:` 压成一行、读盘反转义（写读转义必须对称）；**P58 续跑判定九腿**（未授权 / 授权即开 / 轮号递增 / complete 停 / 轮次用尽标 blocked+round-limit / resume 重开 / pause 收授权 / **objective 转义与信封完整性** / 无目标不开） |
| `goal-e2e` | `make e2e-goal`：真 REPL 11 条命令逐条 grep |
| `goal-sess` | P87 目标属于会话（两条会话互不可见）；**§19.13 D 段**：空日志的恢复不换会话身份（目标还在、id/路径逐字节不变、目录数不变） |
| `todo-resume` | **§19.13**：清单的落盘与折回 —— 提交落 `todo/write`（线上字节逐字段）/ 清空内存折回来一致 / 面板出「任务 1/3」/ 折到 `turn/start` 出空 / 回合开始清空内存清单 |
| `sess-list` | 去重取最后一条、按 `lastActiveAt` 降序、8 档列宽退化、完整 id |
| `sess-list-big` | 踩坑 68：6000 行大索引 —— 归并排序与「金标准（未修的插入排序）」逐行等价、两把键各自有序、排两次结果相同、去重 2000 条、行尾 id 完整（抽查首/中/末） |
| `tui-switch` | P39 换会话：清转录 → 回放 → 回执、脚注保留、滚动模式不动；P25 会话级状态：`/new`、`/resume` 清空 todo 清单（屏幕与 `g_todos.n` 两处），目标不跟着清 |
| `tui-sessions` | `/sessions` 浮层：箱体铺开、默认游标在最后一项、完整 id |
| `tui-sessions-big` | 踩坑 68：2000 项 —— 取行查表 vs 线性扫描**差分逐字节相同** + 取末项 20000 次的自校准比值（查表 ≪ 扫描）+ 第 0/中/末项文本正确 + home/end/↑/↓ 与 sel_set 自洽 + 列表与 reader 成帧各 < 1 s + 正文层无 ESC/NUL |
| `tui-model` | P37 `/model`/`/effort` 浮层：按提供方分组、只列公布的档位、反解、非推理模型不开浮层；**P37 修复**：回合运行中选完模型 ⇒ **泵点当场收口**（`cfg.model` 立刻变、结果不再挂着、浮层已关）；**P62**：同名跨提供方（见踩坑 99）—— 行里带提供方、`✓` 按二元组、选中另一家的同名行真换过去 |
| `tui-worktree` | P41 `/worktree` 动作选择浮层：标题/八个动作/✓ 标当前模式、反解只认动作行（「取消」不认）、默认游标 = `status`；`finish`/`discard` 选定不生效、先翻确认框（默认游标 = 取消）；**真 git**：确认前 worktree 目录与 phase 一个字节不动、确认后才合并 + 删除 |
| `tui-select` | P85 拖选复制（见 §13.2.1 / 踩坑 146）：三事件（按下/拖动/抬起）**一次注入**（真机形状）+ **坐标与事件配对入队**（只留最近一次坐标会让选区退化成一个点）；选区状态机（正向/反向/单击/清空）；**宽字符整字取**（只选一列也取出整个汉字，两头向外取整）+ 行尾空白裁剪 + 转录区裁剪（面板不进选区）；高亮段样式 = `TUI_ST_SEL` 且**无色模式走反显**（`--color=never` 下也看得见）；正文层零改动（无 ESC/NUL）；复制请求两条路（键层整条 / 主循环只取文本）+ 取过即清（下一次无关的抬起不许重写剪贴板） |
| `tui-mouse` | 踩坑 72 鼠标上报开关（`F2` / `/mouse` / `--no-mouse`）：标志位默认开 + `tui_set_mouse` 幂等；`F2` 两种编码（`ESC O Q` / `ESC[12~`）与 `/mouse on·off·非法`；**字节级**进/关/再开/关着进都与开关一致；帮助浮层里有 `F2` 那一条；**真 PTY** 两个方向（默认开必有 `1000h`、`mouse=false` 必无 `1000h`/`1006h`） |
| `title-cmd` | P48 `/title` 与 `set_title`：清洗（80 B / 码点边界 / 控制序列全丢后为空 ⇒ 报错且标题**不动**）、钉住语义（`user` 置位后自动起标题不跑、`clear` 解锁）、revision 门控、落盘事件逐字节（kind 三档 + clear 的**空标题**事件）、索引同步、`set_title` 工具三支（合法/空串/缺键）、工具目录里有它；**P74**：派生的备用标题**不写** `g_sess.title`、**不落** `session/title`（口径：标题由模型总结）；`g_title_auto_done` 首次闩（起过一次之后连待办都不挂，硬挂上也不发） |
| `tui-paste` | P50 括起粘贴九段：进/出粘贴态的字节级判据、CR **不许**提交（踩坑 83 的原始症状）、CRLF 折成一个换行、TAB 是字面内容且**帧里**不出现 TAB、粘贴里的 ANSI 序列逐字节保留、收尾标记被切开也认、断流时悬着的 ESC 不吞、上限对齐 200000 且超限有提示、光标列按显示口径（TAB 四个空格）+ **真 PTY** 粘 3 行只提交一次（按会话日志断言；P80 起轮次开头**清空**夹具 home，并加一条「启动屏上不许有用户条目」的绊线 —— 见踩坑 134） |
| `img-sniff` | P51 图片纯函数层：**真 PNG 字节**（zlib 压出来的 64×48）读尺寸、GIF87a/89a 小端、JPEG 段链（长度段在前，尺寸不在固定偏移）、WebP 三变体（VP8X/VP8L/VP8 ）、纯文本与截断 PNG 一律拒绝、字节/像素两道预算、内容寻址 id 稳定、base64（长度与 PNG 签名）、附件 JSON 往返（**数字字段** + 坏记录只跳那一项）、占位文案与 B/KiB/MiB 三档 |
| `clip-copy` | P85 写方向（见 §13.2.1）：`SetSelectionOwner` / `ChangeProperty` / `SelectionNotify` 的**请求体逐字节**（`items` 是元素个数不是字节数、20 字节头、notify 的四个字段偏移）+ 结果码（空文本 / 超限 / 无 X11 各回各的码，绝不静默清掉用户剪贴板）+ `DISPLAY` 为空时**明确回 NO_X11** |
| `clip-term` / `clip-pty` / `clip-helper` | P83 剪贴板三源（见 §13.2）：`clip-term` = 纯函数（读请求/探测字节**逐字节**比对规范、分片喂入逐字节还原、**逐块** base64 解码走生产路径、非 5522 字节原样透传、一次 read 多帧的一帧一帧交付、DECRPM 的 Ps 判定与缓存、失败文案两两不同、`--clip` 五个取值 + 非法值不落回 auto）；`clip-helper` = 假 helper 脚本（PATH 前置探测、类型表**按行**比对不许子串命中、取数优先级、卡住的 helper **按进程组收且不许挂住**、无工具时的文案）；`clip-pty` = **真 PTY + 假终端**（父进程扮演支持 5522 的终端）：DISPLAY 为空也能贴上图片、应答字节**一个都没进屏幕**、收应答在读预算内当场完成 |
| `clip-parse` | P52 X11 客户端可测部分：`DISPLAY` 五种形态（`:0`/`unix:7`/`host:1.0`/空/畸形）与三种畸形拒绝、**真 Xauthority 字节流**的两条目配对（family 256 + display 号 + MIT-MAGIC-COOKIE-1；不存在的 display 号**不许**回退到别的条目）、失败码文案非空 |
| `tui-title-input` | P48 标题输入框：预填 AI 建议可见 + 编辑（打字/backspace/delete/←→/home·end/ctrl+u/中间插入，**按码点**不劈汉字）+ enter 采纳交回编辑后的文本 / esc 取消**不算改名** + 太矮回落 0 + 方框逐行闭合 + 窄框不越界 + 运行中 `/title <t>` 进安全集而裸 `/title` 不进 |
| `title-cmd-e2e` | `make e2e-title-cmd`：行式真二进制的用法串 / 改名回执 / `/status` 的 title 行 / clear / 空标题报错 / `/help` 可查 / 索引与日志落盘 |
| `title-auto-e2e` | `make e2e-title-auto`：真 PTY + 假网关，**三条腿** —— ① 默认：起标题多发一次请求并落 `kind=provider`（且请求里带 DSH 的两段式前缀 + 会话身份 + 「15 字以内」的词数句）；② `--no-title-auto`：两样都没有；③ **打完任务立刻 esc**（配一个每段流停 3 s 的慢网关）：回合 `reason=aborted`，标题照样有（首发在回合里，不是收尾）；外加三来源（default/env/cli）与 CLI 优先 |
| `tui-md` | P47 markdown 渲染七段：① 行内（`**粗**`/`*斜*`/`~~删~~`/`` `code` ``/链接：标记不上屏、样式落在正确的列、`snake_case` 不被误判）；② 块级（标题去 `#` 并按级着色、无序/嵌套/有序列表、任务清单 `✓`·`·`、引用 `▏ `、分隔线、围栏去标记留语言标签且块内 CODE）；③ **长行不丢字**（60/80/100 列下 100 字符代码行 + 100 字符正文 + 60 汉字逐字符完整、且那些行没有 `…`）；④ **滚到代码块中间样式不串**（贴尾与上滚两面，闭合围栏不再被当成开始）；⑤ 表格（表头 BOLD、框线 DIM、各行列宽一致、8 列在 40 列下整块退回普通行且不丢内容）；⑥ plan 审阅浮层共用同一份渲染 + 方框逐行闭合；⑦ **长条目取行 O(1)**（查表 vs 线性扫描逐行差分 + 贴尾首帧/缓存帧/上翻 20 屏三条成帧预算） |
| `sessions-e2e` | `make e2e-sessions`：只列有标题的会话（空标题整条不见）、最新在最后一行、同 id 取最后一条 |
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
| `web-emu` | P60 服务端终端解释器：把**真实捕获的 TUI 帧字节**（`tui_start` 的输出 fd 指向管道）喂给 `emu_feed`，断言 ① 网格文本与 `tui_screen_text()` **逐字节相同**；② **逐字节分片**喂入结果相同（状态机跨 feed）；③ 白名单外的 CSI **不改动网格**；④ 捕获里出现的 CSI 终字节全在白名单内 |
| `web-http` | P60 HTTP 侧纯函数：`srv_query_get` 能从**带路径前缀**的 URL 里取到参数（修过的「永远 missing id」回归）+ `web_addr_parse` 三形态（默认 8787 / 127.0.0.1:PORT / 0.0.0.0:0）三拒绝（别的 IP / 缺端口 / 非数字端口）+ `web_id_is_hex` 拒绝 `../` 与 `/`（路径穿越） |
| `web-page` | P60 页面：顶栏 `tabs` / `+` 按钮 / 六个端点标识齐全；**整份 HTML 里没有任何外链**（`http://` / `https://` / `src="//"` —— 不引 xterm.js、不走 CDN 的机器判据）；JS 里有方向键映射；**高亮可见**（不许有 `filter:invert`、必须有反显规则，踩坑 113）+ **宽字符排版三件事在**（段上钉宽度 / 按段补字距 / 量过宽字符进宽，踩坑 112）+ **IME 通道在**（有 `id="ime"` 的代理输入框 / `compositionend` / `insertCompositionText` 守卫，且 `keyBytes` 里**没有**单字符兜底 —— 踩坑 116）+ `esid`（订阅身份，踩坑 117）+ **复制与选区五条**（踩坑 125：`dragging` 标志在 / `selInTerm` 判据在 / `copy` 只写 `text/plain` 且**不许**写 `text/html` / `ctrl+c` 按选区分流 / 非修饰键先清残留选区 / `::selection` 定了不透明色）。防假绿对照：把 `keyBytes` 的单字符兜底装回去 ⇒ 当场红 |
| `web-dispatch` | P60 分派语义：非长连接端点（`GET /`、`POST /api/sessions`）必须返回 **false**（= 关连接）；再加一条**带尺寸的真分派**（`POST /api/sessions?cols=150&rows=40` ⇒ 建出来的会话就是 150×40，踩坑 117 的 URL 管道）。防假绿对照：把 `GET /` 改回 `return web_ep_index(c);` 重编 ⇒ 当场红（这是「一次 `+` 建两条会话」那条真回归的判据）；端点不读 query ⇒ 当场红 |
| `web-pty` | P69 会话子进程死后的收口（踩坑 105）：真 fork + 真 PTY 喂主循环真正用的那一支 `web_pty_ready`，断四条 —— ① 退出前那一段输出在网格里（钉「先 `POLLIN` 后 `POLLHUP`」的顺序）② 收口（`alive=false`、`master=-1`、`pid` 清零、子进程不再是 `<defunct>` 僵尸）③ **循环有限圈内结束**（不忙等）④ 重复喂 HUP 幂等。防假绿对照：把 HUP 那一支摘掉重编 ⇒ 当场红五条（`循环圈数=64 master=5`），正是用户那三台实例的状态（`syscr` 20 亿 / CPU 100% / 页面打不进字） |
| `web-frame` | P70 「页面不刷新」（踩坑 106）：管道当连接（不 fork），走生产代码真用的 `web_push_session`/`web_push_frame`，断六条 —— ① 首帧是全量且给所有订阅者 ② 文本变了要推且帧里有那一行 ③ **只动光标也要推**（在输入行里按 ←/→ 一行文本都不改）④ **真没变一个字节都不推**（空帧流量）⑤ 同一会话两条订阅者都拿到（差分基准在会话上，推完才快照）⑥ **只改样式（同一段文本重画、只加 `ESC[7m`）也要推**，且帧里那一行真的带 `attr=16`（踩坑 113：判据走解 JSON 逐段看 attr 位，不在字节里找特征串）+ ⑥b 样式也没变 ⇒ 仍然一个字节都不推；⑦ **摘表不换订阅身份**（订阅 B、`web_remove_at` 摘掉前面的 A ⇒ B 前移到下标 0，没变仍不推、改了 B 仍必须推到 —— 踩坑 114）。观测点是**管道读端**（`web_push_frame` 排完队会立刻 `web_flush_conn`，只看 `c.out` 会把「推了并写成功」误判成「没推」）。防假绿对照：把老判据（`srv_find(frame, "\"rows_changed\":[]", 16)` 那版）装回去重编 ⇒ 当场红三条（②③⑤）；把 `emu_row_diff` 改回只比文本 ⇒ 当场红⑥；把订阅匹配改回按下标 ⇒ 当场红两条（⑦） |
| `web-seg` | 段表的**坐标单位**（踩坑 112）：喂合成行（窄文本 + 宽文本 + 空白 + **BMP 外字符** + SGR 反显）断言四条 —— ① 段首尾相接、无缝无叠；② 每段**显示列数** == 它切出来那段文本的真实列宽；③ **整行段列数合计 == 该行真实列宽**（这是「右边框对齐」的代数形式）+ 每段**只含一个宽度类**；④ 段边界落在**字符**边界上（按码元切片切不出半个代理对）。再把**真实捕获的 TUI 帧**（同 `web-emu` 的做法）逐行跑同一组判据（同源）。判据走 `emu_row_json` 的**真输出**（解 JSON），不另取内部状态。防假绿对照：把 `emu_cols_span` 改回「续格也数一列」重编 ⇒ 当场红 |
| `web-size` | 新建会话的**尺寸握手**（踩坑 117）：真 fork 三条会话，断三条 —— ① 报 150×40 ⇒ 会话记 150×40 **且 PTY 窗口也是**（钉「尺寸真的到了子进程那侧」）② 不报（0/0）⇒ 默认画布 ③ 报超上限 ⇒ 夹到 `EMU_MAX_*` **且与网格 `emu.cols/rows` 一致**。防假绿对照：`web_session_new` 忽略参数 ⇒ 当场红三条（含 PTY 那条） |
| `web-exit` | 子进程退出后**收摊还是留标签**（踩坑 115）：真 fork + 真 PTY 两条腿 —— ① **正常退出**（exit 0 = `/exit` / ctrl+d / 面板选中 `/exit`）⇒ `close_wanted` 置位、`web_sweep_closed` 之后表里没有它、订阅它的长连接被关掉**且管道里有分块终止块 `0\r\n\r\n`**（前端靠干净 EOF 把「会话结束」与「连接坏了」分开）、最后一帧不丢；② **被 SIGKILL** ⇒ 不置位、表里仍在（留标签看最后一帧）。防假绿对照：把「正常退出才置位」改回「一律不置位」⇒ 当场红四条 |
| `web-listen` | 监听套接字的 `SO_REUSEADDR`（踩坑 118）：走**生产代码** `srv_listen` 两条腿 —— ① 选项 `getsockopt` 真读得回来（== 1）；② 真复现用户现场：起监听 → 连一条 → **服务端先关**（本侧留 `TIME_WAIT`，本地端口正是监听端口）→ 关监听 → **立刻**用同一端口重新 `srv_listen` ⇒ 必须成功。防假绿对照：把两条常量改回 BSD 的 `0xFFFF` / `0x0004` ⇒ 两条腿都红（用户报的「ctrl+c 之后 web 监听失败」） |
| `web-childcfg` | P73：会话子进程的环境继承（踩坑 124 ②）。走**生产代码** `web_child_env`，判据看它排好的**环境数组**（`sh_env_array()`，不是 `getenv` —— 那读的是本进程真环境、看不见刚排好的表）：① 父进程给了非默认值时，14 条（权限/沙箱/端点/模型/凭据/档位/信任策略/指纹/工作区/home/max-steps/no-title/no-mouse/no-mcp）**逐条同名同值**；② 父进程没给（出厂默认）时那几条**不许注入**（否则把默认值钉死、挡住子进程读 `settings.yaml`）；③ `UYA_AGENT_WEB` 恒为 0（漏了它子进程递归起 web，踩坑 103）。**权限排第一**：它曾经被悄悄放宽成 `Full access`。防假绿对照：把 `web_child_env_cfg(cfg)` 换成 `_ = cfg;` 重编 ⇒ 当场红 10 条 |
| `tls-pin` / `tls-tofu` | P78 信任档位（踩坑 132，离线、不联网、不需要证书）：`tls-pin` 段验指纹库的纯函数 —— 两行好行 + `#` 注释 + 空行解析出 2 条、主机名与指纹**两侧**大小写折叠、4 行畸形（hex 过短/过长/非 hex/只有主机名）一律跳过而**不中止**（后面那行好行必须还在）、CRLF 行尾与末行无换行都认、同一主机多条指纹命中任意一条、追加行必须是 `<host> <小写 hex>\n`、空库什么都不信、长度不是 64 的查询一律不认；`tls-tofu` 段起**真的临时目录 + 真的文件**走闭环 —— 首次 `FRESH` 且那一行**真的落盘了**、二次 `TRUSTED`、指纹变了 `MISMATCH`、另一台主机照样 `FRESH` 且**不覆盖**第一台的记录。防假绿对照两处：把 `tp_trusts` 改成忽略指纹比对 ⇒ 红 3 条；把 `tls_tofu_verdict` 里「首次落盘」那行删掉 ⇒ 红 5 条 |
| `tls-ca` | P92 链校验与 TOFU 学习（**离线**，夹具是 `testdata/tls_ca` 里自签测试 CA 出的证书，不跑 openssl）：好链（leaf+inter，库里只有根）必须过；SAN 通配 `*.wild.test` 匹配 `a.wild.test`、**不**匹配 `a.b.wild.test` 与 `wild.test`；`SAN=other.test` 的证书不授权 `good.test`；缺中间证书 / 空库+服务端自带自签根 / 库里没有根 三种断链都必须拒（且原因指向对的那一条）；**签名改一个字节必须拒**（改的是签名值本身，不是 TBS —— 改 TBS 会先撞上「扩展畸形」那条更早的判据，签名腿就被别的检查顶替了）；ECDSA P-256 链必须过；有效期三态（现在有效 / notAfter 在过去 / notBefore 在未来 / **拿不到系统时间（now=0）必须判无效** —— 有效期是硬条件，时钟缺失等于这条没验过）；TOFU 学习五态 —— 首次 FRESH、换指纹 MISMATCH、学习关着仍 MISMATCH、学习开着 LEARNED 且**新行真的落盘**（学过之后该指纹变成 TRUSTED）、到 4 条上限只放行不追加。防假绿对照：拆掉 `rv_check_em` 的 DigestInfo 比对 ⇒ 签名腿红；拆掉主机名检查 ⇒ 通配腿红 |
| `e2e-portable` | `make e2e-portable`（P73，踩坑 124）：把 `build/uya-agent` **拷到一个空目录**、`HOME` 也是空目录、**没有 DSH、没有仓库**（真新机器的样子），只带一个二进制。① 内嵌 preset 兜底：`--print-config` 报 `knobs (source: embedded)` 且旋钮值 == 内置缺省（逐字节）；跑一轮 `--plan` ⇒ 假网关收到的请求里必须有 `Make the plan decision-complete`（**该串只存在于上游 preset**，工作树与编译器树 0 命中 ⇒ 判据不可能假绿）；② **反向断言**：`--dsh-root testdata/preset-root` 时必须是 `source: preset` + `readLimit=1777`（内嵌不许夺磁盘的权）；③ web 会话子进程：只走命令行给 `--base-url/--model/--permission read-only/--agent-home`，断言假网关**收到**请求、请求里的模型是父进程给的那个、会话日志落在 `--agent-home` 下；④ `--no-dsh-config` 这类没有 env 口径的开关必须被启动日志点名。防假绿对照（两条都做过）：把内嵌兜底改成恒 `false` ⇒ 红在①；只停 plan 段的抽取（来源/旋钮照旧）⇒ 红在「plan 策略段缺失」；摘掉 `web_child_env_cfg(cfg)` ⇒ 红在③ |
| `dns-resolv` | P80 名字解析（踩坑 133，离线、不联网、不需要证书）：**四段**。① 纯扫描：夹具**特意造出** >512 字节的注释头（并断言 `ns_off > 512`，把「现场的形状」钉进断言）——老实现只读前 512 字节 ⇒ 判成「文件里没有 nameserver」；另加注释行/`;` 注释/`nameserverX`/关键字后必须空白/行尾注释/tab/CRLF/末行无换行/先 v6 后 v4/只有 v6/畸形行不中止/空与纯注释；② 真文件闭环：写一份同形状的临时 `resolv.conf`、把路径钉进去 ⇒ 解析器串**逐字节** `127.0.0.53`、来源 = 文件、删掉文件后**不再**声称来自文件（原因 = 打不开）；③ 覆盖：`$UYA_AGENT_DNS` 合法值优先、非法值**不采用**且记 `ENV_BAD`、端口越界同判、清掉后不报 env。**防假绿对照两处（都真做过）**：① 把整份读退回 `buf_new(512)` ⇒ **真文件轮 4 条红**（扫描轮那两条**不红** —— 纯函数对、接线错也算坏，所以回归腿必须打在读文件那一层）；这条对照顺带抓出产品里一个真缺陷：原因记账没有优先级，`TRUNC` 会盖掉「变量值非法」（修成 `hc_dns_err_rank`）。② 关键字改回「整行按前缀找 + 参数取下一个 token」⇒ 扫描轮 3 条红 |
| `proxy` | P92 出站代理（离线，只打 127.0.0.1）：**四段**。① 形状：`host:port` / `http://host:port` / 带 `user:pass@` 三种合法 + 省端口按 8080 + 末尾一个 `/` 容忍；② 凭据头**逐字节**（`Proxy-Authorization: Basic dXNlcjpwYXNz\r\n`，期望值在自测里独立写死 —— 用产品代码拼期望值等于让判据与实现共享同一个错误）；③ 回环绕过九条（`localhost`/`127.0.0.1`/`127.9.9.9`/`::1` 真；`127.example.com`/`128.0.0.1`/`127.256.0.1`/`127.1` 假）；④ 七类非法值**各指原因**（scheme / host / port / userinfo / extra / toobig / 空）、非法值**不许半采纳**、清空后不报 active、失败分档（可重试与不可重试）。**现地假代理轮**（回环套接字 + fork，verdict 走退出码）：CONNECT 请求行与 `Host` 逐字节 + 隧道**回显透明** / 绝对形式请求行 + `Host` 是目标 + 凭据头在 / 407 ⇒ `HcProxyFailed` 且状态码记对 / 502 ⇒ `HcProxyUnavailable` / 回环绕过。**防假绿对照三处（都真做过）**：CONNECT 目标写成代理自己 ⇒ 隧道步红；绝对形式退回相对形式 ⇒ 假代理步红；删掉回环绕过 ⇒ 回环腿红。另一条记在踩坑里的：`url_host(&u)`（`u` 已是 `&const Url`）会让自测**直接 SIGSEGV**，而编译器全绿 |
| `e2e-proxy` | `make e2e-proxy`（P92，离线，全程只打 127.0.0.1）：假代理（`testdata/mock_proxy.py`，**真转发**：解析绝对形式请求行、或建 CONNECT 隧道后双向搬字节）+ 假网关 + `.invalid` 域名（目标名只用于**断言**，真连接经代理的 `--upstream` 落到假网关 —— 与 `e2e-dns` 用假解析器把 `.invalid` 指到本机是同一手法）。① 正腿：`UYA_AGENT_PROXY` ⇒ 退出 0、答复上屏、**假网关真收到**（`req.bin` 非空 + 模型名）**且**代理日志是绝对形式；② 流式那条路（`hc_open`）另起 SSE 网关 + 第二个代理，答复与代理日志都断言；③ 凭据腿断言 `Proxy-Authorization: Basic dXNlcjpwYXNz`；④ `--proxy` CLI 档同效；⑤ `--no-proxy` 之后代理日志**行数不增**（真直连）；⑥⑦ 反腿：代理死端口 / CONNECT 被回 407 ⇒ 退出 2、说「代理没打通」、指名 `UYA_AGENT_PROXY`、**不许出现 TLS/DNS 字样**（407 那条另断言文案带状态码）；⑧ 反腿：值非法（env 与 CLI 各一次）⇒ 退出 1 + 为什么 + 点名来源；⑨ `--print-config` 四种来源（default / env / cli / `--no-proxy`）；⑩ 回环绕过（代理指死端口，目标 `127.0.0.1` 照样通） |
| `e2e-dns` | `make e2e-dns`（P80，踩坑 133，离线，全程只打 127.0.0.1）：假 DNS（`testdata/mock_dns.py`）+ 假网关 + `.invalid` 域名（**RFC 2606 保留域，真解析器必然解不出来** ⇒ 跑绿只可能来自自家解析器）。① 正腿：`UYA_AGENT_DNS` 指向假 DNS ⇒ 退出 0、答复上屏、网关真收到；①b 同一条在 responses 协议上；②③ 反腿：解析器换成一个没人听的端口 ⇒ 退出 2、「域名解析失败」、给出 `UYA_AGENT_DNS` 这条路，**且 stderr 里不许出现 TLS**（流式与非流式各一条腿 —— 两条路的档位映射以前是各写一份的）；④ `--print-config` 的 `dns = … (source: …)` 两种来源各验一条 |
| `tui-full` | P53 浮层全屏四组：**A** 非全屏仍是居中框（不顶格、`≤16` 行上限、第 30 项看不见）→ 全屏框 = 转录区（顶边第 0 行、左右边框 0 与 `cols-1`、标题 ` · 全屏`、行偏移表口径的逐行闭合、底边**正好**在 `panel_top-1`）+ 16 行上限解除（第 20 项可见、第 30 项仍不可见）；**B** `ctrl+f`（`0x06`）与 `F11`（`ESC[23~`）都切换，且**四种形态各认一次**（列表 / reader / ask / input）；**C** 不吃面板 / 状态区 / 脚注；**D** 没浮层时只落 notice、全屏态不跨浮层残留、`esc` 关掉后转录回来，终端太矮时 fail-closed 判据不变；**F** `/fullscreen` 四态（裸报状态 / `on` / `off` / 非法值只报错且状态不动、重复 `off` 幂等） |
| `tui-mem` | 转录的内存纪律（踩坑 153，**四段判据全是数值、屏幕上看不见**）：① 记账恒等式 —— `tui_text_bytes()`（现算 Σ text.len）必须**逐字节等于** `tui_text_accounted()`（记账），派生同理；夹具含思考超 `TUI_REASON_TAIL` 的截尾与**两种宽度下重折**（这两条正是修前「只加不减」的两个现场），并打印实测的正文/派生字节数；② 派生上限 —— 正常 markdown 灌到正文上限附近（512 条 / 3.6 MB）派生必须 **< 上限**（实测 10.9 MB，即「一条正常内容都不会因为它被丢」的可执行版本），病态夹具（缩进 900 列的长行）派生必须**有界**（实测 20.4 MB）且真丢过条目、且不许把最后一条也丢掉；③ 清空 —— `tui_transcript_clear()` ×10 之后 `tui_entry_live_allocs()` 必须 **= 0**（ASSIST/TOOL/USER/NOTICE 四种条目都建过；修前漏的是 TOOL/USER/NOTICE 的 `wrap_ix`），三个记账与丢弃计数一起归零；④ 单条上限对**整块输入**成立（`✓ ` 起头的 1 MiB 工具行 ⇒ 该条目 `text.len` 不许超 `TUI_ENTRY_MAX`）+ 丢过条目后上滚时第 0 行出现「更早的 N 条已省略」。防假绿对照四次（见踩坑 153） |
| `overlay-fullscreen` | `make p30-check` 第 9 场（真终端 + 假网关）：屏幕几何判据 —— 非全屏顶边 > 0 行且左边框 > 0 列 → `ctrl+f` 后顶边第 0 行、左右边框正好 `0` 与 `cols-1`、标题带 ` · 全屏`、面板与脚注都还在、底边行 < 面板行 → `F11` 关回居中 → 再全屏、`esc` 关掉后方框消失 |
| `tasks-ctrl-t` | `make p30-check` 第 10 场（踩坑 114，真终端 + 假网关 `todo_first=1`）：回合**运行中**按 `ctrl+t` → `┌─ tasks ` ≤1.5 s 上屏**且那一刻 `SELFTEST_OK` 还没到** → 再按一次收回折叠行（实测 101 ms） |
| `watch-pick-e2e` | `make e2e-watch-pick`：真终端 + 假网关两条腿 —— ①裸 `/watch` → 清单 → **一次回车**开跟随浮层（`[step …]`/`▸ bash …` 仍在子代理结束之前上屏）；②假网关把父代理的收尾按住 12 s，期间敲 `/watch sub-1` 必须**当场**开浮层（屏幕上还没有 `PARENT-DONE-OK`） |
| `model-route-e2e` | `make e2e-model-route`：真终端 + **两个**假网关（各自记账模型名与 `Authorization`），两条腿（`--mode text` 带参命令 / `--mode overlay` 浮层）—— 回合被一条慢 bash 撑住时切换模型，断言**回合结束前**信息行就变成新模型/新提供方（实测 102 ms）、之后那条请求打到**新提供方**的网关（旧网关不再收到）、且带的是**新提供方**的密钥（旧密钥不跨提供方），那一轮的答案是新提供方给的。尾判等的是**正面事实** `PROV-B-ANSWER`（以前等「有 `轮 ·` 且没有 `运行中`」，那两半都在回合半途就成立 ⇒ 约 5% 假红，见踩坑 109；基线 104 次红 5 次、修后 104 次全绿，防假绿对照照红）。对照改动前：`VERDICT: FAIL` + 网关记账里 prov-a 收到全部请求（踩坑 96） |
| `session-log` | 控制字节按字节往返、半条记录 `dropped_tail`、重建历史 |
| `json-escape` | `0x00…0x1f` 全转义、无裸控制字节、`jw_key` 同规则 |
| `ctrl-bytes` / `ctrl-bytes-resp` | mock mode 23：`printf 'A\000B'` 以 `\u0000` 回请求；判定码 240 |
| `diag-preview` | cap 停字符边界、`\xNN`、`out_diag` ≤512 B |
| `diag-echo-400` / `diag-echo-400-ns` | mock mode 24：400 回显 → fd 2 一行转义预览、无裸 CR/NUL/ESC |
| `empty-retry` | P54（mock mode 41）：第一轮回「finish_reason=stop + 只有思考、没有正文」→ 转录里那一行证据（`finish=stop have_finish=1 bad_finish=(none) content=0B reasoning=45B calls=0 usage={in=60 cache_read=40 cache_write=0 out=7 reasoning=3} prompt=…B/100tok retries=0/1`）+ 日志一条 `llm/degenerate`（字段逐项核对）→ **同一步重发**：第二轮请求与第一轮**逐字节相同**、`step/start` 仍只有一条、唯一那条 `assistant/message` 的正文是 `SELFTEST-RETRY-OK`、回合退出 0 |
| `empty-retry-giveup` | P54（mock mode 42）：重发也只给空响应 → 只重发**一次**（两条 `llm/degenerate`：`retrying=true/retries=0` → `retrying=false/retries=1`）、退化那一步**一条 `assistant/message` 都没有**、转录里留下带同一条证据的错误行、回合按协议错误退出 3 |
| `max-tokens-cut` | P59（mock mode 44，**一个进程跑两个回合**）：① `finish_reason=length` + 正文 + 一个 `write trunc.txt` 调用 → 一个工具调用都不派发（`trunc.txt` 不存在、日志零 `tool/call`）、正文剪掉断口空白后进历史、`assistant/message` **不带 tool_calls**、转录是 `warning:` + `[max-tokens] …发「继续」…`（**没有** `error: model output was truncated`）、`turn/end` reason = `max-tokens`、那一回合返回 `5`；② 人打「继续」→ 第二个请求里**带着那段正文**、没有 `"role":"tool"`、没有 `"tool_calls"` → 回合以 0 收尾、`turn/end` reason = `completed` |
| `turn-retry` | P94（mock mode 50）：退化两发（第二发与第一发**逐字节相同**）⇒ 同一步的重发额度用尽、回合按错误收场 ⇒ **自动替人打一句「继续」**开新回合 ⇒ 第三发请求体里带着 `"role":"user","content":"继续"` ⇒ 退出 0。判据三侧：转录 `[turn-retry]` 行（第 1 次、**不限次数**（P96）、`backoff=` 落在 [0.5s,3.0s]、`esc/ctrl+c 可停`）、日志（`turn/start` 2 条、`turn/end` 2 条、`turn/retry` 1 条且 attempt=1/maxRetries=-1/rc=3/reason=degenerate-response、一条「继续」的 `user/message`）、mock 侧请求体 |
| `turn-retry-all` | P96（mock mode 51）：第一发 **401**（传输层不重试的那一档）⇒ 回合级自动继续 ⇒ 第二发请求体里带着整条 `"role":"user","content":"继续"` ⇒ 退出 0；第一发的请求体里不许已经出现那条消息。这一腿证明「所有没收完的回合都续」，P94 的实现下必红 |
| `tui-diag` | 4 KiB JSON 只留 ≤512 B、半截汉字变 U+FFFD、`tty_sink_on` 收尾关回 |
| `read-window` | `(Showing lines 1-1000 of 4000. …)`、`offset=3500` 真读到、`limit=2000` |
| `title-format` | OSC/CSI 清洗、模型侧 45 B（15 字）/ 上屏 80 B 上限切码点边界、`ESC[22t`/`ESC[23t` |
| `tty-title-pty` | 滚动模式真 PTY：`fd 2 + 无备用屏幕` 接线，弹栈在最后标题之后 |
| `http401` | mock 401 + 错误体：打印状态与错误体并退出 3 |
| `max-steps` | 显式 `max_steps=3`：3 步后熔断退出 3 |
| `unlimited-steps` | 默认不限步数：跑满 14 步、14 条 `tool_call_id` 带回、退出 0 |
| `hist-keep` | `hist_drop_oldest` 留住 system 与任务原文、整组丢 tool；40 组后原文仍在 |
| `toolcalls-cap` | 踩坑 35：`jw_str_esc_len` 与实际逐字节相等、`calls_json_need` 预算严丝合缝 |
| `toolcalls-big` | 踩坑 35（mock mode 25）：9.6 KiB `write` 头尾标记回到第二请求、`agent_run` 返回 0。同轮第 0 次请求还钉**客户身份**：`User-Agent: uya-agent/0.1 (deepseek-harness-compatible)`（P71，踩坑 109；改回旧 UA ⇒ `verdict 204`）与两个会话 id 头、`session workspace: \"` 机读句 |

**验证用的 make 目标与快捷入口**

- 总闸门：`make selftest`（离线，含 `p30-check` 与全部轮次，SELFTEST PASS / 退出 0）、`make e2e`（真网关）。
- 离线配套：`make check`（A1 类型检查）/ `build`（A2 产出 `build/uya-agent`）/ `codegen-audit` / `tui-selftest` / `shell-selftest` / `e2e-config-flags` / `e2e-api` / `e2e-steps` / `e2e-permission` / `e2e-sandbox` / `e2e-tasks` / `e2e-goal` / `e2e-sessions` / `e2e-resume-big` / `e2e-title` / `e2e-model` / `e2e-model-save` / `e2e-model-route` / `e2e-worktree` / `e2e-diff` / `e2e-watch` / `e2e-watch-pick` / `diff-selftest` / `panel-selftest` / `e2e-ws`。
- PTY 场景：`make p30-check`（`testdata/pty_drive.py --suite`，11 个场景；P91 那场 `goal-menu` 是**真按键**那条腿
  —— 输入框的同步采纳路在 headless 里收不到注入的键，只能在真终端里测；P41 那场 `worktree-menu` 走
  两条入口 —— 命令面板里选中 `/worktree` 与裸 `/worktree` —— 到选择框 → ↓ 到 `finish` → 确认框 →
  回车取消，`PTY_DUMP=1` 会把两张框打出来；踩坑 114 那场 `tasks-ctrl-t` 要假网关的
  第 6 个参数 `todo_first=1`，它让第一次请求回一个 `todo_write` —— 折叠行真的在屏幕上，
  「运行中按 ctrl+t」才有可观察的差别）；
  `make tui-demo` 是排版基准：P47 之前各阶段只差脚注版本串（`p22-tasks` … `p46-wpick`），
  P47 起正文那一屏按新的 markdown 排版变（标题/强调/列表/引用/带语言标签的代码块/表格），
  脚注仍是版本串那一处；P53 新增第 ⑦ 屏（浮层全屏）并把前六屏**逐字节**保持不变
  （非全屏路径一个字节没动，所以这条本身就是「没有回归」的判据）；
  踩坑 114 起第 ① 屏（空态 + 四表全空）同样**逐字节不变** —— 它是「空态屏加了任务块，
  但没内容时排版零漂移」的机器判据。
  **P75 起脚注那一行确实变了**（不再只是版本串那一处）：demo 的 workspace 是本 worktree
  的真实路径（74 列），新窗口把它夹到 30 列并补 `…`；统计行因此整条放得下了（修前被长
  路径挤到只剩四组）。这是**有意的**，也正是用户报的那件事；短路径（`~/proj` 这类）装得下
  时仍然逐字节不变 —— `tui-marquee` 的 A 段钉的就是这条。
- 只跑子集的开关：`UYA_SELFTEST_TUI_ONLY`、`UYA_SELFTEST_PERM_ONLY=1`（P21+P26）、`UYA_SELFTEST_GOAL_ONLY=1`（P29）、`UYA_SELFTEST_SHELL_ONLY=1`（P38）、`UYA_SELFTEST_PANEL_ONLY=1`（P15+P40，`make panel-selftest`）、`UYA_SELFTEST_EMPTY_ONLY=1`（P54，退化响应两轮 —— 跑对照实验时用它，一次约 0.2 s）。
- 探针：`make probe BASE=https://api.deepseek.com/v1` 期望 HTTP 401 + leaf 指纹。

**load-bearing 硬指标**

- PTY 延迟预算：`/status` 浮层 ≤800 ms、空闲 ≤150 ms、bash 跑着 ≤200/300 ms、压缩在飞 ≤300 ms。P30 实测 103–105 ms（旧 2245 ms）；P31 五场景 101/53/62/102/63 ms（旧 103/2280/242/103/2833 ms）；P39 `new-mid-turn` 回执 112 ms、中断 172 ms。
- 退出码：正常 0；401 / 熔断 / `tool_calls` 序列化失败 3；崩溃 139；`SIGTERM` 143；`SIGKILL` 137。`resume-big-e2e` 未修 139 → 修后 0。
- 结构尺寸：`sig-abi` 152 字节；`sig-term-restore` 恢复序列 26 字节（P22 四形状 26/18/31/23）；`tty-editor` termios 60 B；P32 四形状 42/34/47/39；`--title` 模型侧 45 B（15 字）/ 上屏 80 B 上限切码点边界。
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

- P59：**`max_tokens` 截断的收口**（§5.4.1）。用户报的就是转录里那一行
  `error: model output was truncated at the token limit (max_tokens); tool calls dropped`
  —— 三个毛病叠在一起：① 它被当成「模型/协议错」（其实是这一轮的**输出预算**用完了，谁都没出错）；
  ② 截断前那段正文**没进历史**，用户照着提示回一句「继续」，模型只能从零重来（真机现场：一整轮的
  工作白跑）；③ 日志里那条 `assistant/message` 还带着 `tool_calls`（见踩坑 96：`--resume` 会把这半组
  当「未完成一轮」整组丢掉，连正文一起丢）。
  修法逐条对齐 DSH：**不派发**任何工具调用（它 `BlockAssembler` 在 max-tokens 时把 tool-call 块整块
  滤掉；本仓连日志与历史里也不留）、**正文剪掉断口空白后进历史**（DSH 的 UI 提示语就是「已有输出
  保留在对话中。发送"继续"可让模型接着输出」）、`turn/end` 的 reason 记成 `max-tokens`（不是
  `completed` 也不是 `error`），转录从 `error:` 改成 `warning:` + `[max-tokens] …发「继续」…`，
  进程退出码单开一个 **5**（`dsh-headless` 对 max-tokens 同样给非 0：`reason.kind === "completed" ? 0 : 1`）。
  **不重发**：请求与上限都没变，同一发再来一次只会再截断一次（这与 §5.4 的退化响应是两回事，
  所以不占 `EMPTY_RETRY_MAX` 的额度，也不留 `llm/degenerate`）。交互形态（REPL / TUI）不再把它
  说成「本回合异常结束」；同会话续跑驱动器（§9.5）**不收授权** —— 目标没做完，而截断那一轮的正文
  已经在历史里，下一轮（新预算）正好接着写。
  **判定与验收**：新增 `max-tokens-cut` 轮（mock mode 44，`UYA_SELFTEST_EMPTY_ONLY=1` 单跑约 0.3 s），
  它是全仓第一条**在一个进程里跑两个回合**的轮次（截断 → 人打「继续」），判据十项：`trunc.txt`
  不存在（工具调用一个都没派发）、日志零 `tool/call` / `tool/result`、截断那一步的 `assistant/message`
  **不带** `tool_calls` 且正文就是 mock 标记、`step/start` 恰好 2 条、转录含 `warning:` 与
  `[max-tokens] …` 两行且**不含**旧的 `error: model output was truncated`、`turn/end` 的 reason
  依次是 `max-tokens` → `completed`、`llm/degenerate` 为 0、那一回合返回 **5**、第二回合返回 0，
  以及**第二个请求里带着截断前那段正文**（历史真的保住了）。
  **三条防假绿对照实验**（都先看到红再改回来）：① 去掉「正文进历史」那一段 → 红（mock verdict **144**：
  第二个请求里找不到 `SELFTEST-TRUNC-PARTIAL`）；② 截断那一步改回 `keep_calls=true`（日志留下
  `tool_calls`）→ 红（「截断那一步的 assistant/message 里带着 tool_calls」）；③ 收口改回旧文案
  （`error: model output was truncated…`）→ 红（转录里不得出现 `error:` 那一行 / 缺 `warning:` 那两行）。
  ⚠ **本轮没有净增函数**（uya 0.10 的函数表余量是 0，见踩坑 87/91）：新轮次的证据验收**并进**
  P54 那个既有函数（`empty_retry_check` → 改名 `stop_shape_check`，一个函数管两种「异常收尾形状」），
  两回合的驱动与三条端到端判据内联进 `selftest_round` 的 `mode == 44` 分支；`agent.uya` 只加了一个
  常量（`AGENT_MAX_TOKENS`）与一个函数入参（`keep_calls`）。实测声明数 **6836 → 6841**
  （+5 = 那一个常量 + selftest 的 4 个标记字面量；常量不占函数额度），函数净增 **0**。
  验收：`rm -rf build && make build`（干净重编，函数净增 0）＋ `make selftest` 全绿 ＋
  `UYA_SELFTEST_EMPTY_ONLY=1 ./build/uya-agent --selftest`（三条收尾腿一起）。

- P61：**截断的根因 —— 输出上限总是发**（§5.4.2）。用户报「过 aigw 后**容易**报错」，贴的是
  P59 那两行 `warning:` + `[max-tokens] …已丢弃`。P59 修的是**截断之后**怎么收场（对，且继续保留）；
  但「容易」这两个字指向的是**截断本身太频繁**：本仓默认 `max_tokens = 0` = **不发**（理由「对齐
  DSH」），而用户的 `aigw-local` 条目没写 `maxTokens` ⇒ 一个字节都不发 ⇒ aigw 用它的
  `default_max_output_tokens: 8192` 顶上（`openaichat.go:474`），而模型真实能力是 **65536**
  （aigw 自己的 `/v1/models` 就这么公布）。DeepSeek-V4.1-Flash 是推理模型，8192 常被思考吃光
  （网关日志实测 `output=8192, reasoning=8192`）→ `incomplete/max_output_tokens` → 半截工具调用
  整块丢掉。**「不发」≠「不限」，而是把上限的决定权交给中间那一跳** —— 它不知道我们下一秒要写多大
  的文件。数据库旁证：`usage_records` 里 `terminated_reason='incomplete'` **只**出现在本仓
  （`client='unknown'`）的请求上。
  **「对齐 DSH」读了一半**：DSH 确实不把 pi-ai 的**能力申报**当请求默认，但它**自己的** deepseek
  路线有请求默认 —— `dsh-llm-deepseek` 的 `DEFAULT_MAX_TOKENS = 256e3`（`config.maxTokens ?? 256e3`）
  经 `defaultMaxTokens` 落进 `resolveCallWithInfo` 后**真的会发**；pi-ai 那条路的兜底同量级
  （`source.defaultMaxTokens ?? 32768`）。所以「发 256000」比「不发」**更**接近 DSH。
  修法：新增 `effective_max_tokens(cfg)` = `--max-tokens` > 目录 `maxTokens` >
  `DEFAULT_MAX_OUTPUT_TOKENS`（**256000**，照抄 DSH 的 `256e3`）；`build_chat_request` /
  `build_responses_request` **无条件发**（responses 侧保留 16 的下限抬升 —— OpenAI 对
  `max_output_tokens < 16` 直接 400，比截断更坏）；`--print-config` 印**线上会发的值**与来源
  （`cfg.max_tokens = 0` 时以前印 `0`，看着像「不发」，与 P56 的 `reasoning_effort` 同一类
  「配置在说谎」）。新增 `src_max_tokens` 来源码，三个赋值点（CLI / DSH 设置 / 模型目录）各自落码。
  **为什么敢给大**：上限是**上限不是配额**（没输出就不计费），给小于真实能力才是真损失；实测
  **超过**上游能力也不 400 —— aigw 与 autodl 对 `999999` 都照常 200、按各自真实上限截，aigw 只对
  **<16** 报 `max_output_tokens must be >= 16`。这条实测是「敢给大值」的依据，否则「保守给 8192」
  会把根因重新引回来。
  **判定与验收**：`resp_build_round`（`selftest[resp-build]`）里新增两组断言 —— ① `cfg.max_tokens = 0`
  时 chat 请求必须含 `"max_tokens":256000`、responses 请求必须含 `"max_output_tokens":256000`
  （**焊死「不发」这条路口**）；② 显式 `4096` 必须原样发出、不能被默认值盖掉。既有断言
  （`max_tokens = 8` → `max_output_tokens: 16`）继续守着下限抬升。
  验收：`make check` ＋ `make build`（link-audit 通过）＋ `./build/uya-agent --selftest` **全绿
  （SELFTEST PASS，152 条 ok）** ＋ `--print-config` 印 `max_tokens = 256000  (source: default;
  sent as max_tokens)` ＋ `--dry-run` 的请求体末尾带 `"max_output_tokens":256000`。
  网关侧同时把 `default_max_output_tokens` 抬到 65536（配置 + 管理 API PATCH，因为 bootstrap 是
  `upsert`、**只补缺失字段**，改配置文件对已存在的 provider 行不生效 —— 这一点值得记一笔）。

- P76：**一格一条的「簇」里只有选中项滚**（用户报：「命令窗口的命令不要一起滚动」）。

  P75 把跑马灯无条件套到「一格一条」的行上，于是命令面板里放不下的行**一起滚**。
  现场量出来的数：真命令表 23 条、60 列箱体（正文 57 列）下 **11 条**装不下，最长那条
  `/model [名字|提供方/名字]  …` **101 列** —— 同一个 400 ms 时钟、同相位左移，
  **整张面板集体抖**，一条都读不成。

  **判定**：「放不下就滚」这条纪律没错，错的是把它套到**簇**（一格一条、有光标的一组行）
  上。用户口径两条：① **只滚选中那一行**；② **命令名钉住**，只滑后面那段说明。

  **修法**（规则收在一处，调用点只传一个 `sel`）：
  * `style.uya` 新增 `tui_marquee_put_row(slot, p, n, win, style, sel)`：`sel == false`
    就 `stop` 槽位 + 静态截断（= P75 之前的形态）；`true` 就先钉住第一列再滑后半段。
    原 `tui_marquee_put` 变成核心 `tui_mq_draw(pin = 0)` 的薄封装 ⇒ **单元素路径零行为变化**。
  * 钉住段 = **第一个「连续 ≥2 个空格」连同这个空白段**（命令表 / 会话表 / 清单表都用
    这个分列口径；把空白段留在钉住段里，滚出来才是「名字 + 间隔 + `…` + 说明」）。
    没有这个分界、或钉完留给滑动的窗口 `< TUI_MQ_PIN_MIN` ⇒ **不钉、整行滑**。
  * **钉住不改变 maxoff**（尾段列数与窗口同减 `pin`）⇒「滚得到尾」这条老判据不受影响。
  * **槽位仍是「一行一个」**：列表体、选项表、reader 动作行都按行号派生槽位。动作行虽然
    一行能排好几个动作，但**共用槽位是安全的** —— 只有「太长」的条目才进 `tui_marquee_put_row`，
    而长条目必然吃掉整行预算（`avail` 归零、循环结束），所以它必然是这一行**最后**画的那个，
    前面那些短条目的 `stop` 都发生在它之前。这一条是**对照实验证伪出来的**：给槽位加 `i`
    重编，自测照样全绿 ⇒ 那个「共用槽位会把选中的停掉」的猜想**不可达**，于是没有引入它。
  * 三处调用点接线：列表体（`diff.uya`，`chosen = fi == g_tui_ov_sel`）、ask 选项
    （`ask.uya`，`cur`）、reader 动作行（`watch.uya`，`i == g_tui_ov_sel`）。

  **自测**：新轮 `tui-marquee-row` 四段（见 §19 轮次表）。判据的两条边界是本轮踩出来的：
  ① **只认方框之内** —— 脚注 cpu/ctx/时钟、状态区本来就每拍在变，把它们算进「非选中行
  也在动」等于恒红（P75 的 F 段正是被这类噪声盖住才假绿的）；② **选中行在场要靠位置认**，
  不能靠内容（`看/切模型` 正是会被滑走的那半段），也不能靠 `▸`（列表型浮层的选中只体现
  在样式上）。四段里 A（只有选中行动）与 B（钉住 + 换选复位）分别钉住两个方向，缺一个
  都会假绿：只钉「没别的行动」时「谁都不滚」也满足，只钉「选中行在动」时「全都滚」也满足。

  **防假绿对照实验**（每条单独回退重编，跑 `make tui-selftest`）：

  | 回退 | 结果 |
  |---|---|
  | ① 未选中行也滚（`sel` 恒 true） | 红 5 条（A 段「非选中的行也在滚」） |
  | ② 不钉住（`pin` 恒 0） | 红 3 条（A/B 段「命令名没钉住」） |
  | ③ 谁都不滚（`sel` 恒 false） | 红 6 条（A 段「选中行一个字节都没动」） |
  | ④ 动作行的槽位加 `i` | **绿** ⇒ 那个猜想的缺陷不可达，改动撤回（见上） |

  **一次假绿（记下来，因为这一类太容易重犯）**：C 段的判据第一版是「两份屏幕快照
  **有差异**」。它恒真 —— 浮层里还有选中项说明、标题在动，整屏一比就满足，把动作行的
  槽位改坏也照样绿（实验④的第一版就是这么绿的）。改成**只比被测那一行**之后才有意义：
  `tuis_mr_row_moved(&before, &after, row)`。同一条判据还得从**快照**里取行号
  （`tuis_mr_find_in`）—— 拿当前帧的 `tui_row_has` 去找第二帧的行号会对不上，那是假红。

  **验收**：`make check` ＋ `rm -rf build && make build`（link-audit 通过）＋
  `make tui-selftest`（含新轮）＋ `UYA_SELFTEST_TUI_ONLY=1` 与整轮 `make selftest` ＋
  `make lint-size` / `doc-audit` / `doc-cover` 全绿。既有轮的断言一条没动（单元素路径
  逐字节不变）；`--tui-demo` 与改动前逐字节相同（demo 里没有列表浮层）。
  记了一笔**既有失败**：`tui-paste` 的两条真 PTY 断言在本轮基线上同样红（CR 被当成回车提交
  / 会话日志里没有那条三行合一的 user 消息），当时判为「与本轮改动无关」。**那条判断是错的**
  —— P80 查清它是夹具残留（见踩坑 134），两条红都不是粘贴逻辑的毛病。留这行是为了记住
  代价：一句听起来像产品缺陷的失败文案（「CR 被当成了回车提交」）可以让一个夹具缺陷
  以「既有失败」的名义活过好几轮。

- P75：**放不下的文本滚动显示**（用户报：脚注的工作区路径显示 30 个字符、滚动显示）。
  起点是脚注 cwd 一个字段，落地时收成**一条通用纪律** —— 凡是「一格放不下」的单行文本
  都走同一套槽位 + 时间闸门（`style.uya` 的 `tui_marquee_put` / `tui_marquee_tick`），
  覆盖脚注 cwd、常驻状态行、面板信息行、浮层标题/选中项说明、常驻任务块。

  **为什么 cwd 要固定 30 列而不是「有多少给多少」**：它是唯一会随会话变长的字段。
  worktree 会话的路径形如 `<主仓>/.git/dsh-worktrees/session-<id>`（本会话实测 74 列），
  200 列终端上一条路径就把右半区的统计行挤没了 —— 而「统计行」正是用户看账的那一眼。
  夹住之后宽终端上 cwd 恒占 30 列，多余的列留给统计行。

  **三条出口都恰好占满窗口**（宽度不变量：多一列就顶掉右半区前面那一列间隔，踩过
  `cpu 37%1 轮 · 12 步`）：装得下 → 整段照画（**与 P75 之前逐字节相同**，一个 `…` 都不加）；
  off == 0 → 头部裁到 win-1 列 + 尾随 `…`；off > 0 → 跳过 off 列 + 前导 `…` +（到尾了整画，
  否则再裁一列补尾随 `…`）。**到尾那一帧不带尾随 `…`** —— 已经到底了，再挂一个省略号就是假话。

  **设计取舍**（都写进 §11.5 了，这里只记「为什么」）：
  * 偏移集中存**槽位表**而不是各调用点自己存 —— `tui_put_clipped` 有几十个调用点，
    各存一份等于「谁忘了存谁不滚」；同一个格子还会跨帧走不同分支（浮层开着/关着）。
  * 指纹**只取头部 16 字节**：状态行/任务块的尾部每秒都在变（已运行多久），
    把尾部算进去等于每秒归零一次、永远滚不过开头。
  * 只推进**最近一帧画过**的槽位（帧序号）：浮层关掉的标题不该让屏幕每 400 ms 白脏一次。
  * **刻意不滚**的四处：转录与 reader 正文（已按窗口折行，那里的裁剪只是安全网）、
    思考实时行（尾部锚定，「最新」是它的语义）、输入行（跟用户抢视口）、
    `/diff` 单元格（有**自己的** ←/→ 横向滚动，两套会打架）。

  **自测**：新轮 `tui-marquee` 七段（见 §19 的轮次表）。这一段的自测史本身值钱：
  **用户验收时回了「我验证了不会滚动」** —— 全绿的自测没抓住两个真 bug，其中一个
  还正是用户报的那件事：

  * **缺陷 ①（用户报的那个）**：`tui_marquee_tick` 漏了 `tui_mark_dirty()`。
    `tui_render()` 有**自己的** `g_tui_dirty` 闸门 —— 返回值交给 `tui_tick` 的 `need`
    不够，帧率节流那几关过了之后仍在 `!g_tui_dirty` 上早退。症状：路径**夹到 30 列了**
    （所以我和用户都以为改动生效了），但一个字节都不滚。
  * **缺陷 ②**：端点停留被加在了**每一列**之后 ⇒ 实际 2 秒/列，一条 90 列的 worktree
    路径要滚 90 秒。真 PTY 25 秒里只挪了 5 列，看起来仍然像「不滚」。

  **为什么七段自测全绿却没抓住**（三次假绿，一次比一次接近真相，记下来因为这一类太容易重犯）：
  ① C 段里自测自己调 `tui_marquee_tick` ⇒ 「心跳那一行忘了接」照样全绿；改成只走
  `tui_tick` 才红。② 于是补 F 段，但它**每拍都自己调 `tui_build()`** ⇒ 绕过脏闸门，
  缺陷 ① 照样全绿。③ 改成「只认心跳画的那一帧 + 帧数必须涨」**还是绿**：心跳里还有
  procx 采样与任务块那两路本来就会出帧，噪声盖住了这一路；改用脏位（`tui_dirty_pending`）
  **仍然是假绿** —— headless 下 `tui_flush` 因 `out_fd < 0` **当场早退**，`g_tui_dirty`
  **永远清不掉**，任何脏位判据在 headless 里恒为真。
  ⇒ 结论：**这一条只能在真 PTY 下测**。补 G 段（长工作区起真 TUI、**不按键**只收帧，
  路径后段必须自己滚上来），两条缺陷当场都红（各自单独回退复验过）。
  教训：**「假绿」不是判据写错，是判据落在了一条永远为真的路上**；发现它的唯一办法是
  把被测行为**单独回退**再跑一遍 —— 本轮两个缺陷都是这么找出来的，而它们此前都通过了
  「全绿」。与踩坑 121 同族，也与 §19 P75 那条「新判据照亮既有缺陷」互补。

  **连带抓出一条既有缺陷**（记进 §16 踩坑 128）：新轮的 F 段搅动了堆布局，于是
  `tui-model` 的写回腿当场红 —— 根因是 `dshw_save` 用 cstr 口径拼**临时文件名**（那份
  `Buf` 没有 NUL 结尾），路径尾巴粘上了别的缓冲的残留。它一直绿只是因为既有自测的堆布局
  恰好「干净」。一并修掉（`dshw_path_exact` 按长度拼）。

  **真机复核**（真 PTY、本会话的真实 worktree 路径 90 列）：42 秒采样到 **92 个不同的脚注帧**，
  序列是「头部 → 逐列左移 → `…94878-d9e8-4f25-aa65-61159704`（到尾，**无尾随 `…`**）→
  回头部」闭环，节奏 ≈2.5 列/秒、两端各停 ≈1.6 s —— 与设计一致。

  **验收**：`make check` ＋ `make build`（link-audit 通过）＋ `make tui-selftest` 全绿
  （含新轮 `tui-marquee` 七段）＋ `UYA_SELFTEST_TUI_ONLY=1` 与整轮 `make selftest`。
  `--tui-demo` 的脚注行**变了**（不再只差版本串）：demo 用的是本 worktree 的 74 列真实
  路径，新窗口夹到 30 列 + `…`，统计行因此整条放得下 —— 这是本轮要的效果。短路径装得下
  时逐字节不变（`tui-marquee` A 段钉死）；`--tui-demo` 的其余各屏不受影响（跑马灯只在
  「装不下」时改字节，demo 里只有这一行长过窗口）。
  web 端同一份帧模型照推（跑马灯只改帧内容，不改推帧判据）。

- P63：**Uya 语言速查表从 system 前缀里挪出来（改成按需的 `uya_notes` 工具）+ 提问窗口的插入点**。
  两件事都是**用户报的可见问题**，根因也都是「有一份东西一直在付固定开销」与「有一条不变量套错了面」：

  ① **速查表每轮都发**（§5.1）。它原是本项目的补充节（`agent_extra_section`），**无条件**追加在
  system 末尾 —— 467 B，每一轮请求都付，而它只在「模型要写 / 改 Uya 源码」那一步有用。
  修法：删掉那一节，内容**扩成速查表**并搬进按需的 **`uya_notes` 工具**（零参数、只读）。
  净账：system 少 **469 B**（正文 + 分隔符），工具表多 **245 B**（短描述 + 最小无参 schema）
  ⇒ **每请求净 −224 B**；速查表正文（1.2 KB）只在真调用那一步进对话。
  **描述刻意写短**：它同样是每轮请求的一部分，写长等于把刚省下的字节又花回工具表；
  但触发条件（「写/改 `.uya` / `.ush` 之前」）不能省，否则模型不知道该何时调 —— 这一条有钉子（verdict 157）。
  速查表内容**逐条在仓内与 `$UYA_ROOT/std` 核对过，不发明语法**：没有 `for`（实测全仓零 `for`）
  只有 `while`；`match` / `!T` / `try` / `catch |err|` / `as!` / `defer` / 定长数组 `[T: N]` 与
  `[0: N]` / 结构体字面量 `Type{...}` 都是真实用法；末两条（build 命令与 write 的真换行）
  **逐字保留**旧文案 —— 它们是既有钉子（verdict 154/155）守着的句子。

  ② **提问窗口里看不见光标**（踩坑 100）。`ask_user_question` 的弹窗里自定义回答行能打字，
  但屏幕上没有任何插入点：真光标被「浮层开着就藏」的规则藏掉（弹窗正是在 `TUI_RUN_TOOL` 下开的），
  而行上又没有自己画 —— 同族的 P48 input 型浮层画了，ask 这条当年漏了。
  修法：该行**固定留一格**画 `TUI_ST_SEL`（对齐 P48），文本预算 `body_w-2 → body_w-3`、
  右侧补空格 ⇒ **整行显示列逐字节不变**（逐行宽度不变量照旧）。

  顺带：示例任务文案里那个 `Hello, DSH!` 改成 `Hello, uya!`（输入行占位 + `--tui-demo` 的计划与
  转录），demo 里 diff 的「改前」保持 `Hello, DSH!` —— 「从 DSH 改成 uya」这句读起来才自洽，
  改动也仍然看得见。`/diff` 浮层的合成夹具（`TUIS_DIFF_TEXT`）与真机记录**不动**。

  **判定与验收**：`st_responses` 的条数断言 28 → 29；`prompt-todo-plan` 轮（mock mode 10）
  新增五条钉子 —— 轮 0：system 里**不许**再出现速查表正文（152/153，判据只能用正文里的句子，
  因为描述里本来就有 "Uya language cheat sheet" 那句，第一版就踩了这个假红）、工具表里**必须**有
  `"name":"uya_notes"`（154）、描述里必须留着触发条件（157）；轮 1：`uya_notes` 真的跑了且正文
  回灌进了请求（155 "Uya language cheat sheet" / 156 "UYA_ROOT=<lib>"）。`tui-ask` 轮新增三条
  插入点断言（初始态 / 打字态 / 0 选项态，判据是「含 `✎ ` 的那一行里存在一个 `TUI_ST_SEL` 段」，
  不写死列号）。
  **两条防假绿对照实验**（都先看到红再改回来）：① 把速查表**加回** `agent_system_prompt`
  ⇒ 红在 verdict **152**；② 把插入点那一格的 `TUI_ST_SEL` 换成 `TUI_ST_DEFAULT`
  ⇒ `tui-ask` 三条腿当场全红。
  验收：`make check` ＋ `rm -rf build && make selftest` 全绿（`SELFTEST PASS`）。

- 踩坑 110（修复，不占阶段号）：**ctrl+v 变成全屏切换 —— 两个键事件码撞成同一个值**。
  用户报的现象很具体：按 ctrl+v（本该贴剪贴板）变成了浮层全屏开关。根因不在键路由，
  在 `keys.uya` 的**常量数值**：`TUI_K_CTRL_V` 与 `TUI_K_FULLSCREEN` 都是 30，
  而分派是 if 链、全屏那条写在前面 ⇒ 粘贴那条成了**死代码**；浮层内那条链顺序相同，
  所以有浮层时同样错。来历是两条**并行线**各自取了「下一个空号」30（`22dceaa` 的 P49
  全屏 / `5ef9053` 的 P51 ctrl+v，两者互不为祖先），合并时没有任何东西比对数值 ——
  原注释甚至写着「不会与既有绑定冲突」，把「字节不同」当成了「事件码不同」。
  此前全绿的原因与踩坑 94 同族：P51 加键时**没补自测**，`tui-full` 的 B 段只测
  ctrl+f / F11，两侧都没覆盖到 ctrl+v。
  修法：`TUI_K_CTRL_V` 改 **31**（移孤立项，保住 27–30 那条连续段），
  改前确认全仓不依赖数值（无序列化、无按码索引、无范围比较、`ev` 是 `i32`）。
  修法与三条钉子、防假绿对照实验见 §16 踩坑 110；`tui-keys` 轮新增 ctrl+v 两条行为腿
  + 全部事件码两两比对的**根因哨兵** + help 文案钉子。`--tui-demo` 不受影响
  （它不画 help 浮层）。版本串不动（修复轮不占号）。

- 真机模型增补（不占阶段号）：**AutoDL 的 `GLM-5.3-flash` 与 `hy4-preview` 上了本机网关**
  （`aigw-local` → `127.0.0.1:8088` → `www.autodl.art`）。改动分两处：
  `~/ai-gateway` 新增 `scripts/autodl-models.sh`（一次写全三层：供应商模型行含成本价、
  对客模型目录项、模型路由；默认干跑、`--apply` 才写、整数算价、写后读回核对 +
  `router/explain` + `pricing/simulate`）与 `docs/todo_done.md` 一节；本仓这边是
  `~/.dsh/settings.yaml` 的 `aigw-local` 加两个条目 + README 的档位告诫 + §16 踩坑 112。

  **为什么记在本仓**：两条实测结论都会改变本仓的行为，不是纯网关运维。
  ① `GLM-5.3-flash` 对 `reasoning_effort` **只认 `low`/`high`/`max`**
  （`none`/`minimal`/`medium`/`xhigh` → 400），而网关的能力申报只有布尔 ——
  所以 DSH 那边那个 `reasoningEfforts:` 映射**必须按实测写**，照抄全集会让用户选中
  一个必然 400 的档位（`degradation: strip` 只标记不剥离，错误原样透出）。见踩坑 112。
  ② `hy4-preview` 现在**任何请求都 402**（腾讯侧免费额度用尽、未开后付费），
  能力一个都没实测 ⇒ 网关侧 `capabilities` 留空（读作「未知 → 不拦」），本仓这边
  也不给它写 `reasoningEfforts`（不发明档位那条规则的直接后果）。

  **真机验收**（经网关 `/v1/responses`，`GLM-5.3-flash`）：① 普通话 → 200 `completed`；
  ② **工具轮 + `reasoning_content` 回放**（`function_call` + `function_call_output`）
  → 200 `completed`，正文用上了工具结果；③ **模型自己发出的工具调用** → 200，返回
  `function_call get_weather {"city": "Beijing"}`。后两条正是 deepseek 方言
  `replay_reasoning_content` 最会坏的地方（网关对没回传的历史补**空串**，实测被上游接受）。
  计费反算三笔逐位相等（原生按维度 `ceil`、账本 = `ceil(原生合计 × 0.15)`：
  `2593→389`、`208→32`、`239→36` 微美元），说明 CNY 规则集 × `fx_rates.CNY=150000`
  的入账口径在这两个新模型上也是对的。

  与 P61 那条同族的一点：两个模型**都没写 `maxTokens`**（上游没公布可引用的输出上限，
  页面只给了上下文 1024K），所以本仓按 `effective_max_tokens` 发默认 **256000** ——
  「不发 = 把上限交给中间那一跳」这条路口仍然焊死着（P61 的教训），
  而 `hy4-preview` 的 `context_window` 写 1024000（那条是页面公布的事实，不是猜的）。

  验收：网关侧干跑 + `--apply`（6 次写入全 200、读回三层逐字段一致、`router/explain`
  候选在且 `excluded` 空、simulate 两个模型都对）+ 重启回归（`bootstrap done` 增量为 0、
  `snapshot(models=3 provider_models=3 routes=3)`、日志 ERROR 计数与改动前相同）；
  本仓侧 `make lint-size` / `make doc-audit` / `make build` 与 `--print-config` 两条
  （见下一条 bullet 的实测输出）。

### 19.1 与 DSH 的头对头（OpenBench 4 题，P78）

**问题**：同一个模型（`aigw-local/DeepSeek-V4.1-Flash`，推理强度 `max`）、同一批任务，
harness 差多少？用的是第三方基准 **OpenBench**（`minghinmatthewlam/openbench`，
专为「换 harness、不换模型」设计；**不是 DSH 官网的 bench** —— 官网没有 bench 页）。

任务 4 个：`taskflow`（修 5 处逻辑缺陷让 25 个单测全绿）、`make-ci-green`（16 个）、
`add-feature`（给 miniconf 加 `@include`）、`webcore`（给微框架加类型化路由/挂载/内容协商）。
判据是**任务自带的 pristine 测试套件**（cwd 指向 agent 的工作区副本，改工作区里的测试没用），
按 `test_ids.txt` 逐条隔离跑、给部分分 `SCORE: 0.0-1.0`。
测量装置（两个 adapter + dsh 的隔离 home 模板 + 复现命令）已入库：
[`testdata/openbench_adapters/`](testdata/openbench_adapters/README.md) —— 它是**验收装置**，
不进 `Makefile` 的 `SRC`、不参与构建（与 `testdata/` 下其它验收脚本同口径）。

**三道控制先立住**（都在花钱之前）：

| 控制 | 期望 | 实测 |
|---|---|---|
| 负控 `--harness null` | 未改动的仓库必须拿基线分 | `0.28 / 0.3125 / 0.40 / 0.30`，`success` 全 false ✓ |
| 正控 叠 `solution/` | 必须全 1.0（证明题有解、判据不是恒假） | 四个**全 1.0000** ✓ |
| 通路 假 key / 真调用 | adapter 能被 runner 调起、`SCORE` 落盘 | 两侧都调起；token 数与网关账本**逐数相等** ✓ |

**配对轮结果**（两侧输出上限都设 256000，见下「坑一」）——**⚠ 本节全是 n=1，
效率结论已被 §19.3 的 n=3 推翻，只保留能力结论**：

| 任务 | uya-agent | dsh | |
|---|---|---|---|
| `taskflow` | 1.0 · 82.6 s · 613 k tok | 1.0 · **45.1 s** · **373 k tok** | dsh 快 1.8×、省 1.6× —— **⚠ 这一格是 n=1，已被 §19.3 的 n=3 推翻**（中位数打平，dsh 轮数极差 83） |
| `make-ci-green` | 1.0 · 24.3 s · 121 k | 1.0 · **22.5 s** · **104 k** | 基本持平（dsh 略优） |
| `add-feature` | 1.0 · **53.9 s** · **118 k** | 1.0 · 76.2 s · 253 k | uya-agent 快 1.4×、省 2.1× |
| `webcore` | **1.0**（补测轮 514.6 s · 54 步） | 1.0 · 729.9 s · 63 步 | 都能解；配对轮 uya-agent 那格被上游掐断（见「坑三」） |

⇒ **能力上没有差距**：4 题两侧都能拿到满分（`webcore` 的 uya-agent 满分来自补测轮，
不是本轮的 0.30）。**差距全在效率与稳健性上**，且**方向按任务而分**：dsh 在最难的多模块
推理题（`taskflow`）上明显更快更省；uya-agent 在「按规格加一个特性」（`add-feature`）上更快更省。
**⚠ 上面这两句的「效率」部分只是 n=1 的单次抽样，已被 §19.3 的 n=3 复测改写**
（`taskflow` 中位数打平，且 dsh 三次里有一次跑到 96 轮；`add-feature` 方向一致但量级更小）。
**两轮一致、可以引用的只有「能力上没有差距」。**

**三条踩坑（都是实测，不是推测）**：

**坑一：跨 harness 的输出上限必须显式配对，否则结论会反过来。** pi-ai 目录给
`DeepSeek-V4.1-Flash` 的默认 `maxTokens` 是 **32768**，而本仓 `--max-tokens` 默认 **256000**。
第一轮没配对时 dsh 在 `webcore` 上「每步都正常、到第 16 步撞顶」
（会话日志：`outputTokens: 32768` + `finish reason: max-tokens`）——
它想把整个实现写在一次推理里，撞顶后**一个字节都没落盘**（`workspace_changed=false`），
得分停在基线 0.30。把 dsh 的 `maxTokens` 提到 256000 后，**同一个任务 78 步跑完、1.0000**。
⇒ 第一轮那张表**是错的**，已作废；凡跨 harness 比输出上限，必须配对并写进报告。

**坑二（给本仓的、可行动的）：本仓没有传输层重试，dsh 有。**
dsh 的 `dsh-base` 挂了 `dsh-llm-retry`，默认策略是
**对 `TRANSPORT`/`TIMEOUT`/`SERVER`/`RATE_LIMIT`/`EMPTY_RESPONSE` 重试 5 次**，
退避 500 ms–10 s、10% 抖动；本仓 `agent_step_stream` 收到 `err_kind == 3`
（网络/TLS）直接 `return AGENT_NET`（退出码 2），**一层重试都没有**。
实测差距：配对窗口内 dsh **100 次请求 0 次失败**，本仓 **163 次请求 2 次失败**；
`webcore` 上本仓累计被上游掐断 **4 次**（延迟 108–261 s 后 `upstream_error`），
唯一一次跑通的补测轮拿了满分 —— 也就是说**丢的全是本来能解出来的题**。
⇒ 这是本轮唯一一条**直接该改本仓**的结论：一次 5xx/超时不该让整个任务作废。
**（已修：P82，见 §19.3 —— 上面这几段保留为当时的现场记录，判据与验收在那一节。）**

**坑三：上游故障不是 harness 缺陷，别把它记成能力差。** 网关历史里
`upstream_error` 两边都出现过（`unknown`/`dsh`/`uya-agent` 全有），是共享基础设施问题。
本仓那一格 0.30 全部来自「被掐断」而不是「做不出来」—— 报告里必须这么写，
否则就把基础设施故障读成了 harness 差距。

**本仓侧顺带量到的**：本仓平均每次请求的 prompt 是 **56 k token（峰值 213 k）**，
dsh 是 **18.6 k（峰值 53 k）** —— 3× 差距。两者上下文管理策略不同（本仓每步带全历史，
dsh 有压缩/剪枝），这既解释了本仓更高的单请求成本，也解释了它更容易撞上上游的
长请求不稳定。`reasoning` 一列**两侧不可比**：dsh 本版本的会话日志**不写
`reasoningTokens`**（只有 `inputTokens`/`outputTokens`/`cacheReadTokens`），
而账本里确实有 reasoning 计数 ⇒ 报告里 dsh 那列留空，不填 0。

**边界（不许读过头）**：n=1（`webcore` 另补了重复轮），**不是统计显著**，报的是方向性差异；
金额上从打通到收尾（含干跑、作废的第一轮、补测轮与三次诊断复现）总共约 **¥0.84**，
其中**配对轮本身 ¥0.13**。

### 19.2 P79：修 §19.1 量出来的那个真缺陷（剪枝压力闸门）

§19.1 只报告了差距，其中 `taskflow` 那格（dsh 快 1.8× / 省 1.6×）**有具体根因**，本节修掉它。
根因不是「能力」，是 §5.3.1 记的那条：剪枝**每步无条件生效** ⇒ 读一个 >8192 的文件中段被剪
⇒ 模型为找回中段再窄读 ⇒ 那一段又被剪 ⇒ **自锁**。DSH 同套数字但只在压力达标时剪。

**修法**：加 `cmp_prune_armed()` 闸门（与压缩同一条触发线），两个构请求点都过它；
**不动**「只在构请求层、不改历史」那条不变量，也**不动** 8192/4096/1024 三个 DSH 同款默认值。

**验收（都是实测）**：

| 判据 | 结果 |
|---|---|
| `st_stats_ctx` / `prune-bash` 新增 6 条（低压力不剪、高压力要剪、窗口未知仍剪、闸门关掉=旧行为、恰好到线、闸门输入=未剪原文） | 全绿 |
| **负控①** 把闸门写成恒 `true` | 「低压力不剪」+「差一点不到线不剪」**当场红** |
| **负控②** 把闸门写成恒 `false` | 「高压力要剪」+「恰好到线要剪」**当场红** |
| `make selftest`（全轮） | PASS |
| `make lint-size` | 通过（4 个文件） |
| `uya check`（全 113 文件） | 通过 |

**真机复核**（同题同模型，只多了这道闸门）：

| | 模型调用 | read 次数 | 超阈值 read | 得分 |
|---|---|---|---|---|
| taskflow 改前 | 24 | 29 | 8 | 1.0000 |
| taskflow 改后 | **17** | **17** | **5** | 1.0000 |
| make-ci-green 改后（回归腿） | 11（不变） | — | — | 1.0000 |

**踩坑（编译器）**：本机默认的 `/home/winger/uya-0.10/bin/uya` 是 **v0.10.1**，
还带着 **64 个显式输入文件的上限**（CODING.md §1.2.1 记的就是这条）——本仓现在 **113 个**
构建文件，用它 `check`/`build` 只会报 `收集模块依赖失败: <编译器路径>`，
**报错指不到根因、看起来像编译器坏了**。实测 60 个文件过、70 个就炸，正是那条上限。
可用的编译器是 **v0.10.3**（`/home/winger/uya/uya/bin/uya`，`UYA_ROOT=/home/winger/uya/uya/lib/`）。
⇒ 换机/重装后第一步先 `uya --version` 认版本，别把这条当代码 bug 查。

### 19.3 P82：给主链加传输层重试（修 §19.1 坑二）
### 19.4 P81：模型的上下文窗口（`uya-agent.contextWindows` + env + CLI）

> 编号说明：**P80 被名字解析那条线占了**（`705b7f6`：`resolv.conf` 读窗口 + `UYA_AGENT_DNS`，
> 踩坑 133），本线条因此在合并时按惯例让位、记成 **P81**（与「P74/P78 合并 main：踩坑编号
> 让位」同一套做法，踩坑 110 一族）。两条线改的文件重合 8 个，合并时逐处取并集。

用户报的原始症状是「上下文窗口配不动」：只有 `--context-window` 一个入口，而真机那条路线
（`autodl.art` 的 `DeepSeek-V4.1-Flash`，纯 env 部署）既没有 DSH 目录条目、又必须手工传 flag。
动手前先量了三条现状（都是 `--print-config` 实测）：

| # | 事实 | 现场 |
|---|---|---|
| ① | `--context-window` 与 `--model` **谁赢取决于命令行顺序** | `--context-window 99999 --model a-plain` ⇒ `111000 (dsh-settings)`；反序 ⇒ `99999 (cli)` |
| ② | 模型来自 env（或 DSH 默认路线）时，窗口取的是**那条路线**的值 | `UYA_AGENT_MODEL=a-plain`（目录里 111000）+ 默认路线 a-think（222000）⇒ 印 `model = a-plain` 而 `context_window = 222000` |
| ③ | `-1`（未知）被 `as usize` 印成 `18446744073709551615` | `--no-dsh-config --print-config` |

①②③ 都是「配置在说谎」这一族，所以修法一并收口：**四档来源 + 一个定稿点 + 两条可证出口**
（§5.3.4 是设计，这里是验收）。

**验收（都是实测）**：

| 判据 | 结果 |
|---|---|
| 新增自测轮 `ctxwin`（9 条腿，见 §19 上表） | 全绿 |
| 新增 `make e2e-ctxwindow`（8 条腿，真二进制 + 真 settings.yaml，**`env -i` 起**） | 全绿 |
| **负控①** 去掉显式守卫 + 映射不参与 | 自测轮红 8 条（映射压不过条目、显式被覆盖） |
| **负控②** 键匹配改成「键以查询开头」 | `c-f` 那条腿红 |
| **负控③** 键匹配改成「查询以键开头」 | `c-five` 那条腿红 |
| **负控④** env 入口整段变死代码 | `e2e-ctxwindow` 的 env 腿红 |
| `make lint-size` / `make doc-cover` / `make doc-audit` / `uya check` / `make build` | 全通过 |

**负控②③ 是补出来的** —— 原计划只打算用「目录外沿用原值」那条腿抓前缀匹配，实测**抓不住**
（前缀匹配下 `c-six` 本来就查不到任何键，行为与正确实现一致）。真正的判据得让「一个键是另一个
模型名的一部分」：于是夹具里加了 `c-fi: 101010` 与模型 `c-five` / `c-f`，两个方向各自一条腿。
这是本轮最值钱的一条经验：**「我加了这个判据」与「这个判据真的能红」是两件事**，
写判据时先问「哪种错误实现会让它红、那种实现现在会被别的判据拦住吗」。

**与既有口径的一致性**：不写回设置文件（那是 P71 那条线的事，本轮只读）；不读 DSH 的
provider 级 `defaultContextWindow`（DSH 自己的兜底链，本仓另有需要时再单开一轮）；
子代理继承父的窗口（走的是同一份 `Config`），`--exec-effort` 那类自动降档不碰它。

**已知的环境噪声（都不是本轮引入的，逐条量过）**：

| 现象 | 现场 | 结论 |
|---|---|---|
| `make e2e-model` / `e2e-config-flags` 在**宿主已导出 `UYA_AGENT_*`** 的机器上红 | 本沙箱导出了 5 个 `UYA_AGENT_*`（含 `UYA_AGENT_MODEL`），断言 `base_url = … (source: default)` 的腿因此失败 | 这两个目标假定「干净的机器」；`env -i` 起就全绿（实测 4 个目标一起过）。`e2e-ctxwindow` 因此**一律 `env -i` 起**，两种环境都绿 |
| 整轮 `--selftest` 里 `fs-tools` 红（`mock server verdict 47`） | 47 = grep 工具结果里该有 `Line 2: beta two`；而 grep 工具是 **ripgrep 子进程**，这台机器上 `rg` 根本不存在 | 环境缺 `rg`；与本轮无关 |
| 同轮里 `compact-auto` 红（`verdict 88`） | 88 = 压缩后的请求里该有 checkpoint 前言 | 与 `rg` 同类的环境/顺序问题：判据两条 —— ① 换成干净 env、清空 fixture 重跑，**红法逐字相同**；② 该轮走 `agent_run`（进程内），而 `agent_run` → `agent_history_begin` → `agent_turn_loop` **一个字节都不碰**模型目录 / `agent_ctxwin_settle`（新增的调用点只有 `main`、`agent_model_apply`、`agent_model_resume_apply`）⇒ 本轮改动在那条路径上不可达 |
| `tui-paste` 时红时绿 | 真 PTY 轮，三轮里红两轮 | 踩坑 98 那一族（跨轮残留的键盘时钟 / PTY 时序），单跑另说 |

其余 164 条 `selftest[…] ok` 与全部模型相关 e2e（`e2e-model` / `e2e-model-save` /
`e2e-model-route` / `e2e-config-flags`）在干净 env 下全过。

---


§19.1 的坑二是本轮唯一一条**直接该改本仓**的结论，本轮把它做掉：**本仓原来一层重试都没有** ——
`agent_step_stream` 收到 `err_kind == 3`（网络/TLS）直接 `return AGENT_NET`（退出码 2），
一次 5xx/超时就作废整个任务。配对窗口内的实测：dsh **100 次请求 0 次失败**（它挂了
`dsh-llm-retry`，对 `TRANSPORT`/`TIMEOUT`/`SERVER`/`RATE_LIMIT`/`EMPTY_RESPONSE` 重试 5 次、
退避 500 ms–10 s + 10% 抖动），本仓 **163 次请求 2 次失败**；`webcore` 上累计被掐断 4 次
（延迟 108–261 s 后 `upstream_error`）—— 丢的全是本来能解出来的题。

**修法**：新增 `src/net/retryx.uya`（**分类与退避的唯一出处**：`rtx_retryable_err` /
`rtx_retryable_status` / `rtx_retryable_body_code`、纯函数 `rtx_backoff_from`、
可测的 `rtx_backoff_ms`、进程级预算 `rtx_set_max`/`rtx_max`/`rtx_exhausted`、
裸 sleep `rtx_sleep_ms`），step 循环里加第二个内部码 `STEP_RETRY_NET`（102）——
与 P54 的 `STEP_RETRY`（101）**形状刻意一样**：同一步重发、历史一个字节不动，
所以重算出来的 url/req 与上一次**逐字节相同**。

**四条不变量**（都可测，判据见下）：

| # | 不变量 | 为什么它是承重的 |
|---|---|---|
| ① | **同一步重发**：step 不递增、历史不动 ⇒ 请求体逐字节相同 | 往重发路径里塞一个字节（换 header、压条消息、step 推进一格）都会让 mock 端的比对当场红 |
| ② | **退避期间可中断**：≤50 ms 切片 + `llm_pump_input`，esc/ctrl+c/ctrl+d 立刻收口成 130 | 这是「无限重试」不变成「无限卡死」的**唯一**凭据（与踩坑 44 同族） |
| ③ | **有界出口**：`--api-retry-max 0` 逐字节回到 P82 之前的行为 | CI/排障要能 fail fast；也是负控腿的判据 |
| ④ | **失败种类不因重试而混同**：传输错始终 `2`、非 200/协议错始终 `3` | 脚本靠退出码分辨「该重跑」与「配置错了」，重试不许把它抹平 |

**分类表**（写进 `retryx.uya` 文件头，改它之前先问「这条错重试真的会变好吗」）：

| 重试 | 不重试 |
|---|---|
| 连接被拒/断开/超时、响应头半截（`HcConnectFailed`/`HcIoFailed`/`HcTimeout`/`HcBadResponse`）、SSE 没等到 `[DONE]`（`LlmStreamClosed`） | 证书信任（`HcPinMismatch`/`HcTlsUnsupported` —— 确定性的配置问题，重试只会刷屏）、坏 payload（`LlmMalformed`，重复的坏字节）、URL/过大/内存（`HcBadUrl`/`HcTooLarge`/`HcOutOfMemory`） |
| HTTP **408 / 425 / 429 / 5xx** | HTTP 400 / 401 / 403 / 404 / 405 / 422…（配置与鉴权错）；**404 仍归 `api_may_negotiate` 走协议协商**，所以不在重试集合里 |
| 体内错误帧且 `error.code` ∈ {server_error, rate_limit_exceeded, overloaded_error, insuffi­cient_system_resource, internal_error, api_error, upstream_error, timeout} | **code 不认识的一律不重试**（不替上游猜：`context_length_exceeded` 那种越重发越糟）、用户中断（人优先） |

**为什么必须要机器码而不是散文**：`ChatOut` 新增 `err_code`（`llm.uya` 三处已有解析 `error.code`
的地方各回填一次），因为 `err_text` 是**给人看**的前缀（240 B 上限、可能是 message 而不是 code）——
拿散文去搜关键词会重发 `context_length_exceeded`。

**退避**：**0.5–3.0 s 均匀随机**（`rtx_backoff_from` 是纯函数，自测逐值验区间；
`rtx_backoff_ms` 用 xorshift64，种子 = `ua_now_ms() ^ (pid << 16)`）。抖动不是为了「等更久」，
而是让同一故障下的多个客户端不同时回来。

**验收（都是实测）**：

| 判据 | 结果 |
|---|---|
| `net-retry`（mock mode 45：503→429→200）：两条 `[retry]` + 日志两条 `llm/retry` + **三次请求逐字节相同** + `step/start` 只有一条 + 退出 0 | 绿 |
| `net-retry-intr`（mode 46：503 之后**退避里**按 ctrl+c）：退出码 **130**、只有一条 `[retry]`、转录**没有** `error:` | 绿 |
| `net-retry-401`（mode 47）：401 属不可重试 ⇒ `[retry]` **零条**、当场以 3 收口 | 绿 |
| `make e2e-retry` 五条腿：默认重发到成功 / `0`（1 次请求即退 3）/ `1`（同）/ `2`（退 0、一条重试）/ **死端口 `--api-retry-max 3` ⇒ 退 2 而不是 3** | 绿 |
| `make lint-size` / `make doc-audit` / `make doc-cover` | 通过 |
| `make selftest`（全轮） | 见下 |

**防假绿对照实验（五条，都先看到红）**：

| # | 改动 | 结果 |
|---|---|---|
| ① | 把 5xx 从 `rtx_retryable_status` 里摘掉 | `net-retry` 六条断言一起红（行数/序号/日志条数/attempt） |
| ② | `agent_rtx_wait` 去掉 `llm_pump_input`（只睡不读键） | `net-retry-intr` 红（重试行数、日志条数、「已中断本回合」那条全对不上） |
| ③ | 把日志侧 `llm/retry` 的事件类型名改掉 | 转录仍绿、**日志侧两条红** ⇒ 证明「日志判据」不是转录判据的复读 |
| ④ | 重发前往历史压一条 `PERTURB` | `net-retry` 红在 **mock 端判定码**（逐字节比对）—— 退出码照样 0，只有这个判据抓得住 |
| ⑤ | `rtx_exhausted` 恒 `false`（预算闸门失效） | selftest **三条全绿**，`make e2e-retry` **红在 `off` 腿**（退出 0、两次重试）⇒ 「预算是 step 循环读的」这件事只有 e2e 覆盖得到 |

⚠ 对照实验 ③ 顺手抓到自测自身的一个真缺陷：`netretry_check` 第一版把两半的返回值写成了
`return true`（常量）而不是累积的判定 —— 症状是**转录里 FAIL 一行行在打、整轮却报 PASS**
（`SELFTEST RETRY PASS`）。这是本仓踩坑 86「判据要读事实」的又一个现场：**改写判据代码
之后，负控必须重跑一遍**，否则「红过」这件事作废。

**整轮跑出来的两个真缺陷**（都是「只在完整流程里才暴露」那一族，单跑 `UYA_SELFTEST_*_ONLY`
一条都看不见 —— 与踩坑 108/87 同族）：

1. **闸门被每个自建 cfg 的调用方重新拧开。** 第一版 `agent_turn_loop_inner` 无条件
   `rtx_set_max(cfg.api_retry_max)`，而 `cfg_default()` 里那一位是 `RTX_UNLIMITED` ⇒
   `selftest_main` 顶部那句 `rtx_set_max(0)` **当场失效**（每一个夹具轮次都把它拧回去）
   ⇒ 撞上「mock 服务完 `limit` 轮就退出」的轮次就无限重试。**实测量到的现场**：
   `make selftest` 卡在 `e2e-portable` **35 分钟**（整轮套件没有全局超时），
   假网关的 `req.bin` 从几百字节涨到 **30 MB** —— 因为那一轮的假网关回的是**非 SSE 的
   整段 JSON**，而客户端要的是流 ⇒ `LlmStreamClosed`（分类表里正好可重试）。
   **修法两条**：① agent 侧只在 `src_api_retry != 0`（人显式给过）时才动进程级闸门
   —— 与 web 子进程「没给就不注入」同一条纪律；② `e2e-portable` 那一发显式
   `--api-retry-max 0`（它验的是「请求里有没有 plan 段」，不是「网关答得好不好」）。
   **教训**：「进程级默认值 + 每个调用方都带一份 cfg」这个组合里，**无条件照抄 = 把别人的
   设置覆盖掉**；判据不是「我这份 cfg 是什么」，而是「这一位到底有没有人显式给过」。
2. **一条天生会 flake 的断言。** 第一版拿「两次真跑的退避值不相等」当「随机数在动」的判据
   —— 两次独立取样有 **1/2501** 的概率撞上同一个值，整轮 selftest 里红过一次。
   **修法**：把这件事改成**确定性**判据（`rtx_backoff_pure_check`：喂 300 个连续读数，
   看区间与取值个数），并单独成一轮 `net-retry-backoff`（不起 mock、几微秒跑完）。
   **教训**：判「随机」不能靠「观察到两个不同的样本」，那本身是概率事件；要么改成对
   生成函数的确定性判据，要么明确接受概率并写清它。

**边界（不许读过头）**：

* **不加到侧路请求上**：`--probe`（诊断那一发本来就要立刻知道结果）、自动起标题、
  压缩摘要一律**不重试** —— 它们是侧路/后台请求，失败是良性的（标题可选、压缩下个 step
  边界自然会再试），而且不该占着用户的时间。重试只在 `agent_step_stream` /
  `agent_step_plain` 这两个**主链**出口上。
* **不动 `llm_stream_style` 内部**：`st_responses` / `st_round_driver` 里那些直接调解析器的
  轮次因此不受影响（它们钉的是协议解析，不是重试策略）。
* **自测里默认关**：`selftest_main` 顶部 `rtx_set_max(0)`（与 `wt_set_on(false)` 同一条纪律：
  会改变全局行为的东西，自测必须自己钉住初值）—— 否则 mock 服务完 `limit` 轮就退出，
  任何「客户端还会再发一次」的腿都会撞 ECONNREFUSED 然后无限重试下去（整轮套件没有全局
  超时，一个轮次就能拖死它）。P82 那三轮自己把闸门开回来。

### 19.5 P79 交付后复测：**n=1 的「dsh 快 1.8×」是噪声，被 n=3 推翻**

§19.1 那张表是 **n=1**，当时就标了「不是统计显著」。复测把三题各跑 **n=3**，
结论**变了**，记在这里以免那份 n=1 的数字被当成定论引用。

**taskflow（唯一有 >8 KB 源文件、会被剪枝影响的题）**：

| | trial 1 | trial 2 | trial 3 | 中位数 | 极差 |
|---|---|---|---|---|---|
| 本仓 轮数 | 22 | 21 | 23 | **22** | **2** |
| dsh 轮数 | 17 | **96** | 13 | 17 | **83** |
| 本仓 token | 774 k | 624 k | 756 k | 756 k | — |
| dsh token | 769 k | **7 606 k** | 428 k | 769 k | — |

⇒ 中位数上 dsh 轮数 0.77×、**token 1.02×（实际打平）**。§19.1 那句「dsh 快 1.8× / 省 1.6×」
**只反映单次抽样的运气**：dsh 三次里有一次跑到 96 轮 / 7.6 M token（是本仓的 10 倍）。
**同时本仓的极差是 2、dsh 是 83** —— 这一项的差别比中位数更值得看：本仓在这题上**可预测**。

**另外两题**（中位数，dsh / 本仓）：

| 任务 | 轮数 | token | 耗时 | 稳定性（轮数极差） |
|---|---|---|---|---|
| `make-ci-green` | 0.89× | 1.15× | 1.08× | 本仓 1 / dsh 1（都很稳） |
| `add-feature` | 1.07× | 1.31× | 1.12× | 本仓 10 / dsh 5 |

三题两侧 **n=3 全部 12/12 解出**（各题 3/3）——**能力上仍然没有差距**，这是两轮一致的结论。
差别只在效率，且**量级远小于 §19.1 那张表暗示的**（多数项在 ±30% 内，方向按题而分）。

**闸门确实生效**（不是「改了但没触发」）：复测的 transcript 里 **`pruned` 标记 0 个**
（改前同样的题必然出现），因为 taskflow 全程压力远低于触发线（峰值 ctx ≈ 47 k token，
闸门线 = `1e6 × 0.8` = 800 k）⇒ 全程不剪 ⇒ 与 §19.1 那条 A/B（把阈值提到 200 k）**等价**。
也就是说：**闸门把「补救读」这一类浪费消掉了，但 taskflow 的轮数主要由题目难度决定**，
`-3 轮` 那种量级（§19.2 的 24→17 是 n=1）在 n=3 下站不住。

**仍然成立的两条**（两轮复测都一致）：
① `webcore` 上本仓**反复**被上游 `upstream_error` 掐断（本轮又中一次，退出码 2、
`workspace_changed=false`）—— 这是共享基础设施故障，不是能力差；§19.1 报的那条
「本仓没有传输层重试、dsh 有 5 次」**依然是本仓该改的第一项**。
② `make-ci-green` 三题里两边都稳（极差 ≤1），是最干净的对照题。

**代价**：本轮三组（n=1 四题 + taskflow n=3 + 另两题 n=3）共 **26 格**，合计约 **¥1.16**。

**方法论教训（写下来别再犯）**：**n=1 的 harness 对比足以让结论反向**。
`taskflow` 本仓轮数三次 22/21/23（稳）、dsh 17/96/13（狂跳）——单跑一次抽到 17 就会得出
「dsh 快 1.8×」，抽到 96 会得出「本仓快 4×」。凡是跨 harness 报效率差，
**必须先看极差再看中位数**；极差远大于中位数差时，那个差就不是结论。

### 20.1 为什么做：先证伪「省 token」，再给真实理由

动手前在**真机 157 个会话 / 4.59 G prompt token**（提供方 usage 读数）上量过一遍。
流传的说法是「认知图谱记忆能省 90–99% 输入 token」，实测不成立：

| 项 | 实测 | 说明 |
|---|---|---|
| prompt token 里 **cache-read** 占比 | **98.7%** | 已经是 1 折；而「重复读文件」正是它的主体 |
| 折算单价后 cache-read 占总花费 | **74.5%** | 省它是省**折后**量 |
| 「定位型」调用（`ls`/`sed -n`/`find`/`make check`/读 README·Makefile…）折算成本 | **10.5%** | 这就是「完美记忆」的天花板 |
| 最宽松口径（任何文件的首次 read 全算可替代） | 6.7% | |
| 「探索型 read」（该会话中从未被编辑的文件）全算 | **12.9%** | 现实取一半 ≈ 6% |

**所以「省 token」是错的目标函数** —— 盯它会把方向带偏。实测支持的是另一个痛点：

| 指标 | 实测 |
|---|---|
| 会话**以定位调用开场**（第一个动作不是干活） | **101/156 = 65%** |
| 开场连续定位调用中位数 | 1（均值 2.2，p90 5，**max 18**） |
| 开场连续 ≥3 次的会话 | **53 个** |
| 到**第一次 write/edit** 的等待 | 中位 **700 秒** |
| 同一 cwd 下有 ≥2 个会话 | **98.9%**（2528/2557） |
| 跨会话被读过同一文件 | **27.9%**；`README.md` 38 个会话、`Makefile` 19、`src/agent.uya` 18 |
| 逐字重复的命令 | `ls -la` 13 个会话、`pwd && ls -la` 9、`sed -n '1,60p' Makefile` 6、`make check 2>&1 \| tail -20` 4 |

**结论：买的是「跨会话的结论与出处」，不是「省 token」。** 同理，验收指标是
「以定位开场的会话占比」，不是 token 节省。

### 20.2 五条不变量（每条对应一个实测踩过的坑）

| # | 不变量 | 破坏后果 / 实测依据 |
|---|---|---|
| ① | **项目键按归一化仓库根算，不按 cwd** | 实测 167 次 `session/workspace` 是 worktree 切换（真实 cwd 每会话都不同）⇒ 按 cwd 算等于每次都是新项目，记忆永远攒不起来。worktree 的 `.git` 是**文件**（`gitdir: …`）、主仓是**目录**，两种形状都要认；从 gitdir 反推主仓走 `worktrees` 段而不是猜前缀 |
| ② | **分片只追加 + 读时归并，绝不共享快照重写** | 同一仓库根下实测成百个会话（`/tmp` 一个 cwd 就 341 个）⇒ 快照重写 = 最后写者赢 = 前一个会话的信念**静默消失**。归并的 value / 校验锚点按 `ts_last` 取最新（**不是**「谁后读到用谁」），否则结果绑在 `getdents64` 的目录顺序上、开工包不可复现 |
| ③ | **注入前当场校验，正文永不注入** | 实测 **19.2%**（101/525）被读过的文件之后会被改动 ⇒ 注入正文等于注入过期货。只给「去哪读 + 出处 + 次数」；对不上就标 `STALE`、文件没了标 `GONE`。**指针式记忆不可能造成静默误改**——现有 `fs_obs_same_version` 写闸门（§6.3）要求本会话真读过且版本三元组全等才准写 |
| ④ | **抽取确定性，绝不调 LLM** | 让模型自己抽「主张」等于把自证换个位置。而且自测要能复现：时间戳由调用方给、认不出形状就什么都不记。验证命令（`make …`）**两条腿都记** —— commands 回答「怎么跑」、state 回答「上次什么结果」，只记一条会丢信息 |
| ⑤ | **注入只有一次、走独立 user 消息，纯索引而非内容** | system prompt 一个字不改 ⇒ 前缀缓存不受影响（§5.1 的既有纪律）；抄 `skills_catalog` 的形状。`agent_hist_from_log` 在 `--resume` 时会重新求值，所以恢复会话也吃得到 |
| ⑥ | **只记「照着重跑得起来」的命令**（P77 补，见踩坑 130） | 事实里存的是**折叠成一行**的命令，所以多行（实测 19%）与被 512 上限截断的（14%）一律不记 —— 存一条跑不通的比不存更糟（把模型引向死路）。另外剥掉**恒真**的 `cd <本会话工作区> && ` 前缀：不剥则同一条命令在每个 worktree 里都算新 key，跨会话 `n` 恒为 1（本仓实测 468/470）。**只剥目标恰好等于 ws 的那种**，其余 29370 条 `cd X && …` 是别处、剥了就改语义 |

### 20.3 形状：数据与落盘

```
<agent_home>/memory/<repo-key>/obs/<session-id>.jsonl   # 只追加，一行一条事实
```

事实 = `{kind, status, ts, tsLast, n, mt, mtNs, size, key, value, src}`，四类：
`command`（命令可用）/ `convention`（惯例，**只有人确认才算数**）/ `layout`（文件索引 +
stat 三元组）/ `state`（上次什么结果）。`<repo-key>` = 归一化仓库根的 sha256 前 16 hex。

三条工程决定：
* **键用 sha256 而不是把路径转义成目录名**：路径可能 4096 字节而文件名上限 255；哈希定长
  32 且天然消掉 `/`、空格、非 ASCII 的转义分歧。
* **同一 `(kind,key)` 归并成一条**（`n` 累加）：同一文件在 10 个会话各记一次读，渲染时该是
  「读过 10 次」而不是 10 行。
* **目录可整个 `rm -rf`，不丢任何证据**：真相仍在工作区与 `session.jsonl`；`/memory forget`
  就是删目录（与 `/goal clear` 同口径：删干净、不留 tombstone）。

### 20.4 截断顺序与预算

渲染按 **commands → conventions → layout → state**（= 耐久度降序），越靠后越先被预算挤掉：
`state` 最易过期，**commands 永不先丢**（「这个项目怎么跑」最值钱也最稳定）。单条放不下就
**跳过该条继续试**，不做整段截断（截断会把一行切成半截，读起来像坏数据）。预算按字节算，
任何情况下都不超；低于 `PM_DIGEST_MIN` 或一条都没选中就**不注入**。默认 3072 B
（`--memory-budget N` 可调）。头一句固定说明「这是索引不是文件内容」，且刻意压短 ——
它占的是每一次注入的固定税（初版 229 B 的头会把 260 B 的紧预算吃光）。

**但顺序只在「预算不够」时才起作用 —— 还必须有单节份额封顶**（P77 补，见踩坑 130）：
commands 的条数**天然远多于**另外三节（每次成功的 bash 都记一条，而 layout 只在 read 时记、
state 只在验证命令上记），所以「谁先写满谁赢」的实际效果是**最易膨胀的那一节独占预算** ——
实测本仓真记忆目录：3072 B 里 commands 吃掉 **2869 B（99%）**，conventions / layout / state
**一条都进不来**。现在单节最多占正文的 **1/2**（`PM_DIGEST_SECT_DIV`）：份额只改**怎么分**，
不改上面那个截断顺序；某个节没内容时它的份额**照样留给别的节**。

### 20.5 与既有机制的关系（别混）

| 机制 | 管什么 | 与项目记忆的分工 |
|---|---|---|
| `cmp_maybe_prune`（§5.3.1） | **装得下**：超 8192 码点的工具结果剪枝 | 剪枝是「这一次请求」的成本；记忆是「跨会话」的索引 |
| 自动压缩（§5.3.3） | **装得下**：压力 ≥ 0.8×window 时折成 checkpoint | 压缩**主动抹掉**结论；记忆正是要留住结论 |
| `session.jsonl`（§8） | 对话**证据**（原文、可复盘） | 记忆是**派生索引**，删掉不丢证据 |
| `fs_obs`（§6.3） | 本**会话**的写闸门（读没读过 / 版本变了没） | 记忆是跨会话的；写闸门继续兜底 —— 过期记忆也不可能造成静默覆盖 |
| 共享工作区（§9.1） | 子代理之间唯一的长期媒介 | **不改这条**：记忆不做多 agent 共享总线 |

### 20.6 明确不做（不是遗漏，是决定不做）

| 不做 | 理由 |
|---|---|
| 六态信念状态机 / 独立性来源可信度评分 / 8 类边 | 那些为「不确定性推理」服务，实测天花板 <13%，不服务于「减少开工摩擦」这个目标 |
| 向量 / embedding 相似度检索 | 纯 Uya 无数学库与编码器；且会毁掉离线自测的确定性 |
| **用 LLM 抽取主张** | 记忆的价值在「结论由证据推导」；让模型抽取等于把自证换个位置 |
| SQL / RDF / SPARQL / Cypher 查询层 | 那是图数据库的定位，本仓只要一个会话/跨会话的信念索引 |
| 常驻守护进程 / 多写者锁 | 破「单线程 + 泵点」地基（§15.1）；只追加分片 + 归并已够用 |
| 默认全量导入历史会话 | 会把上下文成本转成看不见的爆炸；摄取只从**当前会话**的工具结果开始 |
| 按 cwd 归类 | 见 20.2 ①（worktree 会让每个会话都像新项目） |

### 20.7 已知限制

* **`/memory on` 故意不存在**：开工包在会话开始时就注入了，中途打开对已发出的请求没有意义，
  反而会让人以为「刚才那轮模型看见了」——想开就 `/new`（只给单向的 `off`）。
* **`state` 会过期，而且现在**没有任何机制能标它过期**：它是「上次的结果」，不重跑就不知道
  现在如何。`pm_verify` 只校验带 stat 锚点的**文件类**事实（`PM_K_LAYOUT`），
  `command` / `state` / `convention` 的锚点恒为 0，而「锚点全 0」按口径是**不可校验**（判 0
  = 一致，**不是**过期）—— 所以这两类事实无论过多久都会以干净的样子注入（真机实测：手工塞
  一条 `state: make check — exit 0`，改了项目也一样干净）。渲染时的分区标题
  「Last known state (verify before relying on it)」是**唯一的**提醒，模型只能靠这句话自己
  去重跑。规划里的 `make pm-verify`（重跑被记的验收命令并回写）是唯一能既消灭重复动作、
  又不引入过期风险的机制 —— **尚未实现**。
* **子代理不写记忆**：`agent_pm_begin` 只在主会话的初始化路径上跑；子代理的会话是另开的
  日志，且它的工具结果属于父任务的过程，不该沉淀成项目事实。
* **惯例只有候选**：自动抽取的 `convention` 一律 `observed`，模型与自动流程都**不能**把它们
  晋升成 `confirmed`。计划里的 `/memory confirm <id>` **尚未实现**，所以目前这一节只会积累
  候选（逐条标 `[proposed]`）。

### 20.8 验收

`make pm-selftest`（6 轮，改 `pm/` 时比整轮快得多）＋ `make e2e-memory`（人类命令面）
＋ `make e2e-memory-live`（**真机接线**，见本节末）。

| 轮 | 覆盖点 |
|---|---|
| `pm-identity` | 真 git 仓 + 真 worktree：两者归到**同一个**键；子目录归到仓库根；尾部斜杠不影响；无 git 时以传入目录为根（不报错）。**P71 兼验归类键**（`pm_main_worktree_into`）：worktree → 主工作区、主工作区/仓库子目录/无 git 三种情形**原样**（反向断言钉住「只折 linked worktree」）—— 判据与项目键同源，差别只在「子目录折不折」 |
| `pm-roundtrip` | 写 → 读逐字节等价（含引号 / 反斜杠 / 换行）；同 `(kind,key)` 归并且 `n` 累加；两次读出渲染逐字节相同 |
| `pm-concurrent` | 两种交错顺序的归并结果**逐字节相同**；两个分片都在且非空；半行尾部被丢掉、其余不变 |
| `pm-ingest` | read → layout（带 stat 锚点）；成功的 bash → commands；`make …` 失败 → state 带错误摘要；**没有退出码的结果什么都不记**；失败的非验证命令不进 commands。**P77 加四条闸门**（每条都能单独变红）：**多行命令不记**（`for x in a b; do\necho $x\ndone` 折成一行后重跑不等价）；**触到 512 上限的不记**（尾巴被砍掉）；**恒真的 `cd <本会话 ws> && ` 前缀被剥掉**（key 恰好是 `ls -la`）；**commands 的 key 里不再出现 `cd ` 前缀** |
| `pm-digest` | 一致时无 STALE；**改文件后标 STALE**、删文件后标 GONE；正文（文件内容）永不出现；紧预算不超且 commands 仍在；预算过小不注入；自动抽取的惯例标 `[proposed]`、不出现 `[confirmed]`。**P77 加三条份额断言**（都可单独变红）：灌 8 条长命令 + 紧预算 1200 B 时，**commands 不许饿死 layout / state / conventions**（取消份额封顶 ⇒ 三条当场红） |
| `pm-e2e` | **两个真会话**：会话 1 摄取后，会话 2 的历史里恰好一条 `pm-memory`，含会话 1 的路径与命令 + 索引提示语；重复注入被拒；`--no-memory` 时四条腿（身份 / 注入 / 历史 / 摄取）全不动作；`forget` 后目录消失 |
| `e2e-memory-live` | **跑真二进制**（`testdata/mock_gateway_memory.py` 假网关）：① 摄取真的落盘，且 layout 那条**带真 stat 锚点**（锚点全 0 = 压根没 stat 成功）；② 跨会话真的注入（只看 `<pm-memory>…</pm-memory>` 那一小段）；③ 改文件 → 那条标 `STALE` 且**仍注入**；④ 删文件 → 标 `GONE`；⑤ `--no-memory` **不建记忆目录** |

#### 为什么必须单独有一轮「真机接线」

这一轮是**事后补的**，起因是一个被现象带偏的诊断：用户报「记忆一直不失效」，查下来
**盘上从来没有分片** —— 摄取整条死在接线层，两处独立缺陷叠加（见 §16 踩坑 129）：

* `agent_pm_set_sid` 排在 `agent_pm_begin` **之前** ⇒ 那时 `g_pm.ready` 还是 false、
  `g_pm.dir.len` 还是 0 ⇒ 绑定被拒 ⇒ `g_pm_ing.enabled` **恒为 false** ⇒
  `agent_pm_note_tool` 在守卫处直接 `return`（静默，符合「记忆是旁路」的设计，于是无声）；
* 两处调用点传的是 `&res.ptr` / `&res.len`（**字段的地址**）而不是 `res.ptr` / `res.len`
  （值）⇒ 被调方拿到野指针 + 天文数字长度（实测 `result_len` ≈ 1.4e14）⇒ `find_sub`
  读越界 ⇒ **整个 agent 段错误**。这一条只在「绑定修好、摄取真的跑起来」之后才暴露。

**当时 `make selftest` 151 轮 + `pm-selftest` 6 轮全绿。** 原因是这一族自测全部**直接调**
`pm_ingest_tool(&ing, …)` / `agent_pm_note_tool(…, rres.ptr, rres.len)` 并手写正确的参数 ——
它们证明的是「摄取函数**本身**对」，而**唯一会跑的那条接线**恰好是唯一没被覆盖的。
结论写成本仓的一条纪律：**纯函数自测只能证明函数对，证明不了接线对**；凡是「A 模块调 B 模块」
的接缝，判据必须落在**真二进制 + 真产物**上（与 §19 里「跑真二进制」那一族的理由同源）。

三条**防假绿对照实验**（每条都当场红，已实测）：① 把绑定挪回 `begin` 之前 ⇒ 第①条红
（0 个分片）；② 把传值改回传地址 ⇒ 第①条红（退出码 **139** 段错误）；③ 关掉 `pm_verify`
的锚点比对 ⇒ 第③条红。另外这条目标故意按 `'STALE <路径>'` 判而不是按裸 `STALE` ——
开工包**头一句提示语里本来就有 `STALE`/`GONE` 两个词**，按裸词判会恒真（第一版就踩了）。

自测各轮抓到的真 bug（都是「绿着但其实是错的」那一类，值得记一笔）：
1. 分片漏 `.jsonl` 扩展名 → **写进去读不出来**；
2. `pm_fact_decode` 把 `defer` 里的局部 Buf 指给目标（释放了目标正在用的内存）→ 读取卡死；
3. 归并的 value 取「谁后读到用谁」→ 结果依赖目录顺序，开工包不可复现；
4. `pm_verify` 拿**相对路径**去 stat（事实的 key 是 read 信封里的相对路径）→ 所有文件都判
   「不存在」全标 GONE；**更糟的是 GONE 那条断言也满足，失效轮会假装通过** —— 所以
   `pm_verify` 现在必须收 workspace；
5. 惯例分区标题写死 "user-confirmed"，而抽出来的只是候选 → 标题变谎话。

---

## 21. 插件系统（P70，`src/plugin/`）

这一节回答：**「插件」在本仓是什么、为什么是 MCP、哪些模拟得了哪些模拟不了、
失败与权限怎么收口**。

### 21.1 结论先行：DSH 的进程外插件路径**就是 MCP**

装好 DSH（v0.1.1-rc.2，`~/.npm-global/lib/node_modules/@deepseek-ai/dsh`）读一遍就清楚：

| 事实 | 出处（可复核） |
|---|---|
| DSH 的插件 = **cordis/npm 包**（`@deepseek-ai/dsh-*`），`type: module`，**进程内** TS 模块 | `dsh-base/package.json`、`dsh-tool-todo/lib/index.js` |
| 插件靠 `cordis.yml` 的**行**装配，`config:` 是它的参数 | `~/.dsh/.agent-presets/git-worktree/agent.cordis.yml` |
| 插件往**命名缝**注入：`tools/pre-execute`、`tools/post-execute`、`system-prompt/assemble`、`agent/pre-step`… | `dsh-tools/lib/index.js:3105`、`dsh-system-prompt/lib/index.js:283`、`dsh-agent-loop/lib/index.js:501` |
| `tools/pre-execute` 的返回值就是决策对象：`{kind:"allow"}` / `{kind:"ask"}` / `{kind:"deny",reason}` | `dsh-tools/lib/index.js:3105-3117` |
| `tools/post-execute`：`{kind:"accept",content?}` / `{kind:"block",feedback}` | `dsh-tools/lib/index.js:3366-3394` |
| **DSH 自己的「进程外插件」路径 = MCP**：`@deepseek-ai/dsh-mcp-client`，`transport: stdio \| streamable-http` | `dsh-mcp-client/package.json`、`lib/index.js:738` |
| MCP 工具公开名 = `mcp__<serverName>__<rawName>`；`serverName` 必须 `^[A-Za-z0-9_-]{1,32}$` | `dsh-mcp-client/lib/index.js:119-125, 724, 740` |
| MCP 配置字段逐字：`transport`/`serverName`/`command`/`args`/`env`/`cwd`/`toolCallTimeoutMs`（默认 **60000**） | `dsh-mcp-client/lib/index.js:738-747, 722` |
| stdio 帧 = **一行一条 JSON**（`\n` 分隔，容忍 `\r`）；SDK 1.30.0、协议版本 `2025-11-25` | `@modelcontextprotocol/sdk/dist/esm/shared/stdio.js` |

**所以本仓不造协议，直接实现 MCP stdio 客户端** —— 装好的 MCP server
（`filesystem`、`github`、`sqlite`…）与本仓、与 DSH 共用同一批。命名也逐字对齐
（§21.3），同一个 server 在 DSH 与本仓**叫同一个名字**。

### 21.2 能模拟什么、模拟不了什么（**如实记，别假装**）

「DSH 插件能做的事」拆开是「注册一个工具」与「在某个缝上做决策」两类，MCP 对第一类
一一对应，对第二类能单点决策、**做不出链**：

| DSH 进程内插件做的事 | MCP 能否模拟 | 本仓怎么做 |
|---|---|---|
| `ctx.tools.register(defineTool({name,description,parameters,execute}))`（19 个包这么做） | **完全能** | `tools/list` + `tools/call` |
| `tools/pre-execute` → allow / deny | **能**（单点） | 同名自定义方法（§21.4） |
| `tools/post-execute` → accept / block | **能**（单点） | 同上 |
| `system-prompt/assemble` | **能**，但只能**整体替换** | 同上 |
| `session/created` / `session/disposed` | **能**（通知） | 同上 |
| `static inject = ["subprocess"]` 这类**宿主服务注入** | **不能** | 插件要的是**进程内可调用对象**，跨进程给不了 |
| `sessionProjections.register({apply})`（改宿主状态机） | **不能** | 要求同进程状态同步 |
| `ctx.waterfall` 的**链式 next()** | **不能** | 只能单点否决/替换；多个 server 之间没有链 |
| `dsh-cordis-host-runner`、`dsh-client-ui-*` | **不能** | 前者在宿主里跑 cordis 插件、后者是 Web UI 组件，都与本仓无关 |

⇒ `--list-plugins` 扫到 `@deepseek-ai/dsh-*` 的**进程内**插件行时，如实报
`unsupported (in-process cordis plugins cannot run OOP)` 并说明原因 ——
**不让用户以为「配了就会生效」**。

### 21.3 公开名：逐字复用 DSH 的规则

`mcp_tool_public_name`（`src/plugin/mcp.uya`）与 DSH 的 `publicToolName` 逐条对齐：

1. 常态就是 `mcp__<serverName>__<rawName>`；
2. `[^A-Za-z0-9_-]` 的字符换成 `_`（模型的函数名契约只允许这个字符集）；
3. **发生过替换或长度 > 64** ⇒ 截到 `64-12-1 = 51` 个字符，再拼 `_` + sha256
   （输入 `<serverName>\0<rawName>`）**前 12 位 hex**；
4. **raw 名只在线上发**（`tools/call` 的 `params.name`），绝不从公开名反推 —— 那是有损的。

`serverName` 必须 `^[A-Za-z0-9_-]{1,32}$`，不合法整条丢掉（不猜、不改名）。

⚠ 第 3 步有个**必须用 `min(原名长, 51)`** 的细节：短名字（如 `mcp__fs__read_file` 只有
18 字节）硬取 51 会读过缓冲尾部、把堆上的垃圾字节当名字的一部分（现场症状：公开名里
混进一串 NUL，模型侧名字与派发查表两边都对不上）。DSH 那边是 JS 的
`String.slice(0, 51)`（短串原样），这里对齐的就是那个语义。

### 21.4 钩子：用 DSH 的缝名，但走本仓的扩展方法

DSH 的缝是**进程内**的，而 MCP 规范里**没有**钩子能力（只有 tools/resources/prompts/
sampling/notifications）。所以本仓把钩子做成**自定义 MCP 方法，名字沿用 DSH 的缝名**：
`tools/pre-execute`、`tools/post-execute`、`system-prompt/assemble`、`session/created`。

* server **不认**这个方法 ⇒ 回 `-32601 Method not found` ⇒ 本仓**当作没这个钩子、放行**。
  于是**任何标准 MCP server 都能只当纯工具插件用**（这是绝大多数情况）；
* 认得的 server 才跑钩子。**钩子出错（超时/崩/坏 JSON）一律当放行** ——
  钩子是增强，不能变成故障点；
* 这一条是本仓扩展，DSH 原生不通过 MCP 暴露钩子。将来 DSH 若把钩子也搬到 MCP，
  方法名已经对齐（这是刻意留的升级缝）。

### 21.5 配置来源与优先级

高 → 低（**靠前的先胜**，同名不覆盖）：

| 优先级 | 来源 | 形状 |
|---|---|---|
| 1 | `--mcp-server SPEC` | `name=command [args…] [K=V…]`（`K=V` 判据：`=` 前是合法环境变量名，所以 `--opt=value` 照旧进 args） |
| 2 | `$DSH_HOME/settings.yaml` 的 `uya-agent.mcp.<name>` | 字段与 DSH 逐字相同 |
| 3 | `<projectRoot>/.dsh/mcp.json` + `~/.agents/mcp.json` | 生态通用 `mcpServers` 形状 |
| 4 | `cordis.yml` 的 `@deepseek-ai/dsh-mcp-client` 行 | `config` 原样映射 |

任何一个来源读不到/解析失败都**不是致命错误**（离线要能跑，与 dshcfg 同一条口径）。

### 21.6 权限：MCP server 是第三方进程

| 模式 | MCP 工具 | 钩子 |
|---|---|---|
| `read-only` | **拒绝**（回错误文本指路 `/permission workspace-write`） | **一律不跑** |
| `workspace-write` | `ask_approve_action` 逐次批准 + `san_build_exec` 同档 bwrap | 跑 |
| `danger-full-access` | 放行 | 跑 |

read-only 下钩子**一律不跑**的理由：钩子能改工具参数、能改工具结果 ——
它**就是权限模型的一部分**，read-only 的语义是「不许它动」，不能留一条改参数的旁路。

三条硬口径：

1. **`command` 不做 PATH 查找**（`execve` 只吃路径）。PATH 查找会让「装了哪个插件」
   变成环境变量的函数；示例与文档里一律写绝对路径。
2. 子进程**只继承安全白名单**（`HOME LOGNAME PATH SHELL TERM USER`）+ 配置里显式给的
   `K=V` —— 它是第三方进程，不该看到宿主自己的 `DSH_*` 与凭据类变量。
3. 子进程必须 `sigx_reset_for_child`（信号处置是继承的，否则它收到 TERM 会写父终端）。

### 21.7 与 bash 工具的两处**关键差异**（容易写错）

1. **stdin/stdout 就是协议通道** ⇒ **不能**像 `bash`/`rg` 那样调
   `sh_child_detach_stdio()`（它把 stdin 接到 `/dev/null`）。这里 stdin/stdout 接管成
   管道，**stderr 单独一根管**（转诊断，绝不混进 JSON 流 —— 一个 warning 就能让协议错位）。
2. **一个 server 一个常驻子进程**（MCP 的标准形态，也是 DSH 的做法），
   所以省掉每次 fork 的冷启动；代价是要管子进程生命周期 —— 换工作区、
   `mcp` 元工具 reload、进程退出三处都要收干净（`main` 的 defer 里 `mcp_stop_all`，
   所有早退路径都经过它）。

### 21.8 失败语义：不阻断主流程

| 情况 | 表现 |
|---|---|
| server 起不来 / 崩 / 超时 / 回非法 JSON | 一句**工具结果文本** `Error: …`（模型自己纠正 —— 与 bash 工具同口径） |
| server 一个工具都没报 | 诊断里一行 `name: no tools (<原因>)` |
| 不认的钩子（`-32601`） | **放行**（标准 MCP server 的常态，不是错误） |
| 一个 server 都没配 | 工具表**逐字节不变**（自测 + 对照实验钉这条） |

### 21.9 自测（`make mcp-selftest` / `UYA_SELFTEST_MCP_ONLY=1`）

四条腿，判据全是**事实**（server 自己把收到的请求落盘成 marker，断言读那个文件）：

| 腿 | 判据 |
|---|---|
| `mcp-name` | 公开名规则：干净名原样、非法字符换 `_` 且带 12 位 hex 后缀、超长截断、`serverName` 正则 |
| `mcp-handshake` | server 收到的 `initialize` 原文含 `clientInfo.name=uya-agent`；`notifications/initialized` 在 `tools/list` **之前**；两个工具（一个干净名、一个带点）都登记成归一化名；`inputSchema` 真的透传 |
| `mcp-call` | server 收到的是 **raw 名**（不是公开名）；结果文本逐字节等于 server 回文；`arguments` 原样到达（没被双重转义） |
| `mcp-degrade` | 不配 / 起不来 / 崩掉都是 0 工具 + 有诊断；`-32601` 放行；read-only 不跑钩子且工具被拒；**收口后活着的子进程 = 0**（不留孤儿） |

夹具是**现场写盘的纯 sh server**（`/bin/sh` + `sed`，不依赖 python/node），
落在 `/tmp/selftest_mcp_<pid>` —— **绝对路径**（前面几轮 selftest 会真 chdir，
相对路径会在别处建目录；见 §16 踩坑 107），收尾清掉。

**三条防假绿对照实验**（都先看到红，再改回来）：

| 实验 | 改动 | 结果 |
|---|---|---|
| ① | 线上发**公开名**而不是 raw 名 | `mcp-call` 红 2 条（正是「server 没收到 raw 名」与「上线出现了公开名」） |
| ② | 去掉公开名的「截断 + hash」那一步 | `mcp-name` 红（「超长名字没有截到 64」） |
| ③ | 无条件注入 `mcp` 元工具（没配插件也注入） | 无插件时的工具表从 19540 B 变 **19996 B**，第一处差异正好落在 `"mcp"` 那条 |

实验③用的是**逐字节对照**（本轮改动的核心不变量：没装插件 = 零影响），
所以它比「看起来还在」类断言强一档 —— 这一条与 §16 踩坑 83 的教训同族。

### 21.10 示例与 `.ush` 的三个坑

`examples/mcp-plugins/` 下是**同一件事的三种语言实现**：`wordcount.ush`（Uya）、
`greet.py`（Python）、`echo.sh`（POSIX shell）。写 `.ush` 插件时踩到三条（都已记在文件头）：

1. **`uya run` 的脚本环境只有 `libc` + `std.json`** —— 本仓的 `Buf` / `bufx_*` / `jw_*`
   都用不了（那些要参与编译整个仓库才有符号）。所以示例里全是手写的字节处理。
2. 整数转字节的 `as!` **必须带 `catch`**（`错误联合类型 !T 不能隐式用于普通类型上下文`）。
3. `&"literal"[0: n]` 传给 `*const byte` 形参 ⇒ codegen 生成「切片描述符强转成字节指针」，
   输出直接乱码（`Makefile` 的 `codegen-audit` 扫的就是这个形状）。
   收 `&[byte]` 形参就没这个问题 —— 示例的 `put` 就是这么写的。

另外：`uya` 要用**绝对路径**（`command` 不做 PATH 查找，PATH 里的 `uya` 可能是别的版本 ——
实测过一次「工具数是 0」，根因就是 PATH 里那个旧的 `uya` 不接受 `UYA_ROOT`）。

实现这一条时还顺带修了编译器两处**固定容量表**（详见 §16 与那两个提交）：
call edge 表（`MAX_FN_CALL_EDGES`）与顶层变量类型查找的降级路径 ——
不加插件文件时碰不到，加了就编不过，而报错点落在**与改动毫无关系**的文件里。
### 19.6 P83：剪贴板改成三源（无 X11 / SSH 也能贴）

**为什么做**：原来的剪贴板只有 X11 一条路，于是「粘一张截图给多模态模型」在
**Wayland 会话**、**没有图形界面的机器**、以及**SSH 到远端**时全都失败 —— 最后一种最要命，
因为它失败得很像「剪贴板里没东西」。同时 `DESIGN §13.2` 与失败文案早就**承诺**了一条
并不存在的「外部 helper 回落」。

**做了什么**：三条来源按优先级（`media/clip.uya` 仲裁）—— ① **终端协议**（`media/clipt.uya`
的 OSC 5522 客户端，`term/oscin.uya` 负责从 fd 0 摘回帧）② X11（`media/clipx.uya`，
**语义一字未动**，只是从「唯一」变成「之二」）③ 外部 helper（`media/cliphelp.uya`）。
**终端协议排第一的关键理由**：它把请求发给**终端模拟器**、由它读**本地**剪贴板 ——
是唯一能穿过 SSH 的通道；X11 与 helper 读的都是**远端**那台机器，SSH 下必须让终端先答。
回执会**指名来源**，SSH 下标出「远端」。

**验收**（`make selftest` 全绿；新增三轮见 §19 的表）：

| # | 判据 | 怎么验 |
|---|---|---|
| ① | **无 X11 也能贴到图** | `clip-pty`：子进程环境里 `DISPLAY`/`WAYLAND_DISPLAY` 清空、来源钉成 `term`；父进程扮演终端回 `OK`+`DATA(image/png)`+`DONE` ⇒ 断言图片被收下 |
| ② | **应答字节不进输入行** | 同一轮：断言屏幕上（捕获的帧字节里）**没有** `type=read:status=DATA` |
| ③ | 线格式逐字节对 | `clip-term`：读请求与探针都按规范字节比对（探针**只留一份实现**，见踩坑 136） |
| ④ | 分片与透传 | `clip-term`：1/2/3/5 字节一片都还原；非 5522 字节（含 `ESC[31m`）**逐字节**原样 |
| ⑤ | 逐块 base64 | `clip-term` 走 `clipt_take_data_debug`（**同一份生产实现**）拼接后逐字节等于原图（踩坑 139） |
| ⑥ | 优先级不被覆盖 | 同一轮：**低优先级的文本块不许覆盖已收好的图片**（踩坑 140；这条自测先红） |
| ⑦ | helper 超时不挂住 | `clip-helper`：`sleep 300` 的假 helper 必须**按进程组**收掉且耗时 < 12 s（实测 24.1 s 的版本当场红） |
| ⑧ | 假 helper 探测 | 前置进 PATH 的脚本被认出来、取数按类型表优先级走 |
| ⑨ | **id 比对用长度已知的字节段** | `clip-term` 直接钉 `clipt_frame_status`（同一 id ⇒ 1、别的 id ⇒ 0、DATA/DONE/EPERM ⇒ 2/3/4）；踩坑 142 —— 纯函数与假终端都**碰不到**这条比较 |

**防假绿对照**（每次都先看到红再改回）：

| # | 改坏什么 | 结果 |
|---|---|---|
| A | 探针的 `$`（36）换成 `p` —— 即踩坑 136 的原始 bug | `clip-term` **红**（探针字节不对）+ `clip-pty` **红**（没有探测） |
| B | `clipt_take_data` 改成「拼接后再解码」 | 三轮**全红**（`clip-term` 的逐块断言、`clip-pty` 的收图、以及优先级那条） |
| C | 去掉 `oscin_borrowed` 的早退（让 tick 抢 fd 0） | `clip-pty` **红**（应答被键路吃掉 ⇒ 图收不下）—— **前提是夹具撑过分片边界**，见踩坑 137 |
| D | 扫描器对每个 `ESC` 都开捕获 | `tty-editor` 轮 **16 条断言全红**（裸 ESC 被攥住）—— 这是本轮最贵的回归，见踩坑 135 |
| E | 去掉挂起段的续解 | `clip-pty` **红**（数据收不回来，靠 10 s 超时兜底） |
| F | id 比对改回 `bufx_eq_cstr(..., id)`（踩坑 142 的原始 bug） | `clip-term` **打印 4 条 FAIL**（同一 id 认不出、DATA/DONE/EPERM 全错位）；**`clip-pty` 不红** —— 夹具的 id 恰好也是 `u1`，所以这条必须有直接断言。**⚠ 当时只是「打印」**：那 4 条走的判红通道是坏的（见下方「交付后修复」与 §16 踩坑 145），轮次照样 PASS、退出码 0 —— 修复后重放这条 ⇒ **4 条 FAIL + `SELFTEST CLIP FAIL` / rc=3**，它现在才算一条真对照 |

**未实测的部分**（如实记账）：本机是 **X11 + deepin-terminal**，没有 kitty / ghostty，也没有
`wl-paste` —— 所以 ① 真终端上 kitty 弹授权框、点一下、图贴上这一步，② 真实 Wayland 会话上的
`wl-paste` 这一腿，**都没有在真机上跑过**。协议形状是对着 kitty 的官方规范、`kitty/clipboard.py`
与 ghostty 的 `terminal/osc.zig` 三处核实的；验收靠**假终端 PTY 轮**。tmux/screen 是否透传
5522 取决于它们，我们不实现 DCS 包装（不支持就靠探测失败回落）。

**没顺手做的**：OSC 52 的读取（只带文本、多数终端出于安全默认关闭）、5522 的 paste-event
模式（`DECSET 5522`，会引入**非用户主动**的授权弹窗，与「按一下才读一次」冲突）——
两条都记在 §15.5。

**交付后修复（P83 交付后一轮，两个缺陷都在 `src/selftest/st_clip.uya` 与三轮的判红通道上，
产品代码一行没动）**：起点是「整轮 selftest 只剩一个失败：`clip-helper`」。

| # | 缺陷 | 症状（当时看到的） | 修法 | 为什么它活过了交付验收 |
|---|---|---|---|---|
| ① | 假 helper 的夹具目录**从来没人建** | 干净树上 `clip-helper` 报「**写假 wl-paste 失败**」（假 helper 脚本没落盘） | 夹具第一步 `sess_mkdir_p(dir)`，失败文案改成「建不出夹具目录（假 helper 没地方落盘）」 | 交付那几轮**跑过一次就有目录**（`build/` 不在版本控制里），只有清缓存重编 / 新 clone 才暴露 —— 见踩坑 144 |
| ② | `clips_term_ids` 里五处 `clips_fail(…, &ok)`（`ok` 已是 `&bool`） | 无（屏幕上看不出）—— 但这一组的断言**只打印 FAIL、不判红** | 删掉多余的 `&`（五处） | **编译器在警告**（`-Wincompatible-pointer-types`，五条），而本仓不把警告当错误，它被构建刷屏淹掉了 —— 见踩坑 145 |

**两个缺陷的对照实验（都先看到红、再改回）**：

| 实验 | 改坏什么 | 修前 | 修后 |
|---|---|---|---|
| ① | `rm -rf build/selftest_clip_helper`（= 干净树） | `clip-helper` 红：「写假 wl-paste 失败」 | 绿（夹具自己建目录） |
| ② | id 比对改回 `bufx_eq_cstr`（重放对照 F） | 打印 4 条 FAIL，**而 `SELFTEST CLIP PASS` / rc=0** | 4 条 FAIL + **`SELFTEST CLIP FAIL` / rc=3** |

实验②是**这一轮真正的教训**：§19.6 交付时那条对照 F **是假绿** —— 屏幕上 4 条 FAIL 都在，
于是「红 4 条」被照抄进了本文档，但轮次的判红通道早已被 ② 弄坏，退出码一直是 0。
**判据的判据**（「这一轮会不会真的红」）当时没有任何东西守着。

**验收**（修完实测）：`rm -rf build/selftest_clip_helper && make selftest` 全绿
（`SELFTEST PASS`，三轮剪贴板都在内）；`make lint-size` / `doc-cover` / `doc-audit` 绿；
`make build` 里 `st_clip` 的编译警告从 5 条降到 **0**（**改前改后都数过**——
这是 ② 唯一的机器信号，别只看「构建成功」）。


### 19.7 P84：图片能力位「默认支持」+ 两个显式出口

**为什么做**：用户问的是「怎么通过环境变量给模型加图片支持」—— 查下来发现**没有这条路**，
而且现场比「缺一个 flag」更坏（见 §16 踩坑 143 的两个症状）：能力位只会被写成 `true`、
从不清零，且 env 给的模型**从不查目录**。于是本轮把口径与出口一起补齐。

**口径**：**默认支持**（出厂 `true`）。三个明确的关法，两个可证出口。

| 档 | 来源 | 写法 | source |
|---|---|---|---|
| ① | 命令行 | `--no-input-image` / `--input-image` | `cli` |
| ② | 环境变量 | `UYA_AGENT_INPUT_IMAGE=0\|1` | `env` |
| ③ | 模型目录条目 | `input:` **存在**但不含 `image` | `dsh-settings` |
| ④ | 都没有 | —— | `default`（**支持**） |

**四条不变量**（都可测，判据见下）：

| # | 不变量 | 为什么它是承重的 |
|---|---|---|
| ① | **三态**：`UNSET`（没写 `input:`）/ `YES` / `NO` 分得开 | 「没声明」与「声明不支持」压成一个 bool 时，「清零」与「没信息」都无处安放 —— 这正是踩坑 143 的根因 |
| ② | **一个定稿点**：`agent_vision_settle`（启动收尾 / 切模型 / 恢复会话各一次） | 能力位散布在 `agent_apply_dsh` 与 `adopt_caps` 两处时，切模型那条路漏了一次就是「照收图 ⇒ 400」 |
| ③ | **显式优先**：env / cli 给过的钉子，切模型也不动 | 网关不认图时 `=0` 要能把目录里乐观的 `true` 压回去；否则人唯一的出口被目录悄悄改掉 |
| ④ | **信息不足一律当支持**，但**不许静默** | fail-closed 会让纯 env 部署（autodl 那类）永远挂不上图 —— 而那正是本轮要解决的场景；沿用可以，但 `/model` 与切换回执必须说出来 |

**与上下文窗口的关系**：形状刻意同构（四档来源 + 单一 `*_settle` + 两个出口 + 显式钉住），
但**默认值相反** —— 窗口「一次都没人给过」是 `-1`（未知、压缩不触发），能力位「没声明」是
**开**。这不是不一致：窗口猜错的代价是**静默行为变化**（该压不压），能力位猜错的代价是
**一句明确的 400**，两者的保守方向本来就该相反。

**验收**（都是实测）：

| 判据 | 结果 |
|---|---|
| 新增自测轮 `vision`（§19 上表：12 条腿，含**走真入口** `agent_model_apply` 的两条） | 绿 |
| 新增 `make e2e-inputimage`（6 条腿，真二进制 + 真 settings.yaml + 真 45 B PNG，`env -i` 起） | 绿 |
| `web-childcfg` 扩到 15 条（收图位显式关掉时要传进子进程；出厂值**不许**注入） | 绿 |
| `make lint-size` / `make doc-cover` / `make doc-audit` / `make check` / `make build` | 全通过 |

**防假绿对照（五条，都先看到红再改回）**：

| # | 改坏什么 | 结果 |
|---|---|---|
| A | 去掉 `agent_model_apply` 里那次 `agent_vision_settle` | `vision` 轮**红 2 条**（切到不支持没关、切回支持没开）—— ⚠ 这一条**最初是绿的**：腿只调 settle 函数、不碰调用点。补了「走真入口」那两条腿才抓住，见踩坑 143 的判据教训 |
| B | 去掉 `agent_vision_settle` 的显式守卫 | **红 2 条**（env 钉子被目录覆盖、cli 钉子被目录覆盖） |
| C | 出厂值改回 `false` | `vision` 轮**红 2 条**（默认不再是「支持」、`--no-dsh-config` 那条也跟着红）+ `e2e-inputimage` **红**（纯 env 路线挂不上图）—— 这条直接钉「默认支持」 |
| D | 去掉 `--print-config` 的 `(source: …)` | `e2e-inputimage` **红**（四档 source 全部对不上） |
| E | 去掉 web 子进程的收图位注入 | `web-childcfg` **红 1 条**（终端关了、浏览器里还开着） |

**没顺手做的**：`uya-agent.inputImages` 设置映射（DSH 的 `input:` 已经是那条路的原生写法，
再加一份就是第二个真值源）；能力清单语法（今天只有 image 一种能力，`--context-window` 也没
发明语法）；把 `input_image` 写进会话日志（会话记录里的模型已经足够重建 —— 能力位按当前目录
重新定稿，这才是「切完看得见」的那一半）。

### 19.8 P85：TUI 拖选复制（不按 shift）

**用户报的**：在 uya-agent 的 TUI 里拖鼠标选不了文本，得**按住 shift** 才行
（shift 是终端自己接管拖选的手势）。

**根因（两条，各自独立）**：① 键层只看滚轮 —— `tui_mouse_finish` 把 `b >= 64` 折成
滚轮上/下，其余（按下/拖动/抬起）**一律丢弃**，于是拖选期间屏幕上什么都不动
（踩坑 72 的现场）；② **没有任何现成的复制通道可借** —— 真机逐条排掉：那台终端
（deepin-terminal 6.5.21 / QTermWidget）对 `ESC[?5522$p`（DECRQM）**零应答**
（同机 `ESC[6n` 回 `ESC[1;1R`，证明探针有效）、OSC 52 写 `c`/`p` 两块板子
**一个字节都不变**（BEL / ST / C1-ST 三种终结符都试过）。

**修法**（三个新件 + 三处接线）：

| 件 | 职责 | 关键点 |
|---|---|---|
| `term/tui/keys.uya` | 左键三态 → `TUI_K_MOUSE_{PRESS,DRAG,RELEASE}` | **坐标与事件配对入队**（真机一次 write 送来三个事件）；带修饰的左键滤掉（shift 交回终端）；滚轮口径一字节未动 |
| `term/tui/sel.uya`（新） | 选区状态机 + 文本提取 + 高亮绘制 | 屏幕坐标（滚动时不动）；宽字符两头**向外取整**；行尾空白裁掉；夹在转录区内 |
| `media/clipw.uya`（新） | X11 选区所有者（写方向） | `SetSelectionOwner` + 应答 `SelectionRequest`/`TARGETS`；持有硬上限 1.5 s、期间泵界面、esc 可取消 |

接线：`style.uya` 的 `tui_row_mark_span` 改挂段样式做高亮（**正文层零改动**）、
`TUI_ST_SEL` 在无色模式下补 `ESC[7m`；`screen.uya` 在成帧收尾调 `tui_sel_paint`；
`ag_plan_pump.uya` 在**空闲主循环**与**泵点**两处消费 `TUI_REQ_COPY`（与 ctrl+t 同一
分工），回执报**字符数**（不是字节）并在 SSH 下标出「远端」。

**验收**：新轮 `tui-select`（键解码 + 选区 + 宽字符 + 裁剪 + 高亮 + 请求两条路）与
`clip-copy`（写方向请求体逐字节 + 结果码 + 无 X11）全过；`tui-mouse` 补了「拖动被识别」
与「滚轮不受影响」两条腿后仍过。**真机端到端**（本次交付的硬证据）：在真 PTY 里跑起 TUI、
`xdotool` 驱动拖过一行 → 剪贴板里是**逐字节相同**的原文
（`UNIQUE-MARKER-XYZ-123`，`EXACT: True`），且**进程退出后仍在**（桌面剪贴板管理器接管，
与之前手工量的 0.6 s hold 一致）。

**没顺手做的**：OSC 52 的**写**（这台终端不认，协议形状也没法验）、OSC 5522 的
`type=write`（同一台终端零应答；且分块 base64 规则与读方向**相反** —— 拼接后才要求 4 的
倍数，照抄 `clipt_take_data` 是错的）、写方向的 helper（本机 `wl-copy`/`xclip` 一个都没装，
且它们会 daemonize 持有选区，超时按进程组收有连带杀掉持有者的风险）、行内双击选词 /
三击选行 / 拖到边缘自动滚动（第一版不叠手感参数）。

### 19.9 P87：目标属于会话（修「goal 不是回话级别的」）

**用户报的**：goal 应该是**属于会话**的，不同会话不共享。

**复现（修前，真二进制，两条独立会话共用同一个 `UYA_AGENT_HOME`）**：

```
$ printf '/goal 会话甲的目标\n/exit\n' | … uya-agent    # 会话甲
Goal created … Objective: 会话甲的目标 …

$ printf '/goal\n/exit\n'            | … uya-agent    # 会话乙（另一个进程、全新会话）
Status: active
Objective: 会话甲的目标                                 # ← 乙看到的是甲的目标
Activation: armed                                      # ← 甲的目标还会被乙续跑

$ printf '/goal 第二条会话想干自己的活\n/exit\n' | … uya-agent
A goal is already active. Use /goal edit …             # ← 乙连自己的目标都建不了
```

**根因**：`goal_path` 用 `agent_default_home(cfg)` 拼 `<agent_home>/goal.json` ——
落点表达的是「agent 装在哪」，与会话身份（`<home>/sessions/--<cwd>--/<id>/`）无关，
所以「会话目标」实际是 **home 级单例**。web 最重：8 条会话子进程共用同一个 home。

**修法**：`goal.json` 挪进**会话目录**（与 `session.jsonl` 同目录）；`goal_session_dir`
三条判据（尾名整段 / 在本次 `cfg` 的 home 底下 / 紧跟 `/sessions/`）全中才用会话目录，
否则退回旧的 home 根路径（`--print-config` 那条路仍可用）。落盘前补一次 mkdir
（`--no-save` 的会话不建目录）。换会话（`/new`、`/resume`）后那份内存投影跟着重读，
且必须在 `tasks_panel_sync` 之前。历史遗留的 home 根那份**不迁移、不删、不再读**。

**对照实验（先看到红）**：把 `goal_path` 的会话目录分支短路回修前行为
（`if false && goal_session_dir(…)`）重编 → `goal-sess` 轮**9 条断言当场红**，
包括「会话乙看到了会话甲的目标（不同会话不该共享 goal）」「会话乙应当能建自己的目标
（要 0，实得 1）」；改回即绿。这条对照是必须的：**旧的 `tui-switch` D 段钉的恰好是
相反的语义**（「目标跨会话、不该被清」），只改实现不改断言的话两边一起绿。

**验收**：`make check` / `make build`（静态链接审计通过）全绿；
`--selftest` **SELFTEST PASS**（184 轮 ok、0 条 FAIL，含新轮 `goal-sess`）；
`make e2e-goal` 通过；`tui-switch` 轮 D 段改成「/new 与 /resume 之后投影与屏幕都不再挂着
上一条会话的目标」+ 一条**防假绿**断言（重装夹具后目标段照旧画得出来 —— 证明「消失」是
因为换了会话，不是因为面板整个坏了）；`lint-size` / `doc-audit` / `doc-cover` 通过。

**明确不做**：目标跨会话继承、迁移历史 `goal.json`、给 goal 加「全局目标」这种第二形态
（DSH 的 goal 也是 per-session）。

### 19.10 P88：上下文超窗的**死锁**（真机会话再也发不出请求）

**用户报的**：会话跑着跑着开始报 500，然后每一轮都是

```
· [compact] 摘要请求失败，跳过本次压缩
· [retry] http-status HTTP 500 attempt=1 backoff=1.8s
· 重试中（http-status，第 1 次）
· model endpoint returned HTTP 400
· body: {"error":{"message":"[invalid_params]: {\"error\":{\"message\":\"Input exceeds
  the context limit (1048568 tokens). Please shorten the input. Request id: …
· [turn] 本回合异常结束（可直接输入继续）
```

敲「继续」、敲「exit」、敲「说明状态」——**三次都是同一个 400**。会话进了不可恢复状态。

**现场（真会话日志 `session-43e46f8b-…`，15080 个事件）**：

| 观测 | 值 | 说明 |
|---|---|---|
| 历史规模 | 4883 条消息、4.39 MB（折叠后） | 408 步、2532 次工具调用 |
| 最后一次请求的 prompt | **658 998 token** | 相邻步稳定增长（每步 +200 上下） |
| 网关报的上限 | 1 048 568 token | 「只差一点点」，不是配置量级错了 |
| 压缩次数 | 2 次（seq 6831 / 9776） | 两次都**成功**过；此后 800 步一次都没有 |
| 超窗之后 | `turn/end reason=error` ×4 | 其中一条 turn 号回到 1 ⇒ 是 **`--resume` 之后**发作的 |

**根因（三件事叠在一起，缺一件都不会死锁）**：

1. **摘要请求复制整份历史**（`agent_maybe_compact`）：它先把 `h` 整个 `hist_push_msg_kind`
   到一个临时历史，再挂摘要提示词。于是**摘要请求与主请求一样大** —— 历史一旦超过窗口，
   连「把它压小」的那一发请求也被同一个窗口拒掉。屏幕上那句
   「[compact] 摘要请求失败，跳过本次压缩」**字面上是实话，但读起来像「上游抖了一下」**，
   真实含义是「压缩这条路已经彻底断了」。
2. **溢出被 HTTP 500 包着 ⇒ 掉进「可重试」分类**：本机网关把上游的 400 包成
   `[invalid_params]` + **500** 发回来（见上面那段 body）。`rtx_retryable_status` 说 500
   可重试，于是默认无限重试的闸门一直重发同一个**必然失败**的请求 —— 真正的原因
   （窗口超了）被这层包装盖得严严实实。
3. **压缩只改内存、日志里没有 checkpoint**：`--resume` 把日志**从头折一遍**，被压掉的
   那一段原样回来。于是「重启一次」不是出路，而是回到同一个状态（turn 号回到 1 那一条
   就是证据）。

**修法（四处，各自独立可测）**：

| 处 | 改动 | 判据 |
|---|---|---|
| 摘要请求 | 只带 `system + 被遮蔽段 + 提示词`（`agent_summary_input`） | 摘要请求的体量从此与「要压的那一段」同阶，与主请求无关 |
| 摘要请求 | 预算闸门 `cmp_summary_budget` + `cmp_fit_start`（保守 2.5 B/tok，从新往旧装） | 被遮蔽段本身超大时也不会发出注定 400 的请求；装不下的最老段用 `omittedFrom` 如实记账 |
| 主链 | `rtx_context_overflow`（判据在 `net/retryx`，**唯一一份**）+ `STEP_RETRY_OVERFLOW` | 溢出**排在瞬时状态码之前**判：认出就地压缩后同一步重发，认不出才走网络重试 |
| 恢复 | `agent_log_checkpoint`（落盘）+ 折叠侧认 `source.kind="compaction"` + `cmp_fit_history` | 压过的历史活过 `--resume`；老日志折出来超窗时也兜底裁到装得下 |

**为什么溢出判据必须看体、且必须排在那张状态码表之前**：`rtx_retryable_status(500)` 是
`true` —— 顺序反了就是「无限重发同一发必死请求」。判据本身只认**结构性**措辞
（`context length/window exceeded`、`maximum context length`、`exceeds the context limit`、
`too long for this model`），**不拿散文去搜泛化关键词**：把「限流」误判成「溢出」的代价是
白跑一次压缩（良性），反过来则是无限重试（恶性）。
`overflow-pred` 轮两侧都钉：四条真措辞认得出，限流/欠费/空体/只有状态码**一个都不认**。

**量出来的数（保守口径的取值依据）**：真会话里 360 组「新增字节 / prompt token 增量」
实测 —— 中位 **3.25 B/tok**、p05 **2.90**、p25 3.11。安全口径取 **2.5 B/tok**
（`CMP_EST_NUM/CMP_EST_DEN`）：最坏情况仍留 ~16% 余量。
**它与调度口径的 `bytes / 4` 刻意不同、不许合并** ——
`/4` 是「该不该剪/该不该压」的调度判据（估偏只是早晚一步），2.5 是「这条请求会不会被拒」
的安全判据（**低估就是灾难**：以为装得下 → 发出去 → 400 → 那条路上没有第二次机会）。

**先看到红（两处对照，都跑过）**：

* `overflow-recover` 轮（端到端，假网关把 400 包成 500）：把主链那条派发短路回修前行为
  （`if false && rc == STEP_RETRY_OVERFLOW`）重编 → 该轮**红**，`agent_run returned 103`
  （内部码漏成了退出码 —— 这本身就是「没接住」的第二个证据）；改回即绿。
* `compact-auto` 轮（原有）：闸门第一版写成「`room <= 0` 就一律拒绝摘要」→ **当场红**
  （verdict 88：压缩后的请求里没有 checkpoint）。这一条抓到的是一个**真缺陷**：
  窗口小于「system + 提示词 + 工具表」时那道闸门会让压缩**永远**不发生 ——
  等于用一个死锁换另一个。修法：`room <= 0` 时闸门**让开**（那是触发线的语义，
  不是请求上界），只有「闸门生效且一条被遮蔽消息都装不进」才拒绝。

**这一轮顺带修掉的假绿风险**（两处都是实测踩到的）：

1. 夹具会话路径**手拼** `/sessions/<sid>/session.jsonl` → 目录名其实是按 workspace 路径
   slug 出来的（`--<slug>--`）⇒ 找不到会话 ⇒ 走了「新建」那条路，判据**全部落空却看着绿**。
   改用真实解析器 `sess_find`。
2. 夹具窗口给 4000 ⇒ `--resume` 折日志时先被 `cmp_fit_history` 裁到装得下，等轮到请求时
   历史已经很小 ⇒ 要钉的那条路**根本走不到**（压缩只压掉 1 条消息，看着绿）。
   窗口改成 200000，让**唯一**能引发压缩的就是假网关回的那个「超窗 500」——
   触发源唯一，这一轮才能定性。

**验收**：`make check` / `make build`（静态链接审计通过）全绿；`--selftest` 新增
`overflow-pred` / `ctx-est` / `ctx-fit-start` / `ctx-fit-history` / `overflow-recover` /
`ctx-fold` **六**轮全 ok（`ctx-fold` 钉的是折叠侧：checkpoint 之前的消息必须消失，
钉法是直接调 `agent_hist_from_log` 折一份合成日志）；`lint-size` 通过
（新文件 `src/selftest/st_ctxfit.uya` 均在三条硬指标内）。

**还有一条先看到红的对照**：把折叠侧那个分支短路（`if false && sess_json_str(view, "kind", …)`）
重编 → `ctx-fold` 当场红（「checkpoint 之前的消息已消失：期望 0，实际 1」）—— 这条断言
是落盘那道闸门**唯一**的机器判据，没有它的话「压缩当回合成功、日志里也确实有 checkpoint」
会让一切看起来都对，而 `--resume` 照旧把整段折回来。

**明确不做**：把压缩做成 DSH 那样的「日志事务」（`compaction/start`+`compaction/end` 配对、
落盘原子性）—— 本仓的日志是追加-only 的，checkpoint 事件 + 折叠基线已经够用；
也不做「自动降低 `--context-window`」（窗口是人的配置，猜错了比报错更坏）。

### 19.11 P89：悬空的工具调用**不在结尾**时修不好（会话被自己的历史卡死）

**用户报的**（P88 修好超窗之后紧接着）：

```
model endpoint returned HTTP 400
  · body: {"error":{"message":"[invalid_params]: {\"error\":{\"message\":\"An assistant
    message with 'tool_calls' must be followed by tool messages responding to each
    'tool_call_id'. (insufficient tool messages following tool_calls message) …
 · [turn] 本回合异常结束（可直接输入继续）
```

**现场**（`session-43e46f8b`，就是 §19.10 那一条会话）：日志 seq 15049–15051

```
15049  assistant/message   tool_calls=[call_00_zdqw…]      ← 落了盘
15050  tool/call           call_00_zdqw…  (bash 命令)      ← 落了盘
15051  user/message        「继续」                         ← 人下一次启动敲的
       ✗ 没有 tool/result                                  ← 进程在这里被 kill 了
```

那一步跑的是 `ps -eo pid,args | grep "uya-agent" | grep -v grep`（模型正在清理它自己
留下的测试进程）。**进程被信号 15 杀掉**，于是 `tool/call` 落了日志、应答它的
`tool/result` 没来得及落 —— 日志里留下一个**悬空的 `assistant(tool_calls)`**。

**根因：修复只看结尾，而半组不在结尾。**`hist_trim_incomplete_tail` 从最后一条往前看：

```
while h.len > 1 {
    last = h.len - 1                    ← 只看最后一条
    if last 是 assistant_calls → 丢
    if last 不是 tool         → break    ← 「继续」是 user ⇒ 立刻收工，什么都不做
    ...
}
```

结尾是 `user`（合法的尾巴）⇒ 它**立刻 break**，那个悬空的组**从头到尾没被看过**。
而折叠出来的历史里，这一组后面还跟着五条「继续」——它们才是把尾巴变成合法 user 的
原因。于是合并之后每一发请求都被端点拒掉：**这个会话再也发不出请求**。

复现（纯函数，三条断言）：

```
SYS / TASK / calls(c1,c2) / tool(c1) / USER「继续」
  hist_pairing_ok            → false（确实不合法）
  hist_trim_incomplete_tail  → 0     ← **旧实现完全看不见它**（结尾是 user）
  hist_pairing_ok（修后）     → 仍然 false ⇒ 请求会被拒
```

**修法：`hist_repair_pairing`（扫全段）** —— 判据与 `hist_pairing_ok` 共用同一个
（`hist_group_ok`：调用条数对不上、或某个 `tool_call_id` 找不到应答），但**遍历整段**
而不是只看结尾。三种动作：

| 遇到 | 动作 |
|---|---|
| 完整的一组 | 跳过它应答的那几条 tool（`i += 1 + nc`），**一条都不动** |
| 不配对的组 | 从它开始连它后面那些 tool 一起丢（**整组丢** —— 半组比没有更坏） |
| 孤儿 tool | 单条丢（它的 assistant 已经不在了） |

配一个第三种区间删除 `hist_remove_range`（与 `hist_truncate_to` 切尾巴、
`hist_drop_oldest_below` 从头丢并列：**中间挖一段**）。

接线两处（都要，理由不同）：

* `agent_hist_from_log` 之后（`--resume` / `--continue` 那条路）—— 真机现场在这儿；
* `agent_turn_loop` 收尾 —— 上面那条只看结尾，而**回合收尾时后面可能已经有一条
  user**（运行中敲进来的 steer）。它是「本回合收尾必然留下合法历史」这条不变量的
  唯一出口检查：**在自己这边发现形状坏了，比让端点回 400 再让人猜好得多**。

**两条先看到红的对照（都要，而且它们覆盖的**不是**同一件事）**：

| 改法 | `hist-pairing` | `pair-recover` |
|---|---|---|
| 判据写坏（`if true` 短路 `hist_group_ok`） | **红**（4 条断言） | （不适用） |
| 接线删掉（`const unpaired: usize = 0;`） | 绿 | **红**（verdict 170） |

第二条是这一轮最贵的教训：**判据与接线必须分别可测**。第一版只写了 `hist-pairing`
（纯函数），把接线删掉之后它**照旧全绿** —— 那个「绿」只证明函数本身对，不证明有人
调它。`pair-recover`（端到端：合成一份「悬空组 + user」的日志，`--resume` 之后假网关
断言**请求体里没有那个悬空的 id**）补上了这一半。判据落在**线上字节**上，不看我们
以为自己做了什么。

**顺手抓到的一个挂死**：那个循环按「删掉之后 i 不动、再看同一个下标」写；而
`hist_remove_range` 拒绝动下标 0（system 是请求骨架）。两者凑在一起，**万一** 0 号位
是不配对的组，循环就**永远转下去** —— 挂死，不是崩溃（挂死没有任何出口，比 400 坏得多）。
修法是那一档必须前进一步。这一条**必须**有测试：它只在「0 号位是 assistant_calls」时
触发，而那个形状在正常历史里不可能出现 —— 没有测试的话谁也不会发现它挂。
实测把那个分支短路（`if false && i == 0`）重跑：整轮 selftest **rc=124 超时挂死**
（连 `hist-pairing` 那一行都到不了）；改回即绿。

**明确不做**：给悬空的那一步补一条「工具未执行」的假 `tool/result`。那会往历史里写
一条**没发生过**的事实，而模型下一轮会据此以为命令跑过了 —— 宁可丢掉那一步（它本来
就没有产出）。也不改 `hist_trim_incomplete_tail` 的语义：它管的是**尾部**，改名会让
「谁负责哪一段」这条边界糊掉。

**验收**：`make check` / `make build`（静态链接审计通过）全绿；`--selftest` 新增
`hist-pairing` / `pair-recover` 两轮 ok；`lint-size` 通过。

### 19.12 用户报的：**折叠行的「目标 3/20」没有单位、也看不到目标正文**（不占阶段号）

**用户报的两件事**（同一处界面）：① 常驻块折叠行只写 `目标 3/20` —— 那个 `20` 是什么
（轮次上限？任务数？），屏幕上没有任何一处说得清；② 目标正文只在 `/goal` 弹窗里看得到，
折叠行上一个字都没有，不打开弹窗就不知道这个目标到底是什么。

**根因不是算错，是没人说**：`20` 是 `Goal.max_rounds`（轮次上限），`3` 是**自动续跑驱动器**
开过的轮数（`goal_round_admit` 里 `round+1` 落盘；人在输入行打的回合**不计入**）。
折叠行当初只有一个「1 行预算」，所以正文压根没进这一段。

**改法（四处同一形状）**：

| 处 | 改成 |
|---|---|
| 折叠行 | `目标 3/20轮 · <目标正文>`（非 active：`目标 阻塞 · <正文>`） |
| 展开箱体 | `▸ active · 3/20轮 · <正文>`（去掉 `round` 这个词 —— 单位已经在数字后面） |
| `/goal` 弹窗 | `Objective:` / `Blocker:` **压成一行**（外来文本不许在帧里拆行） |
| 读盘 | `goal_set_unescaped`：`goal_save` 转义了，读回来必须反转义 |

**顺手抓到一个存量缺陷（写读转义不对称）**：写这方面那条测试（带 `\n` 的 blocker）第一版
**红得莫名其妙** —— 打出来的 `Blocker:` 里是**字面量** `\n`（两个字符）。根因是
`goal_save` 用 `jw_str_into` 转义、而 `goal_load` 用 `js_obj_get_str` 取**零拷贝原始视图**
（转义没解码）当正文。实测 `/goal A\B` 存盘再读回变成 `A\\B`，**每存读一次多一层反斜杠**。
修法是 `goal_set_unescaped`（`sv_unescape_to_buf`，失败退回原始视图：宁可显示得难看，
也不静默丢内容）。这条与「目标正文单行显示」是同一件事的两半 —— 不解码的话，
用户看到的仍然是 `\n` 而不是空格。

**验收**（都是实测）：

| 判据 | 结果 |
|---|---|
| `tasks-render` 新增：四条逐字节断言（含正文）、正文带 `\n` 压成一行、裁正文保头（26..78 逐档扫描 + 两条前缀等值） | 绿 |
| `tui-tasks`：折叠行上有 `目标 3/20轮` **与**正文前缀（屏幕上看得见的判据） | 绿 |
| `goal-cmd` 新增：读盘反转义 + `Objective:`/`Blocker:` 压成一行（两条路都钉） | 绿 |
| `make lint-size` / `doc-audit` / `doc-cover` / `check` / `build`（静态链接审计） | 全通过 |

**防假绿对照（五条，都先看到红再改回）**：

| # | 改坏什么 | 结果 |
|---|---|---|
| A | 去掉 `轮` 单位 | `tasks-render` **红 10 条**（四条逐字节 + 裁尾 + 箱体） |
| B | 折叠行不接正文（只留头） | **红 4 条**（四段齐 / 只有目标 / blocked / 带换行） |
| C | 裁正文那条路短路（`if false && seg_head[i] > 0`，退回「丢整段」） | **红 4 条**（扫描判据 + 两条前缀等值 + 箱体）+ `tui-tasks` 红 1 条 —— 证明新路真被走到，不是靠老路径兜底 |
| D | 弹窗不做单行化 | `goal-cmd` **红 2 条**（`Objective:` 没压成一行、正文拆成了两行） |
| E | 读盘不做反转义 | `goal-cmd` **红 1 条**（读盘回来的目标没有反转义）—— ⚠ 这一条**最初是绿的**：腿只调内存那一份，不碰读盘。补了「裸 `/goal` 走读盘」那一腿才抓住 |

**明确不做**：不改三段（任务 / 后台 / 子代理）的显示与丢段规矩；不动 `Rounds:` /
`Status:` / `Activation:` / `Commands:` 的键名（DSH 逐字对齐，`make e2e-goal` 也在 grep
它们）；不往 `/goal` 弹窗加解释文字（这一轮的结论是「用单位 + 正文说清楚」，不是加一段
说明）；不改 `get_goal` 工具面的 `round = N / M` 键值排版（模型面本来就有字段名，无歧义）；
不认领阶段号、不动 `AGENT_VERSION`（用户报的体验修复）。

### 19.13 用户报的：**恢复会话后 goal / tasks 没有恢复**（不占阶段号）

**用户报的一句话**：「修复恢复会话后，goal、tasks 没有恢复的问题」。先按现场分了两件事
（都在 TUI/`--no-tui` 那条线上），各有各的根因 —— 都不是「goal.json 没读」：

| 现象 | 实测 | 根因 |
|---|---|---|
| 清单（tasks）恢复后恒为空 | `/tasks` 打「（没有任务：todo 清单为空…）」，而真会话日志里有 3 次 `todo_write` 调用 | 清单**从来不落盘**：整个仓 `grep "todo/write"` 零命中 —— 它只是内存里的 `g_todos`，进程一换就没了（DSH 是把它当**会话事件**写的） |
| 恢复一条**只有 header** 的会话之后目标也没了 | 可复现：`/goal 把测试跑绿` → `--resume <同一 id>` → `[session] 日志为空或无法解析，改为新建会话` → `/goal` 报 `No goal is currently set.`，而老目录的 `goal.json` 一个字节没动 | `agent_hist_from_log` 对空日志**结构上成功**但折出 0 条消息 ⇒ `agent_session_open` 判 `n > 0` 失败 ⇒ 落到 `sess_open` 新建分支 ⇒ **id 与目录当场换掉**，而 P87 之后「目标属于会话」是**文件位置**保证的（`<home>/sessions/--<cwd>--/<id>/goal.json`）⇒ 目标「消失」；顺带每次都在 `sessions/` 下新造一个空目录（现网真机 2809 个 goal/空日志目录，一堆 `lines=1`） |

**先记两条实测（用来划边界，别把「不是 bug 的」也修了）**：① `--resume <id>` /
`--resume last` / `--continue` / TUI `/resume <id>` / `/sessions` 浮层选中，**goal 那条
本来就是好的**（真 PTY 抓帧确认：常驻块与 `/tasks` 都出现 `目标 ▸ active · 3/20轮 · <正文>`，
连恢复一条 16000 行的大会话也一样）；② 「恢复之后目标在、但不自动续跑」**是设计**
（P58：续跑授权不跨进程，要接着跑得人明确 `/goal resume`）—— 不在这条的范围里。

**改法（四处，按数据流自下而上）**：

| 处 | 改成 |
|---|---|
| `agent/todo.uya` | 新增 `todo_log_write`（把提交成功的整表写一条 `todo/write`；`data.todos` 数组，与 DSH 的 `exec.agent.session.append("todo/write", { todos })` 同形）与 `todo_from_json`（折回，**全或无**）。调用点只有 `todo_tool_write` 的提交分支一处 —— 被校验拒掉的提交一个字节都不进日志 |
| `agent/ag_title_prompt.uya`（折叠侧） | `agent_hist_from_log` 认 `todo/write`（后写覆盖先写）与 `turn/start`（`todo_clear`）—— 与 DSH 投影 `apply: todo/write → event.data.todos / turn/start → null` 同序 |
| `agent/ag_title_prompt.uya`（写侧） | `agent_log_turn_start` 里补上那句**从来没接线**的 `todo_clear(&g_todos)`（注释与 `todo.uya` 的文件头都写着「回合开始时清空」，而调用点只有换会话那一处）；它排在 `g_sess.save` 判断**之前**（`--no-save` 同样清） |
| `session/session.uya` + `agent_session_open` | 新增 `sess_has_events`（读到过一条**完整事件行**）：折出 0 条时用它把「空会话」与「日志坏了」分开 —— 空会话走 `sess_open_resume` **沿用原 id / 原路径**（`next_seq` 取那份「迭代到最后一条事件」的值，空日志即 0）；有事件却折不出才走「改为新建会话」 |

**验收**（离线，全部实测）：

| 判据 | 结果 |
|---|---|
| `make e2e-tasks-resume`（新目标）：进程 A 让模型写清单 → 进程 B `--resume` 后 `/tasks` | 绿（三条正文 + 计数行 `清单 1/3` 都在） |
| `--selftest` 新增 `todo-resume` 轮：写（线上字节逐字段）/ 折（清空内存后一致）/ 面板（`任务 1/3`）/ 复位（折到 `turn/start` 出空）/ 回合开始清空 | 绿 |
| `goal-sess` 轮新增 D 段：空日志恢复 → 目标还在、id 与路径逐字节不变、会话目录数不变 | 绿（真机也复现过同一场景：`--resume` 之后 `/goal` 仍报 `Objective: 把测试跑绿`，`sessions/` 下不加目录） |
| `make lint-size` / `make check` / `make build`（静态链接审计） | 全通过 |

**防假绿对照（五条，每条都先看到红再改回）**：

| # | 改坏什么 | 结果 |
|---|---|---|
| A | `todo_tool_write` 里不调 `todo_log_write` | `todo-resume` **红 2 条**（「不是正好一条」+「日志里没有」）、`e2e-tasks-resume` **红**（日志里没有 `todo/write`） |
| B | 折叠侧删掉 `todo/write` 分支 | `todo-resume` **红 2 条**（清单不一致 + 面板空的）、`e2e-tasks-resume` **红**（恢复后 `/tasks` 空）—— 与 A 是**两截**：A 只红写那一条 |
| C | 折叠侧删掉 `turn/start` 分支 | `todo-resume` **只红 1 条**（「折到 turn/start 之后清单没复位」），其余仍绿 —— 复位那条腿自己可测 |
| D | `agent_log_turn_start` 里拿掉 `todo_clear` | `todo-resume` **只红 1 条**（「回合开始没清空上一回合的清单」）—— 与 C 分得开（C 测折叠侧、D 测产品侧那一句） |
| E | `empty_log` 恒假（退回老行为） | `goal-sess` **红 4 条**（换了 id / 换了路径 / 新造目录 +1 / 目标不见了） |

**明确不做**：不给清单加「恢复后注入回模型上下文」的语义（DSH：那是 UI/replay 状态，
不是第二条模型消息）；不迁移、不删历史遗留的**孤儿** `goal.json`（与 §9.3「不迁移历史文件」
同口径）；不动 `/goal` 的续跑授权口径（P58 的 `--resume` 后 disarmed 是设计）；
不改 `--dsh-web` 那两个写死的投影（`goal:null` / `todos:null` 是另一条线、另一套判据）；
不认领阶段号、不动 `AGENT_VERSION`（用户报的缺陷修复）。

### 19.14 P90：**提供方名能不能用环境变量给**（`UYA_AGENT_PROVIDER`）

**用户问的一句话**：「uya-agent 可以通过环境变量设置供应商的名称吗」。查了一遍：
`UYA_AGENT_BASE_URL` / `UYA_AGENT_MODEL` / `UYA_AGENT_API` / `UYA_AGENT_API_KEY` 都有
env 档，**只有提供方键没有** —— 而它恰恰是「请求打到哪一家、用哪一把密钥」的那一半。

**为什么这一条不只是省事（现状的三种坏法）**：

| 现场 | 现状 |
|---|---|
| 容器 / CI 部署 | 只有环境这一条入口。换一家提供方只能改 `settings.yaml` 的 `agent-default-model.provider` —— 而那是**用户自己的默认路线**，改它等于把本机交互式使用也一起改了 |
| `--dsh-web` 的对话子进程 | 宿主用 `--provider P` 起，子进程的 argv 只有 `--tui`，环境里也没有提供方 ⇒ 父子对「去哪一家」分叉（与踩坑 124 的 `--base-url` 现场同形） |
| `--resume` + 环境 | 没有 env 档时这条无解；有了 env 档还要说清它与会话记录谁说话（见下） |

**口径（三层优先级，由位置保证、不由判断保证）**：`cli`（`--provider`）> `env`
（`UYA_AGENT_PROVIDER`）> `dsh-settings`（`agent-default-model.provider`）。

* **名字在第 1 步落、路线在第 3.51 步解析**。为什么拆开：`--dsh-home` 的预扫在第 2 步，
  在第 1 步解析就会去默认 `~/.dsh` 里找这个提供方（症状是「设置里明明有它」却解析不出
  路线）；而第 1 步必须先把名字落进 `cfg.provider`，`agent_apply_dsh` 那条
  `!cfg.provider_set` 才挡得住设置里的 provider。解析本身复用 `agent_route_apply`
  （P37 那一处收口）⇒ 端点 / 凭据 / 线协议一起跟随，并且自带两条纪律：**显式给过的
  `base_url` / `key` / `api` 一律不动**；**解析不出凭据就清空**（旧密钥绝不跨提供方）。
* **与 `--provider P` 同口径**：`e2e-provider` 的第 ⑦ 条腿把两条路的 `--print-config`
  **逐字节**比（只把来源标签归一化）—— 这是「env 档不是第三套语义」的机器判据。
* **显式优先**：`UYA_AGENT_PROVIDER=beta --model a-plain`（a-plain 只在 alpha 下）不许
  跨提供方回退把 beta 换掉 —— `pinned` 判据从「`src_provider == 3`」扩成
  「2 或 3」，env 与 cli 在这里是同一档。
* **`--resume` 仍跟随会话记录**（env 给的是**本次启动的默认路线**，不是钉子）。这一条是
  想清楚才这么定的：把 env 的提供方也做成钉子，`--dsh-web` 里「用户刚切到 B，重开标签页」
  就会被宿主的默认路线按回 A —— 那是把修好的一半又弄坏。显式那两档里真正被钉住的仍然
  只有端点与凭据（`agent_route_apply` 的口径），回执里打出来的端点就是**实际会用的**那个。
  与 DSH 自己的 `agent-default-model.provider` 同一个槽位，语义也一致：会话记录优先。
* **web 子进程注入**（`web_child_env_cfg`）：只在**显式来源**（env = 2 / cli = 3）时注入
  `UYA_AGENT_PROVIDER`；来自设置（`src == 1`）时**不注入** —— 那是部署默认路线，子进程
  自己会解析，注入了等于把它钉成「env 显式」，切模型时端点就不跟了（上面那条纪律的反面）。
* 顺带一处诚实性修复：`UYA_AGENT_MODEL` 给的模型以前在 `--print-config` 里印成
  `source: default`（旁边 `provider` 却印 `env`）—— 现在 env 档落来源码 2，人不用再猜。

**验收**（离线；真二进制 + 真 settings.yaml，一律 `env -i` 起）：

| 判据 | 结果 |
|---|---|
| `make e2e-provider`（新目标，8 条腿）：① env 压过设置且**路线跟着走**（端点 / `apiKeyEnv` 解出的密钥 / 线协议）；② cli 压过 env；③ 显式优先不回退；④ env 给全两个 ⇒ 按二元组定稿（`context_window` 444000 来自 beta 下那条）；⑤ 凭据不跨提供方（清空 + 告警）、没声明 `baseURL` 就不动端点；⑥ 反腿：没给 env ⇒ 一切照旧 dsh-settings；⑦ 与 `--provider P` 除来源标签外**逐字节**相同；⑧ `--resume` 仍跟随会话记录 | 全绿 |
| `web-childcfg` 轮（P73 那一轮扩表 15 → 16）：显式来源必须注入、**设置来源不许注入** | 绿 |
| 回归（离线，**干净机器口径**：`env -i` 或 `HOME` 指向空目录 + 不导出 `UYA_AGENT_*` / `DSH_HOME`）：`e2e-model` / `e2e-model-save` / `e2e-ctxwindow` / `e2e-inputimage` / `e2e-ws` / `e2e-config-flags` / `e2e-portable` | 全绿 |
| `make lint-size` / `make doc-audit` / `make codegen-audit` / `make ui-audit` | 绿（`doc-cover` 红在**别处**：`dshdoc.uya` / `dshfile.uya` / `dwhschema.uya` 的既有缺口，与本轮无关） |

**防假绿对照（真跑过：改坏 → 看到红 → 改回 → 再绿）**：

| # | 改坏什么 | 结果 |
|---|---|---|
| A | `web_child_env_cfg` 里那次注入整段停掉（`if false`） | `web-childcfg` **红 1 条**，文案正是「提供方没传进子进程（浏览器里会打回设置里的默认路线）」 |
| B | 名字落进 `cfg.provider` 但**不解析路线**（去掉 3.51 那一步） | `e2e-provider` **红**：`FAIL: 端点没跟着 env 给的提供方走（请求会打在 alpha 上）` |
| C | `pinned` 判据退回只认 cli（`src_provider == 3`） | `e2e-provider` **红**：`FAIL: env 给的提供方被 --model 的跨提供方回退改掉了` |

**明确不做**：不加 `UYA_AGENT_PROVIDER` 的「钉子」语义（理由见上）；不改 `--resume` 的
模型/档位跟随口径（P37 的老规矩：只有 cli 显式给过 `--model`/`--effort` 才让位）；
不新增 `UYA_AGENT_PROVIDER` 的取值校验（提供方键是用户设置里的任意字符串，认不出就是
「路线解析不出来」这一条既有路径，与 `--provider` 完全一致）；不动 web 宿主的其它注入。

### 19.15 P91：`/goal` 在 TUI 里开**动作选择浮层**（用户报的）

**用户报的**：命令面板里选中 `goal` 回车之后，屏幕上只有一张状态报告。目标这件事有六个
动作（看 / 建 / 改 / 暂停 / 恢复 / 清除），却没有一处能把它们**列出来** —— 而同一条线上的
`/permission`、`/model`、`/effort`、`/worktree` 早就都是底对齐选择浮层了（P41 那条注释里
写着同一句话）。

**改法**（口径见 §9.3 末那一节）：裸 `/goal`（手敲或面板选中）→ `TUI_OVK_GOAL_MENU`
动作框（六行 + `✓`，游标默认 `status`）；`create`/`edit` 用 P48 的单行输入框收正文
（`edit` 预填当前正文）；六个动作走完都开原来那张状态浮层。带参数 `/goal <objective>`
与滚动模式**一个字节不改**。

**为什么新开一个 kind 而不借 `TUI_OVK_GOAL`**：那个 kind 在接收端是「纯查看，enter 不
派发」语义（结果没人接、被静默丢掉）—— 与 `/watch` 曾经借 `/tasks` 的 kind 是同一条坑
（§16 踩坑 65/73 那一族）。这也正是「加一个浮层要同时改三处」的那条纪律：开浮层、主循环
消费、泵点回执，缺一处就是「按了没反应」。

**验收**（都是实测）：

| 判据 | 结果 |
|---|---|
| `tui-tasks` 的 H 段（抽成 `tuis_goal_menu_case`）：清单有 `/goal`、裸命令开的是 `GOAL_MENU`、六动作与 gloss 上屏、无目标时 `✓ create`、**打开就回车 = status 且盘上不冒 "status" 目标**、有目标后 `✓ pause`、pause/resume 真翻 phase+armed、`esc` 取消不改目标、空正文拒掉、认不出的行不执行、clear 删文件 + 投影清空 | 绿 |
| `tui-tasks` 的泵点腿：回合运行中只落**一次**回执、结果仍在队列（`tui_overlay_result_pending`）、盘上零改动 | 绿 |
| `make p30-check` 第 11 场 `goal-menu`（真终端 + 真按键）：面板选中 59 ms 开框、裸命令 62 ms、`↓`+回车弹输入框、敲正文回车 62 ms 出 `Goal created` + 正文上屏、再开框 `✓ pause`、打开就回车看到 `Status: active` 且没有 `Objective: status` | 绿 |
| `make tui-selftest` / `make p30-check` / `make lint-size` / `doc-cover` / `ui-audit` / `check` / `build`（静态链接审计） | 全通过 |

**两条踩到的坑（都记在这里，因为都很容易重犯）**：

* **headless 测不了阻塞式输入框的「敲正文→回车」**：`tui_title_input_wait` 一进去就
  `tui_key_reset()`（排队键丢掉），而 headless 的注入键**就是**那条队列 —— 注入的键到不了
  阻塞循环。所以 P48 的轮次同样只用**非阻塞**的 `tui_overlay_input_open` 测编辑。这一轮
  的处理：把「框的标题 + 预填」抽成 `agent_tui_goal_prompt`（生产与自测**同一个函数**），
  敲正文那条腿交给 `p30-check` 的真终端场。
* **PTY 驱动里的 `↓` 必须是 `\x1b[B`**：`ESC [ B` 是方向键的转义序列；发字面的 UTF-8
  `↓` 会走 STRING 路径，在**输入行**里落一个 `↓`（实测把命令面板的过滤器搞乱：
  `没有匹配的命令：↓`）。

**明确不做**：滚动模式的浮层（那边没有浮层，`/goal` 照旧打转录）；`clear` 的二次确认
（理由见 §9.3）；新起第二个命令名（`/goal` 一个入口就够）；不动 `AGENT_VERSION`。

### 19.16 P92：出站代理（`UYA_AGENT_PROXY` / `--proxy` / `--no-proxy`）

**为什么要做**：企业网里访问模型端点只有一条路 —— **走代理**。在此之前本仓一个字节都
不会走代理（`httpc` 直连 `tcp_connect`），于是「公司网里跑不起来」这件事在代码里没有
出口，只能靠改 DNS/hosts 之类的外围手段绕。与 P80（`$UYA_AGENT_DNS`）是同一族：
**多给一个可证的、能排障的出口**，而不是让失败长成一句「检查 base-url / 网络」。

**形状**（唯一权威是 `net/proxyx` 的 `hpx_parse`）：

| 项 | 口径 |
|---|---|
| 取值 | `host:port` · `http://host:port` · `http://user:pass@host:port`（scheme 与凭据都可省；末尾一个 `/` 允许） |
| 缺端口 | 按 **8080** |
| 来源 | CLI（`--proxy` / `--proxy=`）> `$UYA_AGENT_PROXY` > 无（直连）；`--no-proxy` = 显式关掉，压过 env |
| 只支持 | **`http://` 明文代理**（HTTPS 目标打 CONNECT 隧道）—— `https://` / `socks5://` **报错退出** |
| 值非法 | **`rc=1`**，消息点名是哪个入口给的 + 合法形状 + 具体是哪一处非法（七类原因码） |

**五条不变量（每条都对应一处会咬人的地方）**：

1. **TLS 判据一个字不变**：CONNECT 只搬字节，TLS 握手仍是**与目标主机**谈 ——
   SNI / leaf 指纹 / TOFU / pin 全部照旧。代理要中间人就必须换 MITM 证书，那时 `pin`/TOFU
   会如实报指纹不符（这正是想要的：**不让代理悄悄改变信任链**）。
2. **传输层不认识环境变量**：`httpc` / `proxyx` 都不读 env；`agent_setup_proxy()` 由
   agent 层在**第一次连接之前**钉进去（与 `hc_dns_set_override` / `hc_set_tofu_path` 同一
   条纪律，踩坑 133 的修法）。
3. **本机目标一律直连**：`localhost` / `127.0.0.0/8`（四段十进制）/ `::1` 走
   `hpx_bypass`。理由不是「省一次转发」，而是**本机进程不该被代理**（`--dsh-web` 连本机
   网关、自测夹具、用户的本地 vLLM/ollama）；代理多半没有回环转发，不绕就是本机自测全红。
4. **失败口径分开**：`HcProxyUnavailable`（连不上代理 / 隧道超时 / 502·503·504，**可重试**）
   与 `HcProxyFailed`（407 凭据错 / 403 / 应答畸形，**不可重试**）是两个码 —— 判据是
   retryx 那条「重发一次会不会变好」（代理刚起来那几秒正是要救的现场；凭据错重发只会刷屏）。
   显示层是**同一档**（`kind 9`），按 `hpx_err_now()` 说人话，且**不提 TLS/DNS**。
5. **子进程覆盖三条路**：`--proxy X` 注入值；`UYA_AGENT_PROXY=X` 走 `env_set_kv` **换掉**
   继承来的同名项；`--no-proxy` 注入**空值**挡住继承 —— 与 `UYA_AGENT_WEB=0` 同款双保险
   （踩坑 103/124）。注入点只有 `websrv` 的 `web_child_env_cfg2` 一处，`--web` 与
   `--dsh-web` 两条 spawn 路径共用它。

**分工**：`net/proxyx` 是**纯数据变换**（解析、状态、报文拼装、应答状态行、失败分类），
零 I/O —— 与 `net/tlspin` 同形，所以整份判据离线可测；真实连接（`tcp_connect`）与
CONNECT 那一次读写留在 `net/httpc`（它才知道名字解析与泵点）。这顺带守住了 httpc 的体量
（改完 1905 行，离 2000 还有余量）。

**验收**：

| 判据 | 位置 | 结果 |
|---|---|---|
| 三种合法形状 / 默认端口 / 凭据头**逐字节** / 回环绕过九条 / 七类非法值**各指原因** / 非法不半采纳 / 清空 / 失败分档 | `selftest[proxy]`（`UYA_SELFTEST_PROXY_ONLY=1`、`make proxy-selftest`） | 绿 |
| **现地假代理**（回环套接字 + fork）：CONNECT 请求行与 `Host` 逐字节 + 隧道**回显透明** / 绝对形式请求行 + `Host` 是目标 / 407 ⇒ `HcProxyFailed` + 状态码 / 502 ⇒ `HcProxyUnavailable` / 回环绕过 | 同上 | 绿 |
| **真二进制穿过代理到上游**：假代理（`testdata/mock_proxy.py`，真转发）+ 假网关，断言**假网关真收到**请求（`req.bin` 非空 + 模型名）**且**代理日志是绝对形式；流式那条腿另起 SSE 网关 + 第二个代理；凭据腿断言 `Proxy-Authorization: Basic dXNlcjpwYXNz`；`--proxy` CLI 档同效；`--no-proxy` 后代理日志**不再增长** | `make e2e-proxy`（并入 `selftest`） | 绿 |
| 反腿：代理死端口 ⇒ `rc=2` + 「代理没打通」+ 指名 `UYA_AGENT_PROXY` + **不许出现 TLS/DNS 字样**；CONNECT 被回 407 ⇒ `rc=2` + 文案带状态码；非法值（env 与 CLI 各一次）⇒ `rc=1` + 为什么；`--print-config` 的 default/env/cli/`--no-proxy` 四种来源 | `make e2e-proxy` | 绿 |
| 回环那条腿：代理指向死端口，目标 `127.0.0.1` 照样跑通 | `make e2e-proxy` | 绿 |
| `web_childcfg`：`--proxy` 进子进程 / 默认不注入 / `--no-proxy` 注空值 | `selftest[web-childcfg]` | 绿 |

**防假绿对照（都真做过，不是设想）**：

* 把 CONNECT 的目标写成**代理自己**（`hpx_bypass` 里改成不做回环绕过也会顺带红）⇒
  `selftest[proxy]` 的隧道步与 `e2e-proxy` 的 ①② 当场红（线上字节与上游收不到）。
* 把绝对形式退回**相对形式**（`hc_append_target` 直接走 path）⇒ 隧道的假代理步红，
  且 `e2e-proxy` ① 报「代理日志里没有相对/绝对形式那一行」。
* 删掉**回环绕过**（`hc_route_for` 不看 `hpx_bypass`）⇒ 回环那条腿连到死端口、红。
* 把 `hc_connect` 里的 `url_host(u)` 写回 `url_host(&u)`（`u` 本身已是 `&const Url`，
  多取一次地址拿到的是**形参的地址**）⇒ `selftest[proxy]` 直接 SIGSEGV（本轮第一版就是
  这么崩的；同族：踩坑 22 的「切片字面量取址」）。这条记在这里，因为**编译器全绿**。

**明确不做**（不是遗漏）：

* **SOCKS5 / `https://` 代理**：要另写一条协议；本轮给的是「报错退出」而不是静默降级。
* **`HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`**：两个来源会让「为什么走了代理」难查；
  `--dsh-assets-install` 的 `npm` 取件仍只认 npm 自己的变量（如实记在这里）。
* **入站服务**（`--web` / `--dsh-web` 的监听）不受影响；MCP 是 stdio，不涉及。
* **明文 HTTP 目标撞上代理 407** 时，407 是以「普通响应状态」回来的（不是 CONNECT 被拒），
  本轮的报错是状态码那一路的常规文案。HTTPS 目标（LLM 端点的主流形态）不受此影响。

**一处顺带修掉的老谎**：`agent_finish_retry`（预算用尽）以前把档位**写死 0**，于是
「已重试 N 次仍失败」那一行永远落回笼统的「网络或 TLS 校验」。代理那两条是**可重试**的，
必然走这条路 ⇒ 不修就等于新功能的报错被重试层吃掉。现在失败档位跨重试留住
（`g_rtx_tls_kind`），`make e2e-retry` 的死端口负控腿也随之从「断言那句笼统话」收紧成
「断言**连不上服务器**，且不许出现 TLS 校验」。
---

### 19.17 P92：`tls_pins` 要多条 —— 「新证书过了发证机构校验才学进库」

**用户报的**（原话）：「tls_pins 支持多个，因为有些网站可能有多个证书，验证合法的都应该可
以用」，追问之后定下的口径是 **D + 新证书要到发证机构验证通过后记录**：库里已经记过的指纹
仍然必须逐字节相符，**没记过的**那张只有在「链能验到系统信任根」时才接受并追加一行。

**为什么这是对的（而不是「改成谁都能加」）**：多证书站点（证书轮换、多机房各发各的 leaf、
CDN 换证）在 TOFU 档下**必然**撞上 `HcPinMismatch` —— 用户看到的是一句「请求失败（网络或
TLS 校验）」，而真相是「这台站点换了一张同样合法的证书」。但「一律接受新证书」等于把 TOFU
唯一的防护（变了就拒）拆掉，中间人只要能让握手成功就行。用户里那句话里的**「验证合法」**
正是分界线：新证书必须自己走一遍链校验。

**链校验是谁做的：本仓自己做的，不 exec openssl**。标准库那条路走不通（§18 的三条死路），
但缺的是**两个具体零件**，不是整门课：

| 缺什么 | 本轮怎么补 |
|---|---|
| `x509/cert.uya` 只解 RSA 公钥，且**不给** subject / issuer / SAN ⇒ 建不了路径、做不了主机名校验 | 新文件 `net/x509min.uya`：自己的最小 DER 走查（`xm_hdr`），解析 TBS 区间、签名算法、issuer/subject 原始 DER、有效期、basicConstraints（CA + pathLen）、keyUsage、extKeyUsage（serverAuth / anyEKU）、SPKI（RSA n/e 或 EC 未压缩点）、**SAN 的 dNSName 列表**。所有 DER 读取都带**显式长度**（`der_len`），未知 critical 扩展、重复扩展、畸形扩展一律 `ext_invalid` 整张作废（fail-closed） |
| `mpi_mul` 装不下 RSA-2048（`MPI_MAX_LIMBS = 32`，两个 2048 位数相乘要 64 limb）⇒ 验签必失败 | 新文件 `net/rsav.uya`：自己的大数（`[u32: 130]`）+ Montgomery CIOS + `e` 的模幂 + PKCS#1 v1.5 的 DigestInfo 逐字节比对。CIOS 单步上界 `(2^32-1)^2 + 2(2^32-1) = 2^64-1` 正好塞进 u64，所以**不需要 u128**（语言里也没有） |
| 信任库只读前 64 KiB（224 KB 的库只进 44 张） | 新文件 `net/cachain.uya`：自己整份读系统 CA 库（上限 1 MiB），PEM 拆块 + base64 解码，**建索引**（一次扫完，之后按 subject 长度预筛），按 `issuer == subject` 从叶往上建路径 |

`net/cachain.uya` 的判定（每一条都是**必须**，缺一条就等于没验）：签名（RSA 走 `rv_`、ECDSA
走 lib 的 `ecdsa_verify_p256/p384`）、有效期、父证书 `basicConstraints CA:TRUE`（且
**critical**）、`pathLenConstraint`、父证书 `keyUsage` 里有 `keyCertSign`（有声明才查）、
**锚点必须真的在系统库里**（服务端自带的自签根只被当作「链走到头了」，不算信任）、叶子按 SAN
的 dNSName 匹配主机名（**没有 SAN 就失败，不退 CN** —— 退 CN 那条老路主流客户端已废弃，猜出来
的「大概对」比失败更危险）。

三条派生纪律（都是「别让一次尝试的结论把另一次的原因顶掉」这一族）：

* **keyUsage 的位号只有一处定义**：`net/x509min.uya` 直接按 RFC 5280 的位号存
  （bit5 = keyCertSign），`net/cachain.uya` 的 `CC_KU_KEY_CERT_SIGN` 就是 `1 << 5`。
  早先一边按「倒序编号」存、一边拿 `0x04` 去与，正牌 CA 会被判「没有 keyCertSign」整条链拒掉。
* **同一 issuer 名字在库里可能不止一张**（新旧同名根、交叉签发副本）：`cc_find_in_flight`
  / `cc_find_in_bundle` 都带 `from` 游标逐张试，只试第一张会把「换过根、两张都还在」的
  正常站点判成链断。
* **失败原因要留住最先那句**：逐张重试会反复覆盖 `cc_last_reason`，最后往往停在「找不到
  签发者」这种兜底话上。`cc_step` 把第一次「验不过」的原因抄进 `keep`，全部候选都失败后
  原样交出来 —— 用户需要看到的是「签名验不过 / 不在有效期 / 没有 CA 位」，不是兜底句。


**TOFU 的三态因此长成四态**（`net/httpc.uya`）：

| 情形 | 旧行为 | 现在 |
|---|---|---|
| 库里没这台主机 | `FRESH`：记一条、放行（verified=false） | 不变 |
| 库里有且指纹命中 | `TRUSTED`，放行 | 不变 |
| 库里有、指纹不命中 | `HcPinMismatch` | **`tls_tofu_ca_check`**：链验过 ⇒ 追加一行 + `LEARNED`（放行，verified=true）；验不过 / 做不了 ⇒ 仍 `Mismatch` |
| 库已满 `TP_MAX_PER_HOST`（4 条） | —— | 放行（`LEARNED`）但**不再追加**：库是只追加的，不淘汰旧条目（淘汰会让「上次信任的那张」悄悄失效） |

开关（默认**开**，因为这就是要的行为；关掉 = 逐字节回到旧行为）：`--tls-tofu-learn` /
`--no-tls-tofu-learn`、`UYA_AGENT_TLS_TOFU_LEARN=0|1`、设置 `uya-agent.tls.tofu-learn`
（**三态**：没写就不覆盖内置默认，二态会把「没写」读成 false，升级之后行为悄悄变）。
系统 CA 库可以用 `--ca-bundle PATH` / `UYA_AGENT_CA_BUNDLE` 覆盖，默认按
`$SSL_CERT_FILE` → Debian/Deepin → RHEL → 通用四档自己找。`--print-config` 打三行：
`tls_tofu_learn`（含来源）、`ca_bundle`（含来源）、原有的 `tls_pins`。

**失败必须留一句话**：`cc_last_reason()` 里的原因会被 `ag_request_stream` 在
`HcPinMismatch` 的报错里印出来（「已按发证机构校验这次的新证书：<为什么没过>」）。
没有系统 CA 库、算法不支持（SHA-1 / RSA-PSS / Ed25519）、握手缓冲把链截断 —— 三种都
**明确失败**，绝不静默放行。

**自己写密码学判据的风险与对策**：最大的风险是「看着对」。所以判据分段验、每段都能单独红：

* `rsav` 先用真实站点抓下来的 RSA-2048 证书跑通（`api.deepseek.com` 的 leaf 由
  `TrustAsia DV TLS RSA CA 2025` 签，验签通过），再补一组与 `pow()` 对拍的模幂用例；
* 自测夹具是**自签测试 CA** 出的证书（`testdata/tls_ca/`，有效期 30000 天，`gen.sh` 记录
  生成命令）：好链 / 错主机名 / 缺中间证书 / 服务端自带自签根 + 空库 / 签名改一个字节 /
  ECDSA P-256 链；
* 防假绿对照（本轮实测两处）：把 `rv_check_em` 里的 DigestInfo 比对拆掉 ⇒ 签名腿红；
  把 `cc_verify` 里的主机名检查拆掉 ⇒ 通配腿红。另外本轮**被自测当场抓住三个自身缺陷**：
  ① CIOS 收尾丢了 `t[n]` 那次条件减法（症状：小指数对、大指数全错，RSA-2048 的模幂整段
  算错）；② `rv_from_be` 按未去前导 0 的字节数算 limb 数（DER 的 2048 位模数是 513 字节
  ⇒ 129 limb，而数值只占 64 个，`rv_cmp` 先比 n 于是全错）；③ SAN 用定长槽存却按「前面各
  条长度之和」读（第二条读出来是槽里的空洞，`*.wild.test` 永远匹配不上）。

**性能**：RSA 链一次校验 ~6–9 ms（含首次把 224 KB 的库扫成索引）；ECDSA（P-256）那条
~300–600 ms（lib 的 `ecdsa_verify_p256` 是朴素实现）。它只在「新证书」这条路上跑
（TOFU 学到过之后走的是查表），所以这个代价可以接受 —— 但**别**把它搬到每次握手都跑的
路径上。

**明确不做**：OCSP / 吊销列表 / CT 日志（离线不可得，做了也是假的安全感）；改
`lib/tls` 的三条死路；把 `chain` 档换成这条链校验（它从「真实站点上必然失败」变成能用，
属于另一轮的改动）；`pin` 档支持多条配置指纹（这次要的是「TOFU 学新证书」，不是
「`--tls-pin` 写多个」）；淘汰旧条目（见上）。

### 19.18 P94：回合异常结束之后**自动替人打一句「继续」**

**用户报的**（原话）：「本回合异常结束（可直接输入继续）自动像 连接重试一样的策略重试」。
现场就是那一行提示：回合以非 0 收场，屏幕上丢下一句「[turn] 本回合异常结束（可直接输入
继续）」，而人接着敲一句「继续」，多半就好了 —— 那件事机器自己会做，不该每次都问人。

**先定边界：只对「空响应」开闸，不给所有失败开**。三条理由：

1. **传输层那半边已经有主**：连接被拒 / IO / 超时 / SSE 早断 / 408·425·429·5xx 由
   `net/retryx` 在**同一步**里退避重发（默认不限次数，请求体逐字节相同）。回合级再插
   一手，只会把同一次失败重放两遍，还把「重发的是同一发请求」这条不变量搅浑。
2. **确定性失败的出口是修配置，不是再来一次**：401/403/404、坏 payload、上下文超窗压不
   动、步数熔断、OOM —— 重发一百次还是同一个错，而每重发一次都真花钱。不替上游猜，
   与 `retryx` 的分类表同一条纪律。
3. **空响应恰恰是「人打继续就好了」的那一类**：上游正常收尾（`finish=stop`）却既没正文
   也没有工具调用。本仓为它已经有「同一步重发一次」（P54）；那一次也没成时，剩下的路
   就是**接着跑一回合**。判据因此很窄：`agent_note_degenerate` 在额度用尽时置一个提示
   位，回合层只在「提示位定过性 + 退出码是协议错」时才继续。

**修法**（新文件 `agent/ag_turn_retry.uya` + `agent_turn_loop` 外面一层循环）：套在
`agent_turn_loop` 这一层，而不是各个交互入口 —— `/continue`、滚动模式、TUI、一次性
任务、子代理**都走它**。判据只有一份答案，五个调用点不必各写一遍（「一处定义」）。

| 要素 | 取值 | 为什么 |
|---|---|---|
| 退避 | `rtx_backoff_ms()`：0.5–3 s 随机 | 与传输层重试**同一套数值**（用户的原话就是「像连接重试一样」）；抖动让同一故障下的多个客户端不同时回来 |
| 中断 | `agent_rtx_wait`：≤50 ms 切片 + 泵点 | esc / ctrl+c / ctrl+d 当场收口 —— 自动重试不许变成「按了没反应」（踩坑 44 同族） |
| 预算 | `TURN_RETRY_MAX = 2`，`0` = 关（**P96 已改成出厂不限**，见 §19.20） | 回合级**不做无限**：一次传输重发只多一发请求，一次自动继续会再跑一整段 step 循环（模型可能连着调几十个工具）。连两次都空，交回人手最稳 |
| 账 | 转录一行 `[turn-retry] … backoff=1.7s（esc/ctrl+c 可停）` + 会话日志 `turn/retry` | 屏幕要能解释「为什么又动起来了」，日志要能复盘「继续了几次、等了多久」。`--quiet` 也照打 |
| 注入 | 与 `/continue` **逐字相同**的「继续」，走 `agent_push_user_with_imgs` + `agent_log_user_att` | 历史、模型看到的东西、会话日志三样因此一致（图片附件与条数上限的腾挪也复用同一条路） |
| 收尾 | 预算用尽 / 不可重试 → 原退出码交回去 | 「本回合异常结束」那句话仍由调用方照旧打出来；`--api-retry-max 0` 那类负控腿的退出码判据不受影响 |
| 全局闸门 | `turn_retry_set_max(0)`（`selftest_main` 里钉住） | 与 `rtx_set_max(0)` 同一条纪律：会改变全局行为的东西，自测必须自己钉住初值 |

**一个容易写错的顺序**：每次进 `agent_turn_loop_once` 之前都要**清提示位**。不清的话，
上一回合留下的「空响应」会给这一回合的 401 当通行证 —— 一个确定性的错被自动重跑，预算
花在必然失败的请求上。另一条：**先退避再注入**（人在退避里叫停时，历史里不该多出一条
没人要的 user 消息）。

**自测**（`turn-retry`，mock mode 50）：三发三态 —— ①退化（只有思考）②与①**逐字节
相同**的重发（再退化 ⇒ 额度用尽 ⇒ 回合按错误收场）③自动继续之后那一发。判据三侧：
转录的 `[turn-retry]` 行（序号 / 预算 / 退避区间 / 怎么停）、会话日志（`turn/start` 两条、
`turn/end` 先 `error` 后 `completed`、`turn/retry` 一条且字段齐全、一条「继续」的
`user/message`）、mock 侧的请求体里那条 `"role":"user","content":"继续"`。

**防假绿对照（两次都真做过）**：

① 把这一轮的预算改回 `0`（等于没有自动继续）⇒ 三类判据一起红（转录、日志、退出码
`agent_run returned 3`）；
② 把注入的文案改成「接着」⇒ **两侧**同时红：日志侧「没有那条继续的 user/message」，
mock 侧 `mock server verdict 254`。
⚠ ②顺手抓到本条自测自身的一条假绿：第一版 mock 侧只搜「继续」两个字，而**系统提示词里
本来就有「继续」** ⇒ 文案改错也照样绿。判据必须落在**整条消息的形状**上
（`"role":"user","content":"继续"`），不能落在裸的文案上。

**边界（明确不做）**：不把 `AGENT_MAX_TOKENS` 与 `AGENT_INTERRUPTED` 算作异常（前者有
`[max-tokens]` 的专门出口，后者是人叫停）；不在退避里抢 steer 的顺序（退避期间敲进来的
正文照旧进 steer 收件箱，下一个 step 边界生效）；不给回合级做「无限次」（理由见预算那一
行）；子代理与一次性任务同样吃这条规则，但它们与主回合共用同一个进程级预算 —— 单线程
主循环下回合不会嵌套，所以不存在互相偷额度的问题。

### 19.19 P95：失败报告里的**两行谎话**（目标写成代理、指纹是上一个回合的）

**用户报的**（原话）：把屏幕上的那一段贴回来问「为什么还有」：

```
error: 请求失败（TLS 握手失败）。
  目标 = localhost:2334
  TCP 已连上，握手阶段断了 —— 通常是中间设备改写了 TLS。
  服务端 leaf SHA-256 = 0b112476…b475d
  uya-agent --probe 会打印传输层细节。
```

这两行**互相矛盾**：`localhost:2334` 是本机的 hiddify 代理端口（用户平时就用
`UYA_AGENT_PROXY=http://localhost:2334`），而那个指纹是 `api.deepseek.com` 的证书。
真话是「隧道打通了、TLS 在隧道里被对端掐断」，屏幕上却把人指向「中间设备改写了 TLS」。

**两条根因，各修各的**：

1. **目标取错了账**。走代理时 `hc_target_*` 记的是**代理自己** —— `tcp_connect` 记的是
   它真连上的那个地址，而隧道那一路连的就是代理。真目标一直在 `hpx_target_*` 里，
   但报告只读 `hc_target_*`。修法不是「显示层特判一下有没有代理」，而是**把路由记成账**：
   `hc_connect` 定路由时写 `hc_last_route`，报告按这一档取 —— 非直连取 `hpx_target_*`
   并把代理一并印出来（`目标 = api.deepseek.com:443（经代理 localhost:2334）`），
   直连才取 `hc_target_*`。路由是**判据本身**（与 `hc_route_for` 同一个出处），
   显示层不复刻它（踩坑 132）。
2. **指纹是上一次的**。`hc_leaf_*` 只在握手**成功**之后写，失败路径一次都不清 ——
   于是「这一次没看到任何证书」被印成「服务端 leaf SHA-256 = <上一个站点的证书>」。
   修法：`hc_connect` 的第一件事把观测账清零，`hc_leaf_*` 从此只表示**这一次**看到了
   什么；报告里没有就如实说「本次握手没有拿到任何证书（对端在 TLS 应答之前就断了）」。

顺带把这一档的**下一步**分开：直连时「中间设备改写 TLS」仍是主嫌；经代理时点明
「隧道多半被对端掐断」，并给出 `--no-proxy` 直连对照这一条判据 —— 同一个错误码，
两种现场，两种修法。

**判据两侧**（都钉在产品代码上，不是复刻品）：

| 门禁 | 判据 |
|---|---|
| `make proxy-selftest`（`st_proxy` 的现地假代理轮，新增第 5 步） | 假代理收下 CONNECT、回 200、读完客户端的第一个 TLS 记录就掐断 ⇒ 客户端必须报**握手失败**；种进去的「上一次指纹」必须被清零；`hc_last_route_now()` 必须是隧道；`hpx_target_*` 是真目标而 `hc_target_*` 是代理（两者确实不同 —— 这就是报告必须分开印的理由） |
| `make e2e-proxy`（新增 ⑥b 反腿，真二进制） | `mock_proxy.py --tunnel-drop` 起一条掐断腿：退出码 2、文案含 `目标 = mock-proxy-e2e.invalid:443`、含 `（经代理 127.0.0.1:<port>）`、含「隧道多半被对端掐断」、**不含** `leaf SHA-256` |

**防假绿对照（两次都真做过）**：

① 删掉 `hc_connect` 里那行 `hc_leaf_n = 0;` ⇒ `proxy-selftest` 红在
「失败那一次还留着上一次的 leaf 指纹」；
② 删掉 `hc_last_route = route[0];` ⇒ 红在「这一次走的路由不是隧道」；
③ 把 `agent_target_line` 退回只看 `hc_target_*` ⇒ `e2e-proxy` 红，而且打印出来的正是
用户屏幕上那一段（`目标 = 127.0.0.1:<代理端口>`）—— 复现与判据同源。

**为什么指纹那条要用测试钩子**（`hc_note_leaf_for_test`，产品路径从不调它）：要造一次
**成功**的 TLS 握手得先搬一台 TLS 服务端进自测，而判据本来只需要「上一次的观测」这个
**初值**。不种而直接断言 0 是假绿 —— 那个 0 从初始化就是 0，删掉清账那行照样绿。

**边界（明确不做）**：不改这一档的**可重试性**（握手仍归「不可重试」：直连时它是确定性
的配置/证书问题）；经代理隧道被掐断在分类上仍是这一档 —— 要把它判成瞬时错得先能证明
「一个字节都没回来」，而 `lib/tls` 的握手失败不区分「没读到」与「读到垃圾」，
猜出来的瞬时错会让确定性的坏配置被无限重发。报告把两条路分开说清，交给人判断。

### 19.20 P96：**所有**没收完的回合都自动继续 + goal 续跑能被 esc 叫停

**用户报的两件事**（原话）：①「改出所有自动继续，直到成功或者用户主动中断」—— P94
（§19.18）只对「模型空响应」开闸、出厂只续 2 次，用户要的是「所有失败都续，一直续到成功
或者我按停」；②「顺手修复 goal 激活后 esc 中断不了」。

**第一件：闸门放开到所有失败，预算改成不限。**

| 要素 | P94 | P96 |
|---|---|---|
| 哪些失败续 | 只有「模型空响应」且同一步重发额度用尽 | **所有没收完的回合**：协议错（401/4xx、坏 payload、步数熔断、上下文压不动）、传输错（DNS / 握手 / 证书这类本身不重试的）、工具错、**有正文的** token 上限截断、空响应 |
| 哪些不续 | 其余全部 | `AGENT_OK`（跑完了）、`AGENT_INTERRUPTED`（人按了 esc / ctrl+c）、`AGENT_USAGE`、**没产出正文的**截断（再发只是重复花同一笔钱 —— 那一档该调的是 `--max-tokens`） |
| 预算 | 出厂 2 次 | 出厂**不限次数**（`TURN_RETRY_MAX = RTX_UNLIMITED`）；`--turn-retry-max N` / `UYA_AGENT_TURN_RETRY_MAX` 给脚本一个出口，`0` = 一次都不续（逐字节回到 P94 之前） |
| 谁不享受 | — | **非交互进程**（管道 / CI / 子代理）：没人能叫停的地方不续（与 `agent_goal_drive` 的「只在有人在键盘前的前台会话里跑」同一条纪律）。显式给过 `--turn-retry-max` 就听人的 |

判据仍然只有一份（`ag_turn_retry.uya::tr_should`），扩的是**入口集合**而不是散点补丁。
两条边界是硬的：人已经要停（`tui_abort_state() != NONE`，含 ctrl+d / `/exit`）与
`AGENT_INTERRUPTED` —— 一个字节都不再发；退避期间照旧 `agent_rtx_wait` 每 ≤50 ms 服务
键盘，esc 当场收口。

**为什么「一直续到成功」不等于「无限空转」**：① 每续一次都在屏幕上说清原因 ——
`[turn-retry] <为什么>——自动替你打一句「继续」再跑一回合（第 N 次，不限次数，backoff=…s；
esc/ctrl+c 可停）`，会话日志的 `turn/retry` 里还带 `rc` 与机器名 `reason`，人一眼能看出
它在同一个错上转；② 默认只在「有键盘可停」的会话里续，CI 里默认不动；③ 停止永远只有
一键（esc / ctrl+c），不靠等预算用尽。

**第二件：goal 续跑按 esc 停不下来**（两处，都在 `agent_goal_drive`）：

1. **中断意图被自己擦掉**。驱动器最前面那道闸门只认 `TUI_ABORT_QUIT`，`TUI_ABORT_TURN`
   直接掉进后半段的 `tui_interrupt_clear()` —— 人刚按的 esc 被当成「上一轮遗留」清掉，
   下一圈照常开轮。修法：`TURN` 单独成一条闸门 —— `goal_disarm` 收授权、说一句「已停下
   自动续跑（esc 叫停；/goal resume 接着跑）」、**把意图消费掉**再返回。消费是对的：
   不清的话下一个用户回合会在第一个 step 边界被它当场打断。
2. **「中断不算异常」这条老规矩本身就错**。P58 收口时把 `AGENT_INTERRUPTED` 当「人只是
   停下当前这一轮，目标该留着」⇒ 授权不动 ⇒ 主循环下一圈立刻又开一轮。屏幕上「已中断
   本回合」与「自动续跑一轮」交替出现，esc 形同虚设。修法：中断**就是**人叫停续跑 ——
   `goal_disarm` 收掉授权，盘上的 `armed` 一起翻成 false（否则面板与 `get_goal` 一直写着
   armed），**phase 保持 active**（目标没被放弃，`/goal resume` 一条命令接着跑）。

**判据（都在离线自测里）**：

| 轮次 | 判据 |
|---|---|
| `turn-retry`（mode 50，P94 的老腿） | 退化两发 ⇒ 回合按错误收场 ⇒ 自动继续 ⇒ 第三发带「继续」⇒ 0 收口；`[turn-retry]` 行写「第 1 次」「**不限次数**」「esc/ctrl+c 可停」，日志 `turn/retry` 一条（attempt=1、maxRetries=-1、rc=3、reason=degenerate-response） |
| `turn-retry-all`（mode 51，本轮新增） | 第一发 **401**（传输层分类表里不可重试的那一档）⇒ 回合级自动继续 ⇒ 第二发请求体里带着整条 `"role":"user","content":"继续"` ⇒ 0 收口。第一发的请求体里**不许**已经出现那条消息（证明注入发生在失败之后）；日志 `reason=protocol-error` |
| `goal-cmd` 的 K10 段（本轮新增） | 直接调驱动器本体：`/goal …` 建目标（授权打开）→ `tui_abort_note_scroll(TURN)` 模拟 esc ⇒ `agent_goal_drive` 必须返回 false（没开轮）、进程本地授权收掉、**盘上 armed=false 且 revision+1**、phase 仍是 active、**中断意图被消费**（`tui_abort_state()==NONE`） |

**防假绿对照（两次都真做过）**：

① 把 `tr_should` 退回「必须有提示位」（= P94 的「只认空响应」）⇒ `turn-retry-all` 整片红：
转录侧的 `[turn-retry]` 五条判据、日志侧四条、退出码 `agent_run returned 3`；
② 把 K10 那条闸门里的 `goal_disarm(cfg)` 删掉（只留回执）⇒ `goal-cmd` 红在「进程本地的
授权没被收掉」「盘上的 armed 还开着」「收了授权却没 +1 revision」。

**边界（明确不做）**：不把「没产出正文的截断」算进自动继续；不在退避里抢 steer 的顺序
（退避期间敲进来的正文照旧进 steer 收件箱，下一个 step 边界生效）；不做「无限次 + 非交互」
（那在 CI 里就是挂死）；不改 `AGENT_INTERRUPTED` 的退出码语义（130 仍是「人叫停」）；
除 `/goal resume` 之外不新增第二条重新授权自动续跑的路（人在键盘前按一次键，比让机器
猜「他是不是还想让它跑」便宜得多）。
