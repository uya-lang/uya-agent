# uya-agent — 纯 Uya 写的极简 CLI 编程 agent

一个**只用 Uya 源码**实现的命令行编程 agent：给它一句话任务，它自己看文件、改文件、跑命令，
多轮 loop 直到给出结论。全部代码 38 个 `.uya` 文件，**不引入任何 C 代码、`@c_import` 或其它语言**，
只依赖 Uya 语言与随编译器分发的标准库。

**P0–P20 全部完成**（P15 这个编号被两条并行线各用过一次：一条是「请求体控制字节全转义 +
默认走 Responses 接口」（落点见 §3 踩坑 27、§2 的 `jsonx.uya`/`session.uya`、§6 的
`json-escape` / `ctrl-bytes*`）、一条是**子代理窗口面板**（§2 的「子代理窗口面板（并行线的 P15）」，
踩坑 29）；P16 是**单行转录 + 思考行**，P17 是**纯 Uya 的全屏 TUI**，
P18 是**常驻状态区 + 思考实时行**；**P19 是诊断出口与 read 窗口**：外来字节（网关错误体 /
坏 payload 头部）只以「转义 + 字符边界截断 + 限长」的一行预览进转录，全文进会话日志
`diag/dump`、原始字节走 `--debug-dump`（踩坑 33）；`read` 改成**流式窗口**读法，`total` 是
数完整个文件得到的真值、只有真越界才报 EOF（踩坑 34））：
LLM 交互是**流式 SSE**（`stream:true` + `stream_options.include_usage`），
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
**P16 把转录压成单行**（对齐 DSH 会话视图里「折叠状态」的样子）：工具只留
`✓ Bash · 打印三行 · exit 0` 这一行（正文退成 `--tool-lines N` 的可选项），
思考（`--show-reasoning`）压成 DSH 的 **Think 行** —— 运行中在提示符那一行里滚动、
块结束时落一行 `✻ 思考 · <首行>…`，**全文写进会话日志**（`assistant/reasoning`）。
**P21 把「权限」补齐成 DSH 的样子**：三级访问模式（`read-only` / `workspace-write` /
`danger-full-access`，机器名与 DSH 一致）、输入面板上的访问模式 chip 与 `shift+tab` 选择浮层
（Full access 过风险确认）、`/permission [预设]`、来源链（CLI / `UYA_AGENT_PERMISSION` /
DSH `permission.defaultPreset`），read-only 下 `write`/`edit` 硬拒、`bash` **逐条人工批准**，
外加**真的内核沙箱**：confined 模式的 bash 在 **bubblewrap** 的 mount namespace 里跑
（只读根 + fresh `/dev` + 私有 PID 的 `/proc`，workspace-write 另加临时 `/tmp` 与可写工作区 bind），
起不来就 fail closed，绝不静默降级。
**P15 给子代理加了窗口面板**：输入行上方常驻一块带边框的窗口区，每个运行中的子代理 2 行
（命令行 + 状态行，含**实时秒数**与已收输出行数），最多显示最后 4 个，跑完立刻收掉并在滚动区
补一行结算通知；边框按显示列逐行补满，自测对每一行断言「列数完全相等」。
**P17 是纯 Uya 写的全屏 TUI**（对齐 opencode 的观感），**P18 把运行状态挪进常驻状态区并加了
思考实时行**：P17 的状态行是「转录的最后一行」，转录一铺满视口就被挤掉 —— 长会话里跑起来
屏幕上**一个动的字节都没有**，看着像卡住（踩坑 32）。现在状态区钉在输入面板正上方
（运行中 1–2 行、空闲 0 行）：第 1 行是 spinner + 状态，第 2 行是**思考的实时文本**
（默认就开、与 `--show-reasoning` 解耦、按显示列从左边截断补 `…`、只留尾部 1 KiB）。
**P20 给脚注加上 DSH 那一行统计**：`轮/步 · LLM/工具耗时 · 首 token 平均/tok-s · 缓存命中 ·
输入/输出 tok` 全部从**会话日志**折叠（`--resume` 后仍逐字节相同），左边再挂上下文占用
（`ctx`，DSH `contextPressure` 的口径）与**全部 uya-agent 进程**的综合 CPU（`%cpu`，
`/proc` + `USER_HZ` 口径）；终端放不下就从尾部丢组，明细进 `/status`。
`--no-stream` / `--compat-fold` 保留两条回退路径。

```
$ ./build/uya-agent --show-reasoning "在当前工作目录写 p15-demo.txt，三行 alpha / beta / gamma；然后用 bash 打印它，并告诉我第二行。"
[task] 在当前工作目录写 p15-demo.txt，三行 alpha / beta / gamma；然后用 bash 打印它，并告诉我第二行。

✻ 思考 · The user wants me to write a file p15-demo.txt with three lines alph…    # Think 行：折叠就是一行
✗ Write · build/p15_ws/p15-demo.txt · 1 lines                                     # 每次工具调用一行（失败是 ✗）
✻ 思考 · The write failed with an error. Let me try with the absolute path or…
✓ Bash · Check working directory and contents · exit 0                            # bash 摘要 = description
✻ 思考 · The write tool failed. Maybe it needs absolute path? Let's try absol…
✓ Write · /home/winger/…/build/p15_ws/p15-demo.txt · +3 -0
✻ 思考 · Now print it with bash and get the second line.
✓ Bash · Print file and second line · exit 0

第二行是 `beta`。
```

（这是真机转录的节选：`--show-reasoning`、`autodl-api` 网关 / `DeepSeek-V4.1-Flash`，
交互模式里那几行 `✻ 思考` 会先在提示符那一行里滚动、块结束才落成上面这样一行；非交互跑法
（管道）没有实时行，只有结算的那一行。中间那次 `✗` 是模型自己把路径写错了，显示层照实记下。）

（`--tool-lines 6` 会把 P14 的正文块开回来：write/edit 的 diff、结果首尾各 6 行、todo 清单。
DSH 的卡片在终端里不可折叠，P16 的取舍是**默认折叠成一行**，要看细节就显式开。）

---

## 1. 构建与运行

需要一个 Uya 编译器（默认用 `/home/winger/uya-0.10`，可在 Makefile 里改）：

```bash
make check        # 词法/语法/类型检查
make build        # 产出 build/uya-agent
make selftest     # 离线端到端自测（内置 mock LLM，不需要网络也不需要 key）
make codegen-audit # 扫构建产物：不许出现「切片描述符 → 字节指针」的强转（终端乱码源头）
make e2e-permission # 访问模式的四级来源 + 非法值报错（离线）
make e2e-sandbox    # 沙箱后端探测 / --no-sandbox / 显式 bwrap 路径（离线）
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
| REPL 命令 | `/help` `/continue` `/status` `/compact` `/plan` `/permission [预设]` `/sessions` `/resume <id>` `/new` `/exit` |
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
| `--permission MODE` | **访问模式**（P21）：`read-only` / `workspace-write` / `danger-full-access`（默认）。也收 `--permission=<MODE>`；非法值报错退出。来源优先级 CLI > `UYA_AGENT_PERMISSION` > DSH `permission.defaultPreset`，见「访问模式」一节 |
| `--no-sandbox` | 关掉 bash 的内核沙箱（bwrap）：confined 模式不再套壳、也不再 fail closed（启动打一行警告） |
| `--bwrap PATH` | 指定 bwrap 可执行文件（默认探测 `/usr/bin/bwrap`、`/bin/bwrap`、`/usr/local/bin/bwrap`） |
| `--skill-dir DIR` | 额外的技能根（冒号分隔，可多次） |
| `--uya-bin PATH` | 跑 workflow 脚本的解释器（默认 `$UYA_BIN` 或 `uya`） |
| `--no-compact` | 关闭自动上下文压缩 |
| `--context-window N` | 压缩判定的窗口（默认取 DSH 模型条目） |
| `--dsh-root DIR` | packaged preset 根（读 persona / plan 段文案） |
| `--dry-run` | 只组装请求并打印（不可打印字节转义成 `\xNN`，排查脏字节） |
| `--debug-dump FILE` | 诊断的**原始字节**（网关错误体 / 坏 payload 头部等）追加落盘（设路径时先清空）；默认关：转录里只有转义预览，全文仍进会话日志 `diag/dump`（见踩坑 33） |
| `--compat-fold` | 工具结果折叠成一条 user 消息（旧协议） |
| `--no-stream-options` | 不发送 `stream_options.include_usage` |
| `--show-reasoning` | 显示思考行（P16 单行口径：滚动模式下运行中在提示符那一行滚动、结束落一行 `✻ 思考 · …`；全文始终进会话日志）。**TUI 下另有一条默认就显示的实时行**（P18，见「全屏 TUI」一节），这个开关在 TUI 里只管「额外把思考收进转录条目」 |
| `--show-usage` | 每轮打印 token 用量（in/out/cache/reasoning） |
| `--tool-lines N` | 工具正文：默认 `0` = 只留一行（P16）；`N>0` = 首尾各 N 行（含 diff / todo 清单，即 P14 的正文块） |
| `--tui` | 全屏 TUI（**TTY 交互模式默认**）；`--no-tui` 退回滚动转录；`UYA_AGENT_TUI=0|1` 同口径。运行中的状态区（spinner + 思考实时行）钉在输入面板正上方，关掉它的方式就是 `--no-tui` / `--quiet` |
| `--color=MODE` | `auto`（默认）/ `always` / `never` / `16` / `256`；`NO_COLOR` 也认 |
| `--tui-demo` | 打印 TUI 的 home / chat / 运行中 三屏纯文本快照后退出（诊断 + 文档） |
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
`UYA_AGENT_REASONING_EFFORT`（`off`/`none` = 不发）、
`UYA_AGENT_PERMISSION`（三档访问模式，非法值告警后忽略）、
`UYA_AGENT_SANDBOX`（`0`/`off` = 等价于 `--no-sandbox`）、`UYA_AGENT_BWRAP`（bwrap 路径），
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
                  在没换行的正文后面都只擦自己那一块）、提示符即状态显示、
                  按显示列截断（`tty_clip_bytes` 截尾 / `tty_clip_tail_bytes` 留尾）、
                  **多行「面板块」**（输入行上方常驻的窗口区：逐行 ESC[2K 擦除 + 相对上移，
                  子代理窗口面板就画在这里）；P17 再加：TUI sink 开关（TUI 激活时所有显示
                  字节进转录，不再打到终端）与 `tty_reason_write`（思考走独立通道）；
                  P19 再加：`tty_diag_escape_into` —— 诊断字节的**唯一**转义实现（转义控制
                  字节与非法 UTF-8、按字符边界收 cap，见踩坑 33）
src/sigx.uya      信号层（P17）：直接绑宿主 glibc `sigaction`（绕开 uya 0.10 `libc.signal`
                  的 SIGSEGV 缺陷）；终止类信号 → 先恢复终端（termios + 离开备用屏幕）再
                  128+sig 退出；SIGWINCH → 只置标志；`sigx_reset_for_child()` 给 fork 子进程
src/tui.uya       全屏 TUI（P17/P18）：帧模型（行=段序列，逐行 diff 重绘）、备用屏幕进出、
                  **访问模式 chip 与底对齐选择浮层、阻塞式确认（tui_confirm_wait）**、
                  转录条目（用户/助手/思考/工具/诊断）、轻量 markdown、输入编辑器（按字符编辑、
                  多行、历史、括起粘贴）、键解码（分片转义序列）、浮层（命令面板/会话/帮助/问答）、
                  sink 通道与清洗、滚动与尾随、帧节流；P18 再加**常驻状态区**（钉在输入面板正
                  上方：spinner 行 + 思考实时行，空闲 0 行）与尾部对齐截断 `tui_put_clipped_tail`；
                  P19：诊断（NOTICE）条目限长（`TUI_NOTICE_MAX`）、非法/半截 UTF-8 → U+FFFD、
                  思考尾部按字符边界切
src/sigselftest.uya 信号层的自测轮次（sig-abi / sig-basic / sig-term-restore / sig-child-reset）
src/tuiselftest.uya TUI 的自测轮次（tui-frame / tui-keys / tui-sink / tui-turn / tui-status / tui-pty；
                  P20 起 tui-frame 还断言脚注统计行在四种宽度下的退化）
src/inbox.uya     输入收件箱：steer（运行中输入的文本，step 边界领取）+ keepInbox 语义
src/yamlcfg.uya   自带 YAML 子集解析器：去注释（块标量/引号感知）、中和 `!!tag`、
                  block/flow 映射与序列、`|`/`>` 块标量、跨行 flow 集合、节点池树 + 导航
src/fsx.uya       文件工具：路径解析（可选工作区守卫）、**read-only 模式下 write/edit 硬拒**、
                  (mtime,size) 版本、观察状态表、
                  read（**流式窗口** `fs_read_window`：真 total + 只缓冲选中行 + 行号 + 三种
                  footer + 行长/字节上限）、write（createIfAbsent / replaceIfVersion）、
                  edit（唯一匹配 / replace_all）src/shellx.uya    bash 工具：bash -c、workdir、timeoutMs、run_in_background、stdout/stderr 分开收、
                  **read-only 逐条人工批准**（TUI 浮层 / 滚动模式 y-N / 无通道则 fail closed）、
                  **confined 模式下套 bwrap profile 执行**（起不来就拒绝）、
                  结果标记（[exit code: N] / [timed out after Nms] / [killed by signal: N]）、DSH_* 环境注入
src/jobs.uya      后台任务表：注册/增量输出（保留内存尾部 1 MiB）/状态机（running/completed/killed）、
                  job_list / job_output（wait + timeout_ms）/ job_kill
src/search.uya    glob / grep：rg 子进程（--files / --json）、VCS 目录排除、条数与行长上限
src/dshsess.uya   读 DSH 自己的会话：扫 <DSH_HOME>/sessions、解析 header、zstd 用 /usr/bin/unzstd
                  解压、把 user/message + assistant/message + tool/result 转成我们的历史
src/dshcfg.uya    读 DSH 设置：$DSH_HOME 解析、settings.yaml 模型路线（agent-default-model →
                  provider 的 baseURL/apiKeyEnv/models[]）、.credentials.yaml、.env 兜底、
                  permission.defaultPreset→访问模式（三级）、uya-agent.tls 命名空间
src/workflow.uya  workflow：把脚本写成 .ush + 生成同目录的自包含 hooks.uya（钩子客户端）、
                  监听 127.0.0.1 的钩子端口、fork+exec `uya run`、边等服务脚本边处理钩子
src/deleg.uya     子代理：fork 不 exec（同二进制跑 agent_run）、结果管道 + 增量读取、
                  父子会话关联（subagent/start 事件）、前台/后台、send_message 续跑、interrupt、ralph、
                  spawn 时刻记账（面板秒数）+ 终态结算通知（跑完即隐）
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
src/perm.uya      访问模式（P21，对齐 DSH permission-presets）：三级 read-only / workspace-write /
                  danger-full-access（机器名与 DSH 一致）、显示名与产品名、策略真值表
                  （confine / allows_write / requires_approval），进程级当前值
src/sandboxx.uya  内核沙箱（P21，对齐 DSH bash-sandbox 的 Linux bwrap 档）：bwrap 探测（功能探测 +
                  进程级缓存）、按访问模式拼 profile argv（只读根 + fresh /dev + 私有 PID 的 /proc；
                  工作区写另加 ephemeral /tmp 与可写 workspace bind）、不可用时的 fail-closed 判定
src/askuser.uya   ask_user_question：交互模式复用行编辑器，非交互读一行，EOF 时回「无回答」；
                  P21 加 ask_approve_command（read-only 下 bash 的逐条批准通道）
src/session.uya   会话日志：路径规范化、id 生成（/dev/urandom→uuid）、header/事件序列化与追加写、
                  索引、读取与崩溃尾部裁剪、按 id/最近查找、括号配平的数组提取
src/stats.uya     会话统计折叠（P20）：逐行对照 DSH 的 `sessionStats` + `tokenUsage` ——
                  step/start→assistant/message 的 llmMs、首个非空正文 delta→消息组装的 ttft 与
                  解码时长/token、tool/call→tool/result 按 callId 配对、step/end 计步
                  （turns 只在该 turn 首次出现时 +1）、未结算调用在 turn/end 丢弃；
                  上下文占用与三段启发式（contextPressure / contextBreakdown 的等价物）；
                  渲染逐字对照 DSH Web 的 `StatsLine`（formatDuration / formatTokens /
                  formatTokensPerSecond / cacheHitPercent，含「有 miss 时不写 100%」的精度阶梯）
src/procx.uya     进程 CPU 采样（P20）：扫 /proc，取 comm 与本进程相同的**所有**进程的
                  utime+stime（不取 cutime/cstime，避免父子双计），USER_HZ = 100、
                  pct = Δticks×1000/Δms（单核口径，可 > 100%），1 秒一次、挂在 TUI 心跳上
src/diffx.uya     行级 diff（只服务显示）：公共整行前后缀裁剪 → LCS DP（60×60 上限）→
                  行列截断 + 头截断；全局暂存最近一次变更，view 层 take 走
                  （P16 起正文默认关闭，它只喂 `· +A -D` / `· replaced` 这两个后缀；
                  正文要 `--tool-lines N`（N>0）才会被 append）
src/view.uya      显示层：工具→标题/关键参数/后缀三张表、状态字形、按显示列截断、
                  **单行转录**（默认没有正文块：正文要 `--tool-lines N`（N>0）才 append）、
                  **思考行**（运行中在提示符那一行滚动、块结束落一行 `✻ 思考 · <首行>…`；
                  P18 再加 `view_think_live`：给 TUI 状态区喂「最新一行」，默认开）、
                  交互模式的「运行中提示符」换入换出、
                  **子代理窗口面板**（2 行/个、最多 4 个、带边框、逐行等宽）
src/agent.uya     CLI、环境变量、消息历史、请求组装、主循环（流式/非流式）、工具分发、
                  交互式 REPL（中断/steer//continue/会话命令）、会话事件记录与恢复、
                  `assistant/reasoning`（思考全文，P16）；P17 再加 `agent_run_tui` /
                  `agent_run_tui_body`（全屏 TUI 主循环，headless 与真终端共用）；
                  P19 再加 `out_diag`（外来字节诊断的**唯一**出口：一行转义预览 + 截断后缀，
                  全文进会话日志 `diag/dump`，`--debug-dump` 落原始字节）；
                  P21 再加 `/permission`、`agent_set_access`（切模式 + 推新运行时上下文快照 + 落日志）
                  与访问模式浮层的结果处理（Full access 过第二道确认）
src/selftest.uya  --selftest 的 mock LLM（含 SSE 受控切分）+ 80 轮断言 + --probe
                  （P17 又加了源文件里的 4 轮信号 + 5 轮 TUI，P18 再加 1 轮 `tui-status`，
                  P19 再加 3 轮诊断，P20 再加 9 轮统计/进程 CPU，P21 再加 7 轮访问模式/沙箱，见 §6）

```
> 两处已知死代码（P14 未清理，改别的东西时别被它们误导）：`src/tools.uya`（P0 的
> `read_file`/`write_file`/`run_shell`，早已被 `fsx`/`search`/`shellx` 取代）、
> `agent.uya` 里的 `dispatch_tool`（`JsonStrView` 版，无调用者）。

### 显示内容（P14 的内容模型 + P16 的单行转录）

DSH 的会话视图里每次工具调用是一张卡片：**标题（工具名 + 关键参数）+ 状态 + 分类正文**
（readBody / diffBody / terminalBody / webBody / todo 行），思考（thinking）则是另一行
**Think**：折叠时一行、展开才看全文。DSH 自己没有终端渲染器（197 个包里没有任何
TTY/ANSI 代码），所以这里是把**那套内容模型搬到滚动终端**；P14 搬的是「行 + 正文块」，
**P16 把转录压成一行**（工具只留描述、思考在一行里滚动），正文退成可选项：

```
✻ 思考 · 先读 hello.uya，再改那一行 println…      # DSH 的 Think 行：折叠状态就是一行
✓ Read · hello.uya · 4 lines                      # <字形> <Title> · <摘要> <后缀>
✻ 思考 · 改完重新编译运行确认…
✓ Edit · hello.uya · replaced
✓ Bash · 编译并运行 hello.uya · exit 0
```

* **工具行**：`<字形> <Title> · <摘要><后缀>`。字形 `✓` 成功 / `✗` 失败 / `●` 运行中
  （只在交互提示符里）；标题按工具映射（`Read` / `Write` / `Edit` / `Glob` / `Grep` / `Bash` /
  `Todo` / `Ask` / `WebSearch` / `Subagent` / `Workflow` …）；摘要取关键参数，`bash` 优先取
  `description`（**对齐 DSH 的 `SUMMARY_KEYS.bash = ["description","command"]`**，缺了才退回
  命令行）；后缀是元信息：`· exit 1`、`· timed out`、`· killed by signal 9`、
  `· background job-2`、`· +4 -0`、`· replaced`、`· 3 items (1 done)`、`· lines 100-149`，
  兜底是 `· N lines`（结果文本行数）。失败判定：结果以 `Error: `（工具模块统一前缀）或
  `error: `（派发层的「参数不是合法 JSON」）开头，或 bash 尾部是 `[exit code: N≠0]` /
  `[timed out …]` / `[killed by signal: N]`。
* **正文默认关闭**：`tool_lines = 0`（默认）时**只出行**，diff / 结果首尾 / todo 清单一律不打；
  `--tool-lines N`（N>0）把正文开回来：4 空格缩进、首尾各 N 行、中间 `… (省略 N 行)`，
  `write` / `edit` 用 **diff** 取代首尾，`todo_write` 用清单（`✓` 已完成 / `▸` 进行中 / `·` 待办）。
* **diff**（`src/diffx.uya`）：采集点在 fsx —— `edit` 用读写之间已有的两份内容（零额外 I/O），
  `write` 在 `O_TRUNC` **之前**读一份旧内容（只在显示打开时读，上限 2 MiB）。
  算法：公共**整行**前后缀裁掉（O(n) 扫描，不建行表）→ 中间段两侧各 ≤ 60 行时用 LCS DP
  （61×61 字节表）出最小编辑脚本 → 更大就只给两行精确汇总（`- (N 行旧内容)` / `+ (N 行新内容)`，
  反正显示也只看前 20 行）→ 输出按显示列截断、按行头截断（`max(4×tool_lines, 20)` 行）。
  **失败的 write/edit 不留假 diff**（正文回落到错误文本）。P16 起正文默认不显示，但这套采集
  仍然跑 —— 行后缀 `· +4 -0` / `· replaced` 就是它算出来的（不想付这次旧文件读取的代价，
  可以把 `diffx_init` 的开关改成 `&& cfg_tool_lines(cfg) > 0`）。
* **思考行**（`--show-reasoning`，P16）：和 DSH 的 `ReasoningRow` 同口径 ——
  **运行中取 `latestLine`**（`trimEnd()` 之后的最后一行，视口贴右端 → 终端里就是从左边按列
  截断、前面补 `…`），**结算取 `firstLine`**（这里多一条兜底：第一行全空白就顺延到第一非空行）。
  交互模式下运行中的那一行就是**提示符**（`✻ 思考 · …最新内容 > `，节流 80 ms 重画一次，
  复用 P14 的提示符换入换出机制）；块结束时把提示符还回去，再把 `✻ 思考 · <首行>…` 落进滚动区。
  块结束的判据是 DSH 的块语义：下一条 `content` / `tool_calls` 增量开始，或整段流结束
  （中断、malformed、网络错误也走同一条收尾路径 —— 不会把提示符停在思考行上）。
  非交互（管道）下没有可改写的一行，所以**不做实时行**，只在块结束时落那一行；
  `--quiet`（含子代理）整层关闭，思考行同样不出现，但日志照记（见下）。
  **TUI 里另有一条默认就开的实时行**（P18：常驻状态区的第 2 行，同一套 `latestLine` +
  从左边按列截断补 `…` 的口径，但**不需要** `--show-reasoning`；见「全屏 TUI」一节）。
* **思考全文进会话日志**：每个 step 追加一条 `assistant/reasoning`
  （`{"turn":N,"step":N,"message":{"role":"assistant","reasoning_content":"…"}}`），
  显示层只留一行、全文在这里活着。独立事件而不是塞进 `assistant/message`：那条要**原样**
  回灌给端点（P4 的严格工具协议），DSH 自己也是分开记的；`--continue` / `--resume` 的
  reader 按已知类型分支，不认识这个类型就跳过，历史里不会多出东西。
* **宽度**：全部按**显示列**算（`tty_body_width()` 跟着终端宽度收在 [40,200]，CJK 汉字 2 列），
  截断在 UTF-8 字符边界上回退并补 `…`（`tty_clip_bytes` 截尾、`tty_clip_tail_bytes` 留尾）；
  非法字节按 1 列宽，保证指针一定前进。
* **通道与开关**：内容块一律走 fd 2（正文与模型输出仍走 fd 1，管道语义不变）；
  会话日志不受影响（`tool/call` + `tool/result` + `assistant/message` + `assistant/reasoning`）。
  `--quiet`（含子代理，它们本来就 `quiet=true`）把整层关掉 —— 输出与 P13 之前的**最小转录
  逐字节一致**；自测里有「关闭态下 fd 2 捕获到 0 字节」的断言守着它。
* **交互模式**：工具运行期间把**提示符**换成运行中的那一行（`● Bash · 跑测试 > `），
  工具返回后先恢复原提示符、再把成品行写进滚动区。这样不用原地改写已输出的一行，
  也不会和正在编辑的输入行打架（复用 P3 的擦除/重画协议）。
  `ask_user_question` / `exit_plan_mode` 会自己提问，跳过这次提示符替换。
* 明确不做：ANSI 颜色（`tty_advance_col` 的列算术不认识零宽转义序列，`make codegen-audit`
  对转义写法也有硬约束）、markdown 渲染、可折叠卡片（P16 的取舍正好相反：**默认折叠成一行**，
  要展开就 `--tool-lines N`）、非交互下的实时思考行、`--resume` 的转录回放。

### 子代理窗口面板（并行线的 P15）

工具内容块下面是**输入行上方的常驻窗口区**（「面板块」）：每个**运行中**的子代理占 **2 行**，
最多显示**最后 4 个**，画在一个共享边框里，输入行永远在它下面：

```
┌─ agents ───────────────────────────────────────────────────────────────────┐
│ ● sub-1 [subagent] 审计 deleg 的等待循环与 fork/exec 差异                  │
│ ● running       3s · 12 · 检查 1030-1120 行的 fork/exec 差异               │
├─ ──────────────────────────────────────────────────────────────────────────┤
│ ● sub-2 [ralph] ralph loop                                                 │
│ ● running      12s · 1 · Round 2 of 4. Objective: 把骨架补齐               │
└─ ──────────────────────────────────────────────────────────────────────────┘
[step 4] > 我在这儿接着打字…
```

* **第 1 行是「命令」**：`● sub-<id> [subagent|ralph] <description>`；**第 2 行是「状态」**：
  `● running` + 已跑秒数（固定 5 列右对齐）+ `·` + 已收输出行数 + `·` + prompt 首行预览。
  状态名 10 列左对齐、秒数固定 5 列 —— 位数变化时 `·` 的列号不变（不会左右横跳）。
* **秒数真的在跳**：`deleg_spawn` 记 `started_ms`，长等待（前台 `subagent` /
  `subagent_output(wait=true)`）的轮询循环每秒刷一次面板；快照没变时一个字节都不写。
* **跑完即隐**：面板只收 `status == DELEG_RUNNING` 的窗口；子代理进终态时窗口在**同一次重画**里
  消失（面板自动缩短），同时在滚动区补一行结算通知
  `[agents] sub-2 [ralph] ✓ idle 27s — ralph loop`。
* **边框不错位的四条硬规则**（自测逐行断言）：
  1. 面板宽 `M = tty_body_width()`（终端宽 − 2），内容行与边框行**都是 M 列**，
     右竖线恒落在第 M 列；
  2. 宽度**只按显示列**算（`tty_cols_between`）—— 中文 1 字 3 字节 2 列，按字节数补空格就歪；
  3. `─` 的数量由「本行实测已用列数」推出来（`view_ag_line_start` 找行首，不能从缓冲区 0 算）；
  4. 内容超宽逐级收窄（预览 → 输出行数），截断先给 `…` 留 1 列再补齐；
     状态名/秒数/`·` 是固定前缀，永不截断。
* **面板块的渲染协议**（`src/tty.uya`）：输入行块 = [窗口行…] + [提示符+输入行]；
  块底行恒从第 0 列开始，块首行可能不在第 0 列（流式正文没换行时）。
  擦除 = 上移 `rows-1` 行（**相对量**，扛滚动）→ 右移到块首列 → **逐行 `ESC[2K`**。
  **不用 `ESC[J`**：它清到屏幕末尾，会连带清掉「紧跟正文的输入行」下面仍然可见的正文文本。
  输出写入（`tty_out_begin`）也走同一套整块擦除，否则窗口行会残留在屏幕上、越叠越多。
* **只在干净行上画**：正文停在半行时不画窗口（只画提示符），下一个干净行再出现 —— 绝不擦掉正文。
* 关联：`view_agents_text` 只认 running、`view_agents_sync` 做快照比对、
  `deleg_agents_refresh` 是唯一的刷新入口（spawn / 终态 / 等待循环 / step 边界）。
  刻意不用回调：**uya 0.10 没有函数指针**，只能「上层推、下层画」。
* `--quiet`（含子代理进程）整层关闭，输出与 P15 之前逐字节一致。

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
* `make` 目标：`check` / `build` / `selftest`（离线 33 轮）/ `probe` / `e2e TASK=… [PIN=…]`（真实网关）/
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
| `read` | `file_path`(必), `offset`(1 基, 默认 1), `limit`(默认 2000, 上限 2000) | **流式窗口**读法（P19，踩坑 34）：一边数全文行数（`total` 是真值，不受窗口/上限影响）、一边只缓冲第 `offset … offset+limit-1` 行（缓冲上限 51200+65536 字节），所以 offset 落在文件后半段也读得到；逐行加**绝对**行号，包在 `<path>/<type>file</type>/<content>` 里；footer 三种：`(End of file - total N lines)`（**只有真到末尾才出**）/ `(Showing lines a-b of T. Use offset=b+1 to continue.)` / `(Output capped. Showing lines a-b. …)`；行长 > 2000 字符截断并标 `... (line truncated to 2000 chars)`；一次输出最多 51200 字节 |
| `write` | `file_path`(必), `content`(必) | **观察策略**：文件存在但**没读过** → 拒绝（`write requires reading "x" first — read the file, then retry`）；读过但**版本变了** → `FS_STALE_VERSION … re-read the file, then retry`；成功回 `Created file` / `Updated file` |
| `edit` | `file_path`, `old_string`(非空), `new_string`, `replace_all`(默认 false) | 必须**先 read**（任何窗口）；匹配必须唯一（否则报 `appears N times`）；成功回 `The file X has been updated successfully.` / `… All occurrences were successfully replaced.` |
| `glob` | `pattern`(必), `path`(可选目录) | `rg --files --glob <p> --sort=modified --no-ignore --hidden` + 排除 `.git/.svn/.hg/.bzr/.jj/.sl`；默认显示前 100 条；空 → `No files found` |
| `grep` | `pattern`(必), `path`(可选), `include`(可选，一个正向 glob) | `rg --json` 逐行解析（不做冒号切分），按文件分组输出 `Line N: 预览`；最多 250 条、每行预览 2000 字节（超出标 ` (line truncated)`）；`include` 拒绝以 `!` 开头或逗号列表；空 → `No matches found` |

* **版本**取 `(mtime, mtime_nsec, size)`；观察状态只在进程内（与 DSH 的已知限制一致：恢复会话后要重新 read）。
* **路径守卫**默认关闭（内置默认模式就是 DSH 的 `danger-full-access`）：`workspace-write` /
  `read-only` 下拒绝绝对路径与 `..`。（早期 README 里写的 `--confine` 开关**从来没有实现过**，
  未知 flag 会直接报错退出；现在请用 `--permission workspace-write`。）
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
  以及 `permission.defaultPreset → 访问模式`（P21：三级都认；`read-only` / `workspace-write` /
  `danger-full-access` 之外的值打一行 warning 后保持内置默认）。
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
* 事件词表：`user/message`、`assistant/message`（含 `tool_calls` 原文）、`assistant/reasoning`
  （P16：该 step 的思考全文，显示层只留一行、全文只活在这里；`--resume` 的 reader 不认识它就跳过）、
  `tool/call`、`tool/result`、`turn/start|end`、`step/start`、`session/title`、
  `diag/dump`（P19：外来字节诊断的**转义全文**，字段 `kind`/`bytes`/`truncated`/`text`；
  转录里只有 ≤320 B 的转义预览 —— 见踩坑 33）。**续写已有会话时不重复写 header**，
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
「转录贴面板、面板贴底」，**运行中的状态区（P18）钉在输入面板正上方**（运行中 1–2 行，空闲 0 行）。

```
         █▓  █▓ █▓  █▓ █▓  █▓        █▓  █▓ █▓  █▓ █▓  █▓ ██▓ █▓ █████▓
         █▓  █▓  ████▓ █████▓ █████▓ █████▓  ████▓ █████▓ █▓  █▓  █▓
         █▓  █▓     █▓ █▓  █▓        █▓  █▓     █▓ █▓     █▓  █▓  █▓ █▓
          ▓▓▓▓   ▓▓▓▓  ▓▓  ▓▓        ▓▓  ▓▓  ▓▓▓▓   ▓▓▓▓  ▓▓  ▓▓   ▓▓▓

  ▌ ↑ Ask anything... "把 hello.uya 的问候语改成 Hello, DSH!"
  ▌ Build   Full access   deepseek-chat   deepseek  tab plan   ctrl+p commands
  ~/uya-agent:main                                                                 p20-stats```

对话态（`--tui-demo` 打印的就是这三屏的纯文本快照）：

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
  ✓ Bash(./hello) · exit 0
      Hello, DSH!
    ◆ 助手
  已改成 Hello, DSH! 并重新编译运行，输出 Hello, DSH!。

  ⠋ 运行中 Bash(make check) · esc 中断   ← 状态区第 1 行：钉在面板正上方（转录再长也挤不掉）
  ▌ ❯ 顺便把 Makefile 的注释补一下_     ← 输入面板（左边缘强调竖条）
  ▌ Build   Full access   deepseek-chat   deepseek  tab plan   ctrl+p commands
  ~/uya-agent:main · ctx 21% · %cpu 37%    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s | 221 tok/s | 缓存命中 71% | 输入 238K tok · 输出 12K tok```

思考阶段多一行实时文本（`--tui-demo` 的第三屏，下面这段转录已经被刻意铺满一屏）：

```
    ◆ 助手
  已改成 Hello, DSH! 并重新编译运行，输出 Hello, DSH!。
  为了把视口铺满，这里再补几行转录：状态区必须照样看得见。
  …（还有 7 行）

  ⠋ 思考中 · esc 中断
  ✻ 思考 · …态区预留对不对，再看 view_think_pick 的 latestLine 口径，最后跑一轮 tui-selftest 收尾
  ▌ ↑ Ask anything... "把 hello.uya 的问候语改成 Hello, DSH!"
  ▌ Build   Full access   deepseek-chat   deepseek  tab plan   ctrl+p commands
  ~/uya-agent:main · ctx 21% · %cpu 37%    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s | 221 tok/s | 缓存命中 71% | 输入 238K tok · 输出 12K tok
```

（第 1 行是状态、第 2 行是思考实时文本 —— 它按显示列**从左边**截断，屏幕上留下的是**最新**的那一段。）

* **开关**：`--tui`（默认）/ `--no-tui` / `UYA_AGENT_TUI=0|1`；
  `--color=auto|always|never|16|256` 与 `NO_COLOR`（无色时只留粗体/暗色）；
  `--tui-demo [COLSxROWS]` 打印 home / chat / 运行中 三屏纯文本（诊断 + 文档；默认画布
  160×40，窄终端可以 `--tui-demo 100x30` 看脚注的退化形态）。
* **运行中的状态区（P18）**：见下一小节。
* **键位**：`enter` 发送 · `ctrl+j` / `alt+enter` 换行 · `esc` 运行中=中断、空闲=清行 ·
  `ctrl+c` 运行中=中断、空闲=清空/两次退出 · `ctrl+d` 空行退出 · **`shift+tab` 访问模式选择浮层** ·
  `↑/↓` 单行=历史、
  多行=上下移光标 · `pgup/pgdn`、`ctrl+home/end` 滚转录 · `tab` 切计划模式（面板显示 `Plan`）·
  `ctrl+p` 命令面板（输入以 `/` 开头也会自动打开）· `ctrl+u/w/k` 清行/删词/删到行尾 ·
  `ctrl+a/e`、`←/→`、`home/end`、`backspace/del` 按**字符**编辑 · `ctrl+l` 强制重绘 ·
  括起粘贴（`ESC[200~`）整段插入不触发提交（> 64 KiB 截断）。
* **浮层**：命令面板、会话列表（选一个 `/resume`）、帮助（`/help`）、`/status` 详情、
  **访问模式选择器与 Full access 确认**（P21，底对齐，贴着输入面板往上弹）、
  **read-only 下 bash 的逐条批准**（P21），以及 `ask_user_question` / `exit_plan_mode` 的
  问答弹窗（↑/↓ + enter，esc = 无回答）。
* **数据流**：TUI 激活后 `tty.uya` 的 `tty_write` 变成一个 **sink** —— 通道 1（助手正文）、
  2（工具块/诊断）、3（思考，新增 `tty_reason_write`）全部进转录，**fd 1 一个字节都不写**
  （管道语义干净，`tui-turn` 轮断言 fd 1 捕获 0 字节）；工具卡片不是靠前缀嗅探，而是
  `view_begin_tool`/`view_end_tool` 走结构化分支、复用纯函数 `view_render_block()` 的产物。
  P18 起还有一条**不经过 sink** 的路：`view_think_live()`（喂状态区的实时行）——
  通道 3 仍然只服务「转录里的思考条目」，两者互不影响。
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
  思考条目只留尾部 4 KiB；状态区的思考实时行只留尾部 1 KiB（都与 P15/P16 的
  「思考行只显示最新一段」同口径）。
* 仍不做：鼠标（滚轮/点击/选择）、图片、可折叠卡片、完整语法高亮（只做轻量 markdown）、
  分屏、主题切换 UI。

#### 运行中的状态区与思考实时行（P18）

**P17 的状态行是「转录的最后一行」**，于是转录一铺满视口它就被挤掉 —— 判据是
`r < panel_top`（`tui_build_chat`），而转录绘制循环的上界也是它：长会话里跑起来屏幕上
**一个动的字节都没有**，看着就像卡住（见 §3 踩坑 32）。P18 把它改成**常驻状态区**：

```
  ⠋ 思考中 · esc 中断                                             ← 第 1 行：spinner + 状态（一直在）
  ✻ 思考 · …态区预留对不对，再看 view_think_pick 的 latestLine 口径  ← 第 2 行：思考实时文本
  ▌ ❯ 输入面板                                                    ← 面板永远在它下面
```

* **行数**：运行中 1–2 行、**空闲 0 行** —— 空闲态的行数/布局与 P18 之前**逐字节一致**
  （转录仍然底对齐、贴面板）。视口算术里先把 `status_h` 扣掉再收转录，所以转录再长也挤不掉它。
* **思考实时行默认开**，且**与 `--show-reasoning` 解耦**：后者只管「转录里的思考条目」与
  「滚动模式在提示符那一行滚动」；实时行只跟 `--quiet`（显示层整层关）与「TUI 在不在跑」有关。
  两个都开时：转录里有条目、状态区同样有实时行（不做隐式二选一）。想彻底关掉就用 `--no-tui`。
* **口径**：喂的是 `view_think_pick(running=true)` 的**最新一行**（`trimEnd` 之后）；
  按显示列**从左边截断补 `…`**（视口贴右端，屏幕上留最新的那一段），宽字符不砍半个；
  控制字节/`ESC` 序列/TAB 在进缓冲区之前就清洗成 `·`/`␛`/四空格，换行只取最后一段
  （这一行必须是单行，否则帧的「一行一段」结构会被冲掉）。
* **收尾**：正文开始 / 工具调用开始 / 中断 / malformed / 网络错都走
  `agent_note_reasoning → view_think_end → tui_think_clear()`；回合收口再经
  `agent_tui_turn_done → tui_set_run(TUI_RUN_IDLE) → tui_think_clear()` 兜一层 ——
  不会把实时行留在屏幕上，也不会让它跨回合串味。
* **成本**：喂进来只写一个小 Buf + 置脏标记，不碰终端；重绘仍然走既有的逐行 diff（≤ 30 fps）。
* 关联：`tui_think_live` / `tui_think_clear` / `tui_status_rows` / `tui_put_clipped_tail`（`src/tui.uya`）、
  `view_think_live`（`src/view.uya`），喂入点在 `src/llm.uya` 的两条 reasoning 增量路径上。

ours
### 统计行、上下文占用与 %cpu（P20，对齐 DSH 的统计条 + 占用表 + 自定义的进程 CPU）

脚注那一行分两半：左边是**状态字段**（`ctx` 上下文占用、`%cpu` 全部 uya-agent 进程的综合
CPU），右边是**整会话统计行** —— 逐字对齐 DSH Web 聊天统计条那一行：

```
  ~/uya-agent:main · ctx 21% · %cpu 37%
      1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s | 221 tok/s | 缓存命中 71% | 输入 238K tok · 输出 12K tok
```

（真实渲染是同一行：状态字段紧跟 cwd，统计行右对齐到终端右边；窄终端见下面的退化规则。）

* **数字是整会话口径**：折叠的输入是**会话日志**（`step/start|end`、`assistant/first-token`、
  `assistant/message` 的 usage、`tool/call`→`tool/result` 配对、`turn/end`），所以压缩换掉历史
  也不改变它；`--resume` 时把日志逐行喂进**同一份状态机**，恢复前后的数字与整条统计行
  **逐字节相同**（`stats-log` 轮钉这条：实时折叠 vs 日志回放）。渲染规则、字段判据、取整方式
  逐行对照 DSH 的 `dsh-session-stats`（`sessionStats`）与 Web 客户端的 `StatsLine`：

  | 组 | 内容 | 出现条件 |
  |---|---|---|
  | 1 | `{turns} 轮 · {steps} 步` | `steps > 0` |
  | 2 | `LLM {d}` · `工具调用 {d}` | 同上；各自时长 > 0 |
  | 3 | `首 token 平均 {d}` · `{tps} tok/s` | 同上；`ttftSteps > 0` / `decodeMs > 0` |
  | 4 | `缓存命中 {p}%` | 计费输入 > 0 |
  | 5 | `输入 {n} tok · 输出 {n} tok` | 计费输入 > 0 或输出 > 0 |

  组间 ` | `、组内 ` · `；时长 < 60s 一位小数（`50.7s`），否则 `2m42s`；token
  `999 / 12.2K / 238K / 1.2M`；tok/s ≥ 10 取整；缓存命中是整数百分比、**全命中才是 100**，
  有 miss 时按 DSH 的最小精度阶梯打 `99.9…x`（不把 99.96% 说成 100%）。合计 `billedInput
  = 未缓存输入 + 缓存读 + 缓存写`，解码只用「既报了输出 token 又有首 token」的步。
* **边界语义（都按 DSH）**：`steps` 数的是**进过的步**（失败/取消/max-tokens 都算 —— 回合
  循环里每个出口都必须补 `step/end`，这是硬约束）；被取消的步**计数但不计时**；`turns` 只在
  该 turn 首次出现时 +1；`tool/call` 在**派发前**落盘、`tool/result` 在其后（早期实现是执行
  完再背靠背写两条，时间差恒为 0）；未结算的调用在 `turn/end` 丢弃；TTFT 是 `step/start`
  → 首个非空正文 delta，用新事件 `assistant/first-token` 记那一刻（事件在流结束后才补写，
  所以时间用 `sess_begin_at` 钉死，不能用写盘时的 `ua_now_ms()`）；解码是首 token → 消息组装。
* **偏差（明写）**：输出 token「未上报」与「上报 0」在日志里不可区分，所以只有 `> 0` 才进
  解码与 tok/s；非流式（`--no-stream`）没有 delta 边界 → 第 3 组自然隐藏（DSH 也只认 chunk）；
  `--resume-dsh` 导入的 DSH 会话不折叠（那份日志的事件形状不同），统计从 0 开始。
* **上下文占用**（`ctx N%`）：DSH `contextPressure` 的等价物 —— `used = 最近一次请求的
  prompt 规模（未缓存 + 缓存读 + 缓存写，来自 `assistant/message` 的 usage；`--resume` 后从
  日志取）+ 自取样以来表层的启发式增量`，`percent = min(100, round(used / contextWindow × 100))`；
  **两者缺一就不显示**（还没请求过、或 DSH 设置里没有模型容量）。压缩之后 `used` 立刻跟着
  表层估算下降，不必等下一轮请求。`/status` 里有 DSH 点击面板的终端等价物：`上下文已用 46%`
  + `~238K / 517K` + 20 格分段条（`█▓▒` 三段 + `░` 轨道）+ `系统提示词 / 工具 / 对话消息`
  三行明细 —— 明细是固定的 `4 字符 ≈ 1 token` 启发式（与 `agent_pressure_tokens` 同口径），
  **三项之和不等于总量**，DSH 也是这么标注的。
* **%cpu**：机器上**所有** comm 与本进程相同的进程（本进程 + 子代理进程 + 其它终端/工作区里
  的实例）的**综合** CPU 使用率，单核口径（并行时 > 100%，显示钳 0…999；不按核数归一）。
  取值是 `/proc/<pid>/stat` 的 `utime + stime`（**不取** cutime/cstime —— 父子同为我们时
  取子进程累计会把同一份 CPU 时间算两遍），单位 `USER_HZ = 100` 是常数而不是 sysconf 读数
  （Linux 对所有架构固定，`cpu-live` 轮用忙循环子进程钉死它）；`pct = Δticks × 1000 / Δms`，
  两次采样之间按**墙上时间**算，所以事件循环被长任务占住也不影响准确度。采样挂在 TUI 的
  心跳（`tui_tick` → `procx_tick`，所有长循环都经过它）上：**1 秒一次、只在 TUI 活跃时**，
  第一次只建基线；`/proc` 读不到 → 字段直接省略（`/status` 会说明原因）。滚动模式
  （`--no-tui`）不采样也不显示。
* **退化规则**：统计行按 `" | "` 拆组、从**尾部**丢组并补 `…`（等价于 DSH 的整行省略号）；
  `ctx` / `%cpu` 在左半区**不参与丢组**；cwd 是唯一的弹性字段（先满足状态字段与统计行，
  不够 8 列就整段丢）；右半区连一组都放不下（< 16 列）时退回版本号。终端没有 hover，
  所以 DSH 的 tooltip 位置由 `/status` 顶替（那里有完整明细）。各种宽度的实际形态：

（下面是 `--tui-demo` 在六种画布下的真实脚注，cwd 换成了短路径以便阅读）

```
160 列：~/uya-agent:main · ctx 21% · %cpu 37%   1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s | 221 tok/s | 缓存命中 71% | 输入 238K tok · 输出 12K tok
120 列：~/uya-agent:main · ctx 21% · %cpu 37%   1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s · 221 tok/s…
100 列：~/uya-agent:main · ctx 21% · %cpu 37%   1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s…
 80 列：~/uya-agent:main · ctx 21% · %cpu 37%   1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s…
 60 列：~/uya-agent:main · ctx 21% · %cpu 37%   1 轮 · 12 步…
 40 列：~/uya-agent/… · ctx 21% · %cpu 37%      ← 统计行整条让位（右半区不足 16 列），
                                                  版本号也放不下就只剩状态字段
```

* **落地位置**：折叠与格式化在 `src/stats.uya`，进程采样在 `src/procx.uya`，脚注排版在
  `tui.uya`，边界喂养在 `agent.uya` 的 `agent_bound_*`（同一个毫秒值既进日志又进折叠，
  所以「实时」与「回放」对得上）。
### 访问模式（P21，对齐 DSH permission-presets）

三级，机器名与 DSH 的 preset key **逐字一致**（所以 DSH 设置文件里的
`permission.defaultPreset` 可以直接喂进来）；显示名按 DSH 的 client 侧规则（kebab → Title Case，
`danger-full-access` 用产品名 `Full access`）：

| 模式 | 机器名 | 标签 | read/glob/grep | write/edit | bash |
|---|---|---|---|---|---|
| 只读 | `read-only` | `Read Only` | 照常（仍受工作区守卫） | **硬拒** | **逐条要用户批准** + 只读沙箱 |
| 工作区写 | `workspace-write` | `Workspace Write` | 照常 | 允许（工作区守卫） | 自由，但在沙箱里（只写工作区 + 临时 /tmp） |
| 全权 | `danger-full-access` | `Full access` | 不受限 | 不受限 | 自由，不套沙箱 |

DSH 那边这三档是 `(sandbox, approval)` 两个旋钮的组合（实测表见 `dsh-base/cordis.patch.yml`）；
本项目没有沙箱拒绝→升级审批那条链，所以 `approval=ask` 落地成 **read-only 下 bash 的逐条人工批准**：

* TUI：弹出底对齐浮层（标题 `Read Only：批准这条 bash 命令？`，条目 `批准并执行` / `拒绝`），
  **光标默认落在「拒绝」**，且真终端下开浮层前会清掉排队按键 —— 运行期间敲进来的键最多只能
  「拒绝」，绝不会误批准；`esc` 也是拒绝（不是中断回合）。
  （headless 自测里注入的键是**立刻派发**的，浮层还没开就已经被输入行吃掉了，所以那条路测不了
  批准；批准流程由 `tui-approve` 轮用**真 PTY** 覆盖：等浮层画出来再送 `↑`+回车。）
* 滚动模式（真 TTY，且不是子代理）：打印命令 + `执行？（y = 批准 / n = 拒绝）`。
* 管道/CI、子代理、浮层画不出来（终端太小）：**fail closed** —— 直接回
  `bash needs per-command approval in read-only mode, but this session has no answer channel …`，
  一个字节的命令输出都不给模型。

界面与命令：

* 输入面板信息行有访问模式 chip（只读=绿、工作区写=默认色、全权=警示色），
  行尾键位提示在**够宽时**会带上 `shift+tab access`（100 列下是 `tab plan   ctrl+p commands`）。
* `shift+tab`（输入为空时）打开选择浮层：当前项带 `✓`，条目后面跟着一句短说明；
  `↑/↓` 选、`enter` 切、`esc` 取消；选 **Full access** 不直接生效，会再过一道
  `确认启用 Full access？`（游标默认停在「取消」，与 DSH 的 RiskConfirmation 同语义）。
* `/permission`（裸）= 报当前值与可选值（TUI 里直接开浮层；管道/CI 的行式 REPL 也会打印一行）；
  行式 REPL 现在也认 slash 命令了（以前只认 `exit`，管道里没法查/切模式）；
  `/permission <preset>` = **直接切**（对齐 DSH 的带参数路径，不过闸门）。
* 切换的副作用（一处做完）：改 `g_perm` → 同步 `g_fsctx.confine` → 更新 chip →
  往历史里 **push 一份新的运行时上下文快照**（它自称 supersedes earlier snapshots，模型下一轮就知道）→
  转录里一行 notice → 会话日志记一条 `permission/mode`。

* 顺手修掉一个**既有缺陷**：`tui_ov_accept()` 会先 `tui_overlay_close()`（把浮层 kind 清 0），
  而调用方是在 `tui_overlay_take()` **之后**才读 `tui_overlay_kind()` —— 于是命令面板与会话列表
  的选中结果一直被静默丢弃（`/` 打开面板、选中、回车 = 什么都不发生）。现在 accept 会把 kind 存进
  `g_tui_ov_done`，没有打开的浮层时 `tui_overlay_kind()` 返回它；`tui-keys` 轮加了一条回归断言。

来源链与今天其它旋钮同构（`--print-config` 逐项打印来源）：
`--permission <v>` / `--permission=<v>`（cli）> `UYA_AGENT_PERMISSION`（env）>
DSH `permission.defaultPreset`（dsh-settings）> 内置默认 `danger-full-access`。非法取值直接报错退出；
DSH 里认不出来的值（例如表示「旋钮不匹配任何预设」的 `custom`）打一行 warning 后保持默认，不猜。

### 沙箱（P21，对齐 DSH bash-sandbox）

**只覆盖 spawn 出去的 shell 代码**（bash 前台/后台任务、子代理里的 bash）；进程内的 write/edit 是
「工具层栅栏」，不是内核边界 —— 这与 DSH 自己的分界一致（`dsh-fs-sandbox`：策略栅栏不是安全边界，
内核级隔离归 `ctx.shell`）。也不把 agent 进程自己关起来：那不可逆，会让「运行中放宽模式」失效。

后端只有一档：**bubblewrap**（DSH 在 Linux 也是优先 bwrap、其次 Landlock）。本机实测：
内核 6.12.65 的 LSM 列表里没有 landlock、`landlock_create_ruleset` 返回 ENOSYS，所以 Landlock 档没写；
`bubblewrap 0.10.0` 可用，profile 实测与 DSH 文档一致。

| 模式 | profile | 实测效果 |
|---|---|---|
| `read-only` | `bwrap --ro-bind / / --dev /dev --proc /proc --unshare-pid --die-with-parent` | 写任何持久路径 → `Read-only file system`；`> /dev/null` **仍然可用**（fresh /dev 里只有它可写） |
| `workspace-write` | 上述 + `--tmpfs /tmp --bind <workspace> <workspace>` | 工作区内可写、`/tmp` 是临时 tmpfs（跑完就没了）、区外 EROFS |
| `danger-full-access` | 不套壳 | 今天的行为 |

* **探测 + 缓存**：启动时（或 `--print-config` / `/status` 首次问到时）fork 一次
  `bwrap … true`，退出码 0 才算可用；结果进程级缓存，`--print-config` 打印
  `sandbox = bwrap  (source: auto, probe: ok)`。
* **不可用就 fail closed**：confined 模式下 `bash` 直接回
  `the file sandbox is unavailable on this host (bwrap: <原因>); bash is refused in <mode> mode …`，
  绝不静默降级成「不沙箱」（DSH 的 `SANDBOX_UNAVAILABLE` 同款态度）。
* `--no-sandbox`（或 `UYA_AGENT_SANDBOX=0`）是显式逃生门：confined 模式不再套壳也不再 fail closed，
  启动时会打一行警告；`--bwrap PATH` / `UYA_AGENT_BWRAP` 可以指定 bwrap 可执行文件
  （指定了就必须真的可用，不悄悄换别的）。
* 工作区解析成 `/` 时不加可写 bind（否则整个根都可写，等于没沙箱）。
* 超时/中断语义不变：杀的还是 fork 出来的那个进程，`[exit code: N]` / `[killed by signal: N]` 口径不动。
* 没做：workflow 的 `.ush` 脚本（`uya run` 起的不是 bash）、隐藏 `/proc` 之外的更多命名空间、
  网络/进程级限制（DSH 自己的权限词汇里也只有文件效果）。
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
   SIGSEGV`，commit `fad26acd`，回移 0.11 的实现 + 两个回归用例；未修的版本跑那两个用例会 `Segmentation fault`、修好后 6/6 通过）。

29. **装了信号处理器以后，阻塞的 `read` 会被打断返回 `EINTR` —— 那不是 EOF。**
   `poll`/`select` 不受 `SA_RESTART` 保护（内核语义如此），所以只要装了处理器，
   交互等待输入时的 `sys_read(0, …)` 就可能返回 `EINTR`（例如用户在流式输出期间缩放终端 →
   `SIGWINCH`）。原来两处读键盘的循环都写成 `const n = sys_read(...) catch { -1; }; if (n <= 0) { 当作 EOF }`
   —— 于是**一次窗口缩放就会把 REPL 直接关掉**（`tty_read_line_blocking` 返回 `TTY_EV_EOF`、
   `ask_read_line` 返回「无回答」）。修法：`catch |err|` 里取 `@error_id(err)`，`== 4`（EINTR）
   就 `continue` 重来（`agent.uya` 与 `askuser.uya` 各一处）。其它 `poll` 循环里的
   `catch { 0 }` 天然是「当作超时继续转」，不用改。

30. **第 21 条那个「把 fd 2 指向 /dev/null」会把显示层一起静音掉。** P16 做思考行时发现
    `--show-reasoning` **从来没有生效过**：P14 那行「✻ 思考」是在 `llm_apply_delta` 里写的，
    而那一刻正在 `tls_noise_mute` 的窗口内（整个请求期间 fd 2 → `/dev/null`），字节全进了黑洞；
    只有加 `--tls-debug` / `--http-debug`（静音被关掉）时才看得见 —— 这就是「本地 mock 复现不出来、
    真机也复现不出来」的原因（两边都没开 debug 时都静音）。修法不是缩短静音窗口（TLS 噪声确实只在
    握手期，但谁也说不准记录层什么时候再吐一句），而是**让显示层写那个「还看得见」的 fd**：
    `tls_noise_mute` 顺手把 `dup(2)` 拿到的原件记进 `g_err_fd`，`unmute` 时换回 2，
    view 层一律 `err_fd()`（工具行、思考行的实时行、提示符重画）而不是字面量 `2`。
    回归：`think-row` 轮里直接在静音窗口内渲染一次，断言字节落在被捕获的那个 stderr 上；
    真机验收（`script -q -c` 跑 REPL）能看到 `✻ 思考 · …` 的滚动行与结算行。
31. **多行块（子代理窗口面板）的擦除与定位，四条都是一次踩出来的**：
    * **别用 `ESC[J` 擦多行块**。它清到屏幕末尾，会连带清掉「输入行紧跟正文」时下面那些
      **仍然可见**的正文文本（缓冲区里还有，屏幕上看不见了 —— 用户以为输出丢了）。
      正确做法：上移 `rows-1` 行回块首（**相对量**，扛滚动；绝对屏幕行号在滚动/流式输出之后是脏的）
      → 右移到块首列 → 逐行 `ESC[2K` 清到块底行为止。
    * **块变矮时「光标已在目标位置就不发序列」这条捷径会害死人**。窗口关掉后面板从 6 行变 1 行，
      `erow/trow` 恰好相等 → 提前 return → 新块的尾巴留在屏幕上、`cur_row` 还按旧值记账，
      下一次擦除就整体错位。修法：面板块在场时禁用这条捷径（`!use_block && !tty_block_on()`）。
    * **`cur_row` 必须相对块首存**（`tty_build_block_erase` 按 `cur_row+1` 上移），
      不能存 `tty_end_pos` 算出来的「相对擦除基准点」的行号 —— 两者差一个 `base_row`。
    * **列数必须从「本行行首」量起**。面板是一行行追加到同一个 `Buf` 里的，
      从缓冲区 0 量会得到几百，补 `─` 的循环一次都不进，底框退化成「└─ ┘」。
      另外按列补空格/截断一律用 `tty_cols_between`（显示列），用字节数会把右竖线拉歪。
      自测里对面板**每一行**断言列宽完全相等，这四条任何一条被写回去都会立刻红。
32. **运行状态行会被「铺满的转录」挤掉 —— 长会话里跑起来屏幕上什么都没有。** P18 做思考实时行时
   发现：P17 的状态行（`⠹ Bash(make check) · esc 中断`）画在转录的最后，判据是
   `if g_tui_run != TUI_RUN_IDLE && r < panel_top`，而转录绘制循环的上界**也是** `r < panel_top`
   —— 于是转录刚好占满视口时 `r == panel_top`，状态行直接不画，剩下的全是补齐的空行；
   输入面板本身在运行期间完全静态（没有 spinner、没有 esc 提示），**屏幕上就没有一个会动的字节**了。
   而这个条件在真实终端里几乎总是成立：`make tui-demo` 在 100×28 下对话屏其实只有 **24** 行
   （真实终端行数），转录正好占满 21 行 —— 也就是说 README 里那张带状态行的截图，
   在 `--tui-demo` 的真实输出里**从来没出现过**（`grep "make check"` 命中 0）。
   修法不是「有位置就画」，而是**给状态区预留行数**：`status_h = tui_status_rows()`（运行中 1–2 行、
   空闲 0 行），先把它从视口里扣掉（`t_bottom = panel_top - status_h`）再收/画转录，状态区画在
   `[t_bottom, panel_top)` —— 空闲态因此与之前逐字节一致，而运行态**永远**贴着输入面板。
   回归：`tui-status` 轮的 A 组（铺满转录后状态行必须仍在，且落在 `tui_nrows() - 4` 那一行）。


33. **把「外来字节」原样打给 fd 2 = 转录里一屏乱码。** 现场：网关 400 的错误体把整个请求
    **回显**回来了（里面有模型的 messages、`\n` 转义、组装好的 `tools` 数组），代码走
    `dump_stream_error` / `dump_http_error` / `err_kind==1` / `LLM_FINISH_ERROR` 这几条路把它
    **按字节**打到 stderr。而 TUI 的显示模型是「fd 2 的每一行 → 一条 NOTICE 条目，每行画一个
    `· ` 前缀」——于是屏幕上出现一大块灰底 `· ` 行：**半个汉字 + 一屏 JSON**（用户报的「乱码」）。
    三条根因叠在一起：
    * **按字节截断切坏 UTF-8**：`llm_err_head` 收 240 B、`dump_*_error` 收 4096 B、`bad_finish`
      64 B，中文在边界上被切成半个字符，终端渲染成替换符、列宽也算不对；
    * **控制字节原样上屏**：错误体里的 CR/LF/ESC 会直接改变终端状态（清屏、挪光标）；
    * **没有上限**：TUI 单条 NOTICE 的文本上限是 256 KiB（`TUI_ENTRY_MAX`），一条诊断就能把整屏
      转录冲掉，而「NOTICE 只在内存里」意味着**会话日志里查不到现场**（当时只能靠截图）。
    修法（入口唯一化 + 有界 + 另有去处）：
    * `tty.uya::tty_diag_escape_into` 是**唯一**的转义实现：可打印 ASCII 原样、`\n`/`\t` 短转义、
      其余控制字节 `\xNN`、合法 UTF-8 原样、非法/半截逐字节 `\xNN`，并在**字符边界**上按 cap 收；
    * `agent.uya::out_diag` 是**唯一**的诊断出口：转义预览（320 B）+ `… N bytes total` 后缀，
      **整条只有一行**（换行都转义了 → TUI 里最多 3–4 行，而不是一屏）；所有原样打印的调用点
      全部改走它（`--dry-run` 也复用它，输出口径不变）；
    * 完整原文（转义后）落会话日志 `diag/dump`（日志因此永远是合法 UTF-8），需要**原始字节**时
      用 `--debug-dump FILE`（设路径即清空旧文件，避免自测被旧文件「假绿」）；
    * TUI 侧再加两道：NOTICE 文本上限 `TUI_NOTICE_MAX = 512 B`（超了补一行截断提示），
      非法/半截 UTF-8 在 `tui_clean_into` 里换成 U+FFFD；`tui_sink_reason` 的尾部保留
      （4096 B）也改成按字符边界切（原来会把思考条目以半个汉字开头）。
    回归：`diag-preview`（纯函数：边界/cap/转义/落盘）、`diag-echo-400` 与 `diag-echo-400-ns`
    （mock 网关回显整个请求，断言转录里只有一行转义预览、没有裸 CR/NUL/ESC、`--debug-dump`
    与会话日志 `diag/dump` 里有完整原文）、`tui-diag`（4 KiB 块只留 ≤512 B + 截断提示、
    半截字节变 U+FFFD、思考尾部不切字）。真机对照（本地假网关回显 18 KB 请求）：
    修前 stderr 297 B / 7 个裸 CR / 9 行，修后 330 B / 0 个裸 CR / 3 行 + `… 18693 bytes total`。

34. **`read` 把「我们自己读到的前缀」当成整个文件 —— 大文件报错行数、offset 越界时假 EOF。**
    症状（真实会话踩到）：`read src/agent.uya`（当时 226 KB / 5756 行）回
    `(End of file - total 3149 lines)`，再 `read` 同一个文件 `offset=3272` 得到
    「空内容 + `End of file - total 3149 lines`」—— 模型据此判定「文件只有 3149 行、已经读完」，
    后面一连串「为什么第 3272 行读不出来」的排查全是在追这个假信息。
    根因在 `fs_tool_read`：它先 `fs_read_file_all(fd, &data, cap+1)` 只读文件头 `cap = 51200+65536`
    字节就停，然后 `total = fs_count_lines(这段前缀)`，窗口再从这个前缀里切 —— 于是
    ① `total` 是**前缀的行数**（文件越大错得越多）；② `offset` 落在前缀之外时 `fs_line_at` 直接
    失败，`shown_end == 0` 走进「一行都没输出」分支，打印 `(End of file - total N lines)`，
    看起来就是文件已经读完（假 EOF）。
    修法：新增 `fs_read_window`，**流式**读一遍文件 —— 一边数真实行数（`total`，末尾无换行的残行
    也按 `fs_count_lines` 口径算一行），一边只缓冲第 `offset … offset+limit-1` 行；缓冲撞上
    `fs_read_max_bytes + 65536` 时**回滚掉半行**（只留最后一个完整行）并置「被截断」，
    让上层走 `(Output capped …)` 而不是把半行当整行渲染。`fs_tool_read` 相应改成窗口内相对下标
    （绝对行号 = `offset + k`），footer 四种分支按「真 total / 真越界 / 输出上限」判。
    回归轮 `read-window`：4000 行 × 40 字节 = 160 KB（> cap）的文件上断言
    ① `limit=1000` → `(Showing lines 1-1000 of 4000. …)`（旧实现会报前缀行数）；
    ② `offset=3500` → 真读到 `3500: L03500`（旧实现这里是假 EOF）；
    ③ `offset=4001` → 才是 `(End of file - total 4000 lines)`；
    ④ 撞输出上限走 `(Output capped …)`；⑤ 末尾无换行的残行算进 `total`。
    真机对照（同一个 5949 行 / 230 KB 的 `src/agent.uya`，`offset=3000, limit=20`）：
    旧 `of 3080` → 新 `of 5949`；`offset=4000, limit=20`：旧「空内容 + `total 3080 lines`」→
    新 20 行 + `(Showing lines 4000-4019 of 5949. …)`（见 §6 的 P19 验收记录）。

35. **「拍脑袋的固定容量」会把「参数有点大」报成 OOM，而且顺手把证据也抹掉。**
    症状（真实会话踩到，用户截图就是这一幕）：一步 `bash`（`mkdir -p …/x11c`）成功后，
    下一步直接
    `error: out of memory serializing tool_calls`
    + `[turn] 本回合异常结束（可直接输入继续）`—— 内存一点问题都没有。
    根因在 `agent_finish_step` 严格协议那一段：assistant 的 `tool_calls` 数组原文要**一次写进
    一个缓冲**，而那个缓冲是 `buf_new(8192)`（P0 时期随手写的容量），`calls_json_from_chat`
    写不下就 `jw_overflow` → 调用点把它当成 OOM、`return AGENT_PROTO` 整轮退出。
    工具参数超过 8 KiB 太容易了：写文件的正文、长 heredoc 的命令行、一次改好几个文件。
    更糟的是**报错点在入史之前**，而 `agent_log_assistant` 用的是同一个固定容量，于是那一步的
    `assistant/message` 事件里连 `tool_calls` 都没有（老代码还是**静默** `return`）——
    事后翻会话日志只看到 `turn/end reason=error`，查不出当时到底调了什么。
    修法：容量按实际需要算，只有一个出处 ——`jsonx.uya::jw_str_esc_len`（转义后的精确长度，
    规则与 `jw_write_escaped` 一一对应）+ `agent.uya::calls_json_need`（骨架 + 三段字符串 +
    元素间逗号 + 256 字节余量），再由 `calls_json_make` 分配并序列化；两个调用点（入史、写日志）
    都走它，谁都不许再写固定值。真正的上限是历史单条 `extra` 的 `MSG_CONTENT_MAX`（200 KiB），
    8 KiB 从来不是设计出来的数；「装不下」现在只剩真 OOM 一种可能，而且报错会把**需要多少字节**
    一起打出来。会话日志那条路失败时也不再静默，会打
    `[session] assistant 事件的 tool_calls 写不进日志（需要 N 字节…）`。
    回归轮两条：`toolcalls-cap`（纯函数：`jw_str_esc_len` 与实际写出逐字节相等、预算与实际长度
    严丝合缝、9 KiB 参数按预算成功而按老的 8192 必然失败、回读 id/name/arguments 逐字节相同）
    与 `toolcalls-big`（端到端：mock 给一发 arguments ≈ 9.6 KiB 的 `write`，断言参数头尾一字不差
    地回到请求里、工具结果配对完整、文件内容与正文逐字节相同）。把 `calls_json_make` 改回
    `buf_new(8192)`，两条轮**同时红**（`error: out of memory serializing tool_calls (9999 bytes)`
    + `toolcalls-big` 的 `agent_run returned 3`）—— 那正是修前的现场（见 §6 的验收记录，
    那里还有用**真实故障会话** + `testdata/mock_gateway_bigcall.py` 做的 before/after 对照）。

---

## 4. 工具实现要点

| 工具 | 实现 | 限制 |
|---|---|---|
| `read_file` | `sys_open` + `sys_read` 循环读进堆缓冲 | 单次最多 64 KiB，超出附 `[truncated]` |
| `write_file` | `sys_open(O_WRONLY\|O_CREAT\|O_TRUNC, 0644)`；父目录缺失时 `mkdir` 一层后重试 | 整文件覆盖写 |
| `run_shell` | `pipe` → `fork` → 子进程 `dup2`+`chdir(workspace)`+`execve("/bin/sh", ["sh","-c",cmd], envp)` → 父进程 `poll` 读 stdout+stderr → 墙钟超时 `SIGKILL` → `waitpid` | 输出上限 64 KiB；默认超时 120 s；`--no-shell` 关闭 |

路径守卫（best-effort，**不是安全边界**）：所有 `path` 相对 `--workspace` 解析，拒绝绝对路径、
`~` 开头、以及含 `..` 段的路径。工具内部任何失败都不抛错，一律写成 `error: ...` 文本回给模型，
让它自己纠正；bash 在 `danger-full-access` 下本来就能执行任意命令，所以别拿它当沙箱用
（要沙箱请用 `workspace-write` / `read-only`，见 P21 那两节）。

**P21 起还有两条工具级策略**：`read-only` 模式下 `write` / `edit` 直接回
`Error: write is refused in read-only mode (the user granted no write access). Do not retry; …`
（在参数校验之后、动文件之前拦下），`bash` 每条命令先过人工批准闸门。

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
| `tui-frame` | 四种尺寸（40×10 / 80×24 / 100×28 / 120×40）下「每行显示列 ≤ cols」「正文层里没有 ESC」；空态整体居中（首行留白 + 块字 logo + 面板 + 脚注 `~/cwd:branch`）、窄终端 logo 退化成单行标题；对话态底对齐 + 面板贴底；工具块/diff/思考/诊断/用户条目都在；跑满一屏后跟随尾部、PgUp/PgDn 夹取、回尾清零；**P20 脚注**：160 列放下整条统计行、120 列按组丢尾部并补 `…`、40 列统计行整条让位（退回版本号），而 `ctx` / `%cpu` 三种宽度下都必须在 |
| `tui-keys` | UTF-8 逐字符编辑（退格不砍半个汉字、←/→ 停在字符边界）、**被切开的 `ESC [ D`** 正确组装、Ctrl-J 换行与多行光标移动、回车提交（内容 + 清空 + 进历史）、↑ 取历史、运行中 esc = 中断 / 空闲 esc = 清行、tab 切计划模式（面板显示 Plan）、`/` 自动开命令面板并选中第二项、Ctrl-D 空行退出 |
| `tui-sink` | TUI 激活后 `tty_write(1/2)` 与 `tty_reason_write` 的字节分别落到 助手/工具/思考 条目；NUL/`ESC[2J`/TAB 被清洗且正文层无 ESC；关掉 sink 后写入回到真实 fd |
| `tui-turn` | headless 端到端（mock LLM，复用手打路径注入「任务+回车」）：屏幕里出现用户条目、`✓ Write(note.txt)`、`✓ Bash(`、最终答案；回合结束状态回 idle、**状态区整块收掉且思考实时行不留残影**；**P20：脚注里必须出现 `1 轮 · ` 与 `工具调用 `**（真实测量的 llm/工具耗时进了界面）；fd 1 无输出 |
| `tui-status` | 常驻状态区 + 思考实时行（P18）：**转录铺满视口后状态行必须仍在**（回归主断言，且落在面板上方那一行）、实时行紧跟在状态行下面且只显示 `latestLine`、超宽按列**从左边**截断补 `…`（保住最新的那一端）、`ESC[2J`/NUL/TAB 被清洗且换行只取最后一段、`tui_think_clear`/`TUI_RUN_IDLE` 之后整块收掉（空闲态 0 行）、滚动时钉住不动、窄终端（30 列）按实际可用列画、窄到放不下前缀（20 列）退化成 1 行不硬画、`view_think_live` 默认开（不看 `--show-reasoning`）而 `--quiet` 下一个字节都不写 |
| `stats-format` | 纯函数逐字节：duration（`0s`/`0.4s`/`12s`/`50.7s`/`59.9s`/`1m0s`/`2m42s`/`60m0s` + 平均值口径不被整数截断 + 除零保护）、tokens（`999`/`1K`/`12.2K`/`238K`/`517K`/`1000K`/`1M`/`1.2M`/负数按 0）、tok/s（`0.4`/`9.9`/`9.94→9.9`/`221`/`994`/无时长）、缓存命中（无计费输入 → 不显示、`0`/`50`/12.5%→13%（ties 向上）/71%/全命中 `100`/999/1000→`99.9`/99.9579%→`99.96`，全部按 DSH 的取整规则） |
| `stats-line` | 整行逐字节：demo fixture = DSH 截图那一行（`1 轮 · 12 步 \| LLM 50.7s · 工具调用 4.1s \| 首 token 平均 1.5s · 221 tok/s \| 缓存命中 71% \| 输入 238K tok · 输出 12K tok`）+ 四种判据（只有步数 / 只有 usage / 两步其一被取消 / 只有首 token / 工具+解码同时出现） |
| `stats-fold` | 同一批边界「实时喂」与「日志逐行回放」的 11 个字段签名必须逐字节相同；再钉边界语义：孤儿 `tool/result` 不计时、未结算调用在 `turn/end` 丢弃、被取消的步只计数不计时、`turn/step` 不匹配时不计时但 token 照记、没上报输出 token 时不记解码、同一 turn 多步只算一轮、重复 callId 取最后一次并只结算一次 |
| `stats-context` | 占用率（容量未知/分子未知 → 不可用、四舍五入、12.5%→13%、超容量夹 100）、`projectedTokens`（样本 + 增量、钳 0、无锚点时只用样本）、`~已用 / 容量` 与 `未知容量` 写法、`/status` 的上下文块逐字节（含 20 格分段条：三段比例切分、无明细时单段、容量未知时不给百分比与条）、统计明细块（空状态的省缺写法） |
| `stats-usage` | 端到端一轮（mock 的答案帧带 usage，**只给这一轮开** —— 打开 usage 会让 `prompt_tokens` 从估算变成读数，进而改变自动压缩的触发时机，其它轮保持原样）：回合正常结束 |
| `stats-log` | 就着 `stats-usage` 那一轮的会话日志：`step/start` 与 `step/end` 必须成对、`tool/result` 不早于 `tool/call`、日志里的步数/首 token 条数/工具时间差之和与实时折叠的数字**逐个相等**；再把整份日志回放一遍（`--resume` 走的就是这条路），统计行与全部字段必须与实时**逐字节相同** |
| `procx-parse` | `/proc/<pid>/stat` 解析：comm 取**第一个 `(` 到最后一个 `)`**（comm 里允许空格与括号）、utime/stime 是 `)` 之后第 12/13 个字段、`|` 后的 cutime/cstime 必须忽略、state 是字母（`S`/`D`）时能跳过；坏行（无括号 / 无右括号 / 缺 stime / utime 非数字）必须失败；`/proc` 目录项名过滤（纯数字才算 pid，`self`/`.`/`..`/11 位不算） |
| `procx-percent` | `Δticks × 1000 / Δms`：0 / 37 / 100（一个核）/ 250（并行 > 100%）/ 0.5% 向上取整 / `Δms=0` 不可算 / 负增量按 0 / 上限钳 999；`USER_HZ = 100` 常量 |
| `cpu-live` | fork 一个忙循环 400ms 的子进程（同一个二进制 → comm 相同），父进程睡 450ms 后两次采样：进程数必须涨、综合 `%cpu ≥ 25`、有时间跨度；只建基线的那次必须不给百分比（防除零爆表） |
| `tui-pty` | **真 PTY**（`/dev/ptmx` + `fork` + `dup2(slave→0/1/2)`）：进备用屏幕（`ESC[?1049h`）、首屏面板/logo、发任务后转录出现 mock 最终答案、`SIGWINCH`（改 winsize + 发信号）后进程仍活着并继续重绘、Ctrl-D 退出码 0、退出后 `TCGETS` 与 fork 前**逐位相同**、离开备用屏幕；不需要 setsid/TIOCSCTTY（fd 0 就是 pts 从设备，Ctrl-C 由程序自己吃字节） |
| `perm-modes` | 三级访问模式的机器名 ↔ 值 ↔ 显示名（含 DSH 产品名 `Full access`）、`custom`/空串判 -1、策略真值表（`confine` / `allows_write` / `requires_approval`） |
| `perm-readonly` | mock LLM 一轮 3 个调用：read-only 下 `write` 必须回逐字拒绝串且**文件没落盘**、`bash` 在非交互会话里必须 fail closed（回「无回答渠道」串、命令输出一个字都不给）而 `read` 照常；请求里必须带 read-only 的 file policy 句 |
| `san-profile` | 三档 profile 的 bwrap argv 逐字断言：read-only = `--ro-bind / / --dev /dev --proc /proc --unshare-pid` 且**没有**可写挂载；workspace-write 多 `--tmpfs /tmp` + `--bind <ws> <ws>`；full access 与 `--no-sandbox` 不套壳；工作区是 `/` 时不加可写 bind；bwrap 不可用时只断言「confined 必须返回 fail closed」 |
| `san-shell` | 直接 fork 出沙箱命令实测（不经工具闸门）：read-only 里 `> /dev/null` 成功、写 `/tmp` 被拒且文件不出现；workspace-write 里工作区内写入逐字节正确、`../` 区外写入被拒；本机没有 bwrap 时打一行 skip（不假绿） |
| `san-tool` | 端到端：`--permission workspace-write` 下让模型跑一条**同时**写工作区内与区外的命令 —— 区内文件必须落盘、区外文件必须不存在（工具层没拦它，是内核拦的） |
| `tui-access` | 访问模式 chip 三种模式的显示、`shift+tab` 只置请求（主循环据此开浮层）、选择器打开（三行齐 + `✓` 只在当前模式那行 + 圆角框 + esc 取消不变更）、↓+enter 选中 Workspace Write 交给处理器（策略全局 + chip + 转录 notice + **恰好一条** runtime-context 注入且不上屏）、运行中切换时 `cfg.access` 必须跟着走（故意把 cfg 设成旧值）、选 Full access 只翻出确认层（游标默认「取消」→ 回车无变化；↑+enter 才切）；末尾一条**回归**：命令面板里选 `/status` 必须真的派发（浮层结果不许被静默丢掉）；每步都查「每行 ≤ cols、正文层无 ESC」 |
| `tui-approve` | read-only 下 bash 逐条批准，两种形态：① headless（注入的键在浮层打开前就被输入行吃了）= 没人回答 → **fail closed**，转录出现逐字拒绝串、命令 stdout 不出现、且不是「没有回答渠道」那条；② **真 PTY**：等 `Read Only：批准这条 bash 命令？` 画出来再送 `↑`+回车 → 命令真的跑（stdout 进转录与下一封请求）、退出码 0 |
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
contextWindow/maxTokens/input image/reasoningEffort/`permission.defaultPreset`→访问模式/`uya-agent.tls` 命名空间；
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
| `tool-view` | 工具行的逐字节断言（P16 单行口径）：bash `description` 优先 / 缺了退回 `command`、exit 0/exit 1 的字形与 `· exit N`、
`Error: ` → `✗`、参数不是合法 JSON → 无摘要、read 的 `· lines a-b`、todo 的 `· 3 items (1 done)`、
write 的 `· +A -D`、**默认（`tool_lines=0`）没有正文**（diff / todo 清单 / 首尾行都不许出现）、
`--tool-lines 6` 时 diff 正文 / 失败不留假 diff / todo 清单原样回来、窄终端下按列截断补 `…`；
最后**把 fd 2 接到文件做端到端断言**：关闭态抓到 0 字节、打开态抓到的字节与 `view_render_block` 完全一致 |
| `think-row` | 思考行的逐字节断言：运行中取最后一行（`trimEnd` 后）并按列**从左**截断补 `…`、结算取第一非空行按列**从右**截断补 `…`、
全空白 / 窄到放不下前缀 → 一行都不出、宽字符不砍半个；`view_think_delta/end` 在非交互与 `--quiet` 下一个字节都不写、
**P18 的 `view_think_live` 在非 TUI（滚动模式）下一个字节都不写**（滚动模式口径不能变）、
`view_think_end` 幂等；**静音窗口**（`tls_noise_mute` 把 fd 2 指向 `/dev/null`）里显示层必须落到 `err_fd()` 那个还能看见的
stderr 上（P16 抓到的坑，见 §3 第 27 条）；`assistant/reasoning` 事件的 data JSON 逐字节 |
| `reasoning-log` | 跑完 `shell` 轮后回读会话日志：必须有一条 `assistant/reasoning`，`reasoning_content` 与 mock 回包**逐字节相同**、
`turn`/`step` 都在 —— 守着「显示层只留一行，但全文不许丢」 |
| `tool-view` | 工具内容块的逐字节断言：bash exit 0/exit 1 的字形与 `· exit N`、`Error: ` → `✗`、
参数不是合法 JSON → 无括号无摘要、read 的 `· lines a-b`、todo 的计数与清单（✓/▸/·）、
write 的 `· +A -D` + diff 正文、**失败的 write 不留假 diff**、窄终端下按列截断补 `…`、
结果首尾 + `省略` 标记、`--tool-lines 0` 无正文；最后**把 fd 2 接到文件做端到端断言**：
关闭态抓到 0 字节、打开态抓到的字节与 `view_render_block` 完全一致。同轮还断言**多行面板块**
的渲染协议：`tty_block_rows/vis0` 的挂起换行口径、`tty_build_block_erase` 的逐字节（CR / ESC[5A /
ESC[12C / 逐行 ESC[2K）、真画一帧后屏幕上的块形状与 `cur_row`、以及**块变矮时按老行数擦除**
（P15 修掉的「光标已在位就提前返回」）|
| `subagent-panel` | 子代理窗口面板：空表不产出面板；只收 **running**（idle/failed 的窗口立刻消失）；
标题写「运行中/总数」（`agent 1/4` / `agents 2/4`）；**每一行的显示列数完全相等**且等于
`tty_body_width()`（含中文标签、超长标题、超长预览的截断情形）；秒数字段固定 5 列
（`3s` / `1m05s` / `59m+`）且**随已跑时长变化**（1Hz 重画的依据）；`buf` 原语逐字节
（这里抓过「标题里混进未初始化字节」）；显示层关闭时零输出 |
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
| `diag-preview` | 诊断出口的纯函数轮（P19，踩坑 33）：cap 落在多字节字符中间时必须在**字符边界**上停（600 B 中文 + cap 320 → 只吃 318 B，`bufx_utf8_valid` 为真）；半截序列与**孤立续字节**逐字节 `\xNN`；NUL/ESC/CR 走 `\xNN`、TAB 与换行走短转义；合法 U+FFFD 原样留着；`out_diag` 出来的字节序列**只有一个换行**、≤512 B、超长带 `… N bytes total` 后缀；`--debug-dump` 文件里有完整原始字节 |
| `diag-echo-400` / `diag-echo-400-ns` | 端到端（mock mode 24，流式与非流式各一轮）：mock 网关回 **400 + 把整个请求原样回显**（含请求头的 CRLF 与 `tools` 数组）→ 断言 fd 2 上只有 `model endpoint returned HTTP 400` + 一行转义预览：CR 转义成 `\x0d`、**没有裸 CR/NUL/ESC**、行数 ≤6、总长 ≤1 KiB；同时断言 `--debug-dump` 里有完整原文、会话日志里有 `diag/dump` 事件（`kind`/`bytes`/`truncated`/`text`，文本里同样没有裸控制字节）。这两条就是「转录一屏乱码」的现场回归 |
| `tui-diag` | 显示层轮（P19）：4 KiB 的 JSON 块从 fd 2 进来 → NOTICE 只留 ≤512 B + 一行截断提示（不修则 40 份重复铺满整屏）；半截汉字在屏幕上变成 **U+FFFD** 且屏幕文本 `bufx_utf8_valid` 为真（终端不会自己渲染半个字）；正文层无 ESC；思考条目尾部截断（4096 B、中文 3 B/字）不切出半个汉字 （这一轮把 `tty_sink_on` 打开做验证，**收尾必须关回去** —— 漏了的话后面每一轮的输出、连最终的 `SELFTEST PASS/FAIL` 都会被吞进转录缓冲区，终端上看起来就是「跑完没有下文」） |
| `read-window` | `read` 的行窗口（P19，踩坑 34）：在 4000 行 × 40 B = 160 KB（> 读缓冲上限 116736）的文件上直接调 read 工具（args 现造、走真实 JSON 解析路径）——断言 `limit=1000` → `(Showing lines 1-1000 of 4000. …)`（**total 是真值**，旧实现报前缀行数）、`offset=3500` → 真读到 `3500: L03500`（旧实现这里是假 EOF）、`offset=4001` → 才是 `(End of file - total 4000 lines)`、`limit=2000` → 走 `(Output capped …)`、末尾无换行的残行算进 `total`（`a\nb\nc` → 3 行） |

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
* **P19 的验收记录（2026-10-03，对应踩坑 33/34）**：两件事都用**本地假网关**在真二进制上做过
  before/after 对照，假网关脚本留在仓里：`testdata/mock_gateway_echo.py`（非 2xx 的错误体里
  **原样回显**收到的整个请求 —— 就是那次乱码的现场形状）。
  * **诊断出口（踩坑 33）**：`python3 testdata/mock_gateway_echo.py 0` 起假网关，
    `uya-agent --no-dsh-config --base-url http://127.0.0.1:$PORT/v1 --api=chat --max-steps 1
    --debug-dump /tmp/diag.bin "写一个文件"`。用 `git archive 416da94`（P19 之前的提交）
    单独编了一份旧二进制做对照，同一场景、同一命令：
    流式 —— 旧 stderr **297 B / 6 行（含 3 个裸 CR）** → 新 **315 B / 3 行 / 裸 CR 0**；
    非流式（`--no-stream`，走 `dump_http_error` 的 4096 B 出口）—— 旧 **4153 B / 12 行 /
    9 个裸 CR** → 新 **405 B / 3 行 / 裸 CR 0**，预览尾部是 `… 18814 bytes total`。
    同时验证「原文另有去处」：会话日志里出现 `diag/dump` 事件
    （`kind=http-error-body bytes=18814 truncated=true text=18454`，文本是转义后的一行，
    没有裸控制字节），`--debug-dump /tmp/diag.bin` 落 **18851 B** 原始字节（头行 + 请求体原文）。
  * **read 窗口（踩坑 34）**：同一个 5949 行 / 230 KB 的 `src/agent.uya`，让假网关发一条
    `read`（`offset=3000, limit=20`）再发最终答案，从会话日志里读回工具结果：
    旧 `(Showing lines 3000-3019 of **3080**. …)` → 新 `(… of **5949**. …)`；
    `offset=4000, limit=20`：旧 `<content>` 空 + `(End of file - total 3080 lines)`（假 EOF）→
    新 20 行真内容 + `(Showing lines 4000-4019 of 5949. Use offset=4020 to continue.)`。
  * 离线回归：新增 3 轮（`read-window` / `diag-echo-400`(+`-ns`) / `diag-preview`）与 1 轮显示层
    （`tui-diag`）；`make check / build / codegen-audit / selftest` 全绿（selftest 退出 0）。
* **tool_calls 容量（踩坑 35）的验收（2026-10-03）**：故障现场来自**真机会话日志**（`~/.uya-agent/sessions/---home-winger-uya-agent--/session-42acda4e…`）：
  turn 3 的第 2 步 `bash mkdir -p …/x11c` 结果 `(no output) [exit code: 0]` 之后紧接着
  `turn/end reason=error`，而第 3 步**根本没有 `assistant/message` 记录**（同一处固定容量把日志
  一起吞了）—— 与用户截图（`✓ Bash · Create x11c directory · exit 0` 下面直接跟
  `error: out of memory serializing tool_calls`）逐行对上。
  修法是**先写测试再修**：加 `toolcalls-cap` 与 `toolcalls-big` 两轮，然后在
  `calls_json_make` 里把容量改回 `buf_new(8192)` 复现修前现场 —— 两轮同时红：
  `toolcalls-cap` 报「按预算分配仍然写不下（容量没按需要算？）」、
  入史路径打 `error: out of memory serializing tool_calls (9999 bytes)`、
  `toolcalls-big` 报 `agent_run returned 3 (expected 0)`、会话日志侧打
  `[session] assistant 事件的 tool_calls 写不进日志（需要 9999 字节…）`；
  改回「按 `calls_json_need` 算容量」之后两轮 PASS（该用例的 `tool_calls` 原文 9849 字节，
  老的固定容量 8192，`make selftest` 退出 0）。
  再用**真实故障会话**做 before/after 复验（把那条会话复制进临时 `--agent-home`，工作区与
  会话目录名都按临时路径对齐，假网关 `testdata/mock_gateway_bigcall.py` 第一步就回一发
  `arguments` ≈ 9.6 KiB 的 `write`，之后把「头尾标记是否一字不差」写进给模型看的最终答案）：
  旧二进制 exit **3**、stderr 正是用户截图那行 `error: out of memory serializing tool_calls
  (10001 bytes)`、假网关只看到 **1** 个请求、文件根本没写出来；
  新二进制 exit **0**、假网关看到 **2** 个请求（第二个请求里 `head=True tail=True`）、
  回答 `BIGCALL-OK 请求数=2 头=True 尾=True`、落盘文件 9618 字节且头尾标记逐字节正确 ——
  也就是那条「已恢复 255 条消息」的真实历史现在能继续跑下去了。
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
  （以及 P16 的 `tool_lines` 与显示开关状态）
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
* **P16 单行转录在真机上验收过**（`autodl-api` / `DeepSeek-V4.1-Flash`，`--tls-verify=none`）：
  ① PTY 里跑「写三行文件 → bash 打印 → 告诉我第二行」：四次思考各自在提示符那一行滚动
  （`✻ 思考 · The > ` → `✻ 思考 · …t with bash, and tell them the second line. … > `），
  每个块结束时落一行 `✻ 思考 · <首行>…`；工具行恒为一行（`✓ Bash · Print file and second line · exit 0`），
  没有任何正文档；会话日志里 4 条 `assistant/reasoning` 与模型给的思考全文逐字一致；
  ② 本地假网关（`--http-debug`）对照跑同一形状的流：默认只有行、`--tool-lines 6` 把
  `one/two/three/[exit code: 0]` 的正文块与 `· exit 0` 一起带回来、`--quiet --show-reasoning`
  在 stderr 上一个字节都不写；
  ③ 修掉 §3 第 27 条那个「静音把显示层一起吞了」的坑之前，真机与本地 mock **两边都看不到**
  思考行（`--show-reasoning` 等于没开）—— 这是本轮最有价值的发现。
* **P18 的常驻状态区 / 思考实时行也真机验收过**（2026-10-03，`autodl-api` /
  `DeepSeek-V4.1-Flash`，`reasoning_effort = max`，`--tls-verify=none`）：
  在 100×30 的 PTY 里（`script -q -c "stty cols 100 rows 30; ./build/uya-agent …"`）跑
  「计算 17×23，只回答数字」，抓到的帧里：
  ① 提交后 26 行是 `⠙ 思考中 · esc 中断`、27 行是 `✻ 思考 · 391` —— **实时思考文本**（就是模型的
  reasoning 片段）出现在状态区第 2 行，且 spinner 从 `⠋` 走到了 `⠙`（真的在动）；
  ② 回合结束时同一屏上 26/27 行变成 `◆ 助手` / `391` —— **状态区整块收掉、转录把行收回**
  （空闲 0 行），没有残影；③ 退出时 `ESC[?2004l ESC[?1049l` 干净收尾（备用屏幕与括起粘贴都关了）。
  **这一屏在 P18 之前是拿不到的**：同样的转录长度下状态行会被挤掉，屏幕上只剩静止的转录 + 面板。
| `http401` | mock 回 401 + 错误体：agent 必须打印状态与错误体并退出 3 |
| `max-steps` | **显式**给 `max_steps=3`：mock 每轮都给 tool_calls，agent 必须在 3 步后熔断退出 3 |
| `unlimited-steps` | **默认不限步数**（这轮故意不设 `max_steps`，吃 `cfg_default()` 的 0）：mock 连给 **14 轮** tool_calls（超过旧默认 12）才给最终答案 —— agent 必须一路跑满 14 步、把 14 条 `tool_call_id` 全带回请求，并以 0 退出。默认值一旦改回 12，mock 只会被服务 12 次，这轮立刻失败 |
| `hist-keep` | 丢老消息的两条保护：`hist_drop_oldest` 必须留住 system 与**任务原文**（下标 1 的 user），且 `assistant(tool_calls)` 与其 tool 结果整组丢；连追加 40 组之后（远超旧 `MSG_MAX=64`）任务原文仍在、历史仍不以悬空 tool 开头（历史条数默认不限制，见 `history-long`） |
| `toolcalls-cap` | 踩坑 35 的纯函数轮：`jw_str_esc_len` 与实际写出长度**逐字节相等**（含 NUL/引号/控制字节/中文，手工口径 40 字节）；`calls_json_need` 的预算与实际序列化长度严丝合缝（走生产那条路 `calls_json_make`）；两个调用（一个 9 KiB 正文 + 一个塞满转义字节）的参数按预算成功，而按**老的固定 8192** 必然失败；回读后 id/name/arguments 与原文逐字节相同 |
| `toolcalls-big` | 踩坑 35 的端到端轮（mock mode 25）：mock 发一发 `arguments` ≈ 9.6 KiB 的 `write`，断言 ① 大参数的**头尾标记**都一字不差地回到第二个请求里；② 工具结果（`Created file`）在请求里且配对完整；③ 落盘文件与 9 KiB 正文**逐字节**相同；④ `agent_run` 返回 0 —— 修前这一步直接以 `error: out of memory serializing tool_calls` 中止（返回 3） |

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

* **访问模式/沙箱的边界（P21）**：
  * 沙箱只覆盖 spawn 出去的 shell 代码（bash 前台/后台、子代理里的 bash）；进程内 write/edit 靠
    工具层栅栏（路径守卫 + read-only 硬拒），不是内核边界 —— DSH 自己的 `dsh-fs-sandbox` 也是这个分界。
  * 没有「沙箱拒绝 → 升级审批重试」那条链（DSH 的 `sandbox_permissions` + approval）：本项目
    read-only 的审批是「允不允许跑这条命令」，不是「允不允许写这个文件」；模型想放宽只能请用户
    `/permission workspace-write`。
  * 后端只有 bwrap。Landlock 没实现（本机内核 LSM 里没有它，`landlock_create_ruleset` 返回 ENOSYS）；
    没有 bwrap 的机器上 confined 模式只能 `--no-sandbox`（显式承担）或退回 `danger-full-access`。
  * bwrap 的 workspace-write 用 `--tmpfs /tmp`（临时）与整棵工作区可写，做不到「工作区内任意子目录
    各自细粒度授权」；网络与进程级效果不在权限词汇里（与 DSH 一致）。
  * 访问模式是**进程级**状态：不进会话日志的恢复语义（`--resume` 按当前进程/设置重新求值运行时上下文），
    只在切换时记一条 `permission/mode` 审计事件；子代理在 spawn 时刻继承父进程的模式。
  * 沙箱拒绝提示（`[sandbox] the <mode> file sandbox denied a file effect …`）是**按 stderr 签名**
    追加的提示（confined + 非零退出 + 命中 `Permission denied` / `Read-only file system`），
    不改任何强制；DSH 对 bwrap 档也是 signature-only。
* 上下文管理很朴素：整个历史每轮重新序列化（没有 token 级增量缓存）。历史**条数默认不限制**，
  内存随会话线性增长，唯一的收敛机制是「按 token 压力的自动压缩」——
  所以**没有配置 contextWindow 时（`--no-dsh-config` 或模型条目里没有 `contextWindow`）压缩不会触发**，
  长会话请显式给 `--context-window N` 或用 `/compact` 手动压一次。单条消息 200 KiB 会在入史时被
  剪枝/截断（会话日志仍是全文）。
* **默认不限步数**：模型若陷入工具循环不会自动停 —— 交互模式 Ctrl-C 中断本回合（历史保留），
  脚本/CI 用 `--max-steps N` 或 `UYA_AGENT_MAX_STEPS=N` 熔断（`make e2e` 也可 `STEPS=N`）。
  没做「重复调用检测」这类启发式熔断。
* `read_file` 一次最多 64 KiB；`write_file` 是整文件覆盖，没有 diff/patch 工具。
* 滚动模式（`--no-tui`）仍然是纯文本字形、不做 markdown 渲染；TUI 模式下有颜色 + 轻量 markdown
  （围栏代码块、行内 code、标题、列表），但不做完整语法高亮/表格/链接重排。
* TUI 不做鼠标（滚轮/点击/选择）、图片、可折叠卡片、分屏、主题切换 UI；`--resume` 只回填
  最近 200 条历史（注入类消息不回填），`--resume-dsh` 走同一条回填路径。
* 终端小于 32×8 时自动退回滚动模式；`cols < 66` 时块字 logo 退化成一行标题。
* 统计（P20）是**整会话**口径、只认我们自己的会话日志：`--resume-dsh` 导入的 DSH 会话不计入
  （从 0 开始）；输出 token「没上报」与「上报 0」在日志里分不开，所以只有 `> 0` 才进 tok/s；
  非流式（`--no-stream`）没有首 token 边界 → 那一组不显示。上下文的三段明细是
  「4 字符 ≈ 1 token」的启发式，三项加起来不等于总量（DSH 也是这个性质）。
* `%cpu` 只在全屏 TUI 里采样（挂在 TUI 心跳上，1 秒一次；滚动模式不采样），统计的是**机器上
  所有同名进程**（含别的终端/工作区里的实例），不是本会话进程树；单核口径，多进程并行时可以
  > 100%。`/proc` 不可读时该字段直接省略。
* `SIGKILL` 之后终端仍可能停在备用屏幕（不可捕获），用 `reset` / `stty sane` 恢复。
* P16 起滚动模式下每次工具调用只有一行（正文要看就得 `--tool-lines N`，即 DSH 卡片的
  「展开」在终端里是显式开关），思考同理：**非交互（管道）下没有实时行**，只有块结束时落的
  那一行 —— 想边跑边看思考就用交互模式。TUI 下思考有两条路：**状态区的实时行默认就开**
  （P18，一行、只留最新一段），`--show-reasoning` 再把思考收进转录条目（只留尾部 4 KiB）。

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
