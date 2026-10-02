# uya-agent — 纯 Uya 写的极简 CLI 编程 agent

一个**只用 Uya 源码**实现的命令行编程 agent：给它一句话任务，它自己看文件、改文件、跑命令，
多轮 loop 直到给出结论。全部代码 32 个 `.uya` 文件，**不引入任何 C 代码、`@c_import` 或其它语言**，
只依赖 Uya 语言与随编译器分发的标准库。

**P0–P14 全部完成**：LLM 交互是**流式 SSE**（`stream:true` + `stream_options.include_usage`），
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
tool 结果超 8192 码点自动剪枝，压力超过窗口 80% 时自动压缩成 checkpoint（真机实测触发过）；
**技能**（发现 → 目录注入 → `skill` 工具）与**联网搜索**（`web_search`，provider 侧搜索）也接上了，
两者都在真机上跑通过；**子代理一族**（`subagent` / `subagent_fork` / `list_agents` / `subagent_output` /
`send_message` / `interrupt_agent` / `ralph`）与**会话级目标**（`create_goal` / `get_goal` / `update_goal`）
也完成，真机上派生子代理并把结果收回父进程验证过；**workflow** 按既定方案用 **Uya 的 `.ush` 脚本**
（`uya run` 执行）编排子代理，脚本里的钩子**代理回父进程**执行。
最后是收尾：**工具/上下文旋钮由 DSH preset 驱动**（`--print-config` 显示来源与取值）、
**能直接读 DSH 自己的会话**（`--list-dsh-sessions` / `--resume-dsh`，含 zstd 压缩）、
`make e2e` 一条命令跑真实网关（步数默认不限，`STEPS=N` 可显式熔断）。
**P14 把终端转录改成 DSH 内容块**：每次工具调用一行「状态字形 + 标题(关键参数) + 后缀」，
正文是结果首尾若干行、`write`/`edit` 的**行级 diff**、`todo_write` 的清单，
`--quiet` 原样退回旧的最小转录。
`--no-stream` / `--compat-fold` 保留两条回退路径。

```
$ ./build/uya-agent "在当前目录创建 hello.uya，编译并运行它，然后把问候语改成 Hello, DSH!"
[task] 在当前目录创建 hello.uya，编译并运行它，然后把问候语改成 Hello, DSH!

✓ Write(hello.uya) · +4 -0
    + export fn main() i32 {
    +     @println("Hello, Uya!");
    +     return 0;
    + }

✓ Bash(UYA_ROOT=… uya build hello.uya -o hello && ./hello) · exit 0
    make: 进入目录"…/.uyacache"
    cc -c -std=c99 -O0 -fno-builtin -I. hello_part1.c -o hello_part1.o
    … (省略 6 行)
    编译完成：hello
    Hello, Uya!
    [exit code: 0]

✓ Read(hello.uya) · 4 lines
    1: export fn main() i32 {
    2:     @println("Hello, Uya!");
    3:     return 0;
    4: }

✓ Edit(hello.uya) · replaced
      export fn main() i32 {
    -     @println("Hello, Uya!");
    +     @println("Hello, DSH!");
          return 0;
      }

✓ Bash(./hello) · exit 0
    Hello, DSH!
    [exit code: 0]

已改成 Hello, DSH! 并重新编译运行，输出 Hello, DSH!。
```

---

## 1. 构建与运行

需要一个 Uya 编译器（默认用 `/home/winger/uya-0.10`，可在 Makefile 里改）：

```bash
make check        # 词法/语法/类型检查
make build        # 产出 build/uya-agent
make selftest     # 离线端到端自测（内置 mock LLM，不需要网络也不需要 key）
make codegen-audit # 扫构建产物：不许出现「切片描述符 → 字节指针」的强转（终端乱码源头）
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
| `--max-steps N` | **熔断上限**：最多几轮工具调用，**默认 0 = 不限** —— 一直跑到模型给出最终答案（对齐 DSH：它没有步数上限） |
| `--max-response N` | 响应体上限，默认 256 KiB |
| `--timeout-ms N` | 单次 HTTP 超时，默认 120 s |
| `--no-shell` | 不提供 `run_shell`（tools schema 里也不会出现） |
| `--no-stream` | 关闭流式，回退一次性响应（老端点兼容） |
| `--api=MODE` | 线协议：`openai-responses`（**默认**）/ `openai-completions`（也接受 `responses` / `chat` / `completions`）。**不写 = 未声明**：先打 `/responses`，只有 404/405/501 才回退 `chat/completions`（每进程一次），见「Responses 接口」一节 |
| `--reasoning-effort V` | 发 `reasoning.effort`（只有 responses 发；`off`/`none` = 不发），默认取 DSH 的 `agent-default-model.reasoningEffort` |
| REPL 命令 | `/help` `/continue` `/status` `/compact` `/plan` `/sessions` `/resume <id>` `/new` `/exit` |
| `--agent-home DIR` | 会话与索引的根目录（默认 `~/.uya-agent`） |
| `--continue` | 接着当前目录最近一条会话继续 |
| `--resume ID` | 恢复指定会话（`ID` 或 `last`） |
| `--list-sessions` | 列出本机会话后退出 |
| `--no-save` | 不写会话日志 |
| `--dsh-home DIR` | DSH 用户目录（默认 `$DSH_HOME` 或 `~/.dsh`） |
| `--no-dsh-config` | 完全不读 DSH 设置 |
| `--strict-dsh-config` | 读不到 DSH 设置就报错退出 |
| `--print-config` | 打印生效配置、preset 旋钮与来源后退出（含 `tls_verify` / `tls_pin` 及来源） |
| `--list-dsh-sessions` | 列出 DSH 自己的会话（`<DSH_HOME>/sessions`，含 zstd） |
| `--resume-dsh ID` | 导入 DSH 会话并继续（id 前缀 ≥8 字符即可） |
| `--yaml-dump FILE` | 打印该 YAML 的解析结果（诊断） |
| `--plan` | 以 plan 模式启动（先出计划、批准后再执行） |
| `--skill-dir DIR` | 额外的技能根（冒号分隔，可多次） |
| `--uya-bin PATH` | 跑 workflow 脚本的解释器（默认 `$UYA_BIN` 或 `uya`） |
| `--no-compact` | 关闭自动上下文压缩 |
| `--context-window N` | 压缩判定的窗口（默认取 DSH 模型条目） |
| `--dsh-root DIR` | packaged preset 根（读 persona / plan 段文案） |
| `--dry-run` | 只组装请求并打印（不可打印字节转义成 `\xNN`，排查脏字节） |
| `--compat-fold` | 工具结果折叠成一条 user 消息（旧协议） |
| `--no-stream-options` | 不发送 `stream_options.include_usage` |
| `--show-reasoning` | 把 `reasoning_content` 打到 stderr |
| `--show-usage` | 每轮打印 token 用量（in/out/cache/reasoning） |
| `--tool-lines N` | 工具结果正文首尾各显示几行，默认 6（`0` = 不显示正文），见 P14 |
| `--tui` | 全屏 TUI（**TTY 交互模式默认**）；`--no-tui` 退回滚动转录；`UYA_AGENT_TUI=0|1` 同口径 |
| `--color=MODE` | `auto`（默认）/ `always` / `never` / `16` / `256`；`NO_COLOR` 也认 |
| `--tui-demo` | 打印 TUI 的 home / chat 两屏纯文本快照后退出（诊断 + 文档） |
| `--max-tokens N` | 发送 `max_tokens`（默认不发送） |
| `--temperature N` | 发送 `temperature`（默认不发送，对齐 DSH） |
| `--tls-verify=chain\|pin\|none` | TLS 信任策略，默认 `chain`，见第 5 节 |
| `--tls-pin HEX` | `pin` 模式要求的 leaf 证书 SHA-256（小写 hex） |
| `--quiet` | 关闭工具内容块（回退到旧的最小转录：只有正文流） |
| `--tls-debug` | 保留 `lib/tls` 的握手调试输出（默认静音，见第 3 节第 14 条） |
| `--http-debug` | 打印每轮响应的头与体首字节（排查网关怪异响应用） |

环境变量：`UYA_AGENT_BASE_URL`、`UYA_AGENT_MODEL`、`UYA_AGENT_WORKSPACE`、
`UYA_AGENT_MAX_STEPS`（步数熔断上限，`0` = 不限，也是默认值；非法值告警后按「不限」处理）、
`UYA_AGENT_API`（`openai-responses` / `openai-completions`；非法值告警后按「未声明」处理，即仍会先试 responses）、
`UYA_AGENT_REASONING_EFFORT`（`off`/`none` = 不发），
以及 key（三选一）：`UYA_AGENT_API_KEY` / `DEEPSEEK_API_KEY` / `OPENAI_API_KEY`。

退出码：`0` 成功 · `1` 用法/配置错 · `2` 传输错（DNS/TCP/TLS/超时）· `3` 模型或协议错
（**只在你显式给了 `--max-steps N` 时**才包含「步数熔断」）· `4` 工具/工作区错。

---

## 2. 代码结构

```
src/bufx.uya      通用字节层：Buf 生命周期、拼接、十进制/十六进制、UTF-8 码点计数与切片
src/jsonx.uya     JSON：JsonWriter 组装请求；JsonValue 导航取值；字符串反转义（关键，见下）
src/httpc.uya     传输层：URL 解析、DNS+TCP、TLS 会话、请求构造、非流式响应解析、leaf 指纹
src/httpstream.uya 流式传输：请求发出后只读到响应头，body 按需增量解码（chunked 状态机）
src/sse.uya       SSE 分帧：字段行、多行 data、空行 dispatch、注释、未终结帧不冲刷
src/llm.uya       请求/响应协议（两种）：chat/completions 的流式 delta 装配与
                  /v1/responses 的事件表解析（content/reasoning/function_call/usage/status）、
                  两者都归一成同一个 ChatOut；非流式响应同样归一
src/tools.uya     三个工具：read_file / write_file / run_shell
src/tty.uya       终端层：termios raw 模式、行编辑器（历史/光标/Delete/词删除，**按 UTF-8
                  字符编辑、按显示列定位**）、渲染协议（擦输入行→写→重画，输入行折行或紧跟
                  在没换行的正文后面都只擦自己那一块）、提示符即状态显示
src/tui.uya       全屏 TUI（P17）：帧模型（行=段序列，逐行 diff 重绘）、备用屏幕进出、
                  转录条目（用户/助手/思考/工具/诊断）、轻量 markdown、输入编辑器（按字符编辑、
                  多行、历史、括起粘贴）、键解码（分片转义序列）、浮层（命令面板/会话/帮助/问答）、
                  sink 通道与清洗、滚动与尾随、帧节流
src/sigselftest.uya TUI 的自测轮次（frame / keys / sink / turn / pty）
src/sigx.uya      信号层（P17）：直接绑宿主 glibc `sigaction`（绕开 uya 0.10 `libc.signal`
                  的 SIGSEGV 缺陷）；终止类信号 → 先恢复终端（termios + 离开备用屏幕）再
                  128+sig 退出；SIGWINCH → 只置标志；`sigx_reset_for_child()` 给 fork 子进程
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
src/dshsess.uya   读 DSH 自己的会话：扫 <DSH_HOME>/sessions、解析 header、zstd 用 /usr/bin/unzstd
                  解压、把 user/message + assistant/message + tool/result 转成我们的历史
src/dshcfg.uya    读 DSH 设置：$DSH_HOME 解析、settings.yaml 模型路线（agent-default-model →
                  provider 的 baseURL/apiKeyEnv/models[]）、.credentials.yaml、.env 兜底、
                  permission→confine、uya-agent.tls 命名空间
src/workflow.uya  workflow：把脚本写成 .ush + 生成同目录的自包含 hooks.uya（钩子客户端）、
                  监听 127.0.0.1 的钩子端口、fork+exec `uya run`、边等服务脚本边处理钩子
src/deleg.uya     子代理：fork 不 exec（同二进制跑 agent_run）、结果管道 + 增量读取、
                  父子会话关联（subagent/start 事件）、前台/后台、send_message 续跑、interrupt、ralph
src/goal.uya      会话级目标：goal.json（id/revision/phase/round/maxRounds/blocker/armed）、
                  精确 id+revision 校验、blocked 至少连续 3 轮
src/skill.uya     技能：5 个发现根（项目 .dsh/.agents → --skill-dir → $DSH_HOME/skills →
                  ~/.agents/skills）、SKILL.md front-matter 解析、目录注入模板、skill 工具结果模板
src/webx.uya      web_search：DeepSeek Anthropic 兼容 Messages API + 服务端 web_search 工具、
                  query 去重、来源解析与渲染、按主机的独立信任策略
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
src/diffx.uya     行级 diff（只服务显示）：公共整行前后缀裁剪 → LCS DP（60×60 上限）→
                  行列截断 + 头截断；全局暂存最近一次变更，view 层 take 走
src/view.uya      工具内容块：工具→标题/关键参数/后缀三张表、状态字形、结果首尾若干行、
                  todo 清单、按显示列截断、交互模式的「运行中提示符」换入换出
src/agent.uya     CLI、环境变量、消息历史、请求组装、主循环（流式/非流式）、工具分发、
                  交互式 REPL（中断/steer//continue/会话命令）、会话事件记录与恢复
src/sigselftest.uya 信号层的自测轮次（sig-abi / sig-basic / sig-term-restore / sig-child-reset）
src/selftest.uya  --selftest 的 mock LLM（含 SSE 受控切分）+ 28 轮断言 + --probe
```

> 两处已知死代码（P14 未清理，改别的东西时别被它们误导）：`src/tools.uya`（P0 的
> `read_file`/`write_file`/`run_shell`，早已被 `fsx`/`search`/`shellx` 取代）、
> `agent.uya` 里的 `dispatch_tool`（`JsonStrView` 版，无调用者）。

### 显示内容（P14，对齐 DSH 工具视图）

DSH 的会话视图里每次工具调用是一张卡片：**标题（工具名 + 关键参数）+ 状态 + 分类正文**
（readBody / diffBody / terminalBody / webBody / todo 行）。DSH 自己没有终端渲染器
（197 个包里没有任何 TTY/ANSI 代码），所以这里是把**那套内容模型搬到滚动终端**：

```
✓ Edit(src/a.uya) · replaced          # 状态字形 + 标题(关键参数) + 后缀
      export fn main() i32 {          # 上下文（未改动的行）
    -     @println("Hello, Uya!");    # 删
    +     @println("Hello, DSH!");    # 增
          return 0;
      }
```

* **行**：`<字形> <Title>(<摘要>)<后缀>`。字形 `✓` 成功 / `✗` 失败 / `●` 运行中（只在交互提示符里）；
  标题按工具映射（`Read` / `Write` / `Edit` / `Glob` / `Grep` / `Bash` / `Todo` / `Ask` /
  `WebSearch` / `Subagent` / `Workflow` …）；摘要取关键参数（`command` / `file_path` / `pattern` /
  `description` / `queries`）；后缀是元信息：`· exit 1`、`· timed out`、`· killed by signal 9`、
  `· background job-2`、`· +4 -0`、`· replaced`、`· 3 items (1 done)`、`· lines 100-149`，
  兜底是 `· N lines`（结果文本行数）。失败判定：结果以 `Error: `（工具模块统一前缀）或
  `error: `（派发层的「参数不是合法 JSON」）开头，或 bash 尾部是 `[exit code: N≠0]` /
  `[timed out …]` / `[killed by signal: N]`。
* **正文**：4 空格缩进；默认首尾各 6 行、中间 `… (省略 N 行)`（`--tool-lines N` 改预算，
  `0` = 只留行不留正文）。`write` / `edit` 用 **diff** 取代首尾（见下），`todo_write` 用清单
  （`✓` 已完成 / `▸` 进行中 / `·` 待办）。
* **diff**（`src/diffx.uya`）：采集点在 fsx —— `edit` 用读写之间已有的两份内容（零额外 I/O），
  `write` 在 `O_TRUNC` **之前**读一份旧内容（只在显示打开时读，上限 2 MiB）。
  算法：公共**整行**前后缀裁掉（O(n) 扫描，不建行表）→ 中间段两侧各 ≤ 60 行时用 LCS DP
  （61×61 字节表）出最小编辑脚本 → 更大就只给两行精确汇总（`- (N 行旧内容)` / `+ (N 行新内容)`，
  反正显示也只看前 20 行）→ 输出按显示列截断、按行头截断（`max(4×tool_lines, 20)` 行）。
  **失败的 write/edit 不留假 diff**（正文回落到错误文本）。
* **宽度**：全部按**显示列**算（`tty_body_width()` 跟着终端宽度收在 [40,200]，CJK 汉字 2 列），
  截断在 UTF-8 字符边界上回退并补 `…`；非法字节按 1 列宽，保证指针一定前进。
* **通道与开关**：内容块一律走 fd 2（正文与模型输出仍走 fd 1，管道语义不变）；
  会话日志不受影响（仍只记 `tool/call` + `tool/result`）。`--quiet`（含子代理，它们本来就
  `quiet=true`）把整层关掉 —— 输出与 P13 之前的**最小转录逐字节一致**，且 `write` 连旧内容都不读；
  自测里有一条「关闭态下 fd 2 捕获到 0 字节」的断言守着它。
* **交互模式**：工具运行期间把**提示符**换成运行中的那一行（`● Bash(npm test) > `），
  工具返回后先恢复原提示符、再把「成品行 + 正文」写进滚动区。这样不用原地改写已输出的一行，
  也不会和正在编辑的输入行打架（复用 P3 的擦除/重画协议）。
  `ask_user_question` / `exit_plan_mode` 会自己提问，跳过这次提示符替换。
* **思考块**：`--show-reasoning` 时每个 step 的思考前面加一行 `✻ 思考`（内容仍原样流式）。
* 明确不做：ANSI 颜色（`tty_advance_col` 的列算术不认识零宽转义序列，`make codegen-audit`
  对转义写法也有硬约束）、markdown 渲染、可折叠卡片、`--resume` 的转录回放。

### preset 旋钮、DSH 会话与 make 目标（P13）

* **旋钮由 preset 驱动**：`<DSH_ROOT>/config/agent-presets/standard/agent.cordis.yml` 里的
  `agent-instructions.maxBytes`、`tool-result-pruner.{thresholdChars,headChars,tailChars}`、
  `tool-fs.{readLimit,readMaxBytes,readMaxLineLength}`、`tool-fs-search.{globMaxResults,grepMaxMatches,…}`、
  `tool-bash.timeoutMs`、`compaction-basic.{thresholdRatioPermille,retainRatioPermille}` 会被读出来
  落成运行时全局（读不到就用 DSH 标准 preset 的默认值）。**group 的 `config` 列表会递归进去**
  （剪枝旋钮就在里面）。`--print-config` 打印每一项与来源（`preset` / `defaults`）。
* **读 DSH 自己的会话**：`--list-dsh-sessions` 列出 `<DSH_HOME>/sessions/**`（id、深度、
  消息数、preset、压缩方式、cwd）；`--resume-dsh <id 前缀>` 把该会话的
  `user/message` + `assistant/message` + `tool/result` 转成我们的历史并**开自己的会话**继续
  （不写 DSH 的日志）。压缩的 `.jsonl.zstd` 走 `/usr/bin/unzstd` 解压。
  消息数只统计已读入的部分（zstd 前缀），所以列表里写作 `msgs≈`。
* `make` 目标：`check` / `build` / `selftest`（离线 28 轮）/ `probe` / `e2e TASK=… [PIN=…]`（真实网关）/
  `e2e-config`（零参数打印生效配置）/ `e2e-dsh`（列 DSH 会话）。

### workflow：Uya 脚本 + 钩子代理（P12）

按「用 ush 代理 js」的约定：workflow 的脚本是 **Uya 的 `.ush`**，用 `uya run` 执行；
`agent()` / `phase()` / `log()` / `done()` 这些钩子**在父进程里真实执行**（脚本只负责编排）。

* 工具参数：`script`（.ush 正文）、`meta`（name/description/phases）、`args`（JSON）。
* 机制：父进程把脚本写成 `/tmp/uya-wf-<ms>/main.ush`，并在同目录生成**自包含**的
  `hooks.uya`（只用 libc + std.json，因为 `uya run` 的脚本环境里没有本项目的 `Buf` 等工具）；
  父进程监听 `127.0.0.1:0`，把端口与 args 通过 env 传给脚本，`fork+exec` `<uya-bin> run main.ush`，
  然后在等待脚本的同时轮询钩子 socket：每来一条 `op payload` 就真的去做
  （`agent_start` 派生子代理、`agent_wait` 等它、`phase`/`log` 记录、`done` 收结果），
  再把 `{"ok":…,"text":…}` 回给脚本。
* 给脚本用的钩子：`wf_args()` / `wf_phase(t)` / `wf_log(m)` / `wf_agent(prompt,label)` /
  `wf_agent_start(prompt,label)` + `wf_agent_wait(h)`（并发靠这对显式配对）/ `wf_done(result)` / `wf_failed(reason)`。
* `--uya-bin PATH` 指定解释器（默认 `$UYA_BIN` 或 `uya`）；把它指向 `/bin/bash` 这类解释器时
  走 `<bin> <script>` 的直接模式（自测就用它跑一个「说同样协议」的 shell 脚本，无需编译器）。
* 结果回给模型：名字/描述、阶段链、处理的钩子数、派生的子代理数、脚本退出码、日志与 `wf_done` 的结果。

### 子代理与目标（P11）

* **派生方式：fork 不 exec** —— 子进程是同二进制的一份拷贝，直接跑 `agent_run`，把最终答复写进管道；
  父进程按后台任务那套语义增量读取。好处是不用把配置序列化成命令行，直接复用已验证的
  流式/工具/会话/压缩代码。stdout/stderr 在子里重定向到 `/dev/null`（排查时设
  `UYA_AGENT_DEBUG_SUBAGENT=1` 保留 stderr）。
* `subagent`（新上下文）/ `subagent_fork`（**继承父会话已完成的轮次**）：`run_in_background` 默认 true；
  前台调用会等到子代理结束并把它的最终文本作为工具结果返回。
* `list_agents` / `subagent_output`（增量，`wait=true` 可等）/ `send_message`（给空闲的子代理
  **续跑同一会话**，表现为新的 `sub-N`）/ `interrupt_agent`（SIGKILL）。
* 子代理的请求带 `x-uya-subagent: <depth>` 头，便于服务端/日志区分父子；
  子会话里有 `subagent/start` 事件记录 `parentSession` 与 `delegationDepth`。
* **只继承「已完成的轮次」**：fork 时父回合可能正在进行（父的 tool 结果还没落盘），
  所以读进父历史后会先裁掉「不完整的尾部」（悬空 tool 结果 / 没有结果的 assistant(tool_calls)）。
  这条同时也让**崩溃恢复**出来的历史一定以完整消息结尾（否则网关会以
  `an assistant message with 'tool_calls' must be followed by tool messages` 拒掉）。
* `ralph`：fresh-agent 循环，每轮**新会话**、objective 不可变、workspace 当长期记忆；
  子代理每轮报告以 `RALPH: COMPLETE|BLOCKED|CONTINUE` 结尾，遇到前两者提前收工。
* **目标工具**：`create_goal`（可从直接的人类请求里推断意图）/ `get_goal` / `update_goal`
  （`edit|pause|resume|complete|blocked`，要求精确 id+revision，`blocked` 至少要连续 3 轮），
  状态落 `<agent_home>/goal.json`，跨进程可读。

### 技能与联网搜索（P10，对齐 DSH skill-filesystem / tool-skill / tool-web）

**技能**发现根（靠前优先，只扫一层）：`<项目根>/.dsh/skills` → `<项目根>/.agents/skills` →
`--skill-dir`（冒号分隔，可多次）→ `$DSH_HOME/skills`（跳过 `.system`）→ `$DSH_AGENTS_HOME|~/.agents/skills`。
布局只有 `<root>/<name>/SKILL.md` 与 `<root>/<name>.md` 两种；front-matter 必填 `name`（kebab-case）与
`description`，`disable-model-invocation: true` 的技能既不进目录也不能被工具调用。

* 目录以一条 user 消息注入（模板逐字对齐 DSH）：`<available_skills>` 里逐条 `- \`name\`: 描述`，
  描述先压空白再截到 500 字符、XML 转义；没有任何可调用技能时**不注入**。
* `skill` 工具结果：`<skill_content name="…">` + `<skill_resources>`（目录型技能给
  「Base directory for this skill: …」与相对路径解析指引）+ `<skill_instructions>`（front-matter 之后的正文）。
* 错误串对齐：`Error: invalid skill name "…"` / `Error: skill "…" is unknown or no longer available` /
  `Error: skill "…" is not available for model invocation`。

**web_search**：`queries` 必填、1–4 条、**去重保留首次出现**；走 DeepSeek 的 Anthropic 兼容
Messages API（`x-api-key` + `anthropic-version: 2023-06-01`，服务端工具 `web_search_20250305`），
从响应里取 text 块的答案与 `citations`、以及 `web_search_tool_result` 的来源（url/title/page_age），
按 URL 去重、最多 8 条，渲染成「答案 + Sources 列表」。
* 凭据：`DEEPSEEK_API_KEY`（进程环境 → `$DSH_HOME/.credentials.yaml` 的 `refs`）；缺失时回
  `WEB_PROVIDER_CREDENTIAL_MISSING` 文案。
* 可用 `DEEPSEEK_SEARCH_BASE_URL` / `DEEPSEEK_SEARCH_MODEL` 覆盖端点与模型（默认
  `https://api.deepseek.com/anthropic/v1`、`deepseek-v4-flash`）。
* **按主机的信任策略**：搜索主机和模型主机通常不是同一个，leaf pin 是按主机的，所以
  web_search 单独读 `UYA_AGENT_WEB_TLS_VERIFY` / `UYA_AGENT_WEB_TLS_PIN`，缺省继承主配置。

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
* **历史条数默认不限制**（`History` 是堆数组，见「严格工具协议要点」）：于是压缩是**唯一**的裁剪机制 ——
  以前还有一条「超过 64 条丢最老」的兜底，那条兜底正是踩坑 26 的事故来源。单条消息超 200 KiB 会被
  剪枝/截断到装得下（会话日志仍是全文），不会因为「太大」拒绝入史。
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
* **`api:` 真的决定线协议**（不再只是打印）：`openai-responses` → `/responses`，`openai-completions` → 
  `/chat/completions`，声明后**不协商**；认不出来的取值（`anthropic` / `azure-openai-responses` /
  `openai-codex-responses` …）打一条 warning 后按「未声明」处理 —— 也就是仍然先试 `/responses`、
  404/405/501 回退 chat。`--api=` / `UYA_AGENT_API` 可以覆盖它（优先级 CLI > env > DSH > 默认）。
* `compat` 也读：`supportsDeveloperRole`（决定系统提示发 `developer` 还是 `system`）、
  `supportsStore`（决定发不发 `"store": false`）、`supportsReasoningEffort`（决定发不发 `reasoning.effort`）；
  provider 级是默认值，**模型条目的同名键覆盖它**（与 DSH 一致）。
* 优先级：**CLI > `UYA_AGENT_*` 环境变量 > DSH 设置 > 内置默认**，`--print-config` 逐项打印来源
  （`default` / `dsh-settings` / `env` / `cli`），敏感值打码成 `sk-…abcd`；
  `tls_verify` / `tls_pin` 也照样打来源，指纹是公开信息所以完整打印（方便直接和 `openssl` 对比）。
  `--no-dsh-config` 完全关闭，`--strict-dsh-config` 读不到就报错退出 —— 这三个 flag 决定
  「去哪儿读设置」，所以必须在加载**之前**预扫一遍，`make e2e-config-flags` 守着这条（见踩坑 25）。
* TLS 信任策略也可以写进同一个设置文件（DSH 会忽略不认识的节）：
  ```yaml
  uya-agent:
    tls: { verify: pin, pin: <leaf sha256> }   # 或 verify: none
  ```
  这样「零参数启动」才真的可用 —— 默认 `chain` 在真实站点上过不去（见第 5 节）。
  写完 `--print-config` 会显示 `tls_verify = pin  (source: dsh-settings)`，
  零参数 `--probe` 即可验证（实测 HTTP 200，指纹与 `openssl s_client` 一致）。
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
* 反转义用**唯一一份完整实现**（`jsonx.uya::sv_unescape`，支持 `\uXXXX` 与代理对）：
  日志写入端把 `0x00…0x1f` 写成 `\u00XX`，读回必须还原成**那个字节**，否则一条带 NUL 的
  工具结果会被静默改成字面量 `u0000`（自测 `session-log` 轮逐字节断言了 NUL/0x01 的往返，
  见踩坑 27 的后半段）。
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
* **中文（UTF-8）编辑**：终端里 1 个汉字 = 3 字节 = **2 列**，所以编辑按**字符**、定位按
  **列**：退格/Delete/Ctrl-W 一次删一个完整字符（按字节删会把汉字砍成半个 `\xe4\xb8`
  —— 屏幕上就是乱码），←/→ 一次跨一个字符，光标回退量按显示宽度算（东亚宽字符 2 列、
  组合符 0 列）。自测里逐个断言了这些原语（`tty_utf8_*` / `tty_char_cols`）与折行口径。
* **渲染协议**：擦除 = 上移回输入行块首行 → 右移到块首列 → `ESC[J` 清到屏幕末尾；
  重画 = 写提示符 + 行内容 → 按列把光标挪到 `cursor` 处。两个细节必须守住：
  ① 输入行**折行**（80 列终端 39 个汉字就折行）时要整块擦掉，不能只擦一行；
  ② 流式输出没换行时输入行接在正文**后面**（块首列 ≠ 0），擦除只能从块首列开始，
  否则会把同一行前半段刚吐出来的正文一起擦掉。窗口宽度每次重画前重读（TIOCGWINSZ），
  缩放后不用重启。
* **slash 命令**：`/help`、`/continue`（带历史再跑一轮）、`/status`、`/exit`。
  运行中输入的 slash 命令也按命令处理（用户并不知道回合是否结束）。
* **中断语义对齐 DSH**：流式期间中断 → assistant 消息只保留非空白前缀且**不含 tool_calls**；
  工具执行期间中断 → 已派发的补 `aborted by user`、未派发的补 `aborted before dispatch`。
  回合一结束就回到提示符，历史完整，`/continue` 或直接输入都能接着跑。
* **步数默认不限**（`--max-steps 0`，也是内置默认）：一个回合只在模型给出**不含 tool_calls 的
  最终答案**时结束 —— 跑多少步由任务决定，不由 CLI 决定（对齐 DSH：它没有步数上限）。
  只有显式给了 `--max-steps N` 才有熔断回合：交互模式下熔断只结束回合、不杀进程
  （一次性运行仍返回退出码 3），提示里会告诉你 `/continue` 可以接着跑。
* **非 TTY 自动回退**：stdin 不是终端时走行式 REPL（同一份 history 连续对话）。
* **已知限制（TAB）**：物理列模型把控制字符（含 TAB）按 0 列算，而终端里 TAB 会跳到下一个
  制表位 —— 只有当 TAB 恰好落在「与输入行同一行」的正文里时，才会把输入行起始列算小几格
  （擦除时多擦几个字符）。带 TAB 的正文（代码块）通常每行以换行收尾、列模型随即归零，
  所以没为它维护制表位表。
* **信号（P17 起）**：装了终止类处理器 —— 被 `SIGTERM` / `SIGINT` / `SIGHUP` / `SIGPIPE`
  打断时**先把终端还回去**（恢复 termios + 关闭括起粘贴 + 复位属性 + 显示光标）再以
  `128+sig` 退出；`SIGWINCH` 只置一个标志（TUI 取用后立刻重排，滚动模式靠每帧查宽度兜底）。
  fork 出来的子进程（bash / rg / 子代理 / workflow / unzstd）都会先
  `sigx_reset_for_child()` 把处置恢复成默认，免得子进程被杀时去写父进程的终端。
* **已知限制**：`SIGKILL` 不可捕获（`kill -9` 之后终端可能停在 raw 模式 / 备用屏幕，
  用 `reset` / `stty sane` 恢复）。uya 0.10 的 `libc.signal.signal` 曾经一调用处理器就 SIGSEGV，
  本项目因此**不使用它**而是自己绑宿主 `sigaction`（`src/sigx.uya`）；
  该缺陷已在 uya 项目侧修复（commit `fad26acd`，见踩坑第 28 条）。

### 全屏 TUI（P17，对齐 opencode 的观感）

TTY 交互模式**默认全屏**（`--no-tui` 退回上一节的滚动转录；不是 TTY / `--quiet` / 子代理
自动退回）。做成**无边框、黑底、单强调色**：空态是块字 logo + 居中输入面板，对话态是
「转录贴面板、面板贴底」，状态不是独立状态栏而是转录里的一行。

```
         █▓  █▓ █▓  █▓ █▓  █▓        █▓  █▓ █▓  █▓ █▓  █▓ ██▓ █▓ █████▓
         █▓  █▓  ████▓ █████▓ █████▓ █████▓  ████▓ █████▓ █▓  █▓  █▓
         █▓  █▓     █▓ █▓  █▓        █▓  █▓     █▓ █▓     █▓  █▓  █▓ █▓
          ▓▓▓▓   ▓▓▓▓  ▓▓  ▓▓        ▓▓  ▓▓  ▓▓▓▓   ▓▓▓▓  ▓▓  ▓▓   ▓▓▓

  ▌ ↑ Ask anything... "把 hello.uya 的问候语改成 Hello, DSH!"
  ▌ Build   deepseek-chat   deepseek               tab plan   ctrl+p commands
  ~/uya-agent:main                                          in 8.1k · out 402 · p17-tui
```

对话态（`--tui-demo` 打印的就是这两屏的纯文本快照）：

```
    ▎ 你
  把 hello.uya 的问候语改成 Hello, DSH!
    ◆ 助手
  我先读一下文件，再改一行，顺手跑一次编译：
  │ ```                       ← 围栏代码块（DIM + 左竖线），行内 `code` 走 INLINE 色
  │ @println("Hello, DSH!")
  │ ```
  ✓ Read(hello.uya) · 4 lines    ← 工具卡片：✓/✗ 标题行 + 4 空格缩进正文
      -     @println("Hello, Uya!");   ← diff：- 红 / + 绿
      +     @println("Hello, DSH!");
  ⠹ Bash(make check) · esc 中断      ← 运行中状态是转录最后一行（不是独立状态栏）
  ▌ ❯ 顺便把 Makefile 的注释补一下_  ← 输入面板（左边缘强调竖条）
  ▌ Build   deepseek-chat   deepseek               tab plan   ctrl+p commands
  ~/uya-agent:main                              in 8.1k · out 402 · ctx 21% · p17-tui
```

* **开关**：`--tui`（默认）/ `--no-tui` / `UYA_AGENT_TUI=0|1`；
  `--color=auto|always|never|16|256` 与 `NO_COLOR`（无色时只留粗体/暗色）；
  `--tui-demo [COLSxROWS]` 打印 home/chat 两屏纯文本（诊断 + 文档）。
* **键位**：`enter` 发送 · `ctrl+j` / `alt+enter` 换行 · `esc` 运行中=中断、空闲=清行 ·
  `ctrl+c` 运行中=中断、空闲=清空/两次退出 · `ctrl+d` 空行退出 · `↑/↓` 单行=历史、
  多行=上下移光标 · `pgup/pgdn`、`ctrl+home/end` 滚转录 · `tab` 切计划模式（面板显示 `Plan`）·
  `ctrl+p` 命令面板（输入以 `/` 开头也会自动打开）· `ctrl+u/w/k` 清行/删词/删到行尾 ·
  `ctrl+a/e`、`←/→`、`home/end`、`backspace/del` 按**字符**编辑 · `ctrl+l` 强制重绘 ·
  括起粘贴（`ESC[200~`）整段插入不触发提交（> 64 KiB 截断）。
* **浮层**：命令面板、会话列表（选一个 `/resume`）、帮助（`/help`）、`/status` 详情，
  以及 `ask_user_question` / `exit_plan_mode` 的问答弹窗（↑/↓ + enter，esc = 无回答）。
* **数据流**：TUI 激活后 `tty.uya` 的 `tty_write` 变成一个 **sink** —— 通道 1（助手正文）、
  2（工具块/诊断）、3（思考，新增 `tty_reason_write`）全部进转录，**fd 1 一个字节都不写**
  （管道语义干净，`tui-turn` 轮断言 fd 1 捕获 0 字节）；工具卡片不是靠前缀嗅探，而是
  `view_begin_tool`/`view_end_tool` 走结构化分支、复用纯函数 `view_render_block()` 的产物。
* **帧与终端**：帧写到启动时 `sys_dup(1)` 的**私有 fd** —— 请求期间 `tls_noise_mute()` 会把
  fd 2 指向 `/dev/null`，走 fd 2 的帧会被吞掉；备用屏幕进出 + 括起粘贴 + 逐行 diff 重绘
  （只重发变化的行，变化超过 60% 时整屏重画）；正文层永远是纯文本（宽度、换行、擦除都按
  显示列算），工具输出里的控制字节/`ESC[2J` 在 sink 里就被清洗成 `·`/`␛`。
* **不卡界面**：`llm` 的流式循环、bash/后台任务/子代理/workflow/rg 的阻塞 poll 循环里都插了
  `tui_poll_tick()`（非 TUI 模式是空调用）—— 工具跑着的时候界面照样刷 spinner、键盘照样收，
  `esc` 记下中断意图、在**下一个 step 边界**结束回合（滚动模式行为不变）。
* **信号配合**：进入 TUI 时 `sigx_arm(私有fd, alt=true)`，被 `SIGTERM/INT/HUP/PIPE` 打断时
  处理器先恢复 termios + 离开备用屏幕再以 `128+sig` 退出；`SIGWINCH` 只置标志（tick 里
  立刻重排，每帧查 TIOCGWINSZ 作兜底）；`read` 的 `EINTR` 一律当「重来」而不是 EOF。
* **`--resume`**：历史会回填进转录（最近 200 条），**注入类的 user 消息**（运行时上下文、
  AGENTS.md、技能目录）不进屏幕 —— 它们是我们塞给模型的背景，不是用户说过的话。
* **记忆上限**：条目 ≤ 512、正文 ≤ 4 MiB、单条 ≤ 256 KiB，超了从最老丢并在顶部留一行标记；
  思考条目只留尾部 4 KiB（与 P15/P16 的「思考行只显示最新一段」同口径）。
* 仍不做：鼠标（滚轮/点击/选择）、图片、可折叠卡片、完整语法高亮（只做轻量 markdown）、
  分屏、主题切换 UI。

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

### Responses 接口（`/v1/responses`）

**默认就支持**：什么都不声明时先按 Responses 发（`POST {base_url}/responses`），
只有「端点不存在」（HTTP **404/405/501**）才在本进程内回退 `chat/completions` 并**记住**——
同一步用另一个协议重发一次，之后所有请求（后续 step、压缩摘要、子代理）都不再试探。
被探测掉的那次只留一行提示（不 dump 响应体）：

```
[api] /v1/responses 不可用（HTTP 404），本进程改用 chat/completions
```

`api:` 一旦被**显式声明**（DSH 设置里 provider 的 `api:` / `UYA_AGENT_API` / `--api=`），就完全不协商：
声明即权威（`--print-config` 会显示 `api = …  (source: dsh-settings|env|cli)`；未声明时显示
`(source: default, negotiable→chat/completions)`）。反过来，状态码 200/400/401/500 都**不会**换协议 ——
那些说明协议没选错，硬换只会把错误藏起来。

请求体（字段顺序固定，便于断言与 KV 前缀稳定）：

```
{ "model": …, "input": [ …items… ], "stream": true, "store": false,
  "tools": [ …扁平 schema… ], "temperature": …?, "max_output_tokens": …?, "reasoning": {"effort": …}? }
```

* 历史 → `input` items（**只在拼请求时转换**，内部历史与会话日志格式不变，所以老会话/`--resume`/
  `--resume-dsh`/子代理 fork 全都继续可用）：

  | 内部消息 | item |
  |---|---|
  | system | `{"role":"developer","content":"<整段>"}`（`compat.supportsDeveloperRole=false` 时用 `system`；content 是普通字符串，与 pi-ai 同形） |
  | user | `{"role":"user","content":[{"type":"input_text","text":…}]}` |
  | assistant | `{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":…}]}` |
  | assistant(tool_calls) | 上面那条 + 每个调用一条 `{"type":"function_call","call_id":…,"name":…,"arguments":"<JSON 文本>"}` |
  | tool 结果 | `{"type":"function_call_output","call_id":…,"output":"<文本；空则 (no output)>"}` |

* **`call_id` 只取 `|` 前那段**，item id（`fc_*`）不回放、reasoning item 也不回放（不发
  `include: ["reasoning.encrypted_content"]`）——与 pi-ai 处理「外来消息」的做法一致，省掉
  `fc_*`/`rs_*` 的配对校验；`--resume-dsh` 导进来的历史里 id 形如 `call_x|fc_y` 也能正确拆开。
* 工具 schema 用**扁平**形状（`{"type":"function","name":…,"description":…,"parameters":…}`），
  由 chat 形状的 26 个常量（其中 25 个进数组）做一次文本变换得到：去掉 31 字节前缀
  `{"type":"function","function":{` 与末尾一个 `}`。变换后逐条 parse 校验（自测 `resp-build` 轮守着）；
  常量若被改成别的形状，构请求时会立刻报 `error: tool schema constant is not in the expected chat shape`。
* `max_tokens` → `max_output_tokens`（下限抬到 16：OpenAI 拒绝更小的值）；`stream_options` 不发；
  `store: false` 默认发，`compat.supportsStore: false` 时整个字段省略。
* 流式事件表（只处理有语义的，其余忽略）：
  `response.output_item.added/done`（`function_call` 建槽/补 name/args）、
  `response.output_text.delta`（`response.refusal.delta` 同）、
  `response.reasoning_summary_text.delta` / `response.reasoning_text.delta`（→ 思考块）、
  `response.function_call_arguments.delta/done`（按 `output_index` 分片累积）、
  `response.completed` / `response.incomplete` / `response.failed`（终局）、`error`。
  终局事件里若带 `response.output[]`，还会按 `call_id` / `output_text` **回填空缺**——
  有些网关只发 `created` + `completed`，正文与参数只在终局里。
* `response.function_call_arguments.delta` 的 `delta` 是**字符串**（内容是 arguments 的 JSON
  文本片段，可能被切成多片），不是对象 —— 解析器按字符串取（`js_obj_get_str` + `sv_unescape`）
  逐片追加。自测的 mock 一开始按对象发，客户端直接忽略，于是「工具拿到空 arguments」在自测里
  溜了过去（那条 marker 断言正好被任务文本里的同名 marker 满足，抓不出来）；现在按规范发字符串，
  `ctrl-bytes-resp` 轮（真跑一条命令、断言工具输出回到请求里）把这个形状钉住了。
* finish 映射：`completed` → stop（有工具调用则 tool-calls）；`incomplete` + `max_output_tokens` → max-tokens
  （工具调用一律丢弃）；`failed`/`cancelled` 或 `error` → error（`err_text` = `code: message`，不派发工具）。
* 协议本身**不发 `[DONE]`**：收到终局事件即收尾；缺终局事件按「流被截断」（`STREAM_CLOSED`）处理。
  少数代理仍会发 `[DONE]`、甚至把 responses 的流按 chat 形状（`choices[].delta`）回 —— 两种都兜住。
* usage：`input_tokens`（**含**缓存）/ `input_tokens_details.cached_tokens` / `output_tokens` /
  `output_tokens_details.reasoning_tokens`，映射进与 chat 相同的四个计数器
  （`usage_in = input - cached - cache_write`）。
* `--no-stream` 也支持：发 `"stream": false`，解析一次性响应体的 `output[]`（`message` / `reasoning` /
  `function_call`），同样归一成 ChatOut。

### 严格工具协议要点（P2）

* assistant 消息连同 `tool_calls` **原样回灌**（`arguments` 用 `jw_raw` 内联，绝不二次转义），
  随后每个调用一条 `role:"tool"` + `tool_call_id`；空结果发 `"(no output)"`。
* 历史裁剪**不拆散配对**：丢掉带 `tool_calls` 的 assistant 时，紧随其后的 tool 消息一起丢；
  历史不允许以 tool 消息开头（否则端点会 400）。丢老消息还有两条保护：下标 1 若是 user
  （本会话的任务原文）则从下标 2 开始丢；**受保护区域之上绝不触碰**（本步刚压入的那一组）。
* **历史条数默认不限制**：`History` 是堆数组（`hist_reserve` 翻倍 realloc），不再有固定 64 条上限。
  只有真 OOM 才会 push 失败，而 push 失败时**整组回滚**（`hist_truncate_to`）——
  绝不留下「`assistant(tool_calls)` 后面缺 tool 应答」的半截历史，否则端点 400 会把会话永久钉死
  （见踩坑 26）。
* 单条消息超 200 KiB 不是「入史失败」：先按 DSH 剪枝规则缩一次，仍超就按 UTF-8 边界做
  「头 + 标记 + 尾」硬截断（`hist_fit_text`），会话日志里保留全文。
* 尾部修复（`hist_trim_incomplete_tail`）**只丢不完整的一组**：应答不全或零应答的
  `assistant(tool_calls)` 整组丢掉，**完整的一组原样保留**（旧实现会把结尾的 tool/assistant_calls
  一路丢空，等于每次恢复都清空历史）；`hist_pairing_ok` 是这套不变量的本地判据。
* `--compat-fold` 回到旧协议（工具结果折叠成一条 user 消息），`--no-stream` 回到一次性响应；
  两条路径共用同一套收尾逻辑（`agent_finish_step`）。

数据流（一轮）：

```
history ──build_model_request(JsonWriter)──▶ POST {base_url}/{chat/completions|responses} ──http_request──▶ 响应体
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
22. **第 16 条那个坑的另一种死法：把 `&"字面量"[0:n]` 传给 `*const byte` 会往终端写乱码。**
    `sys_write(fd, &"\r\x1b[2K"[0: 5], 5)` 生成的 C 是
    `sys_write(fd, (const char *)(&(struct uya_slice_uint8_t){ .ptr = …, .len = 5 }), 5)` ——
    即「切片描述符的地址强转成 char*」，于是**写出去的是那 8 字节指针的前 5 字节**。
    症状：交互模式每次重画提示符都在行首挂一串乱码（还会随 ASLR 变，实测 `\xb9x\xe0gi`），
    而且因为 `\r\x1b[2K` 根本没发出去，旧行不会被擦掉，屏幕上会一行行叠着
    `乱码> 乱码> 写一篇…`。修法：用数组字面量取址（`const S: [byte: 5] = [13,27,91,50,75];`
    → `&S[0]`），或者传 `"…" as *const byte`。`make codegen-audit` 会扫构建产物里的这种
    形状，把它挡在门外（`make selftest` 会先跑它）。
23. **终端光标位置要用「挂起换行」口径算，否则擦除会多擦一行。** 一行正好写满 `cols` 列时，
    光标**仍停在最后一列**（DECAWM 挂着待换行），下一个字节才落到下一行第 0 列。所以
    「写满 80 列」的行号是 0 而不是 1（`tty_end_row_col` / `tty_rows_of` 两个函数必须同口径，
    自测里都断言了）。另外 CSI 的参数 0 是「默认值」不是 0：`ESC[0A` 会上移 **1** 行、
    `ESC[0C` 会右移 1 列，所以参数为 0 时宁可不发这段序列。
24. **流式输出期间输入行不在第 0 列**：正文没换行时提示符紧跟着正文画，擦除前必须先回到
    该行的起始列再 `ESC[J`（清到屏幕末尾），否则会把同一行前半段刚吐出来的正文擦掉。
    `tty.uya` 为此维护物理列（`out_col`/`out_wrap`）与块首列（`start_col`）；自测断言了
    擦除序列的每个字节。
25. **「影响加载的 flag」必须预扫，否则会静默失效。** `--dsh-home` / `--no-dsh-config` /
    `--strict-dsh-config` 的语义是「去哪儿读设置」，但完整 CLI 解析排在 DSH 加载**之后**，
    于是三个 flag 全都读不到：`--no-dsh-config` 照样读 `~/.dsh`、`--dsh-home X` 照样读
    `~/.dsh`、`--strict-dsh-config` 也不报错，而 `--print-config` 仍旧显示
    `source: dsh-settings`，看上去一切正常 —— 加 tls 的来源打印时才撞出来。
    修法：在主循环之前加一趟只认这三个 flag 的预扫（主循环稍后仍会再解析一次，天然幂等）。
    这类「flag 是后续步骤的前置条件」的 bug 不会报错，只会让参数悄悄不起作用，
    所以最好用 `--print-config` 亲眼确认来源、并给它配一条常驻回归（`make e2e-config-flags`）。
26. **「某一步只压了一半」的历史是毒药：端点 400，而且会一直 400。** 真实事故：一条很长的会话
    （恢复日志 + 多轮工具调用）跑到第 10 步时，`hist_push_msg(h, ROLE_TOOL, …)` 因为固定数组
    `MSG_MAX = 64` 打满而返回 false，代码直接报 `error: could not append tool result to history` 结束回合 ——
    但**上一条 assistant(tool_calls) 已经在历史里了**。于是之后每次 `/continue` 都被端点以
    `An assistant message with 'tool_calls' must be followed by tool messages responding to each
    'tool_call_id'. (insufficient tool messages following tool_calls message)` 拒掉，会话再也推不动。
    同一次排查还挖出两个同源问题：① 恢复会话时的尾部裁剪**无条件**丢掉结尾的 tool/assistant_calls，
    而结尾几乎总是「一组完整工具调用」，`while` 一路往后丢，实测把 60 条恢复消息里的 59 条全丢了
    （等于静默清空上下文）；② 日志重放时 push 失败只 `continue`，历史打满就「留最老、丢最新」。
    修法与两条不变量：
    * **追加要么成功、要么回滚**：assistant(tool_calls) 与它的 N 条 tool 结果是一组，
      写不进去就 `hist_truncate_to` 整组回滚（丢弃计数/失败都打印出来），历史永远满足配对要求；
      丢老消息时用 `hist_drop_oldest_below(h, floor)` 把「本步这一组」划成受保护区域。
    * **尾部修复只丢不完整的一组**：应答不全/零应答的 assistant(tool_calls)、孤儿 tool 结果才丢，
      完整的一组必须原样保留；`hist_pairing_ok(h)` 是这套不变量的本地判据（也是自测的断言）。
    顺带把根因本身去掉：历史改成**默认不限条数**的堆数组（`hist_reserve` 翻倍 realloc），
    单条超 200 KiB 先剪枝、再头尾截断，绝不因为「太大」拒绝入史。
    回归：`history-long`（40 轮 × 2 调用，逐请求断言配对完整且 80 条结果一条不少）+ `hist-repair`
    （完整组不丢 / 缺应答整组丢）；旧实现在 `history-long` 上必然失败（复现记录在 §6 的验收事实里）。
27. **请求体里少转义一个控制字节 = 会话报废：端点 400，而且之后每一轮都 400。** 真实事故：
    一次 bash 调用的输出里带了一个 **NUL**（探测终端属性的小程序写出来的，用
    `printf 'A\000B'` 就能复现），工具结果原样进了历史；而构请求时用的
    `std.json.encoder.json_write_str_view` **只转义 `"` `\` `\n` `\r` `\t`**，其余控制字节
    原样落进 `messages[].content` —— 请求体于是不再是合法 JSON，Go 网关（`encoding/json`）
    直接回 `Invalid request, invalid character '\x00' in string literal`。更糟的是这条工具结果
    **永远**留在历史里：之后每次 `/continue` 都带着同一个 NUL，肉眼看就是「这个会话再也推不动」，
    而错误信息里只有网关的 400，完全指不到 NUL 上。修法与两条不变量：
    * **转义自己实现，规则对齐 RFC 8259**：`0x00…0x1f` 全部转义（`\b`/`\f`/`\n`/`\r`/`\t`，
      其余走 `\u00XX`），见 `jsonx.uya::jw_str` / `jw_write_escaped`（`jw_key` 复用同一套）。
      别再退回标准库那个实现 —— 它省掉的正是「必须转义」的那一半。
    * **请求体（紧凑 JSON）里不许出现任何裸控制字节**：这是本地就能判的硬不变量。`selftest` 的
      mock LLM 对**每一个**收到的请求体都扫一遍（判定码 240），另有纯函数轮 `json-escape`
      逐字节比对转义文本、端到端轮 `ctrl-bytes`（真跑一条输出 NUL 的命令，断言它以 `\u0000`
      的形式回到请求里；chat 与 responses **两条协议各跑一遍** —— 两条路径共用这套转义）。
    * **日志写入端一直是对的**（`session.uya::jw_str_into` 把 `0x00…0x1f` 全写成 `\u00XX`），
      所以出事的会话**在磁盘上看起来完全正常** —— 漏的是「上线」那一步。但顺藤摸瓜还挖出
      读回那一端的同源 bug：`sess_json_str` 手写的反转义只认 `\n \t \r \" \\`，其余
      `\X` 一律「去掉反斜杠留字符」，于是 `\u0000` 被还原成字面量 **`u0000`**（NUL 消失、
      内容多出 4 个字符，而且只在恢复会话时才发生，肉眼几乎不可能发现）。修法：反转义统一走
      `jsonx.uya::sv_unescape`（唯一一份完整实现，含 `\uXXXX` 与代理对），认不出的转义才退回
      原文照抄；`session-log` 轮逐字节断言 NUL/0x01 的往返。
28. **uya 0.10（以及 1.0 那一支）的 `libc.signal.signal()` 装的处理器一收到信号就 SIGSEGV。**
   它的实现**不是 glibc 的 `signal`**（`export extern "libc" fn signal(...)` 带函数体，链接时
   直接盖掉同名符号），内部走裸 `rt_sigaction`，传的是 `sa_flags = 0`、`sa_restorer = null`，
   而 x86-64 上内核交付信号时要用 `sa_restorer` 里的 `rt_sigreturn` 垫片（glibc/musl 一律置
   `SA_RESTORER = 0x04000000` 并指向自己的垫片）。旧代码那句注释「sa_restorer 为 null 时不要置
   SA_RESTORER（与 Linux uapi / glibc 行为一致）」是错的。实测三组对照（最小复现都在
   `build/sig_*.uya`，不入库）：① `signal()` 装处理器 + `kill -USR1` → 退出码 **139**，
   **处理器体一次都没执行**（不是「返回时崩」）；② 同一套裸 `rt_sigaction`，只补
   `SA_RESTORER|SA_RESTART` 并复用宿主 `sigaction` 回读出来的 `sa_restorer` → 处理器正常执行
   并返回；③ 直接绑宿主 `sigaction` → 同样正常（回读它的动作可见 `SA_RESTORER` 已置、
   `sa_restorer` 非空）。本项目因此在 `src/sigx.uya` 里**直接声明宿主 `sigaction`**
   （`SigxAction` 按 glibc 布局：handler@0 + mask128 + flags@136 + restorer@144 = 152 字节，
   `sig-abi` 轮按字节断言），而不是去修工具链 —— 这样在没修过的 0.10 上也能跑。
   同一缺陷已在 uya 项目侧修复并提交（`libc.signal: 修复 signal() 装的处理器一收到信号就
   SIGSEGV`，commit `fad26acd`，回移 0.11 的实现 + 两个回归用例；未修的版本跑那两个用例会
   `Segmentation fault`、修好后 6/6 通过）。
29. **装了信号处理器以后，阻塞的 `read` 会被打断返回 `EINTR` —— 那不是 EOF。**
   `poll`/`select` 不受 `SA_RESTART` 保护（内核语义如此），所以只要装了处理器，
   交互等待输入时的 `sys_read(0, …)` 就可能返回 `EINTR`（例如用户在流式输出期间缩放终端 →
   `SIGWINCH`）。原来两处读键盘的循环都写成 `const n = sys_read(...) catch { -1; }; if (n <= 0) { 当作 EOF }`
   —— 于是**一次窗口缩放就会把 REPL 直接关掉**（`tty_read_line_blocking` 返回 `TTY_EV_EOF`、
   `ask_read_line` 返回「无回答」）。修法：`catch |err|` 里取 `@error_id(err)`，`== 4`（EINTR）
   就 `continue` 重来（`agent.uya` 与 `askuser.uya` 各一处）。其它 `poll` 循环里的
   `catch { 0 }` 天然是「当作超时继续转」，不用改。

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
| `tty-editor` | 行编辑器：事件/历史/粘贴多行/pend；**UTF-8 按字符编辑**（退格、Delete、Ctrl-W 不会砍出半个汉字，←/→ 停在字符边界）；显示列宽（汉字 2 列、组合符 0 列）；折行与「挂起换行」的光标口径；擦除序列逐字节断言（含块首列 ≠ 0 的情形） |
| `stream-badjson` | 坏 JSON 帧 → `MALFORMED_RESPONSE` + payload 头部，之前的内容保留 |
| `stream-length` | `finish_reason=length` → max-tokens，reasoning 正常累积 |
| `steer` | 回合运行中输入的文本，必须在**下一个 step 的请求**里出现（mock 断言 `STEER-MARKER`） |
| `interrupt` | 预置 Ctrl-C：回合以 `AGENT_INTERRUPTED` 结束、工具**未派发**、只发生一次请求 |
| `tui-frame` | 四种尺寸（40×10 / 80×24 / 100×28 / 120×40）下「每行显示列 ≤ cols」「正文层里没有 ESC」；空态整体居中（首行留白 + 块字 logo + 面板 + 脚注 `~/cwd:branch`）、窄终端 logo 退化成单行标题；对话态底对齐 + 面板贴底；工具块/diff/思考/诊断/用户条目都在；跑满一屏后跟随尾部、PgUp/PgDn 夹取、回尾清零 |
| `tui-keys` | UTF-8 逐字符编辑（退格不砍半个汉字、←/→ 停在字符边界）、**被切开的 `ESC [ D`** 正确组装、Ctrl-J 换行与多行光标移动、回车提交（内容 + 清空 + 进历史）、↑ 取历史、运行中 esc = 中断 / 空闲 esc = 清行、tab 切计划模式（面板显示 Plan）、`/` 自动开命令面板并选中第二项、Ctrl-D 空行退出 |
| `tui-sink` | TUI 激活后 `tty_write(1/2)` 与 `tty_reason_write` 的字节分别落到 助手/工具/思考 条目；NUL/`ESC[2J`/TAB 被清洗且正文层无 ESC；关掉 sink 后写入回到真实 fd |
| `tui-turn` | headless 端到端（mock LLM，复用手打路径注入「任务+回车」）：屏幕里出现用户条目、`✓ Write(note.txt)`、`✓ Bash(`、最终答案；回合结束状态回 idle；fd 1 无输出 |
| `tui-pty` | **真 PTY**（`/dev/ptmx` + `fork` + `dup2(slave→0/1/2)`）：进备用屏幕（`ESC[?1049h`）、首屏面板/logo、发任务后转录出现 mock 最终答案、`SIGWINCH`（改 winsize + 发信号）后进程仍活着并继续重绘、Ctrl-D 退出码 0、退出后 `TCGETS` 与 fork 前**逐位相同**、离开备用屏幕；不需要 setsid/TIOCSCTTY（fd 0 就是 pts 从设备，Ctrl-C 由程序自己吃字节） |
| `sig-abi` | `SigxAction` 必须是**宿主 glibc** 布局（152 字节；handler@0 / flags@136 / restorer@144，按字节回读）；恢复序列逐字节（带备用屏幕 26 字节 / 不带 18 字节） |
| `sig-basic` | 处理器装上以后真的被调用、返回以后进程还活着（P0 的回归闸门：缺 `SA_RESTORER` 的实现在这里直接 139）；`SIGWINCH` 处理器只置标志、取用即清零 |
| `sig-term-restore` | fork 子进程里给自己发 `SIGTERM`：管道上必须收到完整 26 字节恢复序列、退出码必须是 **143**（139 = 处理器路径崩了、7 = 处理器根本没跑） |
| `sig-child-reset` | fork 子进程 `sigx_reset_for_child()` 之后被父进程 `SIGTERM`：按**默认处置**死于信号 15，且**一个字节都不写**父进程的输出 fd（否则子代理被杀会擦掉父进程的终端） |
| `tty-editor` | termios 布局(60B)/raw 位运算；行编辑（插入/退格/左右/Delete/Home/End/词删除）、
一次喂入多行拆成多个提交、分片转义序列、裸 ESC 判定、历史上下翻、中断前缀裁剪 |
| `preset-knobs-dshsess` | 假 preset（值故意与默认不同：readLimit 7、prune 111/22/33，
且剪枝旋钮放在 group 的 `config` 列表里验证递归）断言旋钮与 persona 折叠标量；
再造一个假 DSH 会话（裸 jsonl）断言扫描、header 解析、前缀查找、导入后的角色序列与 tool_call_id |
| `workflow` | 两个变体：① 假 runner（`--uya-bin /bin/bash` + 一个说同样协议的 shell 脚本）验证钩子协议本身
（阶段/日志/`agent_start`/`agent_wait`/`done` 五个钩子 + 子代理结果回流）；② 真 `uya run` 跑一个 Uya 的
`.ush` 脚本（生成的自包含 hooks.uya 必须真的编译通过）。 |
| `subagent-goal` | 一轮 9 个调用：`create_goal`/`get_goal`/`update_goal(pause)`、`subagent`（后台）+
`subagent_output(wait=true)`、`list_agents`、`subagent_fork`（前台）、`ralph(maxRounds=2)` +
读它的逐轮报告；mock 用 `x-uya-subagent` 头区分父/子请求，第二轮断言目标回显、
子代理结果回到父、`sub-1 [subagent] idle`、`[round 1]/[round 2]` 都出现在请求里 |
| `skills-web-search` | 造一个目录型技能（front-matter + 正文）→ 断言目录注入、`skill` 工具结果模板与
资源指引、未知技能错误串；provider 侧用 mock 的 Anthropic 形状响应，断言 `web_search` 请求带
服务端搜索工具与鉴权头、query 去重后只出现一次、答案与两条来源都被渲染 |
| `compact-prune` | 让 bash 产生 20000 字符输出 → 断言请求里出现剪枝标记、完整中段已消失 |
| `compact-auto` | 小窗口（200）强制触发：工具轮 → **摘要请求**（断言提示词模板）→ 压缩后的请求里
必须出现 `automatically generated checkpoint` 与 `<compacted-summary>` |
| `history-long` | **「历史条数默认不限制」的验收**：mock 连回 40 轮 × 2 个工具调用（≈124 条消息）→
断言回合正常结束（旧实现在第 64 条处中断，报 `could not append tool result to history`）、**每个请求都配对完整**
（每个 `tool_calls` 后面紧跟应答它的 `tool` 消息 —— 这正是端点 400 的判据）、且最后一轮请求里 80 条工具结果
一条不少（数 `"tool_call_id":"call_h…`） |
| `hist-repair` | 尾部修复语义：完整的一组（2 调用 + 2 应答）**一条不丢**（旧实现会把结尾的 tool/assistant_calls
一路丢空）；缺应答 / 零应答 / `tool_call_id` 对不上 → 整组丢掉；孤儿 tool → 丢掉；尾部是 user 时不动；
每步都用 `hist_pairing_ok` 复核，并断言 `h.bytes` 记账仍然准确 |
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
| `resp-text` | Responses 流式：`created/in_progress` + `output_item.added/done` + `output_text.delta` ×2 + `completed` → content、`input_tokens(100)-cached(40)=60`、out/reasoning、`finish=stop`；`event:` 行必须被忽略 |
| `resp-tools` | Responses 工具轮：`reasoning_summary_text.delta` ×2 + 两个 `function_call`（`output_item.added` + arguments 交错分片 ×4 + `done`）+ `completed` → `ncalls=2`、`call_id`/`name`/拼好的 `args`、`finish=tool_calls` |
| `resp-args-done` | 只在 `output_item.done` 里给完整 `arguments`（不发 delta）也能补齐 |
| `resp-terminal-only` | 只发 `created` + `completed`，正文/参数只在终局 `response.output[]` 里 → 必须回填（按 `call_id` 建槽） |
| `resp-incomplete` | `response.incomplete` + `incomplete_details.reason=max_output_tokens` → `finish=max-tokens` |
| `resp-failed` | `response.failed`（`error.code/message`）→ `finish=error` + `err_text` 带 `code: message`，且**不是** `STREAM_CLOSED` |
| `resp-noterminal` | 缺终局事件 = 流被截断（`STREAM_CLOSED`），但已收到的正文保留 |
| `resp-doneframe` | 代理多补一帧 `[DONE]` → 当正常收尾（协议本身不发 `[DONE]`） |
| `resp-chatshape` | 网关把 responses 的流按 chat 形状（`choices[].delta`）回 → 兜底解析仍拿到正文 |
| `resp-badjson` | 半截 JSON 帧 → `MALFORMED_RESPONSE` + payload 头部，之前内容保留 |
| `resp-nonstream` | `responses_out_from_nonstream`：`output[]` 的 message（含 refusal）/reasoning/function_call（`call_id` 带 `\|` 要拆）+ usage + `status=incomplete` 全字段断言 |
| `resp-build` | 扁平工具 schema 逐条 parse（顶层 `name`/`parameters`、没有 `function` 键）+ `build_model_request` 的 `input` items / `store` / `max_output_tokens`（8→16）/ `reasoning.effort` / `developer→system` 开关 / `api_url` 拼接（base 带不带斜杠） |
| `api-negotiate` | 协商状态机：未声明时默认 responses；404/405/501 才可协商、200/400/401/500 不行；协商一次后锁存；显式声明后恒不协商；**DSH 的 `api:` 真的落到 cfg**（`openai-responses`/`openai-completions` → `src_api=1`，不认得的按未声明处理） |
| `responses` | 端到端（mock mode 19）：整轮 agent 循环走 `/v1/responses`，mock 断言请求是 responses 形状（有 `input`、无 `messages`、`developer`、`store:false`、扁平 tools），第二轮断言 `function_call`/`function_call_output` 配对（无 `tool_call_id`）与工具输出 |
| `responses-nostream` | 端到端（mock mode 20）：`--no-stream` + responses（`"stream":false` + 一次性 JSON 响应） |
| `responses-fallback` | 端到端（mock mode 21）：**未声明**协议 → 第一个请求打 `/responses`（mock 回 404）→ 同一步改用 `/chat/completions` 重发，之后每轮都必须是 chat（钉住「只协商一次」） |
| `responses-compact` | 端到端（mock mode 22）：自动压缩也跟随协议 —— 摘要请求与压缩之后的请求都必须走 `/v1/responses`（有 `input`、无 `messages`），并断言 checkpoint 文案 |
| `api-flags` | `make e2e-api`：默认 = responses + negotiable；`--api=chat` / `UYA_AGENT_API=responses` 生效且不再协商；非法 `--api=` 报错退出；`--dry-run` 的请求体跟着协议走 |
| `diff-render` | 纯函数逐字节断言 diff：新旧一样 → 空（且**不输出上下文**）、只差结尾换行 → 空、
中间一行改动 → 前后各 2 行上下文 + `-`/`+`、新文件 → 全 `+`、两侧 >60 行 → 只给精确汇总、
60 行编辑脚本 → 头截断成 24 行 + `… (省略 36 行)`、增删计数、按显示列截断（汉字 2 列） |
| `tool-view` | 工具内容块的逐字节断言：bash exit 0/exit 1 的字形与 `· exit N`、`Error: ` → `✗`、
参数不是合法 JSON → 无括号无摘要、read 的 `· lines a-b`、todo 的计数与清单（✓/▸/·）、
write 的 `· +A -D` + diff 正文、**失败的 write 不留假 diff**、窄终端下按列截断补 `…`、
结果首尾 + `省略` 标记、`--tool-lines 0` 无正文；最后**把 fd 2 接到文件做端到端断言**：
关闭态抓到 0 字节、打开态抓到的字节与 `view_render_block` 完全一致 |
| `session-log` | 写 header/事件 → 读回逐行校验（转义层级、`tool_calls` 数组提取、`callId`）；
**内容里的控制字节（NUL、0x01）必须按字节往返**（写入端写 `\u00XX`，读回不许变成字面量 `u0000`）；
手工追加半条记录 → 断言丢弃并标记 `dropped_tail`；用日志重建历史 → 断言角色/`tool_call_id`
且能重新组装成合法请求；索引与按 id / 最近查找 |
| `json-escape` | 纯函数逐字节断言请求体的字符串转义：`0x00…0x1f` 全部转义（`\b`/`\f`/`\n`/`\r`/`\t`
与 `\u00XX`）、`"` `\` 转义、输出里不再有裸控制字节、`jw_key` 同规则 + 冒号、空串与中文不被改坏
（std 的 `json_write_str_view` 只认 5 个短转义，退回它就必然红） |
| `ctrl-bytes` / `ctrl-bytes-resp` | 端到端（mock mode 23，chat 与 responses 各一轮）：mock 让 agent 真跑一条**输出含 NUL** 的命令（`printf 'A\000B'`）→
第二轮断言这条工具结果以 `\u0000` 的形式回到请求里、id 配对完整（chat 看 `tool_call_id`，
responses 看 `call_id`）；**chat 与 responses 各一轮**，且顺便断言端点没串（`POST /v1/chat/completions` vs `/v1/responses`）。
再加上「每个请求体都不许有裸控制字节」的全局哨兵（判定码 240）—— 这条就是真机那次
`invalid character '\x00' in string literal` 的本地等价判据 |

**P1/P2 的验收事实**（2026-10-02）：

* 5 轮流式轮 + 6 轮既有轮全部通过；前一阶段的所有断言（tools schema、越权路径、
  超时 SIGKILL、401、熔断）在流式路径下同样成立。
* 严格协议在**请求字节**上被断言：`"role":"assistant"` + `"tool_calls"` 原样回灌、
  `"id":"call_…"` 保留、`"tool_call_id"` 条数与调用数一致（shell 2 / no-shell 1 / tools 4）。
* TTY 交互用**真 pty** 验证（`script -qec`）：进入 raw 模式、banner 干净、一次粘贴
  4 行会分成 4 次提交（任务 → `/help` → `/status` → `/exit`），退出后终端恢复。
* **中文乱码修复的验收（2026-10-03）**：在真 pty 里跑交互模式，把输出的字节回放进一个
  只实现本项目所用控制序列的极简终端模拟器（**临时写的一次性校验脚本，没入库** —— 仓库里的
  常驻回归是 `make selftest` 的 `tty-editor` 轮 + `make codegen-audit`），
  逐屏断言「没有 UTF-8 替换符、banner 不丢行」。
  修前：提示符前每次挂 5 字节乱码、旧行擦不掉，屏幕上叠成
  `乱码> 乱码> 写一篇30000字未来科技小说…`（66 个替换符）；修后：0 个替换符，
  中文退格/左移/Delete/Ctrl-W/折行/`/help` 输出全部正确。
  另外用**本地假网关**（`text/event-stream`，含「把事件字节切在汉字中间」的分段）
  把真实回合跑了一遍：流式输出的中文完整、流式期间敲入的 steer 字被正确画在输入行上、
  回合结束提示符重画干净（修前同一场景下正文末行会被擦掉一段）。
* 子代理在真机上验证过：让模型「用 subagent（前台）让子代理写一个 hello.sh 打印 SUBAGENT-OK」→
  子代理真的创建并自测了脚本，父进程又独立复核了一遍输出；`subagent_fork` 的子代理历史里
  确实带有父会话已完成轮次的内容（调试输出逐条列过）。
* **历史容量与尾部修复的验收（2026-10-03）**：`history-long` 先写、在旧实现上跑出真实故障
  （`[history] dropped oldest message to stay within limits` + `error: could not append tool result
  to history`，`agent_run` 返回 3），修后同一轮 PASS（41 次请求全部配对完整、80 条工具结果一条不少）。
  再用**真实故障会话**做只读复验（把 `~/.uya-agent/sessions/**` 里那条会话复制到临时 `--agent-home`，
  跑 `--resume <id> --dry-run --no-save`，并用同一个配对判据复算请求体）：
  ① 原样恢复：旧二进制把 60 条恢复消息丢了 59 条（只剩 system + 3 条注入消息），新实现 0 条被丢、
  `messages=63`、`tool_replies=37`、配对违规 0，第 10 步 `edit` 的结果（`has been updated successfully`）
  仍在请求里；② 把日志截在「assistant(tool_calls) 已落盘、tool 结果还没落盘」的形状
  （= 用户当时卡死的状态）：旧二进制丢 58 条（`messages=4`），新实现只丢 1 条悬空 assistant
  （`messages=61`、配对违规 0）—— 也就是 `/continue` 现在能继续。
* **控制字节转义的验收（2026-10-03，对应踩坑 27）**：先用**本地假网关**（一次性 Python mock，
  逐请求统计裸控制字节）把故障复现到字节级：mock 让 agent 跑 `printf 'A\000B'`，第 2 次请求体里
  出现 1 个裸 `\x00`（`"content":"A\x00B\n[exit code: 0]"`）—— 这正是真机
  `invalid character '\x00' in string literal` 的来源；修后同一条请求里是 `A\u0000B`、裸控制字节 0。
  再用**真实故障会话**做只读复验（把 `~/.uya-agent/sessions/---home-winger-uya-agent--/` 里那条会话
  复制到临时 `--agent-home`，同样打到本地假网关，`--no-save`）：① 旧二进制恢复后的请求里，那条带
  NUL 的工具结果成了字面量 `u0000`（`\u0000` 计数 0）—— NUL 在恢复时被静默吞掉；② 新二进制同一
  请求里是 `\u0000`（计数 1）、裸控制字节 0，186 条恢复消息一条不少、`tool_call_id` 配对完整。
  另外是**先写测试再修**：`json-escape` 与 `ctrl-bytes` 两轮在旧 `json_write_str_view` 路径下必然
  失败（前者报「控制字节转义文本不对」+「字面量里还有裸控制字节」，后者报判定码 245），修后全绿；
  与「默认走 responses」那条线合流后，控制字节轮在 **chat 与 responses 两条协议**上各跑一遍都通过
  （合流时还顺手修了 mock 的 responses arguments 分片形状，见「Responses 接口」一节最后一颗星）。
  最后在**真机网关**上收口：用本地 mock 造一条「工具结果里带 NUL」的小会话（`--agent-home` 与
  `--workspace` 都在临时目录），再用修好的二进制 `--resume` 它并追加一句新任务 —— 真机返回正常
  回答（不再 400），证明转义后的 `\u0000` 被真网关接受；随后又用 `make e2e TASK="…"` 跑了一轮
  全新会话，同样正常。
* 技能与联网搜索都在真机上验证过：让模型「说出本次会话可用的技能名」→ 正确回答
  `agently-mail、h2s-long-context`（来自真实 `~/.dsh/skills`）；让它「用 web_search 搜 uya 语言」→
  `web_search` 工具真的调通了 DeepSeek 的搜索服务并给出总结。
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
  `--print-config` 显示 `base_url/model/api_key/context_window/confine/tls_verify/tls_pin`
  （以及 P14 的 `tool_lines` 与显示开关状态）
  的来源全是 `dsh-settings`，实际提问「2+2 等于几」得到 `4。`
  （TLS pin 也写在 `~/.dsh/settings.yaml` 的 `uya-agent.tls` 节里，连环境变量都不用给；
  三个「决定去哪儿读设置」的 flag 由 `make e2e-config-flags` 常驻回归）。
* 会话恢复做了**跨进程 + 真实模型**验收：进程 1 让它「记住 4271」，进程 2 `--continue`
  带恢复的历史问「我刚才让你记住的数字是多少」→ 回答 **4271**；日志里 header 只有一条、
  `seq` 跨两个进程连续 0…9。
* 真实网关（autodl，`DeepSeek-V4.1-Flash`，pin 模式）跑「创建 hello.uya → 编译 → 运行 → 结论」：
  3 步完成（write_file → run_shell → 结论），stdout 流式输出
  `运行输出：\`Hello, Uya!\`（编译通过，退出码 0）。`，产物 `hello` 是真实 ELF、
  独立运行输出 `Hello, Uya!`；usage 逐轮打印（含 `cache_read=896` 前缀缓存命中）。
* P14 显示层在真机上验收过三次（零参数配置 + `--tls-verify=none`）：
  ① 「创建 → 编译运行 → 改问候语」的完整任务，`write` 块给出 `+4 -0` 与 4 行 `+`、
  `edit` 块给出 `- @println("Hello, Uya!")` / `+ @println("Hello, DSH!")` 与两侧上下文、
  bash 块给出 `· exit 0` 与首尾各 6 行 + `… (省略 42 行)`；
  ② 同一任务加 `--quiet`：stderr 只剩正文流，**没有**任何 `✓/✗` 行（旧的最小转录）；
  ③ 用 `script` 分配 PTY 跑 REPL：工具运行期间提示符变成 `● Bash(echo PTY-CHECK) > `，
  返回后恢复 `[step 1] > `，内容块落进滚动区，全程没有乱码（P3 的擦除/重画协议照旧成立）。
| `http401` | mock 回 401 + 错误体：agent 必须打印状态与错误体并退出 3 |
| `max-steps` | **显式**给 `max_steps=3`：mock 每轮都给 tool_calls，agent 必须在 3 步后熔断退出 3 |
| `unlimited-steps` | **默认不限步数**（这轮故意不设 `max_steps`，吃 `cfg_default()` 的 0）：mock 连给 **14 轮** tool_calls（超过旧默认 12）才给最终答案 —— agent 必须一路跑满 14 步、把 14 条 `tool_call_id` 全带回请求，并以 0 退出。默认值一旦改回 12，mock 只会被服务 12 次，这轮立刻失败 |
| `hist-keep` | 丢老消息的两条保护：`hist_drop_oldest` 必须留住 system 与**任务原文**（下标 1 的 user），且 `assistant(tool_calls)` 与其 tool 结果整组丢；连追加 40 组之后（远超旧 `MSG_MAX=64`）任务原文仍在、历史仍不以悬空 tool 开头（历史条数默认不限制，见 `history-long`） |

另外几条独立验收：

```bash
make check                                   # A1 类型检查通过
make build                                   # A2 产出 build/uya-agent
make probe BASE=https://api.deepseek.com/v1  # A4 期望 HTTP 401 + leaf 指纹（无需 key）
make e2e-steps                               # 步数默认值回归：默认不限步数、CLI/env 同口径（离线）
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

**Responses 协议的真机验收（2026-10-03）**：本机 DSH 设置里那几条 `api: openai-responses` 路由当时都
打不通 —— `tirisen`（`https://gpt.tirisen.hk/v1`）对 `/responses` **任何**请求体（含用 curl 手写的最小
body）都回 `502 upstream_error`，而它的 `/chat/completions` 回 400
（`The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account`，即该路由是 Codex 形状）；
`aigw`（`https://mnl.iotalking.top/aigw/v1`）DNS 解析不了；`sglang-8080` / 本地 Ollama 都没起。
所以 Responses 这条线的验收**只做到**：① `--print-config` 从真 `~/.dsh` 正确读出
`api = openai-responses (source: dsh-settings)`；② 真机请求确实打到了 `/v1/responses` 并正常拿到
HTTP 状态与错误体（没有被网关当成坏请求体拒绝）；③ 协议本身由 §6 的两条端到端轮（`responses` /
`responses-nostream` / `responses-fallback` / `responses-compact`）在真实 socket + chunked 分片的
mock 上逐字段验收。换一台 `openai-responses` 网关可用时，零参数再跑一次即可（`--print-config` 先看
`api = …  (source: dsh-settings)` 与 `endpoint = responses`）。

---

## 7. 已知限制

* 上下文管理很朴素：整个历史每轮重新序列化（没有 token 级增量缓存）。历史**条数默认不限制**，
  内存随会话线性增长，唯一的收敛机制是「按 token 压力的自动压缩」——
  所以**没有配置 contextWindow 时（`--no-dsh-config` 或模型条目里没有 `contextWindow`）压缩不会触发**，
  长会话请显式给 `--context-window N` 或用 `/compact` 手动压一次。单条消息 200 KiB 会在入史时被
  剪枝/截断（会话日志仍是全文）。
* **默认不限步数**：模型若陷入工具循环不会自动停 —— 交互模式 Ctrl-C 中断本回合（历史保留），
  脚本/CI 用 `--max-steps N` 或 `UYA_AGENT_MAX_STEPS=N` 熔断（`make e2e` 也可 `STEPS=N`）。
  没做「重复调用检测」这类启发式熔断。
* `read_file` 一次最多 64 KiB；`write_file` 是整文件覆盖，没有 diff/patch 工具。
* 滚动模式（`--no-tui`）仍然没有颜色、不做 markdown 渲染；TUI 模式下有颜色 + 轻量 markdown
  （围栏代码块、行内 code、标题、列表），但不做完整语法高亮/表格/链接重排。
* TUI 不做鼠标（滚轮/点击/选择）、图片、可折叠卡片、分屏、主题切换 UI；`--resume` 只回填
  最近 200 条历史（注入类消息不回填），`--resume-dsh` 走同一条回填路径。
* 终端小于 32×8 时自动退回滚动模式；`cols < 66` 时块字 logo 退化成一行标题。
* `SIGKILL` 之后终端仍可能停在备用屏幕（不可捕获），用 `reset` / `stty sane` 恢复。
* diff 是行级的、面向显示：中间段两侧超过 60 行就退化为两行汇总（不做 Myers 全量 diff），
  也不高亮词级改动。
* 只做 IPv4（标准库 `dns_client_resolve_first_ipv4`），不做 IPv6、不走代理。
* Responses 协议只做 `openai-responses`：`anthropic` / `azure-openai-responses` /
  `openai-codex-responses` 不支持（前者认证与端点都不同，Azure 还要 `api-version` 与 `api-key` 头，
  Codex 走 OAuth），设置里写了会告警并退回「未声明」处理。
* 未声明协议时**首次请求可能多一次 404**（先用 `/responses` 探一次），只留一行 `[api]` 提示。
  协商结果只存在于进程内，不写设置也不写会话（换进程会重新探一次）。
* 不做 DSH 的 `reasoningEfforts` 模型级 clamp：`reasoning.effort` 原样透传设置里的值
  （网关不认就 `--reasoning-effort off` 或 `--api=chat`）。
* Responses 下不回放 reasoning item（不发 `include: ["reasoning.encrypted_content"]`，
  也不发 `prompt_cache_key`/`prompt_cache_retention`）；历史按「外来消息」重放，只带文本与工具调用。
  工具 schema 不带 `strict`，也不做 404 之外的协议自动探测（换个协议请显式 `--api=`）。
* 目标平台是 Linux x86-64（代码里的 syscall/常量按这个平台写）。
* 换到 `uya-0.11`：`tls/https.uya`、`std/json/*`、`x509/verify.uya` 与 0.10 逐字节相同，
  但 `libc/syscall.uya`、`std/runtime/runtime.uya`、`tls/ssl/context.uya` 有差异，需要重新验证
  （`make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...`）。
