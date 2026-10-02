# uya-agent — 纯 Uya 写的极简 CLI 编程 agent

一个**只用 Uya 源码**实现的命令行编程 agent：给它一句话任务，它自己看文件、改文件、跑命令，
多轮 loop 直到给出结论。全部代码 9 个 `.uya` 文件，**不引入任何 C 代码、`@c_import` 或其它语言**，
只依赖 Uya 语言与随编译器分发的标准库。

**P1–P9 已完成**：LLM 交互是**流式 SSE**（`stream:true` + `stream_options.include_usage`），
增量 chunked 解码 + SSE 分帧 + `tool_calls` 按 `index` 分片累积；消息协议是**严格工具协议**
（`assistant.tool_calls` 原样回灌 + 每条结果一条 `role:"tool"` + `tool_call_id`）；
交互界面是**真 TTY**（termios raw + 行编辑器），流式期间可打断、可继续输入、可续跑；
会话**落盘可恢复**（`--continue` / `--resume` / `/sessions`，跨进程实测「记住 4271 → 下一个进程问它 → 答 4271」）；
**直接读 DSH 的设置文件**：`--print-config` 显示 base_url / model / api_key / contextWindow 全部来自
`~/.dsh`，实测**零参数启动**（只额外给信任策略）能直接跑通真机网关；
**工具改用 DSH 标准模式的原名**（`read`/`write`/`edit`/`glob`/`grep`/`bash`/`job_*`），
实现了 DSH 的文件观察策略（read-before-write / 版本守卫）与**后台任务**
（`bash run_in_background` → `job_list` / `job_output` / `job_kill`），
子进程会拿到 `DSH_*` 环境；system prompt 改为**分节装配**（persona 从 DSH preset 读、
`{{model}}`/`{{cwd}}` 变量替换、空节丢弃、`\n\n` 连接），并注入 AGENTS.md 与运行时上下文，
配上 `todo_write` / `exit_plan_mode` / `ask_user_question`；**上下文管理**也齐了：
tool 结果超 8192 码点自动剪枝，压力超过窗口 80% 时自动压缩成 checkpoint（真机实测触发过）。
`--no-stream` / `--compat-fold` 保留两条回退路径。

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
| `--no-stream` | 关闭流式，回退一次性响应（老端点兼容） |
| REPL 命令 | `/help` `/continue` `/status` `/compact` `/plan` `/sessions` `/resume <id>` `/new` `/exit` |
| `--agent-home DIR` | 会话与索引的根目录（默认 `~/.uya-agent`） |
| `--continue` | 接着当前目录最近一条会话继续 |
| `--resume ID` | 恢复指定会话（`ID` 或 `last`） |
| `--list-sessions` | 列出本机会话后退出 |
| `--no-save` | 不写会话日志 |
| `--dsh-home DIR` | DSH 用户目录（默认 `$DSH_HOME` 或 `~/.dsh`） |
| `--no-dsh-config` | 完全不读 DSH 设置 |
| `--strict-dsh-config` | 读不到 DSH 设置就报错退出 |
| `--print-config` | 打印生效配置与来源后退出 |
| `--yaml-dump FILE` | 打印该 YAML 的解析结果（诊断） |
| `--plan` | 以 plan 模式启动（先出计划、批准后再执行） |
| `--no-compact` | 关闭自动上下文压缩 |
| `--context-window N` | 压缩判定的窗口（默认取 DSH 模型条目） |
| `--dsh-root DIR` | packaged preset 根（读 persona / plan 段文案） |
| `--dry-run` | 只组装请求并打印（不可打印字节转义成 `\xNN`，排查脏字节） |
| `--compat-fold` | 工具结果折叠成一条 user 消息（旧协议） |
| `--no-stream-options` | 不发送 `stream_options.include_usage` |
| `--show-reasoning` | 把 `reasoning_content` 打到 stderr |
| `--show-usage` | 每轮打印 token 用量（in/out/cache/reasoning） |
| `--max-tokens N` | 发送 `max_tokens`（默认不发送） |
| `--temperature N` | 发送 `temperature`（默认不发送，对齐 DSH） |
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
src/bufx.uya      通用字节层：Buf 生命周期、拼接、十进制/十六进制、UTF-8 码点计数与切片
src/jsonx.uya     JSON：JsonWriter 组装请求；JsonValue 导航取值；字符串反转义（关键，见下）
src/httpc.uya     传输层：URL 解析、DNS+TCP、TLS 会话、请求构造、非流式响应解析、leaf 指纹
src/httpstream.uya 流式传输：请求发出后只读到响应头，body 按需增量解码（chunked 状态机）
src/sse.uya       SSE 分帧：字段行、多行 data、空行 dispatch、注释、未终结帧不冲刷
src/llm.uya       请求/响应协议：消息组装、流式 delta 装配（content/reasoning/tool_calls）、
                  usage 合并、finish_reason 映射、非流式响应 → 同一 ChatOut
src/tools.uya     三个工具：read_file / write_file / run_shell
src/tty.uya       终端层：termios raw 模式、行编辑器（历史/光标/Delete/词删除）、
                  单行渲染协议（擦输入行→写→重画）、提示符即状态显示
src/inbox.uya     输入收件箱：steer（运行中输入的文本，step 边界领取）+ keepInbox 语义
src/yamlcfg.uya   自带 YAML 子集解析器：去注释（块标量/引号感知）、中和 `!!tag`、
                  block/flow 映射与序列、`|`/`>` 块标量、跨行 flow 集合、节点池树 + 导航
src/fsx.uya       文件工具：路径解析（可选工作区守卫）、(mtime,size) 版本、观察状态表、
                  read（窗口 + 行号 + 三种 footer + 行长/字节上限）、write（createIfAbsent /
                  replaceIfVersion）、edit（唯一匹配 / replace_all）
src/shellx.uya    bash 工具：bash -c、workdir、timeoutMs、run_in_background、stdout/stderr 分开收、
                  结果标记（[exit code: N] / [timed out after Nms] / [killed by signal: N]）、DSH_* 环境注入
src/jobs.uya      后台任务表：注册/增量输出（保留内存尾部 1 MiB）/状态机（running/completed/killed）、
                  job_list / job_output（wait + timeout_ms）/ job_kill
src/search.uya    glob / grep：rg 子进程（--files / --json）、VCS 目录排除、条数与行长上限
src/dshcfg.uya    读 DSH 设置：$DSH_HOME 解析、settings.yaml 模型路线（agent-default-model →
                  provider 的 baseURL/apiKeyEnv/models[]）、.credentials.yaml、.env 兜底、
                  permission→confine、uya-agent.tls 命名空间
src/compact.uya   上下文管理：tool 结果剪枝（8192/4096/1024 **码点**，只在构请求时生效）、
                  压力判定（prompt_tokens，退化时按字节/4 估）、摘要提示词、checkpoint 替换
src/prompt.uya    system prompt 分节装配（order 排序 / 空节丢弃 / `\n\n` 连接 / 变量替换）、
                  persona 与 plan 段从 DSH preset 读取（读不到用内置默认）、运行时上下文 user 消息
src/instr.uya     AGENTS.md / CLAUDE.md 发现（用户全局 → 项目根 → cwd，由广到窄）、
                  预算截断（65536 字节，从最广端丢）、`<system-reminder>` 渲染
src/todo.uya      todo_write：整表替换、content/去重/状态校验、计数回显
src/plan.uya      plan 模式状态机 + exit_plan_mode（非 plan 模式报错、`# ` 开头的计划、CLI 审批）
src/askuser.uya   ask_user_question：交互模式复用行编辑器，非交互读一行，EOF 时回「无回答」
src/session.uya   会话日志：路径规范化、id 生成（/dev/urandom→uuid）、header/事件序列化与追加写、
                  索引、读取与崩溃尾部裁剪、按 id/最近查找、括号配平的数组提取
src/agent.uya     CLI、环境变量、消息历史、请求组装、主循环（流式/非流式）、工具分发、
                  交互式 REPL（中断/steer//continue/会话命令）、会话事件记录与恢复
src/selftest.uya  --selftest 的 mock LLM（含 SSE 受控切分）+ 15 轮断言 + --probe
```

### 上下文管理（P9，对齐 DSH compaction-basic + tool-result-pruner）

* **tool 结果剪枝**：文本超过 **8192 码点**时替换成「前 4096 码点 + 标记 + 后 1024 码点」，
  标记逐字对齐 DSH：`\n\n[... tool result middle pruned ...]\n\n`。
  剪枝**只在构请求时生效**（历史不动），所以天然幂等；按码点计数，不会切坏 UTF-8。
* **自动压缩**：每个 step 边界测压（压力 = 最近一次响应的 `prompt_tokens`，拿不到就按字节/4 估），
  达到 `floor(contextWindow × 0.8)` 就把**较早的一段**压成 checkpoint：
  - 保留最近约 16% 的原文（至少 2 条），且**不拆散** assistant(tool_calls) 与它的 tool 结果、
    保留段也不能以孤儿 tool 结果开头；
  - 摘要走一次独立模型调用，提示词用 DSH 的原文头部与八个小节结构（Primary Request and Intent /
    Key Technical Concepts / Files and Code / Errors and Fixes / Pending Jobs / Current Work /
    Next Step / Critical Context）；
  - 摘要**必须比被遮蔽内容短**，否则放弃（DSH 的硬规则）；
  - 替换成 `[system 原文] + [CHECKPOINT_PREAMBLE + <compacted-summary>…</compacted-summary>] + [保留的尾部]`。
* 触发开关：`--no-compact` 关掉自动压缩，`--context-window N` 覆盖窗口（默认取 DSH 模型条目），
  REPL 里 `/compact` 手动触发一次。
* 已知偏离：DSH 还有 overflow 兜底重试与 retries 配置，这里只做「一次尝试」。

### 提示词与上下文状态（P8）

* **system prompt 分节装配**：persona（order 0）→ plan 策略（order 50，仅 plan 模式激活时）→
  工具引导（100–106）→ 本项目的 Uya 语言要点；空节丢弃、`\n\n` 连接、只有一条 system 消息。
  persona 文案优先从 `<DSH_ROOT>/config/agent-presets/standard/agent.cordis.yml` 读（`--dsh-root`
  或 `$UYA_AGENT_DSH_ROOT` 指定根），读不到就用标准 preset 的内置默认值（逐字一致）；
  `{{model}}` / `{{cwd}}` 做变量替换。
* **运行时上下文**是一条独立的 user 消息：`Current runtime context. This snapshot supersedes
  earlier runtime-context snapshots.` + 各节（文件策略、plan 状态）。
* **AGENTS.md**：用户全局 `$DSH_HOME/AGENTS.md` 最先，然后从项目根（最近的 `.git`）到 cwd 逐级，
  每个目录按 `AGENTS.md → CLAUDE.md → AGENTS.local.md → CLAUDE.local.md`；整段预算 65536 字节，
  超预算从最广端丢弃，渲染成 `<system-reminder>…</system-reminder>` 的 user 消息（首次请求前注入）。
* **todo_write**：整表替换；回显 `Updated todo list: N pending, N in progress, N completed.`；
  重复 content / 空 content / 非法 status 都会被拒；列表不回注上下文（与 DSH 一致）。
* **plan 模式**：`exit_plan_mode` 两种模式都注册（工具目录稳定），非 plan 模式调用报
  `exit_plan_mode is only available in plan mode`，计划必须以 `# ` 开头；批准走 CLI 问答
  （`y/N`），批准后退出 plan 模式。`--plan` 以 plan 模式启动，REPL 里 `/plan` 切换。
* **ask_user_question**：交互模式下复用行编辑器（带选项编号），非交互读一行；
  读到 EOF 时返回 `(no answer channel: the user could not be asked)` 而不是挂死。

### bash 与后台任务（P7，对齐 DSH tool-bash + tool-jobs）

| 工具 | 参数 | 行为要点 |
|---|---|---|
| `bash` | `command`(必), `description`(必), `timeoutMs`, `workdir`, `run_in_background` | `bash -c`；stdout 与 stderr **分开收**，stderr 归到 `[stderr]` 段；尾部标记 `[exit code: N]`、`[timed out after Nms]`、`[killed by signal: N]`、`[output truncated]`；完全无输出 → `(no output)`；后台调用立刻回 `started background job job-N` |
| `job_list` | — | `<job-id> [bash] <status> — <描述>`；空 → `(no background jobs)` |
| `job_output` | `job_id`(必), `wait`, `timeout_ms` | **增量**语义（只给上次读之后的新输出）；`wait=true` 最多等 30 s（上限 600 s）；无新输出 → `(no new output)`；尾部 `[status: running\|completed\|killed, exit N]` |
| `job_kill` | `job_id`(必), `reason` | 运行中 → `requested cancellation of job N`；已结束 → `job N had already finished [status: …]` |

* 超时是**墙钟**的，且一定会 SIGKILL 进程组里的子进程；被信号杀掉时退出码报 `128+信号号`。
* 每个子进程都会拿到 `DSH_HOME`、`DSH_SHELL=1`、`DSH_SESSION_ID`、`DSH_SESSION_JSONL`
  （继承来的旧 `DSH_*` 会先清掉），与 DSH 的 shell-env 约定一致。
* 任务输出保留**内存尾部 1 MiB**，超出打 `[output truncated]`（DSH 会落盘 spill，记为偏离）。

### 文件系统工具（P6，对齐 DSH tool-fs + fs-observation-policy）

| 工具 | 参数 | 行为要点 |
|---|---|---|
| `read` | `file_path`(必), `offset`(1 基, 默认 1), `limit`(默认 2000, 上限 2000) | 逐行加行号，包在 `<path>/<type>file</type>/<content>` 里；footer 三种：`(End of file - total N lines)` / `(Showing lines a-b of T. Use offset=b+1 to continue.)` / `(Output capped. Showing lines a-b. …)`；行长 > 2000 字符截断并标 `... (line truncated to 2000 chars)`；一次最多 51200 字节 |
| `write` | `file_path`(必), `content`(必) | **观察策略**：文件存在但**没读过** → 拒绝（`write requires reading "x" first — read the file, then retry`）；读过但**版本变了** → `FS_STALE_VERSION … re-read the file, then retry`；成功回 `Created file` / `Updated file` |
| `edit` | `file_path`, `old_string`(非空), `new_string`, `replace_all`(默认 false) | 必须**先 read**（任何窗口）；匹配必须唯一（否则报 `appears N times`）；成功回 `The file X has been updated successfully.` / `… All occurrences were successfully replaced.` |
| `glob` | `pattern`(必), `path`(可选目录) | `rg --files --glob <p> --sort=modified --no-ignore --hidden` + 排除 `.git/.svn/.hg/.bzr/.jj/.sl`；默认显示前 100 条；空 → `No files found` |
| `grep` | `pattern`(必), `path`(可选), `include`(可选，一个正向 glob) | `rg --json` 逐行解析（不做冒号切分），按文件分组输出 `Line N: 预览`；最多 250 条、每行预览 2000 字节（超出标 ` (line truncated)`）；`include` 拒绝以 `!` 开头或逗号列表；空 → `No matches found` |

* **版本**取 `(mtime, mtime_nsec, size)`；观察状态只在进程内（与 DSH 的已知限制一致：恢复会话后要重新 read）。
* **路径守卫**默认关闭（对齐 DSH 的 `danger-full-access`）；`--confine` 打开后拒绝绝对路径与 `..`。
  preset 的 `permission.defaultPreset` 会决定这个默认值（见 P5）。
* 观察策略现在是硬约束：**没读过的已存在文件不能直接覆盖**，这会让「多轮自测」暴露出
  清理脚本的 bug —— 本轮就靠它抓到了 `ws_prepare` 里少补 NUL 的 `unlink`（见踩坑 30）。

### DSH 设置文件兼容（P5）

* 读哪些文件：`$DSH_HOME/settings.yaml`（模型路线、preset 选择、权限预设）、
  `$DSH_HOME/.credentials.yaml`（`refs: {NAME: secret}`）、`<cwd>/.env`、`$DSH_HOME/.env`。
  `$DSH_HOME` = `--dsh-home` > `$DSH_HOME` > `$HOME/.dsh`。
* 解析出的东西：`base_url`（provider 的 `baseURL`）、`model`、`reasoning_effort`、
  `context_window` / `max_tokens` / `input_image`（模型条目）、`api_key`
  （按 `apiKeyEnv` 走「进程环境 > `.credentials.yaml` > `<cwd>/.env` > `$DSH_HOME/.env`」四层）、
  以及 `permission.defaultPreset → confine`（`danger-full-access` 不限制，其它预设启用工作区守卫）。
* 优先级：**CLI > `UYA_AGENT_*` 环境变量 > DSH 设置 > 内置默认**，`--print-config` 逐项打印来源
  （`default` / `dsh-settings` / `env` / `cli`），敏感值打码成 `sk-…abcd`。
  `--no-dsh-config` 完全关闭，`--strict-dsh-config` 读不到就报错退出。
* TLS 信任策略也可以写进同一个设置文件（DSH 会忽略不认识的节）：
  ```yaml
  uya-agent:
    tls: { verify: pin, pin: <leaf sha256> }   # 或 verify: none
  ```
  这样「零参数启动」才真的可用 —— 默认 `chain` 在真实站点上过不去（见第 5 节）。
* `--yaml-dump FILE` 可以打印解析出来的配置树，排查「设置没生效」很有用。
* 为什么自带 YAML 解析器而不是用 `std.yaml`：见踩坑第 26 条。

### 会话持久化与恢复（P4）

* 布局（沿用 DSH 形状，**不压缩**）：
  `<agent-home>/sessions/--<normalized-cwd>--/<session-id>/session.jsonl` + `<agent-home>/index.jsonl`。
  `<agent-home>` = `--agent-home` > `$UYA_AGENT_HOME` > `$HOME/.uya-agent`。
* 首行 header（`type/version/id/createdAt/cwd/delegationDepth/agentPreset/model/provider`），
  之后每行一个 `{"type":…,"seq":N,"time":N,"data":{…}}`，`seq` 从 0 连续递增，追加-only。
* 事件词表：`user/message`、`assistant/message`（含 `tool_calls` 原文）、`tool/call`、`tool/result`、
  `turn/start|end`、`step/start`、`session/title`。**续写已有会话时不重复写 header**，
  `seq` 接着已有最大值往下走（跨进程实测连续）。
* **崩溃恢复**：最后一行不完整（没有换行结尾）时丢弃它并在 stderr 告警 —— 对应 DSH 的
  「保留有效尾部工作」。
* 恢复时会**原样还原** `tool_calls`（用括号配平提取数组文本，不重新序列化，避免 arguments 二次转义），
  因此恢复出来的历史可以直接再序列化成合法请求（自测断言了 `tool_call_id` 与 `tool_calls` 都在）。
* 入口：`--continue`（当前目录最近一条）、`--resume <id|last>`、`--list-sessions`、`--no-save`；
  REPL 里 `/sessions`、`/resume <id>`、`/new`。
* 不持久化（恢复时重建）：AGENTS.md 与技能目录、运行时上下文、工具 schema；
  文件观察版本表在恢复后为空（与 DSH 已知限制一致）。

### TTY 交互（P3）

* **raw 模式**：`ioctl(0, TCGETS)` 成功即 TTY（libc 没导出 `isatty`）；清
  `ICANON|ECHO|ISIG|IEXTEN` 与 `IXON|ICRNL`，`VMIN=1/VTIME=0`，**保留 OPOST**
  （否则项目里大量 `
` 输出会变阶梯状）。退出（正常返回 / 错误返回 / Ctrl-D / `/exit`）
  都会恢复 termios。
* **按键**：

  | 键 | 回合运行中 | 空闲（提示符） |
  |---|---|---|
  | 回车 | 文本进 steer 收件箱，**下一个 step 边界**作为普通 user 消息被采纳 | 作为新一轮任务 |
  | Ctrl-C | 中断本回合：停止读取流、丢弃未派发的 tool_calls、只保留 content 的非空白前缀、历史保留 | 输入非空→清行；空行→提示一次，2 秒内再按→退出 |
  | Ctrl-D | 忽略 | 空行→退出；非空→删光标处字符 |
  | Esc | 同 Ctrl-C（`ESC[` 前缀识别为方向键序列） | 清行 |
  | ↑/↓ | 历史导航（32 条） | 同左 |
  | Ctrl-U / Ctrl-W / Ctrl-L | 清行 / 删词 / 重绘 | 同左 |
  | Backspace/Del/←/→/Home/End | 行编辑 | 同左 |

* **事件与行的顺序不变量**（踩过坑）：事件是排队的，而「正在编辑的行」只有一份，
  所以取用顺序必须是 **已排队事件 → pend（一次读取里剩下的字节）→ 读键盘**；
  反过来做会让 `read` 一次拿到的多行（粘贴）粘成一行，并让事件与行内容错位。
* **slash 命令**：`/help`、`/continue`（带历史再跑一轮）、`/status`、`/exit`。
  运行中输入的 slash 命令也按命令处理（用户并不知道回合是否结束）。
* **中断语义对齐 DSH**：流式期间中断 → assistant 消息只保留非空白前缀且**不含 tool_calls**；
  工具执行期间中断 → 已派发的补 `aborted by user`、未派发的补 `aborted before dispatch`。
  回合一结束就回到提示符，历史完整，`/continue` 或直接输入都能接着跑；
  交互模式下 `--max-steps` 只结束回合不杀进程（一次性运行仍返回退出码 3）。
* **非 TTY 自动回退**：stdin 不是终端时走行式 REPL（同一份 history 连续对话）。
* **已知限制**：被 SIGKILL/SIGTERM 打断时终端可能停在 raw 模式，用 `reset` / `stty sane` 恢复。
  原因是 uya 0.10.1 的 `libc.signal.signal` 注册的处理器一被调用就 SIGSEGV
  （最小复现：handler 里只做 `sys_write` + `sys_exit`，`kill -TERM` 后进程以 139 退出），
  所以干脆不装信号处理器 —— 详见踩坑第 21 条。

### 流式协议要点（P1）

* `hc_open()` 只读到 `\r\n\r\n` 就返回，`hc_fill()` 每次读一段网络并推进解码，返回
  `1=有新体字节 / 2=读到数据但还没解出体 / 0=结束`；调用方靠它决定继续读还是收工。
* chunked 解码是**状态机**（SIZE→DATA→CRLF→TRAILER→DONE），chunk 长度行、CRLF、data 行、
  JSON 字符串都可能被 TCP 切开，自测用「37 字节一个 chunk + 每 19 字节写一次 + 2ms 间隔」
  把这种切分钉死。
* `tool_calls` 按 wire `index` 归并：首帧带 `id`/`function.name`，后续帧只有 `arguments` 片段；
  片段**逐个反转义再拼接**（服务端每个片段都是合法 JSON 字符串，因此与整体解码等价）。
* `finish_reason=length` 时**丢弃全部 tool_calls**（参数可能是半截的），对齐 DSH。
* 缺 `[DONE]` 视为流被截断（`STREAM_CLOSED`），坏 JSON 帧报 `MALFORMED_RESPONSE` 并把
  payload 头部带出来。
* `usage` 的缓存读数只在**本帧给了明细**时更新：网关尾随的 usage-only 帧常常只带
  `prompt_tokens`/`completion_tokens`，无条件覆盖会把已拿到的 `cached_tokens` 清成 0。

### 严格工具协议要点（P2）

* assistant 消息连同 `tool_calls` **原样回灌**（`arguments` 用 `jw_raw` 内联，绝不二次转义），
  随后每个调用一条 `role:"tool"` + `tool_call_id`；空结果发 `"(no output)"`。
* 历史裁剪**不拆散配对**：丢掉带 `tool_calls` 的 assistant 时，紧随其后的 tool 消息一起丢；
  历史不允许以 tool 消息开头（否则端点会 400）。
* `--compat-fold` 回到旧协议（工具结果折叠成一条 user 消息），`--no-stream` 回到一次性响应；
  两条路径共用同一套收尾逻辑（`agent_finish_step`）。

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
16. **`&"text"[0:n]` 是切片不是指针**：把它传给 `&const byte` 形参拿到的是**切片结构体的地址**，
    不是字符内容。`llm.uya` 里比较 `finish_reason` 时踩过这个坑：编译通过、运行时不相等，
    表现为「所有 finish_reason 都变成 error」。要传 C 指针就传 `s.ptr`，或者用
    `bufx_eq_cstr(ptr, len, "stop")` 这种拿字面量当 C 字符串的辅助函数。
17. **checker 不会抓「对已是指针的参数再取址」**：`fn f(o: &const T)` 里写 `g(&o)` 会得到 `**T`，
    Uya 类型检查通过、**C 编译阶段**才报 `incompatible pointer type`。移动函数体时要特别小心。
18. **数组字面量初始化会带上结尾 `0`**：`var m: [byte: 9] = "got-term\n";` 会被拒
    （"容量不足：至少需要 N>=10"）。字面量初始化要求 `N >= 字符数 + 1`。
19. **别对已经是指针的参数再取址**（同 17 条，但这次是 `**History`）：把一次性的
    `agent_run` 拆出 `agent_turn_loop(cfg, h: &History)` 之后，函数体里遗留的
    `&h` 变成了 `**History` —— checker 通过、C 只给 warning、运行**段错误**。
    移动/抽取函数体时，务必把「本地变量 → 参数引用」的取址全部清一遍。
20. **信号处理器在 uya 0.10.1 上不可用**：`libc.signal.signal(SIGTERM, &handler as &void)`
    注册的处理器一旦被调用就 SIGSEGV（最小复现：handler 只做 `sys_write` + `sys_exit`，
    `kill -TERM` 后以 139 退出）。想要「被信号杀掉时恢复终端」的功能，目前只能不做。
21. **`lib/tls` 会把握手全过程写到 fd 2**（`https_debug`/`hs_debug`）：CLI 里得在发请求期间把
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
| `tools` | 一封 tool_calls 里塞 4 个调用：`write_file`（**content 带换行与引号**）、`read_file` 读回、`read_file ../escape.txt`（必须被路径守卫拒绝）、`run_shell sleep 5 timeout=300`（必须被 SIGKILL 并回 `(timeout, killed)`）；请求里内容必须只被转义一次；落盘 `esc.txt` 逐字节校验 |
| `noshell-nostream` | `--no-stream` 回归：同一份 mock 数据走非流式路径 |
| `shell-fold` | `--compat-fold` 回归：请求里必须有折叠头、且不出现 `role:"tool"` |
| `stream-basic` | SSE 分帧 + content 累积 + usage 合并（含尾随 usage-only 帧不带明细） |
| `stream-tools` | `tool_calls` 按 index 交错分片累积（两个调用、arguments 被切成 4 段） |
| `stream-nodone` | 缺 `[DONE]` → `STREAM_CLOSED`，但已收内容仍在 |
| `stream-badjson` | 坏 JSON 帧 → `MALFORMED_RESPONSE` + payload 头部，之前的内容保留 |
| `stream-length` | `finish_reason=length` → max-tokens，reasoning 正常累积 |
| `steer` | 回合运行中输入的文本，必须在**下一个 step 的请求**里出现（mock 断言 `STEER-MARKER`） |
| `interrupt` | 预置 Ctrl-C：回合以 `AGENT_INTERRUPTED` 结束、工具**未派发**、只发生一次请求 |
| `tty-editor` | termios 布局(60B)/raw 位运算；行编辑（插入/退格/左右/Delete/Home/End/词删除）、
一次喂入多行拆成多个提交、分片转义序列、裸 ESC 判定、历史上下翻、中断前缀裁剪 |
| `compact-prune` | 让 bash 产生 20000 字符输出 → 断言请求里出现剪枝标记、完整中段已消失 |
| `compact-auto` | 小窗口（200）强制触发：工具轮 → **摘要请求**（断言提示词模板）→ 压缩后的请求里
必须出现 `automatically generated checkpoint` 与 `<compacted-summary>` |
| `prompt-todo-plan` | 第一轮断言 system prompt（persona 变量替换、`{{cwd}}`、工具引导段）、运行时上下文
user 消息、AGENTS.md 注入，以及**请求里没有 NUL 字节**；第二轮断言 todo 计数回显、
重复 content 被拒、`exit_plan_mode` 在非 plan 模式报错、计划必须以 `# ` 开头 |
| `bash-jobs` | 一轮 6 个调用：后台短任务 / 后台长任务 / `job_list` / `job_output(wait=true)` 等到
`BG-DONE` / `job_kill` 取消长任务 / 前台静默命令 → 第二轮断言全部结果文本 |
| `fs-tools` | 一轮内 10 个文件工具调用：write（未读→拒）/ read（窗口+footer）/ write（读后覆盖）/
edit（多匹配→拒、成功、找不到）/ glob（两条路径）/ grep（命中两行、无命中）/ glob（无文件）→
第二轮断言全部结果文本，并逐字节校验最终落盘内容（含 edit 后的 `ALPHA one`） |
| `dsh-config` | 假 `$DSH_HOME`：settings.yaml（block+flow 混排、行尾注释、跨行 flow、`|` 块标量、
`!!js` 标签）+ `.credentials.yaml` → 断言 provider/model/baseURL/apiKeyEnv/凭据来源四层/
contextWindow/maxTokens/input image/reasoningEffort/`permission→confine`/`uya-agent.tls` 命名空间；
再断言 YAML 预处理（注释去掉、块标量里的 `#` 保留、`!!js` 中和）；最后若存在真实 `~/.dsh` 就顺带校验一次 |
| `session-log` | 写 header/事件 → 读回逐行校验（转义层级、`tool_calls` 数组提取、`callId`）；
手工追加半条记录 → 断言丢弃并标记 `dropped_tail`；用日志重建历史 → 断言角色/`tool_call_id`
且能重新组装成合法请求；索引与按 id / 最近查找 |

**P1/P2 的验收事实**（2026-10-02）：

* 5 轮流式轮 + 6 轮既有轮全部通过；前一阶段的所有断言（tools schema、越权路径、
  超时 SIGKILL、401、熔断）在流式路径下同样成立。
* 严格协议在**请求字节**上被断言：`"role":"assistant"` + `"tool_calls"` 原样回灌、
  `"id":"call_…"` 保留、`"tool_call_id"` 条数与调用数一致（shell 2 / no-shell 1 / tools 4）。
* TTY 交互用**真 pty** 验证（`script -qec`）：进入 raw 模式、banner 干净、一次粘贴
  4 行会分成 4 次提交（任务 → `/help` → `/status` → `/exit`），退出后终端恢复。
* 自动压缩在真机上实测触发过：`--context-window 700` 下跑一个多步任务，
  日志出现 `[compact] 已压缩较早的 2 条消息（pressure=2381 limit=560）`，
  压缩后模型仍正确完成并给出结论。
* 提示词装配在真机上验证过（并因此抓出 getcwd 的 NUL bug）：新 prompt 下模型正常使用
  `glob` 并给出结论；`--dry-run` 现在能看到完整请求体（转义后）且不含 NUL。
* 后台任务在真机上做了冒烟：让它「用 run_in_background 跑 `sleep 2; echo BG-JOB-DONE`，
  再用 job_output(wait=true) 读输出」→ 模型 `bash` → `job_output` 两轮完成，
  回答「输出内容是 `BG-JOB-DONE`（job-1 正常结束，exit 0）」。
* 文件工具在真机上做了冒烟：让它「创建 demo.txt 写三行，然后用 grep 找 banana 在第几行」，
  模型按新工具名一路调用 `write → run_shell → grep`，最后回答「banana 出现在第 2 行」，
  产物 `demo.txt` 内容逐字节符合预期。
* 自测现在是**幂等**的：连续跑两次都 PASS（以前靠「反正覆盖」掩盖了清理失败）。
* DSH 配置兼容做了**零参数启动**验收：在空目录里不传 `--base-url/--model/--api-key`，
  `--print-config` 显示 `base_url/model/api_key/context_window/confine` 的来源全是 `dsh-settings`，
  实际提问「2+2 等于几」得到 `4。`（只额外用环境变量给了 TLS pin，因为默认 `chain` 在真机过不去）。
* 会话恢复做了**跨进程 + 真实模型**验收：进程 1 让它「记住 4271」，进程 2 `--continue`
  带恢复的历史问「我刚才让你记住的数字是多少」→ 回答 **4271**；日志里 header 只有一条、
  `seq` 跨两个进程连续 0…9。
* 真实网关（autodl，`DeepSeek-V4.1-Flash`，pin 模式）跑「创建 hello.uya → 编译 → 运行 → 结论」：
  3 步完成（write_file → run_shell → 结论），stdout 流式输出
  `运行输出：\`Hello, Uya!\`（编译通过，退出码 0）。`，产物 `hello` 是真实 ELF、
  独立运行输出 `Hello, Uya!`；usage 逐轮打印（含 `cache_read=896` 前缀缓存命中）。
| `http401` | mock 回 401 + 错误体：agent 必须打印状态与错误体并退出 3 |
| `max-steps` | mock 每轮都给 tool_calls：agent 必须在 `max_steps` 步后熔断退出 3 |

另外三条独立验收：

```bash
make check                                   # A1 类型检查通过
make build                                   # A2 产出 build/uya-agent
make probe BASE=https://api.deepseek.com/v1  # A4 期望 HTTP 401 + leaf 指纹（无需 key）
DEEPSEEK_API_KEY=... ./build/uya-agent --tls-verify=pin <sha256> "创建 hello.uya，编译并运行它"   # A5 真实端到端
```

**目前状态：A1–A6 全部通过；P1（流式）/P2（严格协议）已完成并通过离线 + 真实网关验收。**

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

* 上下文管理很朴素：整个历史每轮重新序列化，超过 24 条/单条 200 KiB 时丢最老的对话；
  没做 token 计数或智能摘要。
* `read_file` 一次最多 64 KiB；`write_file` 是整文件覆盖，没有 diff/patch 工具。
* 只做 IPv4（标准库 `dns_client_resolve_first_ipv4`），不做 IPv6、不走代理。
* 目标平台是 Linux x86-64（代码里的 syscall/常量按这个平台写）。
* 换到 `uya-0.11`：`tls/https.uya`、`std/json/*`、`x509/verify.uya` 与 0.10 逐字节相同，
  但 `libc/syscall.uya`、`std/runtime/runtime.uya`、`tls/ssl/context.uya` 有差异，需要重新验证
  （`make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...`）。
