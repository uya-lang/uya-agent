# uya-agent — 纯 Uya 写的极简 CLI 编程 agent

一个**只用 Uya 源码**实现的命令行编程 agent：给它一句话任务，它自己看文件、改文件、跑命令，
多轮 loop 直到给出结论。全部代码 42 个 `.uya` 文件，**不引入任何 C 代码、`@c_import` 或其它语言**，
只依赖 Uya 语言与随编译器分发的标准库。

**P0–P29 全部完成**（**P29 是 `/goal` 人类命令**：会话目标的看 / 建 / 改 / 暂停 / 恢复 / 清除，
版本串 `p29-goal`，见 §2 的「会话目标与 /goal（P29）」与 §6 的验收记录；
**P28 是「退不出」修复**：运行中的 `esc`/`ctrl+c`/`ctrl+d`/`/exit`
必须**当场**生效，版本串 `p28-quit`，见 §2「退出与中断」与 §3 踩坑 46；P15、P21 这两个编号各被两条并行线用过一次，P22/P23/P24/P25/P26 也是
并行线前后脚合的流：P21 的一条是**三级访问模式 + 内核沙箱**（机器名与 DSHpermission-presets 一致，见「访问模式」/「沙箱」两节，版本串 `p21-perm`）、另一条是
**终端标题**（合流时按后到的编号记成 **P22**，版本串 `p22-title`）；P22 之后到的是
**命令面板与 `/status` 浮层这条链**（合流时记成 **P23**，见 §3 踩坑 40）；再后到的是
**脚注的 `内存` 字段 + 首 token 打点口径**（合流时记成 **P24**，版本串 `p24-mem`，
见 §3 踩坑 41）；**任务状态 /tasks + 常驻任务块**记成 **P25**（版本串 `p25-tasks`）；本条线（**plan 模式写闸门 + `exit_plan_mode` 审阅浮窗**）按后到的编号记成 **P26**（版本串 `p26-plan`，见「plan 模式：写闸门与审阅浮窗」一节）；P15 的一条是「请求体控制字节全转义 +
见 §3 踩坑 41）；再后到的是**任务状态 `/tasks` 与常驻任务块**（合流时记成 **P25**，
版本串 `p25-tasks`）；最后到的 `/diff` 浮窗记成 **P27**（版本串 `p27-diff`）；
P15 的一条是「请求体控制字节全转义 +
并行线前后脚合的流：P21 的一条是**三级访问模式 + 内核沙箱**（机器名与 DSH
permission-presets 一致，见「访问模式」/「沙箱」两节，版本串 `p21-perm`）、另一条是
**终端标题**（合流时按后到的编号记成 **P22**，版本串 `p22-title`）；P22 之后到的是
**命令面板与 `/status` 浮层这条链**（合流时记成 **P23**，见 §3 踩坑 40）；再后到的是
**脚注的 `内存` 字段 + 首 token 打点口径**（合流时记成 **P24**，版本串 `p24-mem`，
见 §3 踩坑 41）；最后到的 `/diff` 浮窗记成 **P27**（版本串 `p27-diff`）；P15 的一条是「请求体控制字节全转义 +
默认走 Responses 接口」（落点见 §3 踩坑 27、§2 的 `jsonx.uya`/`session.uya`、§6 的
`json-escape` / `ctrl-bytes*`）、一条是**子代理窗口面板**（§2 的「子代理窗口面板（并行线的 P15）」，
踩坑 29））；
P16 是**单行转录 + 思考行**，P17 是**纯 Uya 的全屏 TUI**，
P18 是**常驻状态区 + 思考实时行**；**P19 是诊断出口与 read 窗口**：外来字节（网关错误体 /
坏 payload 头部）只以「转义 + 字符边界截断 + 限长」的一行预览进转录，全文进会话日志
`diag/dump`、原始字节走 `--debug-dump`（踩坑 33）；`read` 改成**流式窗口**读法，`total` 是
数完整个文件得到的真值、只有真越界才报 EOF（踩坑 34）；**P20 是脚注统计行 + 上下文占用 +
%cpu**；**P21 是三级访问模式 + 内核沙箱（bubblewrap）**；**P22 是终端标题跟随会话标题**；
**P23 是命令面板与浮层这条链**（派发收口 / 无匹配不静默 / 运行中只读命令在 step 边界派发 /
浮层滚动与溢出指示）；**P24 是脚注的 `内存` 字段（同批进程的 PSS 合计）、`%cpu` 改名 `cpu`，
以及首 token 打点从「首个正文 delta」放宽成「第一个非空 delta」**（推理/工具型会话里那一组
不再整组空着，tok/s 从爆表的几千回到真实的 150–290 量级；版本串 `p24-mem`，见踩坑 41）；
**P25 是任务状态 `/tasks` 与可展开的常驻任务块**（清单 / 后台任务 / 子代理 / 会话目标四类汇成
一张进度表，版本串 `p25-tasks`，见 §2 的「任务状态与 /tasks（P25）」与 §6 的验收记录））；
**P26 是 plan 写闸门 + 审查浮窗**（版本串 `p26-plan`）、**P27 是 `/diff` 浮窗**（`p27-diff`）、
**P28 是「退不出」这条线**（运行中的 esc/ctrl+c/ctrl+d 与 `/exit` 当场生效，`p28-quit`）、
**P29 是 `/goal` 人类命令**（对齐 DSH 的 `/goal`，版本串 `p29-goal`）；
**P32 是 `/sessions` 列表这条线**（三列 = 标题 / 工作区 / session id、按 `lastActiveAt` 倒序、
列宽随终端自适应、同 id 只留最后一条索引记录，版本串 `p32-sess`；它和并行线的 `p31-wait`
撞了号，按「后到的顺延」记成 P32，见 §2「会话持久化与恢复（P4）」与 §3 踩坑 49/50）；
**P30 把「运行中的 `/` 命令要等整个 step」这条边界去掉**（版本串 `p30-pump`）：派发点从
step 边界一处铺到**全部泵点**（流式每 ≤50 ms 一次 + bash/后台任务/子代理/搜索/workflow 的轮询
循环），只读命令当场开浮层（真终端实测 2245 ms → **103 ms**），有副作用的命令立刻给回执并写清
落点（`/new`、`/resume` 先中断当前回合，`/compact` 排 step 边界）；**没有走真线程** ——
试通了但被工具链的分配器否掉，证据与口径见 §3 踩坑 47 与 §2 的「运行中的命令不再等
step 边界（P30）」。
**P31 把「请求在飞的那段」也插上泵点**（版本串 `p31-wait`）：P30 之后还剩三段没有泵点的路——
`hc_open` 读响应头（整段阻塞、上限就是 `timeout_ms`）、写请求体（每 16 KiB 一条 TLS 记录）、
压缩的摘要请求（`interactive` 写死 false），以及「命令派发之后要等下一次 tick 才上屏」；
真终端实测：等响应头那段 **2280 ms → 53 ms**、压缩在飞 **2833 ms → 63 ms**、空闲 **242 ms →
62 ms**，见 §3 踩坑 48、§2 的「请求在飞的那段也不再是空白（P31）」与 §6 的验收记录。
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
（`ctx`，DSH `contextPressure` 的口径）、**全部 uya-agent 进程**的综合 CPU（`cpu`，
`/proc` + `USER_HZ` 口径）与**同一批进程的内存合计**（`内存`，PSS 口径）；终端放不下就
从尾部丢组，明细进 `/status`。
`--no-stream` / `--compat-fold` 保留两条回退路径。
**P21 把「权限」补齐成 DSH 的样子**：三级访问模式（`read-only` / `workspace-write` /
`danger-full-access`，机器名与 DSH 一致）、输入面板上的访问模式 chip 与 `shift+tab` 选择浮层
（Full access 过风险确认）、`/permission [预设]`、来源链（CLI / `UYA_AGENT_PERMISSION` /
DSH `permission.defaultPreset`），read-only 下 `write`/`edit` 硬拒、`bash` **逐条人工批准**，
外加**真的内核沙箱**：confined 模式的 bash 在 **bubblewrap** 的 mount namespace 里跑
（只读根 + fresh `/dev` + 私有 PID 的 `/proc`，workspace-write 另加临时 `/tmp` 与可写工作区 bind），
起不来就 fail closed，绝不静默降级。
**P22 让终端标题自动跟着会话标题走**（对齐 DSH 的 session-title 口径）：交互模式起来先压
标题栈并上基标题 `uya-agent · <工作目录名>`，第一条用户消息之后变成**裸会话标题**
（前 5 个词 / ≤40 B / 清洗 + 码点边界截断），`--continue`、`/resume`、`--resume-dsh` 都能把
已有标题接上，退出或收到终止信号时弹栈还给 shell（见踩坑 39）。
**P25 把「任务状态」摆到台面上**：`/tasks`（TUI 浮层 / 滚动模式打印同一份报告）把四类在跑的东西
汇总成一张进度表 —— `todo_write` 的清单（`✓/▸/·` + `2/5 40%` + 20 格进度条）、后台任务
（状态字形 + 已跑秒数 + 输出体量 + 标签）、子代理（秒数 + 输出行数 + ralph 的 `Round n/m`）、
会话目标（`active 3/20 · objective`）；输入行上方常驻一块**任务块**，默认折叠成 1 行
（`▸ 任务 2/5 40% · 后台 1/3 · 子代理 2/4 · 目标 3/20`），`ctrl+t`（或 `/tasks open|close`）展开成带
边框的清单箱体；没有任务时一个字节都不画（布局与 P21 之前逐字节相同）。
**P26 把 plan 模式从「提示词里的软引导」变成真的闸门与审阅**：plan 模式下 `write`/`edit` 硬拒
（全权模式也一样），模型要动手只能先用 `exit_plan_mode` 交计划；交计划时 TUI 弹出**审阅浮窗**
（`计划待审 · 第 a 行/共 b 行` + 可滚动的完整计划 + 一行选中项说明 + `继续讨论 / 解决 / 确认执行`
三个动作），三个动作分别对应「改一版再弹」「关掉浮窗、你直接说话」「退出 plan 模式开始动手」，
`esc` 等同「解决」，没人回答一律**不批准**。运行中切 plan 模式还会给模型补推一份新的运行时
上下文快照（不然模型下一轮看到的仍是旧状态）。
**P27 加上 `/diff` 浮窗**：一个命令看「工作区相对 HEAD 改了什么」—— 浮窗**左侧是文件列表**
（git 的 XY 状态码 + numstat 的 `+A -D`，↑↓ 选文件），**右侧工作区分两栏**
（`旧 · HEAD` / `新 · 工作区`，行号 + 逐行对齐：配对上的改动左右并排、落单的删/增各占一侧），
**显示的是整份文件的全文比对**而不是只给几行首尾（`git diff -U100000`）。
数据来源是**只读地 fork `git`**（`status -z` / `diff --no-index` / `rev-parse`，
`GIT_OPTIONAL_LOCKS=0` 不写 index.lock、不经 bash、不套沙箱、不走审批），
解析与配对在 `src/gitdiff.uya`，绘制在 `tui.uya` 的新浮层 `TUI_OV_DIFF`；
`esc`/`q` 关闭、`pgup/pgdn` 翻页、`←/→` 左右滚、`r` 重扫，非 TUI 模式打单列 unified diff 回退。
**P29 把「会话目标」交给人类直接管**：`/goal`（语法与措辞逐条对齐 DSH 的
`commands/command-goal`）—— 裸命令看状态（phase / objective / `Rounds: r/m` / `Activation: armed`,
没有目标时给用法），`/goal <objective>` 创建、`/goal edit <objective>` 改目标、
`/goal pause` / `/goal resume` / `/goal clear`；控制词**只有独占整行时**才算控制词
（`/goal pause after verification` 创建的就是那个字面目标），已有**未完成**的目标不许被顶掉
（必须先 `edit` 或 `clear`），已完成的让位给新身份（id +1）。落盘仍是 `goal.json`，
与模型工具 `create_goal` / `get_goal` / `update_goal` 共用同一份状态：工具走 CAS
（id + revision），人在回路里直接以当前为准。TUI 里结果是**浮层**、滚动模式打转录，
带参数的那条还会当场重画常驻任务块的目标段（P22 的块与 `/goal` 共用同一条投影）。


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
make e2e-tasks      # /tasks 报告头 / 空态串 / open|toggle|非法参数 / /help（离线）
make e2e-goal       # /goal 用法 / 创建 / 拒绝顶掉 / edit / pause·resume / clear / /help（离线）
make e2e-sessions   # /sessions 三列 / 时间倒序 / 同 id 取最后一条 / id 完整（离线）
make sess-selftest  # 只跑 /sessions 那两轮（纯函数排版 + TUI 浮层），改会话列表时最快
make probe        # 传输层探针：打真实 https 端点，期望 HTTP 401（不需要 key）
```

不带 make 的等价命令（关键点：**显式导出 `UYA_ROOT`**，并尽量用编译器的绝对路径）：

```bash
export UYA_ROOT=/home/winger/uya-0.10/lib/
export UYA_SPLIT_C_DIR=$PWD/build/uyacache      # 多文件 C 缓存别丢在仓库根目录
/home/winger/uya-0.10/bin/uya build src/agent.uya src/httpc.uya src/jsonx.uya src/tools.uya src/selftest.uya -o build/uya-agent
```

用法：

常用斜杠命令：`/diff`（git 修改浮窗：左文件列表 + 右双列全文比对）· `/status` · `/goal`（会话目标）·
`/permission` · `/plan` · `/tasks` · `/sessions` · `/compact` · `/help` · `/exit`。

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
| REPL 命令 | `/help` `/continue` `/status` `/tasks [open\|close\|toggle]` `/goal [<objective>\|edit <objective>\|pause\|resume\|clear]` `/compact` `/plan` `/permission [预设]` `/sessions` `/resume <id>` `/new` `/exit` |
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
| `--plan` | 以 plan 模式启动（先出计划、批准后再执行）；P22 起 plan 模式**真的拦写**，非交互会话（管道/CI）里没有审阅渠道 ⇒ 只产出计划、写工具始终被拒 |
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
| `--title` | 交互模式（TUI / 滚动 REPL）下把**终端标题**写成当前会话标题（**默认开**，见「终端标题」一节）；`--no-title` / `UYA_AGENT_TITLE=0` 关掉整件事；一次性运行与非 TTY 路径本来就不写 |
| `--color=MODE` | `auto`（默认）/ `always` / `never` / `16` / `256`；`NO_COLOR` 也认 |
| `--tui-demo` | 打印 TUI 的 home / chat / 运行中 三屏 + 常驻任务块两帧（折叠 / 展开）+ **plan 审阅浮窗**一帧的纯文本快照后退出（诊断 + 文档） |
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
`UYA_AGENT_SANDBOX`（`0`/`off` = 等价于 `--no-sandbox`）、`UYA_AGENT_BWRAP`（bwrap 路径）、
`UYA_AGENT_TITLE`（`0` = 不改终端标题，其它非空值 = 开；`--title` / `--no-title` 优先），
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
                  字节与非法 UTF-8、按字符边界收 cap，见踩坑 33）；
                  P22 再加：**终端标题层** —— `tty_title_clean_into`（全仓唯一的标题规范化：
                  去 OSC/CSI/ESC 序列、去 C0/C1 与零宽方向控制符、空白折叠、按码点边界收字节）、
                  `tty_title_fallback_into`（前 N 词 + 字节上限的兜底派生）、
                  `tty_title_begin|set|end`（压标题栈 → `ESC]2;<标题>BEL` 去重上屏 → 弹栈）
src/sigx.uya      信号层（P17）：直接绑宿主 glibc `sigaction`（绕开 uya 0.10 `libc.signal`
                  的 SIGSEGV 缺陷）；终止类信号 → 先恢复终端（termios + **弹标题栈** +
                  离开备用屏幕）再 128+sig 退出；SIGWINCH → 只置标志；`sigx_reset_for_child()` 给 fork 子进程
src/tui.uya       全屏 TUI（P17/P18）：帧模型（行=段序列，逐行 diff 重绘）、备用屏幕进出、
                  **访问模式 chip 与底对齐选择浮层、阻塞式确认（tui_confirm_wait）**、
                  **P22 reader 浮层（tui_reader_wait：计划审阅 —— 可滚动正文 + 三动作）**、
                  转录条目（用户/助手/思考/工具/诊断）、轻量 markdown、输入编辑器（按字符编辑、
                  多行、历史、括起粘贴）、键解码（分片转义序列）、浮层（命令面板/会话/帮助/问答）、
                  sink 通道与清洗、滚动与尾随、帧节流；P18 再加**常驻状态区**（钉在输入面板正
                  上方：spinner 行 + 思考实时行，空闲 0 行）与尾部对齐截断 `tui_put_clipped_tail`；
                  P19：诊断（NOTICE）条目限长（`TUI_NOTICE_MAX`）、非法/半截 UTF-8 → U+FFFD、
                  思考尾部按字符边界切；P25 再加**常驻任务块**（钉在状态区之上：转录 → 任务块 →
                  agents 箱体 → 状态区 → 面板）、`ctrl+t` 切展开态（键层只置请求、主循环落地）、
                  信息行在块非空时才挂 `ctrl+t tasks` 提示
src/sigselftest.uya 信号层的自测轮次（sig-abi / sig-basic / sig-term-restore / sig-child-reset）
src/tuiselftest.uya TUI 的自测轮次（tui-frame / tui-keys / tui-sink / tui-turn / tui-status / tui-pty /
                  tty-title-pty；P20/P24 起 tui-frame 还断言脚注统计行的逐级退化、右对齐
                  （末尾 3 列空白）与 `ctx` / `cpu` / `内存` 三档让位顺序，
                  P22 起 tui-pty 与 tty-title-pty 还逐字节断言终端标题；
                  tui-frame 现在还逐行量**浮层方框**的左右边界列——长行把右边框顶出去那类
                  缺陷（踩坑 42）只有它会红；P26 起加 tui-plan：审阅浮窗排版/滚动/三动作/数字直选 +
                  headless fail closed + 真 PTY 批准与解决；P31 起加 tui-p31：派发之后**同一次
                  调用里**就出一帧（`tui_frame_count()` +1）+ 泵点上下文登记/清掉的口径）
src/inbox.uya     输入收件箱：steer（运行中输入的文本，step 边界领取）+ keepInbox 语义
src/yamlcfg.uya   自带 YAML 子集解析器：去注释（块标量/引号感知）、中和 `!!tag`、
                  block/flow 映射与序列、`|`/`>` 块标量、跨行 flow 集合、节点池树 + 导航
src/fsx.uya       文件工具：路径解析（可选工作区守卫）、**read-only / plan 模式下 write/edit 硬拒**、
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
                  解压、把 user/message + assistant/message + tool/result 转成我们的历史；
                  P22 起还从日志的 `session/title` 事件里取出会话标题（latest-wins）当本会话标题
src/dshcfg.uya    读 DSH 设置：$DSH_HOME 解析、settings.yaml 模型路线（agent-default-model →
                  provider 的 baseURL/apiKeyEnv/models[]）、.credentials.yaml、.env 兜底、
                  permission.defaultPreset→访问模式（三级）、uya-agent.tls 命名空间
src/workflow.uya  workflow：把脚本写成 .ush + 生成同目录的自包含 hooks.uya（钩子客户端）、
                  监听 127.0.0.1 的钩子端口、fork+exec `uya run`、边等服务脚本边处理钩子
src/deleg.uya     子代理：fork 不 exec（同二进制跑 agent_run）、结果管道 + 增量读取、
                  父子会话关联（subagent/start 事件）、前台/后台、send_message 续跑、interrupt、ralph、
                  spawn 时刻记账（面板秒数）+ 终态结算通知（跑完即隐）
src/goal.uya      会话级目标：goal.json（id/revision/phase/round/maxRounds/blocker/armed）、
                  精确 id+revision 校验、blocked 至少连续 3 轮；
                  P29 再加人类命令面 `goal_cmd_run`（/goal 的看/建/改/暂停/恢复/清除，
                  控制词只在独占整行时不区分大小写、未完成的目标不许被顶掉）与 `goal_clear`
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
src/plan.uya      plan 模式状态机 + **写闸门**（plan_blocks_write，进程级镜像供工具层查询）+
                  exit_plan_mode（非 plan 模式报错、`# ` 开头的计划、三裁决审阅：浮窗 / CLI y-N / 无渠道）
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
src/procx.uya     进程资源采样（P20/P24）：扫 /proc，取 comm 与本进程相同的**所有**进程的
                  utime+stime（不取 cutime/cstime，避免父子双计），USER_HZ = 100、
                  pct = Δticks×1000/Δms（单核口径，可 > 100%），1 秒一次、挂在 TUI 心跳上；
                  同一次走查里按 5 秒节奏顺带累加**内存**：`smaps_rollup` 的 `Pss:`（整批统一，
                  读不到就整批退回 `status` 的 `VmRSS:`），显示成 `312M` / `1.2G`
src/gitx.uya      只读地跑 git（P28）：PATH 解析 git 路径（stdlib 没有 execvp）、fork/execve +
                  poll 双管道收 stdout/stderr、10s 墙钟超时 SIGKILL、超限**照读不误**（不排空会把
                  子进程卡在写管道上）；环境继承 + 覆盖 GIT_PAGER/GIT_OPTIONAL_LOCKS/LC_ALL，
                  并剔除 GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE（防父进程把仓库指到别处）
src/gitdiff.uya   /diff 的数据模型（P28）：`status --porcelain -z` 出文件列表（XY + numstat 计数）、
                  `diff -U100000 HEAD`（未跟踪/无 HEAD 走 `--no-index /dev/null`）出整份文件的
                  unified diff，再把删块/增块**配对**成左右两栏的行表（CTX/MIX/DEL/ADD/HDR）、
                  行号、增删计数与二进制/仅模式变更/截断说明；另含非 TUI 的单列文本回退
src/diffx.uya     行级 diff（只服务显示）：公共整行前后缀裁剪 → LCS DP（60×60 上限）→
                  行列截断 + 头截断；全局暂存最近一次变更，view 层 take 走
                  （P16 起正文默认关闭，它只喂 `· +A -D` / `· replaced` 这两个后缀；
                  正文要 `--tool-lines N`（N>0）才会被 append）
src/tasks.uya     任务状态（P25）：把四张表（todo 清单 / jobs / deleg / goal）折叠成
                  「折叠行 / 展开箱体 / /tasks 报告」三份文本（**纯函数**：不 poll、不读盘、
                  不写终端，now_ms 也显式传参 —— 自测可逐字节断言），外加一张面板块快照：
                  变了才推送（滚动模式走 tty 面板块，TUI 只置 dirty 后从 tasks_latest 拉）；
                  地方不够按「展开+agents → 展开 → 折叠+agents → 折叠」逐级退化（行数与字节
                  两条预算：tty 面板块上限 8192 超了会被**静默丢弃** → 块凭空消失）
src/view.uya      显示层：工具→标题/关键参数/后缀三张表、状态字形、按显示列截断、
                  **单行转录**（默认没有正文块：正文要 `--tool-lines N`（N>0）才 append）、
                  **思考行**（运行中在提示符那一行滚动、块结束落一行 `✻ 思考 · <首行>…`；
                  P18 再加 `view_think_live`：给 TUI 状态区喂「最新一行」，默认开）、
                  交互模式的「运行中提示符」换入换出、
                  **子代理窗口面板**（2 行/个、最多 4 个、带边框、逐行等宽）；
                  P25 起推送原语是 `view_panel_push`（谁生成文本谁调用）—— agents 面板与
                  任务块共用同一块面板块快照，不允许两个写者抢
src/agent.uya     CLI、环境变量、消息历史、请求组装、主循环（流式/非流式）、工具分发、
                  交互式 REPL（中断/steer//continue/会话命令）、会话事件记录与恢复、
                  `assistant/reasoning`（思考全文，P16）；P17 再加 `agent_run_tui` /
                  `agent_run_tui_body`（全屏 TUI 主循环，headless 与真终端共用）；
                  P19 再加 `out_diag`（外来字节诊断的**唯一**出口：一行转义预览 + 截断后缀，
                  全文进会话日志 `diag/dump`，`--debug-dump` 落原始字节）；
                  P21 再加 `/permission`、`agent_set_access`（切模式 + 推新运行时上下文快照 + 落日志）
                  与访问模式浮层的结果处理（Full access 过第二道确认）；
                  P26 再加 `agent_plan_apply` / `agent_plan_force`（plan 模式切换的唯一入口）与
                  `agent_plan_snapshot_sync`（step 边界补推运行时上下文快照 —— 运行中切模式模型也得知道）
src/selftest.uya  --selftest 的 mock LLM（含 SSE 受控切分）+ 84 轮断言 + --probe
                  （P17 又加了源文件里的 4 轮信号 + 5 轮 TUI，P18 再加 1 轮 `tui-status`，
                  P19 再加 3 轮诊断，P20 再加 9 轮统计/进程 CPU，P21 再加 7 轮访问模式/沙箱，
                   P22 再加 1 轮 `title-format` + 1 轮 `tty-title-pty`，
                   P25 再加 2 轮任务状态（渲染 + 滚动模式活路径；TUI 侧另有 `tui-tasks`），
                   P29 再加 1 轮会话目标人类命令（`goal-cmd`），见 §6）
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
  `e2e-config`（零参数打印生效配置）/ `e2e-dsh`（列 DSH 会话）/ `e2e-title`（终端标题开关四条回归，
  P22）/ `e2e-permission` / `e2e-sandbox`（P21 访问模式与沙箱）/ `e2e-tasks` / `e2e-goal` /
  `e2e-sessions`（P32 会话列表）/ `tui-selftest`（只跑 TUI 轮）/ `sess-selftest`（只跑 P32 那两轮）/
  `tui-demo`（打印 TUI 的几屏纯文本快照：home / chat / 运行中 / 常驻任务块 / plan 审阅浮窗）。

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
* **plan 模式（P22 起是闸门 + 审阅）**：`exit_plan_mode` 两种模式都注册（工具目录稳定），
  非 plan 模式调用报 `exit_plan_mode is only available in plan mode`，计划必须以 `# ` 开头；
  plan 模式下 `write`/`edit` 硬拒（见「plan 模式：写闸门与审阅浮窗」一节），
  bash 仍按访问模式走。审阅三裁决：TUI 浮窗（`继续讨论` / `解决` / `确认执行`）、
  滚动模式 `y/N`、无渠道（管道/CI、子代理、浮窗画不出来）→ 回「没有渠道」且**不退模式**。
  `--plan` 以 plan 模式启动，REPL 里 `/plan` 切换；运行中切换会给模型补推一份新的运行时
  上下文快照（否则模型下一轮看到的仍是旧状态）。
* **ask_user_question**：交互模式下复用行编辑器（带选项编号），非交互读一行；
  读到 EOF 时返回 `(no answer channel: the user could not be asked)` 而不是挂死。
  （仍是行式问答 —— 只有 `exit_plan_mode` 有浮窗，见 §7 已知限制。）

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
* **会话列表（P32）**：`/sessions`（浮层）、滚动模式的 `/sessions`、`--list-sessions` 打印的是
  **同一份**三列表 —— **① 标题 ② 工作区 ③ session id**：
  * 顺序按 `lastActiveAt` **倒序**（最新的在第一行；缺这个字段的记录排最后），回车即恢复最新那条；
  * 索引是追加写的（每关一次会话追加一条），同一个 id 会有多行 —— 列表按索引自己的契约
    「同 id 取最后一条」去重，所以同一个会话只出现一次（2026-10-03 真机 `index.jsonl`
    实测 332 行 / 322 个会话，其中一个 id 出现 4 次；这个文件一直在长，每跑一次会话就多几行）；
  * 列宽随终端宽度自适应：浮层箱体铺到 `cols-6`，可用列数按
    「三列 → 两列（丢掉工作区列）→ 只剩 id」退化，每列至少 6 列才画（不足 6 列的那一列不如不画）；
  * 列宽按**显示列**算（汉字 2 列），标题**保头**补 `…`、工作区**保尾**补 `…`（路径尾部信息量最大），
    单元格内容先过 `tty_title_clean_into` 清洗（控制字节 / ESC / 半截 UTF-8 都换掉）；
  * **id 在条目文本里永不裁剪**：选中项的 id 是从条目文本里取的，显示层再窄也只是「看不见」，
    `/resume` 永远拿到完整 id（滚动模式没有渲染层，打印前用 `sess_rows_clip_into` 按列硬裁并补 `…`
    —— 半截 id 抄去 `/resume` 一定失败，得让人看出来被裁过）；
  * 浮层里回车走 `agent_tui_sessions_head`（**取行尾那个 token**，且必须以 `session-` 开头），
    不是面板那套「取行首第一个词」—— 第一列现在是标题，取错就变成拿标题去 `/resume`（见踩坑 49）。
* `session/title`（P22）就是终端标题的来源：首条用户消息派生一条（`source.kind = "fallback"`，
  对齐 DSH 的前 5 词 / ≤40 B 口径），恢复会话时由日志里**最后一条** title 事件决定标题。
  注意 `sess_open` 会重新初始化整个 `SessionLog`（含 `title`），所以恢复路径必须把回放出来的
  标题在 `sess_open` 之后再放回去 —— 否则 `--continue` 的标题会静默丢掉（见踩坑 39）。
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
  | Ctrl-C | 中断本回合：停止读取流、丢弃未派发的 tool_calls、只保留 content 的非空白前缀、历史保留；**正在跑的工具子进程当场被杀掉**（P26） | 输入非空→清行；空行→提示一次，2 秒内再按→退出 |
  | Ctrl-D | **退出**（P26 起；工具跑着也生效，见 §2「退出与中断」） | 空行→退出；非空→删光标处字符 |
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
  打断时**先把终端还回去**（恢复 termios + 关闭括起粘贴 + 复位属性 + 显示光标 +
  弹终端标题栈，见「终端标题」一节）再以
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
  ~/uya-agent:main                                                                 p32-sess
```

对话态（`--tui-demo` 打印的就是这几屏的纯文本快照）：

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
  ~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s · 221 tok/s | 缓存命中 71%…```

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
  ~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s · 221 tok/s | 缓存命中 71%…
```

（第 1 行是状态、第 2 行是思考实时文本 —— 它按显示列**从左边**截断，屏幕上留下的是**最新**的那一段。）

plan 审阅浮窗（`--tui-demo` 的**第 ⑤ 屏**，任务块那两帧是 ④a/④b）：模型交出计划时弹在转录区中间 —— 标题栏是
`计划待审 · 第 a 行/共 b 行`，正文是完整计划（markdown-lite，可滚动），最后两行是
**选中项说明**与**三个动作**（`▸` 标当前选中；无色模式下 `TUI_ST_SEL` 不产生 SGR，所以
前缀不能省）：

```
           ╭─ 计划待审 · 1/18 ──────────────────────────────────────────────────────────╮
           │ # 把 hello.uya 的问候语改成 Hello, DSH!                                    │
           │                                                                            │
           │ ## 第一步：读现状                                                          │
           │ · 读 hello.uya，确认现在的问候语是 Hello, Uya!                             │
           │ · 顺手看一眼 Makefile 里有没有别处引用这个字符串                           │
           │                                                                            │
           │ ## 第二步：改一行                                                          │
           │ · 只动那一行字面量，不动缩进与分号                                         │
           │ · 用 edit 工具替换，避免整文件重写带来的 diff 噪音                         │
           │                                                                            │
           │ ## 第三步：验证                                                            │
           │ · 编译并运行：期望输出 Hello, DSH!                                         │
           │ · 跑一次 make check，确认没有连带影响                                      │
           │                                                                            │
           │ ## 风险与回滚                                                              │
           │ · 风险只有一处字符串，回滚就是把这一行改回去                               │
           │ 留在 plan 模式：模型按你的反馈改一版，再弹一次这个浮窗                     │
           │ ▸ 继续讨论     解决     确认执行                                           │
           ╰────────────────────────────────────────────────────────────────────────────╯

  ▌ ↑ Ask anything... "把 hello.uya 的问候语改成 Hello, DSH!"
  ▌ Plan   Full access   deepseek-chat   deepseek   tab plan   shift+tab access   ctrl+p commands   ctrl+t tasks
  ~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s · 221 tok/s | 缓存命中 71%…
```

* **开关**：`--tui`（默认）/ `--no-tui` / `UYA_AGENT_TUI=0|1`；
  `--color=auto|always|never|16|256` 与 `NO_COLOR`（无色时只留粗体/暗色）；
  `--tui-demo [COLSxROWS]` 打印 home / chat / 运行中 三屏 + 常驻任务块两帧（④a 折叠 / ④b 展开）
  + **⑤ plan 审阅浮窗**一帧的纯文本快照（诊断 + 文档；默认画布 160×40，窄终端可以
  `--tui-demo 100x30` 看脚注的退化形态）。
`/diff` 浮窗（P27，`--tui-demo` 的第 ⑥ 屏 —— 数据由 `gd_load_fixture` 注入，demo 不碰 git）：

```
  ╭─ /diff · uya-agent · M  src/diffx.uya  (+13 -4) · +2 -1                                                                                                  ╮
  │文件 (3)                            │旧 · HEAD                                                 │新 · 工作区                                               │
  │▸  M  src/diffx.uya  (+13 -4)       │@@ -1,7 +1,7 @@                                                                                                      │
  │  ??  src/gitdiff.uya  (new)        │    1 // src/diffx.uya — 行级 diff（P14：write / edit 的… │    1 // src/diffx.uya — 行级 diff（P14：write / edit 的… │
  │   M  README.md  (+1 -0)            │    2 // 只服务显示，不参与线上协议。                     │    2 // 只服务显示，不参与线上协议（P22 起 /diff 走 git …│
  │                                    │    3 const DIFFX_MID_MAX: usize = 60;                    │    3 const DIFFX_MID_MAX: usize = 60;                    │
  │                                    │    4 const DIFFX_MID_LINES: usize = 3721;                │    4 const DIFFX_MID_LINES: usize = 3721;                │
  │                                    │    5 const DIFFX_MAX_BYTES: usize = 2 * 1024 * 1024;     │    5 const DIFFX_MAX_BYTES: usize = 2 * 1024 * 1024;     │
  │                                    │    6 const DIFFX_CTX_LINES: usize = 2;                   │    6 const DIFFX_CTX_LINES: usize = 2;                   │
  │                                    │@@ -20,3 +20,4 @@                                                                                                    │
  │                                    │   20 fn diffx_note(old: &[byte], new: &[byte]) void {    │   20 fn diffx_note(old: &[byte], new: &[byte]) void {    │
  │                                    │                                                          │   21     // P22：/diff 的双列视图不复用这里的 LCS（git … │
  │                                    │   21     if !g_diffx_on {                                │   22     if !g_diffx_on {                                │
  │                                    │   22         return;                                     │   23         return;                                     │
  …（内容区剩下的空行）
  │ ↑↓ 文件 · pgup/pgdn 滚动 · ←→ 左右 · r 刷新 · q/esc 关闭                                                                              行 1-12/12 · +2 -1 │
```

（左列表是 git 的 XY 码 + numstat 计数，`▸` 是选中项（终端里还带反显）；右工作区两栏是
`旧 · HEAD` / `新 · 工作区`，行号在每栏左内侧；`@@` 说明行**跨两栏**（所以那一行没有中缝）。
`-` 行只在左栏上色、`+` 行只在右栏上色、配对上的改动左右并排 —— 一行的宽度是算出来的，
竖线在每一行都落在同一列（`tui-diff` 轮逐行断言）。）

* **开关**：`--tui`（默认）/ `--no-tui` / `UYA_AGENT_TUI=0|1`；
  `--color=auto|always|never|16|256` 与 `NO_COLOR`（无色时只留粗体/暗色）；
  `--tui-demo [COLSxROWS]` 打印 home / chat / 运行中 / **任务块（P25）** / **`/diff` 浮窗（P28）**
  五屏纯文本（诊断 + 文档；默认画布 160×40，窄终端可以 `--tui-demo 100x30` 看脚注的退化形态；
  `/diff` 那一屏的数据由 `gd_load_fixture` 注入 —— demo 不碰 git，输出可复现）。
* **运行中的状态区（P18）**：见下一小节。
* **退出与中断（P26）**：见后面「退出与中断：任何时刻都退得出去（P26）」一节 ——
  三条退出路径（`ctrl+d` / `/exit` / 运行中二次 `ctrl+c`）在**回合跑着的时候**也必须立即生效。
* **键位**：`enter` 发送 · `ctrl+j` / `alt+enter` 换行 · `esc` 运行中=中断（**当场杀掉正在跑的工具子进程**）、空闲=清行 ·
  `ctrl+c` 运行中=中断（两秒内再按=退出）、空闲=清空/两次退出 · `ctrl+d` 空行退出（**运行中也生效**）· `/exit`（打字或面板选）退出 · **`shift+tab` 访问模式选择浮层** ·
  `↑/↓` 单行=历史、
  多行=上下移光标 · `pgup/pgdn`、`ctrl+home/end` 滚转录 · `tab` 切计划模式（面板显示 `Plan`）· **`ctrl+t` 展开/收起常驻任务块** ·  `ctrl+p` 命令面板（输入以 `/` 开头也会自动打开）· `ctrl+u/w/k` 清行/删词/删到行尾 ·
  `ctrl+a/e`、`←/→`、`home/end`、`backspace/del` 按**字符**编辑 · `ctrl+l` 强制重绘 ·
  括起粘贴（`ESC[200~`）整段插入不触发提交（> 64 KiB 截断）。
* **浮层**：命令面板、会话列表（三列 = 标题 / 工作区 / session id，按时间倒序、列宽随终端自适应，
  回车把选中的会话 `/resume` 回来 —— 见 §2「会话持久化与恢复（P4）」的 P32 那条）、帮助（`/help`）、`/status` 详情、
  **`/goal` 会话目标**（P29：纯查看型，正文就是 `goal_cmd_run` 的输出 —— 状态块或用法）、
  **访问模式选择器与 Full access 确认**（P21，底对齐，贴着输入面板往上弹）、
  **read-only 下 bash 的逐条批准**（P21：↑/↓ + enter，esc = 无回答）、
  **plan 审阅浮窗**（P26：reader 型浮层，↑/↓/pgup/pgdn 滚正文、tab/←/→ 切动作、
  1/2/3 直选、enter 确认、esc = 解决；见「plan 模式：写闸门与审阅浮窗」一节），
  以及 `ask_user_question` 的**行式**问答（带编号选项 —— 它没有浮层，见 §7）。
  `/help` 走的就是这里说的帮助**浮层**（不是滚动模式的纯文本帮助）；
  `/exit`（同 `/quit`）在面板里选中或直接输入都会退出 ——
  命令的返回值就是「停」，三种入口（面板 / steer / 普通提交）都尊重它。
  浮层里 `↑/↓` 选条目、`pgup/pgdn/home/end` 滚内容（P23：内容比框高时标题栏右侧给
  `↑`/`↓` 溢出指示），回车取选中项、esc 取消。换成面板打字时会**过滤**条目；
  回车时一条都没匹配上不再静默 —— 敲进去的文字回到输入行 + 一条
  `没有匹配的命令：…` 的 notice。浮层画在转录区上（打开时转录被它盖住，只有输入面板
  与脚注还在），esc 关掉就回来。
  命令面板是由输入行里的 `/` 触发的，**派发之后那个 `/` 会被一起收走**（P23）——
  否则下一次敲 `/status` 会拼成 `//status`，被当成未知命令丢掉（见 §3 踩坑 40）。
  回合运行中敲 `/status` / `/help` / `/tasks` / `/sessions` / `/diff` 也能用：**按键当下**就派发
  （P30 起派发点在每个泵点，不再等 step 边界；P31 起「请求在飞」的那几段——等响应头 / 写请求体 /
  压缩的摘要请求——也有泵点，且派发之后**当场画一帧**）；`/new`、`/resume` 会**先中断当前回合**
  再执行，`/compact` 排在 step 边界，`/continue`、`/exit` 等回合结束 —— 每条都先给回执，见 §7。
  命令面板里的 `/goal` 只会交出**裸命令名**，带参数的 `/goal pause` 那种要写盘，所以回合里手敲的
  走 steer → 主循环那条路（`agent_tui_cmd_safe` 放行的也只有裸 `/goal`）；`/diff` 只读，当场派发。
* **`/diff` 浮窗（P28）**：占满转录区可用高度（面板之上、状态区之外；放不下就**不开**
  并给一条提示 —— 画不出来却吞键是老坑），左列表 + 右两栏：
  `↑/↓` 选文件（选中即重载右侧）、`pgup/pgdn` 翻页、`home/end` 顶/尾、`←/→` 左右各滚 8 列
  （滚动过就补 `‹`）、`r` 重扫（失败保留原内容、原因写进提示行）、`esc`/`q` 关闭。
  单元格文本一律走 `tui_clean_into`（ESC/TAB/控制字节/半截 UTF-8 都换掉）、按**显示列**裁剪并
  补位到定长，所以竖线逐行同列（`tui-diff` 轮逐行断言）；浮层重画转录区之后会把状态区**补回来**
  （P18 的承诺在浮层下同样成立），整帧行数也补齐（终端上不留上一帧的残影）。
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
  `tui_poll_tick()`（非 TUI 模式是空调用）—— 工具跑着的时候界面照样刷 spinner、键盘照样收。
  P26 起这些循环还问一句 **`tui_abort_check()`**（0=继续 / 1=中断 / 2=退出）：
  接到非 0 就**当场**把自己那个子进程 SIGKILL 掉再收工，而不是「把键收下来却没人看」
  （以前 `sleep 300` 一跑起来，esc/ctrl+c/ctrl+d 全都石沉大海 —— 见踩坑 36）。
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

### 统计行、上下文占用、cpu 与内存（P20，对齐 DSH 的统计条 + 占用表 + 自定义的进程 CPU/内存）
脚注那一行分两半：左边是**状态字段**（`ctx` 上下文占用、`cpu` 全部 uya-agent 进程的综合
CPU、`内存` 同一批进程的内存合计），右边是**整会话统计行** —— 逐字对齐 DSH Web 聊天统计条
那一行：

```
  ~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M
      1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s | 221 tok/s | 缓存命中 71% | 输入 238K tok · 输出 12K tok
```

（真实渲染是同一行：状态字段紧跟 cwd，统计行右对齐到终端右边；上面这行是 **200 列**下的
形态 —— 160 列会丢掉最后一组并补 `…`，各宽度的实际形态见下面的退化规则。）

* **字段名是 `cpu`，值是百分比**：P24 起不再写 top 的 `%cpu` 样式（`cpu 37%` 而不是
  `%cpu 37%`），口径一个字都没改；`内存` 是同一次 `/proc` 走查顺带采的（见下面的内存段）。

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
  → **第一个非空 delta**（P24：正文/思考/工具参数都算），用新事件 `assistant/first-token`
  记那一刻（事件在流结束后才补写，所以时间用 `sess_begin_at` 钉死，不能用写盘时的
  `ua_now_ms()`）；解码是首 token → 消息组装，所以分子分母覆盖**同一段生成过程**。
* **偏差（明写）**：输出 token「未上报」与「上报 0」在日志里不可区分，所以只有 `> 0` 才进
  解码与 tok/s；空串 delta、`delta:{}`、usage-only 帧不算首 token（P24 之前只认**正文**
  delta，推理/工具型会话几乎打不到点、偶尔打到时分母只盖住生成的尾部 → tok/s 爆表，见
  §3 踩坑 41）；解码窗口量的是客户端**看到** delta 的区间，网关把短回答攒成一批发的时候
  （实测 60 个 token 只在 70–148 ms 内到达）窗口会偏小、数字偏高 —— 会话级数字由长回答
  主导，长回答那一步的窗口与真实速度对得上（§6 的 P24 验收记录里有原始 SSE 对照）；
  非流式（`--no-stream`）没有 delta 边界 → 第 3 组自然隐藏（DSH 也只认 chunk）；
  `--resume-dsh` 导入的 DSH 会话不折叠（那份日志的事件形状不同），统计从 0 开始。
* **上下文占用**（`ctx N%`）：DSH `contextPressure` 的等价物 —— `used = 最近一次请求的
  prompt 规模（未缓存 + 缓存读 + 缓存写，来自 `assistant/message` 的 usage；`--resume` 后从
  日志取）+ 自取样以来表层的启发式增量`，`percent = min(100, round(used / contextWindow × 100))`；
  **两者缺一就不显示**（还没请求过、或 DSH 设置里没有模型容量）。压缩之后 `used` 立刻跟着
  表层估算下降，不必等下一轮请求。`/status` 里有 DSH 点击面板的终端等价物：`上下文已用 46%`
  + `~238K / 517K` + 20 格分段条（`█▓▒` 三段 + `░` 轨道）+ `系统提示词 / 工具 / 对话消息`
  三行明细 —— 明细是固定的 `4 字符 ≈ 1 token` 启发式（与 `agent_pressure_tokens` 同口径），
  **三项之和不等于总量**，DSH 也是这么标注的。
* **cpu**：机器上**所有** comm 与本进程相同的进程（本进程 + 子代理进程 + 其它终端/工作区里
  的实例）的**综合** CPU 使用率，单核口径（并行时 > 100%，显示钳 0…999；不按核数归一）。
  取值是 `/proc/<pid>/stat` 的 `utime + stime`（**不取** cutime/cstime —— 父子同为我们时
  取子进程累计会把同一份 CPU 时间算两遍），单位 `USER_HZ = 100` 是常数而不是 sysconf 读数
  （Linux 对所有架构固定，`cpu-live` 轮用忙循环子进程钉死它）；`pct = Δticks × 1000 / Δms`，
  两次采样之间按**墙上时间**算，所以事件循环被长任务占住也不影响准确度。采样挂在 TUI 的
  心跳（`tui_tick` → `procx_tick`，所有长循环都经过它）上：**1 秒一次、只在 TUI 活跃时**，
  第一次只建基线；`/proc` 读不到 → 字段直接省略（`/status` 会说明原因）。滚动模式
  （`--no-tui`）不采样也不显示。
* **内存（P24）**：与 cpu **同一次 `/proc` 走查**、同一批进程（comm 相同），值取
  `/proc/<pid>/smaps_rollup` 的 `Pss:` 之和 —— 子代理是 `fork` 出来的，PSS 按比例分摊，
  **不会**把父子共享的页算两遍（RSS 会，所以默认不用它）；内核没有 `smaps_rollup` 时
  **整批**退回 `/proc/<pid>/status` 的 `VmRSS:`，两种口径不混着加（`/status` 里写明是哪种）。
  节奏 **5 秒一次**，比 CPU 慢一档：算 PSS 要遍历页表（3 GB 进程实测 ~60 ms/次，1 秒一次会
  把心跳、也就是界面拖住；uya-agent 这类几十 MB 的进程 ~1 ms）。显示成 `312M` / `1.2G`
  （二进制单位，M 取整、G 一位小数）。同样只在 TUI 活跃时采，读不到就整段省略。
* **退化规则**：统计行按 `" | "` 拆组、从**尾部**丢组并补 `…`（等价于 DSH 的整行省略号）；
  `ctx` / `cpu` 在左半区**不参与丢组**，`内存` 只在「加进来还放得下」时才带（32 列那种最小
  画布会让它整段让位）；cwd 是唯一的弹性字段（先满足状态字段与统计行，不够 8 列就整段丢，
  连它一起丢的时候状态字段前面那个 ` · ` 也不画）；右半区连一组都放不下（< 16 列）时退回
  版本号。终端没有 hover，所以 DSH 的 tooltip 位置由 `/status` 顶替（那里有完整明细）。
  各种宽度的实际形态：

（下面是 `--tui-demo` 在八种画布下的真实脚注，cwd 是短路径 `~/uya-agent:main` 以便阅读）

```
200 列：~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s · 221 tok/s | 缓存命中 71% | 输入 238K tok · 输出 12K tok
160 列：~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s · 221 tok/s | 缓存命中 71%…
120 列：~/uya-a… · ctx 21% · cpu 37% · 内存 312M 1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s · 221 tok/s…
100 列：~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M   1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s…
 80 列：~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M   1 轮 · 12 步…     ← 内存占 12 列之后，
 60 列：~/uya-agent:ma… · ctx 21% · cpu 37% · 内存 312M   p24-mem              统计行在 80 列就只剩
 40 列：ctx 21% · cpu 37% · 内存 312M                                       第一组了；版本号那两行是
 32 列：ctx 21% · cpu 37%                                                   右半区整条让位的形态
```

（同一行的左半区与右半区之间至少留 1 列空白；右半区右边缘固定在 `cols − 3`。）

* **落地位置**：折叠与格式化在 `src/stats.uya`，进程 CPU/内存采样在 `src/procx.uya`，
  脚注排版在 `tui.uya`，边界喂养在 `agent.uya` 的 `agent_bound_*`（同一个毫秒值既进日志
  又进折叠，所以「实时」与「回放」对得上）；首 token 打点在 `llm.uya` 的两条流式路径上。

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

### 任务状态与 /tasks（P25）

四类在跑的东西汇成一张进度表：**todo 清单**（`todo_write`）、**后台任务**（`jobs.uya`）、
**子代理**（`deleg.uya`）、**会话目标**（`goal.uya`）。三个入口，一份内容：

* `/tasks` —— TUI 开浮层、滚动模式（`--no-tui`）直接打印（`tasks_report`，两处同一份文本）；
* `/tasks open|close|toggle`（也接受 `expand`/`collapse`）—— 只切**常驻块**的展开态；
* `ctrl+t`（TUI）—— 与 `/tasks toggle` 同效（键层只置 `TUI_REQ_TASKS`，主循环落地）。

常驻块钉在输入面板上方、**状态区之上**（层序：转录 → 任务块 → agents 箱体 → 状态区 → 面板）。
折叠态就 1 行，`--tui-demo` 的第 ④a 屏就是它（真机输出）：

```
  ▸ 任务 2/4 50% · 后台 1/2 · 子代理 1/1 · 目标 3/20
```

`ctrl+t` 展开成带边框的箱体（第 ④b 屏；子代理窗口是 P15 那个独立的箱体，跟在后面）：

```
  ┌─ tasks ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ 清单      2/4   50%  ██████████░░░░░░░░░░                                                                                                                │
  │   ▸ 补自测轮与 make 目标                                                                                                                                 │
  │   · 把 README 第 6 节的验收表补齐                                                                                                                        │
  │   ✓ 写 src/tasks.uya（聚合 + 文本 + 快照推送）                                                                                                           │
  │   ✓ 接进 TUI 浮层与常驻块                                                                                                                                │
  │ 后台任务  1 跑中 / 2                                                                                                                                     │
  │   ● job-1 [bash] running 12s · 输出 33B · 编译内核模块                                                                                                   │
  │   ✓ job-2 [bash] completed · exit 0 · 输出 21B · 跑一遍单测                                                                                              │
  │ 目标      ▸ active · round 3/20 · 把 /tasks 的任务状态进度接进 TUI 与滚动模式                                                                            │
  └─ ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
  ┌─ agent ────────────────────────────────────────────────────────────────────┐
  │ ● sub-1 [subagent] 审计 deleg 的等待循环                                   │
  │ ● running       7s · 12 · 把 deleg 的等待循环与 fork/exec 差异看一遍       │
  └─ ──────────────────────────────────────────────────────────────────────────┘
```

`/tasks` 的报告把四类都列全（含**已结束**的后台任务/子代理 —— 常驻块只列运行中的）：

```
--- 任务（/tasks 的内容）---
清单      2/4   50%  ██████████░░░░░░░░░░
  ▸ 补自测轮与 make 目标
  · 把 README 第 6 节的验收表补齐
  ✓ 写 src/tasks.uya（聚合 + 文本 + 快照推送）
  ✓ 接进 TUI 浮层与常驻块
后台任务  1 跑中 / 2
  ● job-1 [bash] running 12s · 输出 33B · 编译内核模块
  ✓ job-2 [bash] completed · exit 0 · 输出 21B · 跑一遍单测
子代理    1 跑中 / 1
  ● sub-1 [subagent] running 7s · 12 行 · 审计 deleg 的等待循环
目标      ▸ active · round 3/20 · 把 /tasks 的任务状态进度接进 TUI 与滚动模式
提示      ctrl+t 展开/收起常驻块（TUI），/tasks open|close 同效
```

* **口径**（都进自测逐字节断言）：清单 `✓ 完成 / ▸ 进行中 / · 待办`，百分比与进度条按
  四舍五入（`1/200 → 1%`）；清单默认按**进行中 → 待办 → 完成**分组展示（组内保持清单原序），
  常驻箱体里最多 6 行、超出补 `… 还有 N 项（/tasks 看全部）`，`/tasks` 全量列出。
* **后台任务**：`● running`（带已跑时长）、`✓ completed`（带 `exit 0`）、`✗ completed`（非零退出）、
  `■ killed`（退出码 128+信号）；输出体量用**字节数**（`33B` / `3.2K` / `512K` / `1.0M`），
  不数行 —— 1 MiB 的缓冲逐行扫在 30fps 下太贵；超上限被截尾时标 `（已截断）`。
* **子代理**：复用 `view_status_glyph`/`deleg_status_name`（`running` / `idle` / `failed` /
  `interrupted`），ralph 多一段 `Round n/m`。
* **目标**：从 `goal.json` 读进内存（启动时、每次 goal 工具之后、`/tasks` 之前各重读一次）；
  `active` 显示 `round 3/20`，其余显示 `暂停 / 完成 / 阻塞`，`blocked` 还会带上阻塞原因。
* **刷新模型**：「上层推、下层画」（uya 0.10 没有函数指针）：每个工具结果之后
  `tasks_poll`（`jobs_poll_all` + `deleg_poll_all`，只 drain + `WNOHANG`，与 step 边界同一套语义）
  → `tasks_panel_sync`（重建 → 与上次逐字节比 → 变了才推）；TUI 另有 1Hz 心跳
  （`tui_tick → tasks_tick`，秒数/状态在这里刷新），滚动模式跟 P15 一样按「step 边界 / 等待循环 /
  工具结果」刷新。**文本生成是纯函数**，TUI 每帧只做一次 memcpy，不在帧里重建。
* **没任务就什么都没有**：四类全空时 `tasks_line` 一个字节都不写 → 滚动模式清掉面板块、
  TUI 0 行，布局与 P21 之前**逐字节相同**（`tui-frame` / `tui-status` 那些排版断言因此不受影响）。
* **地方不够按「展开+agents → 展开 → 折叠+agents → 折叠」退化**：行数与字节两条预算一起守；
  先丢子代理窗口（它还有 `/tasks` 与结算通知兜着），最后退成 1 行折叠。
  这么退的另一个原因：tty 面板块有 8192 字节上限，超了 `tty_block_set` 会**静默丢弃** ——
  「块凭空消失」比少几行糟得多。
* `/tasks` 也进了 P23 那条链的「回合运行中可当场派发的只读命令」集合（与 `/status` / `/help` /
  `/sessions` 同列）：回合还在跑时在命令面板里选它就当场开浮层，改历史的命令照旧等回合结束。
* **滚动模式也真验过**：`tasks-scroll` 轮走 `tasks_panel_sync → view_panel_push → tty_block_* →
  tty_draw_line`，断言折叠行与 agents 箱体一起进面板块、提示符在它下面、展开后每行 98 列
  （`tty_body_width()` 口径）、收起即隐。
* `--quiet`（含子代理进程）整层关闭：不生成、不推送（与 P15/P20 同口径）。
### 运行中的命令不再等 step 边界（P30，版本串 `p30-pump`）

**现场**（用户报的）：回合只有一个长 step（长流式 / 长 bash）时，敲 `/` 命令十几秒到几分钟
没反应 —— 看着就是卡死。**根因**：P23 把「运行中接受的面板项」放在**step 边界**派发
（`agent_turn_loop_inner` 里 `agent_claim_steer` 之后那一处），而一个 step 可以长到几分钟。

改动（都在同一条线程里，没有引入线程 —— 为什么见踩坑 47）：

* **统一泵点 `agent_pump_light()`** = 老的「边跑边抽帧」`tui_poll_tick()` + `agent_tui_poll_pending_cmd()`。
  调用点：**流式循环**（`llm_pump_input`，每 ≤50 ms 一次）、以及 `shellx` / `jobs` / `deleg` /
  `search` / `workflow` 各自的轮询循环。泵点上下文（当前回合的 `cfg`/`History`）在
  `agent_turn_loop_inner` 入口登记、出口清掉，只有本线程读写。
* **只读命令当场派发**：`/status`、`/help`、`/tasks`、`/sessions` 只读当前状态，同一条线程里
  执行就是安全的 —— P23 的「只能在 step 边界」是「TUI 没法回调进 agent」的架构限制，不是安全性。
  面板的派发收口（收走触发用的那个 `/`）原样保留。
* **有副作用的命令：立刻回执 + 写清落点**（同一条命令只提示一次，泵点里不刷屏）：
  * `/new`、`/resume`：`已收到 …：先中断当前回合，随后执行` —— 置中断标志（`tui_request_interrupt`），
    本回合在下一个泵点收回（历史保留），主循环随后执行它；
  * `/compact`：`已排队 …：当前 step 结束后执行` —— 落在 step 边界
    （`agent_tui_step_boundary_cmd`，与自动压缩同一处）；
  * `/continue`、`/exit`、其余：`已收到 …：本回合结束后执行`，结果原样留给主循环。
* **非流式请求也泵**：`http_request`（`--no-stream` 的整段回答、`web_search`、会话导入）以前是
  一口气阻塞读到 EOF，长回答期间界面全冻；现在改成 `poll(≤50 ms)` + 泵点，超时口径仍按 `timeout_ms`。
* **TUI 下的问答改走输入行**：`ask_user_question` 以前用行编辑器直接读 fd 0（和界面抢键盘，
  提示还画在 fd 2 上被 sink 吞掉 —— 屏幕上什么都看不见），现在把提问落进转录、答案用输入行的
  下一次回车，esc = 不回答（回合继续）。
* **粘住的打断标志一并修掉**：`g_tui_interrupt` 以前没人清零，esc 打断一回合之后**后面每个回合
  都会在第一个泵点被立刻打断**（PTY 复现：两条任务都秒回 `[interrupted]`）；现在被打断的回合
  收工时 `tui_interrupt_take()`。

**没有走真线程**（试过、写通了、最后否掉）：见踩坑 47 —— 工具链的堆在两条线程并发 malloc 时
必崩（8/8），所以界面与回合仍在同一条线程里，泵点是**协作式**的。

### 请求在飞的那段也不再是空白（P31，版本串 `p31-wait`）

**现场**（用户报的）：P30 之后 `/status` **还是**慢。真终端量下来，慢的不是流式那一段（103 ms），
而是**请求已经发出去、响应头还没回来**的那一段：敲 `/status` 要等头到才动 —— 假网关把头压住
3 s，浮层就是 **2280 ms** 才出来；压缩的摘要请求同理（**2833 ms**）。根因三条，都是「一个泵点
都没有」的阻塞段：

* **`hc_open` 读响应头**（`src/httpstream.uya`）：读 `\r\n\r\n` 的循环是纯阻塞 `conn_read`，
  头没到之前没有 poll、没有泵 —— 空白的上限就是 `timeout_ms`（默认 120 s）。P30 的验收 mock
  （`mock_send_sse_slow`）刻意让「响应头 + 第一帧先到」，正好绕开了这一段（踩坑 47 里那条
  「假阴性」记的就是它，其实它是**用户可见的真窗口**）。
* **写请求体**（`src/httpc.uya` 的 `tls_write_all`）：每 16 KiB 一条 TLS 记录，每条都是阻塞写；
  大上下文 + 慢上行时同样是秒级空白。
* **压缩请求**（`agent_maybe_compact`）：`llm_stream_style` 的 `interactive` 写死 `false`，
  于是摘要请求的**整段流式**都没有泵点；而且主循环发起的命令（空闲时敲 `/compact`）不在回合里，
  泵点上下文（`g_pump_cfg`/`g_pump_hist`）是空的 —— 就算泵了也不会派发命令。

改动（仍是一条线程，没有引入线程）：

* **`hc_open` 等响应头**：`poll(≤50 ms)` + `agent_pump_light()`，与 `httpc.uya` 的读到 EOF 循环、
  同文件的 `hc_fill_wait` 同一套做法；超时按**墙上时间** `timeout_ms` 判（与 SO_RCVTIMEO 同口径，
  只是更严一点：原来每个分片各给一次 timeout）。非 TUI（子代理 / 一次性运行 / 管道 / `--probe`）
  走原样的阻塞读，行为不变。
* **进阻塞段之前先泵一次**：DNS 解析与 TLS 握手在工具链调用内部，插不进泵点（`std/net/dns.uya`、
  `https_client_handshake`），但至少可以在踏进去之前服务一次键盘与命令。
* **`tls_write_all` 每写一条记录泵一次**：把「刚发请求」的空白缩到一条记录（≤16 KiB）。
* **压缩请求改成 `interactive = g_interactive`**：键盘与运行中的只读命令照常服务，esc/ctrl+c
  现在能中断压缩（被中断时打 `[compact] 已中断（历史未改动）`，不再复用「摘要请求失败」那句
  误导文案）。
* **主循环跑命令时也登记泵点上下文**（`agent_pump_ctx_begin`/`agent_pump_ctx_end`）：空闲时敲
  `/compact` 发出去的摘要请求在飞时，`/status` 之类照样当场派发。
* **派发之后当场出帧**：`agent_tui_poll_pending_cmd` 在派发（或给出回执）之后直接 `tui_render()`；
  TUI 主循环每圈开头也先 `tui_render()` 再进阻塞等待。以前命令执行完只是标脏，要等下一次
  `tui_poll_keys(200)`（空闲）或下一个泵点（回合内 ≤50 ms）才上屏 —— 空闲那 242 ms 全在这里。

剩下真正插不进泵点的只有 **DNS 解析**（≤5 s）与 **TLS 握手**（≤`timeout_ms`）两段，见 §7。

### 会话目标与 /goal（P29）

会话目标（`goal.json`）P11 起就有，但之前只能由模型侧的 `create_goal` / `get_goal` /
`update_goal` 写；**人在终端里没有入口**。P29 补上人类命令面，语法与措辞**逐条对齐 DSH 的
`@deepseek-ai/dsh-command-goal`（`/goal`）**：

| 输入 | 结果 |
|---|---|
| `/goal` | 报当前状态（`Status` / `Objective` / `Rounds: r/m` / `Activation: armed\|disarmed` + 下一步可用命令）；没有目标时给用法 |
| `/goal <objective>` | 创建（`active` + `armed` + revision 1）；已有**未完成**的目标时**拒绝**，必须先 `edit` 或 `clear` |
| `/goal edit <objective>` | 改目标：只换 objective（phase / armed / round 都不动，revision +1）；`complete` 的目标换成**新身份** |
| `/goal pause` / `/goal resume` | 暂停（`paused` + `armed=false`）/ 恢复（`active` + `armed=true`） |
| `/goal clear` | 清除（删掉 `goal.json`；再 clear 回「没得清」，幂等） |

规则与 DSH 同源，两条最容易踩的写下来：

* **控制词只在独占整行时才算控制词**（大小写不敏感）：`/goal pause after verification` 创建的
  就是那个**字面目标**，不是「暂停 + 备注」；`clearx` 也不等于 `clear`，而 `/goal CLEAR` 照样命中。
* **未完成的目标不会被顶掉**：重复 `/goal <objective>` 逐字回 `A goal is already active. Use
  /goal edit <objective> to change it or /goal clear before replacing it.`（盘上的目标一个字都不改）。

展示两条腿：TUI 里结果是**浮层**（`TUI_OVK_GOAL`，标题 `目标（esc 关闭）`，纯查看 —— 回车只是关掉），
滚动模式（`--no-tui`）直接打进转录。带参数的那条命令还会**当场重画常驻任务块的目标段**
（`tasks_goal_reload` + `tasks_panel_sync`）—— 裸 `/goal` 是纯读，不碰面板（与 `/status` 同一条纪律）。
命令解析与渲染全在 `src/goal.uya` 的 `goal_cmd_run`（`agent.uya` 只决定「打到哪儿」）。

与模型工具的分工：**共用同一份 `goal.json`**，工具走 CAS（id + revision 都要对，挡住过期写入），
人类命令直接以当前状态为准（人在回路里不存在读过期值这回事）。人类命令**没有** `complete` 动词
（与 DSH 一致）—— 把目标标成完成是模型工具的事。

### 终端标题（P22，TTY title）

交互模式跑起来以后，**终端窗口/标签页的标题自动跟着当前会话标题走**（xterm 的 OSC 2）。
对齐 DSH 的 `@deepseek-ai/dsh-session-title`：`session/title` 事件的语义、清洗规则与
「前 5 个词 / ≤40 B」的兜底口径都是同一套。

* **标题是什么**：有会话标题（首条用户消息派生出来的、日志里恢复的、或 `--resume-dsh`
  导入的）就写**裸标题**；还没有标题时写基标题 `uya-agent · <工作目录名>`
  （目录名取不到就只留 `uya-agent`）。
* **什么时候变**：进界面时上基标题 → 开完会话（`--continue` / `--resume`）立刻换成日志里
  的标题 → 首条用户消息派生出的标题上屏 → `/resume <id>` 换标题、`/new` 回基标题。
  同一个标题只写一次（逐字节去重），所以标题不是每帧重写的。
* **兜底派生（对齐 DSH preset）**：清洗 → 取**前 5 个词**（`fallbackMaxWords`）→ 按**≤40 B**
  （`fallbackMaxBytes`）在**码点边界**截断。清洗后为空（全控制字节 / 全空白）就**不落标题**，
  留给后面真正有内容的输入；上屏前还会再收一次 **80 B**（`maxTitleBytes`）。
* **清洗规则**（`tty_title_clean_into`，全仓唯一实现）：OSC 序列（含**未终结**的尾巴）、
  CSI 序列、两字节/带中间字节的 ESC 序列**整段丢弃**；C0/C1 与 DEL 丢弃；TAB/LF/CR/VT/FF
  与各种 Unicode 空白（NBSP、全角空格…）折叠成**一个空格**并去首尾；零宽与方向控制符
  （U+200B/U+200E/U+200F/U+202A–202E/U+2060–2064/U+2066–206F/U+FEFF）丢弃；非法/半截
  UTF-8 丢弃（**不留半个汉字**）。
* **终端标题栈**：进界面写 `ESC [ 2 2 t`（压栈），退出或被
  `SIGTERM/SIGINT/SIGHUP/SIGPIPE` 打断时写 `ESC [ 2 3 t`（弹栈）—— 支持 xterm 标题栈的
  终端会把 shell 原来的标题还回去。**故意不写空标题**：把标签页清成空串比留着一个会话标题更糟。
* **只在交互模式**：TUI 与滚动 REPL 各有一条独立接线（fd 分别是 TUI 的私有 dup 与 fd 2），
  由 `tty_title_begin` 打开通道；一次性运行、管道、`--print-config` / `--dry-run` /
  `--selftest` / `--tui-demo`、子代理进程**一个 OSC 字节都不写**（这条有离线回归：
  `make e2e-title` 看开关，PTY 自测轮看字节）。开关：`--no-title` / `UYA_AGENT_TITLE=0`。

```
$ ./build/uya-agent            # 进 TUI
$ printf '\e]2;x\a'            # 手测终端本身吃不吃 OSC 2（能看到标签页标题变 x 就支持）
```

### plan 模式：写闸门与审阅浮窗（P26）

plan 模式原来只是**提示词里的软引导**：system prompt 里加一段（来自 DSH preset 的 `plan-mode.section`）、
运行时上下文加一句 `Plan mode is active`，此外什么都没有 —— 模型完全可以不调 `exit_plan_mode`
就直接开工，审阅浮窗就永远不会出现（真机现场见踩坑 44）。P26 把它补齐成两件事：

**① 写闸门（工具层）**。plan 模式下 `write` / `edit` 直接回：

```
Error: write is refused in plan mode (no file changes before the user approves the plan). Do not retry; present the complete plan through exit_plan_mode first.
Error: edit is refused in plan mode (no file changes before the user approves the plan). Do not retry; present the complete plan through exit_plan_mode first.
```

* 判据是 `plan_blocks_write()`（`plan.uya` 里的进程级镜像，与 `perm.uya` 的 `g_perm` 同款）；
  检查排在 `read-only` 那道之前 —— 当前最直接的障碍是「计划还没批」，文案也最能指路。
* **只看写文件**：`read` / `glob` / `grep` / `bash` / `todo_write` 都不拦。bash 归访问模式
  （P21）管，plan 阶段照样要能跑 `git status`、读测试、看构建。这与 DSH 的立场一致：
  plan mode 是引导而非沙箱，我们只把「改文件」这一条硬起来。
* plan 模式是**进程级**状态，fork 出来的子代理会继承它（与它们本来就会继承 `g_plan.active`
  的提示词段一致）：父进程在 plan 模式下，子代理也写不了文件。

**② 审阅浮窗（reader 型浮层）**。模型调 `exit_plan_mode` 时：

| 动作 | 语义 | 回到模型的工具结果 |
|---|---|---|
| `继续讨论`（默认光标） | 不认可：留在 plan 模式，按反馈改一版再弹一次 | `The user chose to keep planning; revise the plan and present it again.` |
| `解决`（`esc` 同义） | 关掉浮窗、留在 plan 模式，**模型停下等你直接在输入框里说** | `The user dismissed the plan review to speak instead; stay in plan mode, stop here, and wait for their message.` |
| `确认执行` | 批准：退出 plan 模式，从下一步开始照计划动手 | `Plan approved — plan mode exited; carry out the plan starting with your next step.` |
| 无渠道 | 管道/CI、子代理、浮窗画不出来 | `no user-questions channel is available to review the plan; ask the user to switch the session mode instead`（**不退模式**） |

这三个动作与 DSH `plan-review` 卡片的 `Keep planning` / `Chat about it` / `Approve` 一一对应
（裁决用「选中项原文」判定，从不依赖选项顺序）。

* **排版**：转录区中间的圆角方框，标题栏 `计划待审 · 第 a 行/共 b 行`（滚动指示），
  正文是完整计划（复用转录那套 markdown-lite：围栏代码、`#` 标题加粗、列表、行内 code），
  倒数第二行是**选中项的一句话说明**（终端里没有 tooltip），最后一行是三个动作。
  高度取 `min(panel_top-2, 20)`、宽度 78 列（窄终端退到 `cols-6`，下限 24 列），
  正文按显示列折行（复用 `tui_wrap_into`，宽度是缓存键，`SIGWINCH` 后重折）。
* **键位**：`↑/↓` 滚正文一行、`pgup/pgdn` 翻页、`home/end` 顶/尾、`tab`/`shift+tab`/`←/→`
  环选动作、`1/2/3` 直选、`enter` 确认、`esc` 取消（= 「解决」）。
* **默认光标停在「继续讨论」**，且开浮窗前沿用 P21 的做法 `tui_key_reset()` 丢掉排队按键：
  运行期间敲进来的键**最多只能让它继续讨论**，绝不会替用户批准（真终端才丢；headless 自测例外）。
* **fail closed**：浮层画不出来（面板顶行 < 6）或没人回答（headless / 中断）一律**不批准**；
  后者按「解决」处理 —— 老实说「没人做决定」，而不是假装用户要改一版。
* **记录不丢**：浮窗打开前先把计划落进转录（`=== 计划 === … === 计划结束 ===`），
  浮窗是临时的、转录里那份留着回看；正文超过 128 KiB 时浮窗按行截断并留一行指路。
* **滚动模式**（`--no-tui` 真 TTY）不变：仍是 `批准这个计划并退出 plan 模式？[y/N]`。

**③ 运行中切模式，模型必须知道**。system prompt 与首份运行时上下文都只在会话开始时装配/注入
一次，所以运行中切 plan 模式（tab / `/plan` / 批准退出）在 P26 之前对模型是**不可见**的。
现在 `agent.uya` 记一份「模型已经被告知的状态」，每个 step 边界对不上就补推一份新的运行时
上下文快照（自称 supersedes earlier snapshots）并落一条 `plan/mode` 会话日志 ——
与 P21 的访问模式切换同一条路子（见 `agent_set_access`）。切模式同时同步输入面板的 `Plan` chip，
所以 `/plan` 以前那个「chip 不跟着变」的小毛病也一起没了。

**④ 顺手修掉的既有缺陷**：`plan_review()` 原来是
`ask_write(plan_text.ptr as &const byte)` 打印计划正文，而 `ask_write` 按 **C 字符串**长度算、
`js_obj_get_str_unescaped()` 给的 Buf **没有 NUL 结尾**（`buf_new` 是裸 `malloc`）——
真机第一次跑就会一路读到未初始化的堆尾巴。现在改成按长度写（`tty_stream_write(2, p, len)`），
自测里 `plan-gate` 轮会把这段转录逐字看一眼（与踩坑 43 里 `tui_puts` 那条同款：按长度传）。

#### 退出与中断：任何时刻都退得出去（P28）

**症状**（用户报的「退不出」）：跑着长命令的时候按 `esc` / `ctrl+c` / `ctrl+d` / 打 `/exit`，
界面**一点反应都没有**，只能等工具自己跑完（`sleep 300` 就是 5 分钟），或者去另一个终端
`kill`。P28 把这条路上的四个坑一起修了 —— 三个在本进程的输入路径上，一个在**子进程**上。

**① 阻塞循环只收键、不看键。**
`tui_poll_tick()` 只负责「把键盘收下来 + 刷帧」，而 bash 前台、后台任务等待、子代理等待、
workflow 脚本、`rg` 这五处循环里**没有一个人看**收下来的意图 —— 于是 `g_tui_interrupt` /
`g_tui_quit` 置上了也没人理。现在这些循环统一问 **`tui_abort_check()`**：

```
export const TUI_ABORT_NONE: i32 = 0;   // 继续
export const TUI_ABORT_TURN: i32 = 1;   // esc / ctrl+c：停掉当前这一步（本回合到此为止）
export const TUI_ABORT_QUIT: i32 = 2;   // ctrl+d / /exit / 运行中二次 ctrl+c：杀子进程并退出
```

接到非 0 就 `sys_kill(子进程, SIGKILL)` 并把自己那一步的结果收口（bash 的结果里会多一行
`[aborted by user]`，子代理是 `[aborted by user] subagent sub-N was interrupted by the user`，
workflow 是脚本退出码 `137` + `result: [aborted by user]`），**滚动模式（`--no-tui`）也走同一套**
（非 TUI 时这一函数会服务一遍键盘：整行进 steer 收件箱、Ctrl-C = 中断）。

**② 流式期间的退出意图被吞掉。**
`llm_stream_style` 的交互循环以前只认 Ctrl-C/Esc 两个事件，`TTY_EV_EOF`（用户在流式期间按了
`ctrl+d`、或 `/exit`）直接掉在地上 —— 退出了但流还在哗哗地读。现在三个事件一视同仁：立刻
`LlmInterrupted`，回合收口后主循环看到退出标志自己收工。副作用是自测那边的
「headless 下注入的键用完」不能再借用 `g_tui_quit`（那会被读流循环当成用户中断），
于是把它拆成独立的 `g_tui_headless_done`（见踩坑 46(e)）。

**②′ step 边界先判中断，再决定要不要发请求。**
中断/退出意图按 DSH 口径在**下一个 step 边界**生效 —— 那就没必要把一个注定被自己掐断的
请求发出去（真机上这一下是 1–2 秒的往返）。`agent_turn_loop_inner` 的 step 开头统一问一句
`tui_abort_state()`，非 0 就直接以 `AGENT_INTERRUPTED` 收口。

**③ `/exit` 与命令面板的选择根本没生效。**
两条独立的毛病：`tui_do_submit` 提交路径不认识 `/exit`（打字回车会被当成**任务文本**发给模型，
运行中还会进 steer 收件箱），以及浮层的 kind 在 `tui_overlay_close()` 里被清零 —— 而 close 是
accept 的**收尾**动作，于是主循环读到的 `tui_overlay_kind()` 永远是 0，**面板里选出来的东西
（含 `/exit`、`/sessions` 里挑会话）被静默丢掉**（踩坑 46）。现在：`tui_is_exit_command()` 是唯一
判定口径，提交路径与面板选中路径都走它，退出标志**当场**置上（回合跑着的时候主循环不在，
只有标志能立刻生效）；kind 另存一份**结果** kind，跨 close 存活。

**④ fork 出来的子代理在抢父进程的键盘。**
子进程是 `fork` 出来的：`g_tui_on`、帧输出 fd（父进程启动时 `dup(1)` 的那个）、fd 0（终端）
全是继承来的且**从来没人清**。子代理自己的流式循环与工具循环照样 tick —— 于是它会把帧画到
用户的屏幕上，还会从 fd 0 **抢键**：用户按 esc/ctrl+c/ctrl+d，键被正在跑的子代理吃掉，
父进程永远收不到（这就是「派了子代理之后按什么都没反应」）。现在子代理一进 `deleg_child_main`
就 `tui_child_detach()`：不画帧、不读键、不写转录。

**键位口径**（与空闲态一致，只多一条运行中的二次 ctrl+c）：

| 键 | 回合运行中 | 空闲 |
|---|---|---|
| `esc` | 中断本回合（当场杀掉正在跑的工具子进程） | 清行 |
| `ctrl+c` | 第一次=中断；**2 秒内再按一次=退出** | 输入非空=清行；空行=提示一次，2 秒内再按=退出 |
| `ctrl+d`（空行） | **退出** | 退出 |
| `/exit`、`/quit`（打字或面板选） | **退出** | 退出 |

`tui-quit` 轮在真 PTY 里把这三条钉死：工具（`sleep 15`）跑着的时候 `ctrl+d` 必须在 5 秒内退出
（老代码要等 15 秒）、`esc` 必须让「已中断本回合」在几秒内出现且进程还活着、中断过的会话
再提交一个任务必须**照常跑完**（中断意图随回合收口作废，不能跨回合残留 —— 残留的话新任务
会在第一个字节被打断，看着像 agent 死了）。
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
36. **「当前状态」和「刚才发生了什么」混在一个变量里，结果就会被静默丢掉。**
    这一条在本仓库**踩过不止一次**：`tui_ov_accept()` 先写结果、再
    `tui_overlay_close()`，而 close 会把 `g_tui_ov_kind` 归零；调用方却是
    「先 `tui_overlay_take()`、后读 `tui_overlay_kind()`」—— 读到的永远是 0，
    命令面板与会话列表的选中项被无声丢弃（`/` 开面板 → 选中 → 回车 = 什么都不发生）。
    §2 的访问模式一节记了修法（accept 把 kind 存进 `g_tui_ov_done`，浮层关闭时
    `tui_overlay_kind()` 回退到它），这里只留教训：**清理「当前状态」的代码路径，
    不能顺手把「刚才发生了什么」也清掉**；两者的生命周期不同，就该是两个变量。
    同类形状还有「take 之后才问类型」「消失的浮层已经答过一句话」——
    新增浮层类型时先确认读 kind 的时机。

37. **TUI 主循环把命令的返回值丢掉，`/exit` 就成了摆设。**
    `agent_repl_command()` / `agent_tui_command()` 的返回值语义是「该停了吗」，
    滚动模式的 REPL 一直在用（`const stop = …; if stop { run = false }`），
    但 TUI 那三处调用点全写成 `_ = agent_tui_command(…)` —— 于是 TUI 里
    **直接输入 `/exit` 回车不退出**，面板里选中 `/exit` 同样不退出。
    更阴的是它看起来「像在工作」：`ctrl+d`（空行退出）走的是另一条键位路径，
    所以手动测的时候很容易被 `ctrl+d` 的成功掩盖。修法是把三处调用点都接上返回值。
    回归：`tui-pty` 轮的退出动作从 `ctrl+d` 换成 **`/exit` + 回车** ——
    正因为 `ctrl+d` 不经过命令分派，它测不出这个 bug；换掉之后旧实现立刻报
    「`/exit` 之后子进程没有退出（命令的返回值被丢了？）」，并且连带报出
    「没有离开备用屏幕 / termios 没有还原」（进程根本没走到收尾）。

38. **浮层标题的「字节数」写死 = 读越界，而且字符数不等于字节数。**
    `tui_overlay_list(kind, title, tn, …)` 的 `tn` 是**字节数**，实现按它 `memcpy`。
    三处调用把字节数拍成了字符数/旧值：会话标题写 `44`（实际 38）、状态标题写 `46`
    （实际 22）、确认标题写 `6`（「请确认」实际 9）。多出来的部分会把 `.rodata` 里
    紧邻的字面量字节一起复制进标题缓冲 —— 屏幕上就是标题尾巴上挂着别的命令的碎片，
    而且 `×` 这个形状会先在 client 侧 OOB 崩掉（不是每次都能崩，更毒）。
    规矩：**能用 `strlen()` / `bufx_cstr_len()` 量就别写死**，这条仓库里已经重复过
    好几次（`tui_overlay_confirm` 的 `6`、`tui_set_commands` 的字面量长度）。

39. **终端标题（OSC）是「写出去就收不回来」的一类字节：谁来写、写去哪、写什么，三个都得钉死。**
    P22 把终端标题接上会话标题时，一次踩齐三条：
    * **谁来写（门控）**：OSC 只能写给**真 TTY 的交互界面**。管道里带一个 `ESC]2;…BEL`
      就是坏数据（opencode 有过一次真实事故：ACP 模式把 OSC 0 写进了 stdout，直接把
      JSON-RPC 流冲烂 —— 见 [opencode#17282](https://github.com/anomalyco/opencode/issues/17282)）。
      本项目的门控是 `tty_title_begin()` 只在「stdin 是 TTY 且拿到输出 fd」之后调用，
      非交互路径 `tty_title_set` 全是空操作；自测对 `--print-config` / 一次性运行 /
      `--no-title` 断言「捕获流里 0 个 `ESC]2;`」。
    * **写去哪（通道）**：必须直接 `sys_write` 到界面自己的 fd，**不能走 `tty_write`** ——
      TUI 激活后 `tty_sink_on = true`，显示字节全被 `tui_sink_bytes` 收进转录条目，
      标题会被吞成屏幕上的一行乱码（这正是 `tty_reason_write` 那条独立通道的同款理由）。
    * **写什么（清洗 + 截断）**：标题串是不可信输入 —— 首条用户消息可能是粘进来的任意字节，
      `--continue` 恢复的标题来自**别人写的**日志。一个没清掉的 `ESC` 就能伪造控制序列、
      一个 `BEL` 能提前终结标题、一个 `CSI` 能把光标搬走；而当时的兜底派生是「首条消息的
      **前 40 个原始字节**」—— 中文一个字 3 字节，40 会**正好切出半个汉字**，
      屏幕上就是标题栏里一个乱码方块。现在统一走 `tty_title_clean_into`（去 OSC/CSI/ESC、
      去 C0/C1、去零宽/方向控制符、空白折叠、按码点边界收字节），
      派生按 DSH 口径（前 5 词 / 40 B）且上屏再收 80 B。
    顺带记一个**同源陷阱**：`--continue` 时 `sess_open` 会把整个 `SessionLog` 重新初始化
    （`l.title` 重新分配 = 清空），而恢复标题的日志回放排在它前面 —— 标题会**静默丢掉**
    （`--continue` 后标题栏一直停在基标题上，直到用户再打一句话）。修法是在 `sess_open`
    前后把标题抄出来再放回去。

40. **「`/status` 没反应」是四件事叠在一起**（P23，用户报的就是这个）。四条都能在真 PTY 里
    逐帧复现，也都各自有独立的根因（最后一条属于踩坑 38 那一类，这里只说它没覆盖到的几处）：

    * **① 面板派发之后输入行里留着触发它的那个 `/`。** 面板是「输入行第一个字符是 `/`」自动
      开的（`first_slash`），之后敲的字进的是**面板过滤器**而不是输入行 —— 于是选中项派发掉
      以后，输入行里还剩一个 `/`。下一次敲 `/status` 就拼成 `//status`，被当成未知命令丢掉，
      屏幕上只多一行 `· 未知命令（/help 看可用命令）；已忽略`，状态浮层**不再出现**
      （第二次、第四次…… 交替失败，最难查的那一类）。修法：`tui_input_drop_slash_trigger()`
      —— 只在输入**恰好**是 `/` 时清空（`ctrl+p` 带草稿开面板时一个字节都不动），
      主循环的空闲派发与回合中的 step 边界派发都走同一个收口 `agent_tui_palette_apply()`
      （它同时把「该不该停」的返回值传出去，见踩坑 37）。
    * **② 回车但一条都没匹配上 = 静默。** `tui_ov_accept` 找不到匹配项时只置 `cancel`，用户
      敲进去的那串字（在过滤器里）就此消失，屏幕上什么都不发生 —— 「按了回车没反应」的字面
      现场。修法：把过滤器文字**还回输入行** + 一条 `没有匹配的命令：…` 的 notice。
    * **③ 回合运行中接受的面板项要等整个回合结束才派发。** 浮层结果只有 TUI 主循环会取
      （`while run` 顶部），而回合期间主循环整个不跑（`agent_turn_loop` 占着栈）—— 慢回合里
      敲 `/status` 十几秒毫无动静。修法：step 边界（`agent_turn_loop_inner` 里
      `agent_claim_steer` 之后）加 `agent_tui_poll_pending_cmd()`，用新的
      `tui_overlay_peek()` **非破坏性**地看一眼待取结果：只读命令（`/status`、`/help`、
      `/sessions`）当场派发，其余（`/new`、`/resume` 会 `hist_free` 掉回合正在用的历史、
      `/compact` 会改写历史）原样留在队列里给主循环。uya 0.10 没有函数指针（见 §2 P15 的
      「不用回调」），所以派发点只能在 step 边界，不能做到「按键当下」。——**P26 把这条限制
      去掉了**：派发点铺到每个泵点（`agent_pump_light`），按键当天下沉到 ≤50 ms，见 §2 的
      「运行中的命令不再等 step 边界（P30）」与踩坑 47 的测试方法那一段。
    * **④ 浮层的窗口是死变量。** `g_tui_ov_top` 只被写、从来没被读过，绘制按 `want = r - 1`
      取前几项：24 行的 `/status` 只画得出 14 行（`上下文占用` 那一段永远看不见），
      `↓` 按多了连高亮都会移出可见窗口。修法：`tui_ov_box_h()` / `tui_ov_body_rows()` /
      `tui_ov_sel_into_window()` 三个函数把「框多高、能放几项、选中项必须在窗口里」变成单一
      事实来源，绘制与按键都问它们；`↑/↓` 选项、`pgup/pgdn/home/end` 滚内容，标题栏在
      内容溢出时给 `↑`/`↓` 指示（不溢出时布局与之前**逐字节相同**，P21 的访问模式选择器
      断言原样通过）。
    * 手写的字节数在踩坑 38 修掉的三处标题之外还有五处，一并改成量出来的长度：
      `(没有找到会话)`（22/20）、`error: 无法把任务写入历史`（40/34）、
      `(再按一次 ctrl+c 退出；或直接输入任务)`（43/52），以及 `agent_tui_is_injected`
      里两个 `bufx_mem_eq` 的字面量长度（30/29、13/14 —— 前者让注入类的运行时上下文
      被当成用户发言回填进转录）。自测里另加一条**全局不变量**：正文层不许出现
      NUL 字节（越界读会先带进来一串 NUL，这类缺陷从此会当场红）。

    回归轮 `tui-cmd`：面板派发后 `tui_input_len() == 0`、连敲两次 `/status` 都开浮层、
    标题不含 `<system-remind`、无匹配时文字回输入行 + notice、运行中只读命令在 step 边界
    派发而不安全命令留在队列、PgDn 滚到 `上下文已用`/`version` 且指示器跟着变，
    外加**真 PTY**：回合还在跑（脚注还是「1 轮 · 1 步」）的时候浮层已经画出来了。
    （P30 又加了一轮 `tui-p30` 专门盯「单步长流式」：那一刻浮层要在 ≤800 ms 内出现，
    见 §6 的 P30 验收记录。）

41. **首 token 只认「正文」delta —— 推理/工具型会话里那一组几乎永远空着；偶尔打到时 tok/s 爆表。**
    现场（真实会话踩到）：脚注右边 `首 token 平均 / tok/s` 那一组大多数时候**整组不显示**，
    某次突然冒出 `6371 tok/s`。
    根因两条，同一个错：① `llm_note_first_token` 只在 `delta.content` 分支打点，而推理模型
    先流十几秒 `reasoning_content`、正文 delta 只在末尾出现，工具调用回合干脆没有正文 delta
    —— 32 步的会话只记到 1 条 `assistant/first-token`；② 分子是提供方上报的**全部**输出 token
    （正文 + 思考 + 工具参数），分母却只从「首个正文 delta」起算，于是窗口只盖住生成过程的
    最后几个百分点。实测同一条会话：旧口径 `60087 tok / 8990 ms = 6684 tok/s`，
    而地面真值 `Σ输出token / Σ步时长 = 124741 / 786.3s ≈ 158.6 tok/s`（逐步 165–178）。
    修法：判据改成「本帧出现了**任意一种**非空增量」——正文、`reasoning_content`、
    `tool_calls` 的参数片段都算（`got_payload` 标记，只有 `index` 的元数据帧不算），
    空串 delta / `delta:{}` / usage-only 帧仍然不算；chat 与 responses 两条流式路径同口径，
    非流式与终局回填依旧不打点。窗口与 token 从此覆盖同一段生成过程，`首 token 平均`
    也回到真实的 prefill 量级（~1s 而不是十几秒）。回归轮：`stream-firsttok-reasoning` /
    `stream-firsttok-call` / `stream-firsttok-none` 与 responses 侧的两个同名轮。
42. **「被裁时要多补一个 `…`」的裁剪函数，预算里必须先把那一列扣掉 —— 否则方框右边会参差。**
    `tui_put_clipped(p, n, max_cols, style)` 的语义是「正文最多 `max_cols` 列，**超了再补一个
    `…`**」，而那个 `…` 不在预算里。浮层正文直接用它，后果是**只有长到需要截断的那一行**
    比方框宽 1 列：它的右边框 `│` 落在其它行右边一列上 —— 真机截图里就是命令面板的
    `/permission 切换访问模式（read-only / workspace-write / d…│` 把右边框顶了出去
    （顶边 / 底边 / 其余九行都在第 80 列，只有它一个在第 81 列），用户看到的就是
    「弹窗右边没有对齐」。修法是最小改动：新增 `tui_ov_put_clipped()`，先用
    `tty_clip_bytes` 量一次，确定「这一行会被裁」就把预算减一，保证「正文 + `…`」仍然
    ≤ 方框内宽。页脚那处早就是这么做的（`show_cwd = cwd_budget - 1`），这一条只是把
    同一个规矩补齐到浮层。教训：**凡是「超出就补个尾巴」的排版函数，调用点的预算都该按
    「含尾巴」算**；只测短行（从不触发截断）的用例看不见这类缺陷 ——
    回归必须拿**真会撑满的那一行**（`/permission`）在多种宽度下逐行量方框的左右边界。
43. **uya 0.10 的四个「写下去才发现」的坑（P25 一次性全撞上，都是编译期/运行期各报一次就记住的事）**：
    * **全局变量的初始化式必须是常量**：`var g: Goal = Goal{ phase: buf_empty(), … }` 编不过 ——
      `buf_empty()` 是函数调用，生成的 C 是 `{.phase = bufx_buf_empty(), …}`，
      gcc 直接 `error: initializer element is not constant`。全局只能写字面量
      （`Buf{ ptr: null, len: 0, cap: 0 }`，也不能拿别的 `const` 当初始值，同样要写字面量）。
    * **`const x = if 条件 { a } else { b }` 在循环体里会生成「给只读变量赋值」的 C**：
      `const size_t __uya_ifexpr_9;` 然后两个分支去写它 → `error: assignment of read-only variable`。
      同一个写法在函数顶层有时又没事（`tui_draw_footer` 里那句就活着），别去赌 —— 循环里一律
      `var x = a; if !cond { x = b; }`。
    * **`match` 是保留字**：`var match: bool = false;` 报 `意外的 token 'match'`（解析阶段，不是类型阶段）。
    * **`tui_puts` 按 cstr 量长度**：它内部 `bufx_cstr_len`，而 `buf_new` 出来的缓冲区**没有 NUL**。
      P25 把信息行右侧提示从字面量改成拼出来的 `Buf` 之后，屏幕上就多出一截堆里的旧字节
      （实测是 `\x8c输出 Hello, DSH!。` 粘在 `ctrl+p commands` 后面，`--tui-demo` 的快照里一眼可见）。
      凡是要画 `Buf` 里的字节，一律用 `tui_putn` / `tui_put_clipped`（显式给长度）。
44. **plan 模式只是「提示词里的软引导」时，模型会直接开工 —— 而审阅问答在 TUI 下等于不存在。**
    现场（会话 `session-6918e8ef`）：plan 模式激活后模型说「然后直接给你写一个可运行的
    markdown→ANSI 渲染模块并验证」，一个 `exit_plan_mode` 都没调，用户手动中断
    （`turn/end reason=aborted`）。根因是两条各自独立：
    ① plan 模式当时**只有**一段 system prompt（来自 DSH preset）+ 一句 `Plan mode is active`，
    `write`/`edit`/`bash` 上没有任何 plan 相关的闸门 —— `perm_allows_write()` 只看访问模式；
    ② 就算模型调了 `exit_plan_mode`，审阅走的也是 P8 时代的 CLI 问答（`ask_write` + y/N），
    而 TUI 里 `tty_raw_on()` 已经开了 raw ⇒ `tty_is_interactive()` 为真 ⇒ 读的是**老 tty 行编辑器**，
    它跟 TUI 自己的键队列互不相干（streaming 期间键被 `tui_pump_input()` 收进输入行、
    工具执行时又没人抽帧）：没有浮窗、提示只当 sink 文本落进转录、按键去向不确定。
    用户看到的就是「计划直接开始执行」。修法：plan 模式加**写闸门**（`plan_blocks_write()`）
    + `exit_plan_mode` 走 reader 浮层（`tui_reader_wait`），并把 fs/tui 两侧都用自测轮钉死
    （`plan-gate` / `tui-plan`）。**教训**：只要「提示词说了但工具没拦」，就一定会有人（模型）
    绕过它；交互通道必须和界面同源 —— 两套按键通道并存时，UI 那一套才是用户以为自己在用的那套。
46. **「把键收下来」不等于「看键」—— 于是一旦有东西在跑，就什么都退出不了。** 用户报的是
   「退不出」：`sleep` 之类的长命令一跑起来，`esc` / `ctrl+c` / `ctrl+d` / `/exit` 全都没反应，
   只能等工具自己结束。挖下去是**四个**独立的坑，全都在「这个进程到底谁在看输入」上：

   * **(a) 阻塞循环只 tick 不看标志。** bash 前台（`sh_run_foreground`）、后台任务等待
     （`job_wait`）、子代理等待（`deleg_tool_subagent` / `deleg_tool_output`）、workflow 脚本
     （`workflow` 的等待循环）、`rg`（`search`）这五处只调 `tui_poll_tick()`：它把键解析进
     `g_tui_interrupt` / `g_tui_quit` 就完事了，**没有任何一处读这两个标志** —— 用户在工具跑着
     的时候按键，等于往一个没人看的盒子里丢纸条。修法是统一接口 `tui_abort_check()`
     （0/1/2），接到非 0 就当场 SIGKILL 自己的子进程再收工（TUI 模式顺带刷帧读键；
     `--no-tui` 滚动模式走 `llm_pump_input`，意图存进 `g_block_abort` 粘住到 step 边界）。
   * **(b) 流式循环不认 `TTY_EV_EOF`。** `llm_stream_style` 只把 Ctrl-C/Esc 当中断，
     `TTY_EV_EOF`（运行中按 `ctrl+d`、或 `/exit`）被直接忽略 —— 退出意图置上了，读流的循环
     却还在跑。三个事件必须一视同仁。
   * **(c) 退出标志跨回合残留。** `g_tui_interrupt` 只有按键会置、**没人复位**，而流式循环
     一开头就问「有没有中断意图」——于是**中断过一次之后，后面每一个新任务都在第一个字节
     被打断**，屏幕上只剩一句「已中断本回合」，看起来像 agent 死了。复位要放在**回合开始前**
     （主循环里提交任务处）并在 `agent_tui_turn_done()` 再兜一层。回归：`tui-quit` 的 C 段
     （把两处复位都删掉，这一段立刻红）。
   * **(d) 子代理在抢父进程的键盘。** 子进程是 `fork` 出来的：`g_tui_on`、帧输出 fd
     （父进程 `dup(1)` 那个）、fd 0（终端）全是继承的，而 `deleg_child_main` **从来不清**。
     子代理自己的流式/工具循环照样 tick —— 它会把帧画到用户屏幕上、还会从 fd 0 **抢键**：
     用户按 esc/ctrl+d，字节被正在跑的子代理吃掉，父进程永远收不到（现象就是「派了子代理
     之后按什么都没反应」）。子进程一进来就 `tui_child_detach()`：不画帧、不读键、不写转录。
     这一条是**竞态**（父子都在 poll fd 0），真 PTY 回归里不一定每次都抓到 —— 所以它在
     `tui-keys` 轮里是**单元断言**（detach 之后 `tui_active()` 必须为 false）。
   * **(e) 「自测脚本演完了」和「用户要退出」被塞进同一个标志。** headless 自测里
     「注入的键用完」以前直接置 `g_tui_quit`，它同时被三处读：主循环（收工）、
     审批浮层的等待（`tui_confirm_wait`：没人回答 → 一律拒绝）、以及**读流/工具循环的
     中断判定**。P26 把第三处打开（`TTY_EV_EOF` 也当中断）之后，headless 的每个回合都会
     在第一帧被自己的脚本掐死；于是我把 headless 的置位改成「只在空闲时」，结果又把
     审批浮层的 fail-closed 拆了 —— `tui-approve` 轮直接 **100% CPU 死转**（浮层等一个永远
     不会来的答案）。正解是**把两个语义拆开**：`g_tui_headless_done`（脚本演完了：主循环与
     审批等待据此收工）与 `g_tui_quit`（用户真的要退出：中断/退出判定才认）。
   * **(f) 回合结束后提前跳出主循环 = 屏幕停在旧帧上。** 我顺手在「跑完一轮」之后加了
     `if tui_quit_wanted() { run = false; }`，看着无害 —— 其实主循环还要再走一圈
     （poll + tick）才会把**最后一屏**画出来；提前跳出时屏幕上是「⠋ 思考中」的旧帧，
     转录里这一轮的工具卡片与最终答案一个都没有（`tui-turn` 轮就是这么红起来的）。
     结论：收工判定放在循环顶部，别在回合尾巴上抢跑。

   * **（顺带）浮层结果与「通知文本长度」两处小坑。** `tui_ov_accept()` 的顺序是
   「挑中 → 写 `g_tui_ov_result` → `tui_overlay_close()`」，而 `tui_overlay_close()` 顺手把
   `g_tui_ov_kind` 清零 —— 主循环紧接着问 `tui_overlay_kind()`，读到的**永远是 0**，
   于是 `if kind == TUI_OVK_PALETTE` / `TUI_OVK_SESSIONS` 两个分支都不成立：
   面板里选 `/exit`、`/help`、`/sessions` 里挑会话，**全都没反应**（`tui-keys` 轮当时只断言了
   「结果交出来了」和「选中项文本对不对」，没断言 kind，所以一直没抓到）。修法：结果 kind
   另存一份结果 kind（`g_tui_ov_kind` 只在「还开着」时有意义，另存一份给 take 之后的调用方），
   `tui_overlay_kind()` 返回它。回归：`tui-keys`（kind 断言）+ `tui-exit` 轮（走完整主循环，
   用 `/help` 把帮助正文写进转录当钉子）。
   这个坑两条并行线各踩了一次、各修了一次（P21 那条线用了 `g_tui_ov_done`，本轮的侧重是
   「面板里的 `/exit` 必须**当场**置退出标志」—— 回合运行中主循环不在跑，只有标志能立刻生效），
   合并时收敛成同一份实现。

   * **（顺带）中文提示语 + 手写的字节长度 = 尾字被砍掉 / 读越 NUL。** `tui_add_notice(p, n)` 是按**字节数**
   追加的，而所有调用点都写成 `tui_add_notice("…中文…" as &const byte, 43)` 这种人肉计数 ——
   一个汉字 3 字节，数错是常态：`"(再按一次 ctrl+c 退出；或直接输入任务)"` 实际 52 字节、
   代码里写的是 **43**（屏幕上尾巴消失，还可能把一个汉字砍成半个）；`"(没有找到会话)"` 实际 20、
   写的是 **22**（多读 2 字节，读过 NUL 之后的内存）。P26 顺手全改成
   `bufx_cstr_len("…" as &const byte)`：长度不再是手写的常量。

45. **`const x = if c { a } else { b };` 会在 0.10 的 C 生成里变成「给 const 变量赋值」。**
    症状（P27 写 `/diff` 时踩到）：`uya check` **类型检查全过**，`make build` 却在 C 编译阶段报
    `error: assignment of read-only variable '__uya_ifexpr_8'`。
    根因：编译器把 if 表达式内联成 GNU 语句表达式，而那个临时变量会被写成
    `const uint8_t __uya_ifexpr_8; if (…) { __uya_ifexpr_8 = …; } else { … }` —— 赋值给 const，
    gcc 直接拒绝。触发面很窄（同一份文件里写 `const size_t take = if a { 1 } else { 2 };`
    有时又能过），所以**别去猜规则**：跨过这一层，把 if 展开成先声明再分支赋值
    （`var c: byte = 32; if len > 0 { c = p[off]; }`）。
    同类地，`buf_append(&out, …)` 里那个 `out` 已经是 `&Buf` 形参时，`&out` 是 `Buf**` ——
    同样只在 C 编译阶段暴露（`passing argument 1 of 'bufx_buf_append' from incompatible pointer type`）。
    这也是本项目坚持 `make check` 之后**必须**再 `make build` 的原因：`check` 抓不到这两类。

47. **「TUI 渲染与 agent loop 分两条线程」写通了，最后被工具链的分配器否掉**（P30）。
    这条记两件事：机制**是**成立的，以及为什么最终没这么做。
    * **成立的证据**（真终端 + 假网关，PTY 量出来的）：`libc.pthread` 能起线程（固定入口 +
      `&void` 参数，不需要函数指针）；`sys_tgkill` + 一个**不带 `SA_RESTART`** 的处理器能把
      阻塞在 `read`/`poll` 上的那条线程以 EINTR 叫醒（`build/probe_thx_signal.uya` 实测 errno=4）；
      拆成两条线程之后 `esc`/`/status` 的按键当下性也拿到了：单步长流式里 `/status` **69 ms**
      出现、`/new` 立刻回执并中断。**但**：
    * **工具链的堆不支持两条线程并发分配**（`testdata/probe_heap_threads.uya`）：两条线程**各自**
      `malloc/free`（没有任何指针共享），200 B 与 8 KiB 两种块、预热与不预热四种组合 ——
      **8/8 崩**（`free(): double free detected in tcache 2` 或 SIGSEGV）。`libc/heap.uya` 是
      工具链自带的分配器（per-thread tcache + 一把全局自旋锁），并发路径就是坏的；而界面渲染
      与 agent 组请求都必然要分配内存 —— 「同进程两条线程」在这套工具链上没有活路。
    * **`libc.pthread` 的互斥自己也不干净**（`testdata/probe_thx_mutex.uya`）：
      `PTHREAD_MUTEX_RECURSIVE` 的解锁在 `state` 从 1 → 0 时**故意不 wake**（只有 `prev != 1`
      才 wake），而递归等待者睡在 `futex_wait(&state, 1)` 上（只等「变成 1」）—— 先睡下的那条
      线程再也醒不过来（现场：工作线程进去就没出来，28 s / CPU 0.04 s，纯阻塞）；普通锁在
      「两条线程对称争用」下 4/4 死锁。真要用线程，锁也得自己用 `atomic` + `sys_futex` 写一份。
    * **于是 P30 选了「单线程 + 泵点加密」**：用户可见的结果一样（运行中敲命令当场有反应，
      实测延迟与线程版同量级），分配器与锁的老问题一个都不碰。
    * 顺手记一条**测试方法**上的坑：`mock_sse_gap_ns` 的停顿发生在**响应头之前** —— 那段时间
      客户端还卡在「等响应头」，根本没进流式循环，用它测「运行中派发」会得到**假阴性**
      （实测延迟 4.8 s，看着像没修）。要测这个必须让**响应头 + 第一帧先到**、正文再停：
      见 P30 新加的 `mock_send_sse_slow`（`mock_mode = 40`）。
      后话（P31）：那条「假阴性」判错了性质 —— 它不是测试写错，而是**用户可见的真窗口**：
      「等响应头」这段本来一个泵点都没有，见踩坑 48。

48. **「`/status` 还是慢」：慢的不是流式那段，是「请求在飞」的那段**（P31，用户报的）。
    P30 把派发点铺满泵点之后，用户复测还是慢。真终端（`testdata/pty_drive.py` 的新场景 +
    假网关新增的 `HEAD_DELAY_MS`）量出来的分布是这样的：

    | 场景 | 改前 | 改后 |
    |---|---|---|
    | 回合流式中 | 103 ms | 101 ms |
    | **请求已发出、响应头未到**（头压住 3 s） | **2280 ms** | **53 ms** |
    | 空闲 | 242 ms | 62 ms |
    | bash 跑着 | 103 ms | 102 ms |
    | **压缩在飞**（`/compact` 的摘要请求） | **2833 ms** | **63 ms** |

    * **根因一（大头）**：`hc_open` 读响应头的循环是纯阻塞 `conn_read`，头到之前**没有 poll、
      没有泵** —— 敲的 `/status`、esc、ctrl+c 全都没人读，空白的上限是 `timeout_ms`（默认
      120 s）。修法与 `httpc.uya` 读到 EOF 那条路、`hc_fill_wait` 完全一样：`poll(≤50 ms)` +
      `agent_pump_light()`，超时改按墙上时间判。
    * **根因二**：命令执行完只是 `tui_mark_dirty()`，没人当场画帧 —— 空闲要等下一次
      `tui_poll_keys(200)`（242 ms 全在这里），回合内要等下一个泵点。修法是派发（或给出回执）
      之后直接 `tui_render()`，主循环每圈开头也先 `tui_render()` 再阻塞。注意**不能**改成调
      `tui_tick()`：它有空闲 8 fps 的节流（`now - last_frame < 120` 就跳过），刚派发完那一帧
      正好会被它吞掉。
    * **根因三**：`agent_maybe_compact` 把 `interactive` 写死 `false` → 摘要请求整段流式都没有
      泵点；而且主循环跑命令时泵点上下文是空的（`agent_pump_ctx_begin`/`agent_pump_ctx_end` 补上）。
    * **写测试时的坑**：压缩场景第一版把浮层留着就去查转录里的 `[compact]`，而浮层正好盖住转录
      → `compact_ran` 恒为 false（判据自己骗自己，看着像「压缩没发请求」）。改成先 esc 关浮层再查。
      判据必须能**证明这一轮真跑过**，否则「浮层很快出现」可能只是因为压根没发请求。

49. **第一列换了，选中项的口径就得跟着换 —— 否则 `/resume` 拿着标题去查会话。**（P32）
    `/sessions` 的条目原来是 `<id>  <cwd>`，选中项用 `agent_tui_item_head`（取行首第一个
    空白分隔 token）当会话 id —— id 正好在第一列，所以没问题。改成「标题 / 工作区 / session id」
    三列之后**行首变成了标题**：同一个 `agent_tui_item_head` 取出来的是标题的第一个词，
    `/resume 修个` 于是找不到会话（而且属于「静默失败」那一类：用户只看到一行
    `error: 找不到该会话`）。正解是**取行尾那个 token**（`agent_tui_sessions_head`），
    并要求它必须以 `session-` 开头；认不出来就落一条可见提示（`这一行里没认出会话 id`），
    绝不猜。连带两条同样重要的：
    * **id 只能在显示层裁**。条目文本是选中项的唯一来源，所以 `sess_rows_render` 里 id 一律
      原样写出（三列 / 两列 / 只剩 id 都一样），「画不下」交给显示层
      （浮层是 `tui_ov_put_clipped`，滚动模式是打印前的 `sess_rows_clip_into`，两者都补 `…`）。
      反过来（排版时就按列裁 id）会让窄终端上的 `/resume` 时好时坏，且失败得毫无线索。
    * **索引是追加写的，同一个 id 一定会有多条**。`index.jsonl` 每关一次会话就追加一条，
      「同一个会话列两次」是默认行为；列表侧必须按索引自己的契约「同 id 取最后一条」去重
      （真机索引实测 308 行 / 298 个会话，其中一个 id 出现 4 次）。不去重的话
      「最新的排第一」里会连续出现同一会话的副本，看起来就像列表坏了。
    验收：`sess-list` 轮（纯函数：去重 / 倒序 / 三档列宽 / 控制字节清洗 / id 完整）、
    `tui-sessions` 轮（浮层宽箱体 + 方框闭合 + 回车取完整 id + `sess_find` 找得到）、
    `make e2e-sessions`（真二进制，管道喂 REPL）。

50. **uya 0.10 的 `p[a: b]` 是「从 a 起 b 个字节」，不是「到 b 为止」。**（P32 实测）
    全仓的切片几乎都写成 `p[0: n]` —— 两种语义在 a=0 时完全一样，所以这个坑一直没露头。
    P31 要给「索引里第 k 行」做切片解析，写了 `idx.ptr[lo: lo + ll]`，实际拿到的是
    **从 lo 起 `lo + ll` 个字节**的窗口：越读 `lo` 个字节到后面几行去（行号越大越界越多，
    最后一行还会越过缓冲区末尾）。现场：一条**没有** `lastActiveAt` 的记录被解析成了后面
    那行的 9000，于是「按时间倒序」整个错位（`sess-list` 轮 12 条断言一起红）。
    探针（`p = "0123456789"`，`p[2: 5].len`）实测打印 **5**（= 长度），不是 3。
    正解：**别用非 0 起点的切片** —— 把那一行先拷进 scratch Buf 再按 `[0: len]` 解析
    （`session.uya` / `agent.uya` / 自测助手都这么写）；真要「从 a 起 n 个字节」就写
    `p[a: n]` 并注明第二个数是长度。已有的正确例子是 `httpc.uya` 的 `head[i: name.len]`。

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

**P22 起有第三条工具级策略**：plan 模式下 `write` / `edit` 直接回
`Error: write is refused in plan mode (no file changes before the user approves the plan). …`
（拦在参数校验之后、动文件之前，且排在 read-only 那道之前）—— 见「plan 模式：写闸门与审阅浮窗」。

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
| `stream-firsttok-reasoning` / `-call` / `-none` | **P24 首 token 打点的三条边界**：只有 `reasoning_content`、只有 `tool_calls` 参数片段 → 必须打点（旧口径这两类一步都打不到）；只有空串 delta + usage-only 帧 → 不许打点（否则解码窗口从 0 起算） |
| `resp-firsttok-reasoning` / `-call` | responses 路径的同口径两条（`response.reasoning_summary_text.delta` / `response.function_call_arguments.delta` 独有） |
| `steer` | 回合运行中输入的文本，必须在**下一个 step 的请求**里出现（mock 断言 `STEER-MARKER`） |
| `interrupt` | 预置 Ctrl-C：回合以 `AGENT_INTERRUPTED` 结束、工具**未派发**、只发生一次请求 |
| `tui-frame` | 八种尺寸（32×8 / 40×12 / 60×20 / 80×24 / 100×28 / 120×40 / 160×30 / 200×30）下「每行显示列 ≤ cols」「正文层里没有 ESC」；空态整体居中（首行留白 + 块字 logo + 面板 + 脚注 `~/cwd:branch`）、窄终端 logo 退化成单行标题；对话态底对齐 + 面板贴底；工具块/diff/思考/诊断/用户条目都在；跑满一屏后跟随尾部、PgUp/PgDn 夹取、回尾清零；**P20/P24 脚注**：200 列放下整条统计行、160 列按组丢尾部并补 `…`、120/100/80 列逐级退化、60 列退回版本号、40 列 cwd 让位（且行首不留孤立的 ` · `）、32 列连 `内存` 也让位；统计行右边缘在 200/160/60 列下必须落在 `cols − 3`（右对齐没被改掉），`ctx` / `cpu` 一直不丢；**浮层方框**（踩坑 42）：5 种宽度 × 3 类浮层（真实命令表 / 帮助 / 确认层）逐行量方框的**左右边界列**必须完全相同、首尾字符必须是边框字形 —— 长到需要截断的那一行（`/permission`）不能再把右边框顶出去 |
| `tui-keys` | UTF-8 逐字符编辑（退格不砍半个汉字、←/→ 停在字符边界）、**被切开的 `ESC [ D`** 正确组装、Ctrl-J 换行与多行光标移动、回车提交（内容 + 清空 + 进历史）、↑ 取历史、运行中 esc = 中断 / 空闲 esc = 清行、tab 切计划模式（面板显示 Plan）、`/` 自动开命令面板并选中第二项、Ctrl-D 空行退出、**浮层结果的 kind 跨 close 存活**（踩坑 44）、Ctrl-D（空闲与**运行中**都退出）、运行中 Ctrl-C 一次=中断/两秒内两次=退出、面板里选中 `/exit` 当场置退出标志且**不当作任务提交**、`tui_abort_state()` 三档口径、子进程 `tui_child_detach()` 之后 `tui_active()` 必须为 false || `tui-sink` | TUI 激活后 `tty_write(1/2)` 与 `tty_reason_write` 的字节分别落到 助手/工具/思考 条目；NUL/`ESC[2J`/TAB 被清洗且正文层无 ESC；关掉 sink 后写入回到真实 fd |
| `tui-turn` | headless 端到端（mock LLM，复用手打路径注入「任务+回车」）：屏幕里出现用户条目、`✓ Write(note.txt)`、`✓ Bash(`、最终答案；回合结束状态回 idle、**状态区整块收掉且思考实时行不留残影**；**P20：脚注里必须出现 `1 轮 · ` 与 `工具调用 `**（真实测量的 llm/工具耗时进了界面）；fd 1 无输出 |
| `tui-status` | 常驻状态区 + 思考实时行（P18）：**转录铺满视口后状态行必须仍在**（回归主断言，且落在面板上方那一行）、实时行紧跟在状态行下面且只显示 `latestLine`、超宽按列**从左边**截断补 `…`（保住最新的那一端）、`ESC[2J`/NUL/TAB 被清洗且换行只取最后一段、`tui_think_clear`/`TUI_RUN_IDLE` 之后整块收掉（空闲态 0 行）、滚动时钉住不动、窄终端（30 列）按实际可用列画、窄到放不下前缀（20 列）退化成 1 行不硬画、`view_think_live` 默认开（不看 `--show-reasoning`）而 `--quiet` 下一个字节都不写 |
| `tui-p30` | 运行中的峰值延迟（P30）：headless 断言「泵点当场派发只读命令（`/status` 立刻开浮层）/ `/new` 立刻回执 + 置中断标志、结果仍旧留给主循环（不 `hist_free` 到回合正在用的历史）/ `/compact` 泵点**不**落、`agent_tui_step_boundary_cmd` 处才落」；真 PTY 段用 mock 的**单步长流式**（`mock_mode = 40` + `mock_send_sse_slow`：响应头与第一帧立刻发、正文停 2.5 s）断言「敲 `/status` 之后浮层 ≤800 ms 出现，且那一刻正文还没发出来」——旧实现要等这一步走完（≥2.2 s） |
| `tui-p31` | 请求在飞的每一段都能当场响应（P31，踩坑 48）：headless 断言「泵点派发只读命令之后**同一次调用里**就画出一帧（`tui_frame_count()` +1，旧实现只标脏、要等下一个泵点或下一次 200 ms 轮询）」「不安全命令的回执同样当场出帧，结果仍旧留给主循环」「泵点上下文登记期间才派发、`agent_pump_ctx_end` 之后面板结果不许被吞」；真 PTY 段另有三条延迟上限（等响应头 ≤800 ms、空闲 ≤150 ms、bash 跑着 ≤300 ms）在 `make p30-check` 里 |
| `tui-cmd` | 命令面板 ↔ `/status` 浮层这条链（P23，踩坑 40）：面板派发之后**输入行里不许留着触发它的 `/`**（`tui_input_len() == 0`），于是第二次敲 `/status` 仍旧开出浮层（旧实现这里是 `//status` → 「未知命令」）；浮层标题逐字节是 `状态（esc 关闭）`、**不含**越界读来的 `<system-remind`（并且全局不变量「正文层无 NUL」在每一步都查）；回车但无匹配时文字回输入行 + `没有匹配的命令：…` notice；回合运行中接受的面板项**不当场派发**、由 `agent_tui_poll_pending_cmd` 在 step 边界派发只读命令（`/status` 开浮层）、不安全命令（`/permission`）原样留在待取队列；浮层滚动（PgDn 后 `上下文已用`/`version` 可见、`↑`/`↓` 指示随窗口变、滚到底顶端不再停在最前面）；外加**真 PTY**：回合还在跑（脚注仍是「1 轮 · 1 步」）时浮层已经画出来，esc 关掉后回合照常跑完、最终答案回到转录 |
| `stats-format` | 纯函数逐字节：duration（`0s`/`0.4s`/`12s`/`50.7s`/`59.9s`/`1m0s`/`2m42s`/`60m0s` + 平均值口径不被整数截断 + 除零保护）、tokens（`999`/`1K`/`12.2K`/`238K`/`517K`/`1000K`/`1M`/`1.2M`/负数按 0）、tok/s（`0.4`/`9.9`/`9.94→9.9`/`221`/`994`/无时长）、缓存命中（无计费输入 → 不显示、`0`/`50`/12.5%→13%（ties 向上）/71%/全命中 `100`/999/1000→`99.9`/99.9579%→`99.96`，全部按 DSH 的取整规则） |
| `stats-line` | 整行逐字节：demo fixture = DSH 截图那一行（`1 轮 · 12 步 \| LLM 50.7s · 工具调用 4.1s \| 首 token 平均 1.5s · 221 tok/s \| 缓存命中 71% \| 输入 238K tok · 输出 12K tok`）+ 四种判据（只有步数 / 只有 usage / 两步其一被取消 / 只有首 token / 工具+解码同时出现） |
| `stats-fold` | 同一批边界「实时喂」与「日志逐行回放」的 11 个字段签名必须逐字节相同；再钉边界语义：孤儿 `tool/result` 不计时、未结算调用在 `turn/end` 丢弃、被取消的步只计数不计时、`turn/step` 不匹配时不计时但 token 照记、没上报输出 token 时不记解码、同一 turn 多步只算一轮、重复 callId 取最后一次并只结算一次 |
| `stats-context` | 占用率（容量未知/分子未知 → 不可用、四舍五入、12.5%→13%、超容量夹 100）、`projectedTokens`（样本 + 增量、钳 0、无锚点时只用样本）、`~已用 / 容量` 与 `未知容量` 写法、`/status` 的上下文块逐字节（含 20 格分段条：三段比例切分、无明细时单段、容量未知时不给百分比与条）、统计明细块（空状态的省缺写法） |
| `stats-usage` | 端到端一轮（mock 的答案帧带 usage，**只给这一轮开** —— 打开 usage 会让 `prompt_tokens` 从估算变成读数，进而改变自动压缩的触发时机，其它轮保持原样）：回合正常结束 |
| `stats-log` | 就着 `stats-usage` 那一轮的会话日志：`step/start` 与 `step/end` 必须成对、`tool/result` 不早于 `tool/call`、日志里的步数/首 token 条数/工具时间差之和与实时折叠的数字**逐个相等**；再把整份日志回放一遍（`--resume` 走的就是这条路），统计行与全部字段必须与实时**逐字节相同** |
| `procx-parse` | `/proc/<pid>/stat` 解析：comm 取**第一个 `(` 到最后一个 `)`**（comm 里允许空格与括号）、utime/stime 是 `)` 之后第 12/13 个字段、`|` 后的 cutime/cstime 必须忽略、state 是字母（`S`/`D`）时能跳过；坏行（无括号 / 无右括号 / 缺 stime / utime 非数字）必须失败；`/proc` 目录项名过滤（纯数字才算 pid，`self`/`.`/`..`/11 位不算） |
| `procx-percent` | `Δticks × 1000 / Δms`：0 / 37 / 100（一个核）/ 250（并行 > 100%）/ 0.5% 向上取整 / `Δms=0` 不可算 / 负增量按 0 / 上限钳 999；`USER_HZ = 100` 常量 |
| `procx-mem` | 内存取数与显示逐字节：`smaps_rollup` 的 `Pss:`（**不吃** `Pss_Dirty:`，只认行首）、`status` 的 `VmRSS:`（制表符 + 前导空格）；非行首标签 / 标签后无数字 / 空文本 → 失败且 out 归 0；显示 `0K`/`512K`/`1M`/`8M`/`312M`/`1.0G`/`1.3G`/`65.7G`，`-1`（不可用）不写字节 |
| `cpu-live` | fork 一个忙循环 400ms 的子进程（同一个二进制 → comm 相同），父进程睡 450ms 后两次采样：进程数必须涨、综合 `cpu ≥ 25`、有时间跨度、**内存合计 ≥ 1 MiB 且口径已探明**（P24）；只建基线的那次必须不给百分比（防除零爆表） |
| `tui-pty` | **真 PTY**（`/dev/ptmx` + `fork` + `dup2(slave→0/1/2)`）：进备用屏幕（`ESC[?1049h`）、首屏面板/logo、发任务后转录出现 mock 最终答案、`SIGWINCH`（改 winsize + 发信号）后进程仍活着并继续重绘、**`/exit` + 回车**退出码 0（刻意不用 Ctrl-D：它不走命令分派，测不出「命令返回值被丢掉」）、退出后 `TCGETS` 与 fork 前**逐位相同**、离开备用屏幕；不需要 setsid/TIOCSCTTY（fd 0 就是 pts 从设备、Ctrl-C 由程序自己吃字节）；**P22 起还断言终端标题**：起始 `ESC[22t` + `ESC]2;uya-agent · selftest_ws_tui_pty BEL`（且首帧捕获里 OSC 2 **只有 1 条** = 标题不是每帧重写的）→ 发任务后 `ESC]2;把 hello-selftest 写进 note.txt BEL`（OSC 2 共 2 条）→ 退出时 `ESC[23t` 且出现在最后一条标题之后 |
| `tui-exit` | headless + 完整主循环：命令面板里选中 `/help` 之后帮助正文必须进转录（面板选择被执行 = kind 修好了），主循环正常收工；mock 一次请求都不该被发出去 |
| `tui-quit` | **真 PTY + 边跑边发键**（P26「退不出」回归）：A 工具（`sleep 15`）跑着的时候 `ctrl+d` 必须 5 秒内退出（退出码 0 / 离开备用屏幕 / termios 逐位还原）；B 同一窗口按 `esc` → 「已中断本回合」必须几秒内出现（= 工具子进程被当场杀掉，不是等 sleep 跑完）且进程还活着；C 中断过的会话再提交 `task-two` → 必须照常跑完（中断意图不残留，删掉两处复位这一段就红）；D 打 `/exit` 回车 → 退出码 0 |
| `perm-modes` | 三级访问模式的机器名 ↔ 值 ↔ 显示名（含 DSH 产品名 `Full access`）、`custom`/空串判 -1、策略真值表（`confine` / `allows_write` / `requires_approval`） |
| `perm-readonly` | mock LLM 一轮 3 个调用：read-only 下 `write` 必须回逐字拒绝串且**文件没落盘**、`bash` 在非交互会话里必须 fail closed（回「无回答渠道」串、命令输出一个字都不给）而 `read` 照常；请求里必须带 read-only 的 file policy 句 |
| `san-profile` | 三档 profile 的 bwrap argv 逐字断言：read-only = `--ro-bind / / --dev /dev --proc /proc --unshare-pid` 且**没有**可写挂载；workspace-write 多 `--tmpfs /tmp` + `--bind <ws> <ws>`；full access 与 `--no-sandbox` 不套壳；工作区是 `/` 时不加可写 bind；bwrap 不可用时只断言「confined 必须返回 fail closed」 |
| `san-shell` | 直接 fork 出沙箱命令实测（不经工具闸门）：read-only 里 `> /dev/null` 成功、写 `/tmp` 被拒且文件不出现；workspace-write 里工作区内写入逐字节正确、`../` 区外写入被拒；本机没有 bwrap 时打一行 skip（不假绿） |
| `san-tool` | 端到端：`--permission workspace-write` 下让模型跑一条**同时**写工作区内与区外的命令 —— 区内文件必须落盘、区外文件必须不存在（工具层没拦它，是内核拦的） |
| `tui-access` | 访问模式 chip 三种模式的显示、`shift+tab` 只置请求（主循环据此开浮层）、选择器打开（三行齐 + `✓` 只在当前模式那行 + 圆角框 + esc 取消不变更）、↓+enter 选中 Workspace Write 交给处理器（策略全局 + chip + 转录 notice + **恰好一条** runtime-context 注入且不上屏）、运行中切换时 `cfg.access` 必须跟着走（故意把 cfg 设成旧值）、选 Full access 只翻出确认层（游标默认「取消」→ 回车无变化；↑+enter 才切）；末尾两条**回归**：命令面板里选 `/status` 必须真的派发（浮层结果不许被静默丢掉）、`/help` 必须开**帮助浮层**（不许掉回滚动模式的纯文本帮助）；每步都查「每行 ≤ cols、正文层无 ESC」 |
| `plan-gate` | P26 plan 写闸门：纯函数真值表（`plan_init`/`plan_set`/`plan_toggle` 三处一致 + 三个动作 → 三裁决 + 认不出的选中项必须是「继续讨论」）+ 端到端（**全权模式**下 plan 模式里 `write`/`edit` 逐字被拒且 `plan-gate.txt` **没落盘**、`exit_plan_mode` 在管道里回「没有渠道」且**不退模式**、请求里必须带「写工具被拒」那句运行时上下文） |
| `tui-plan` | P26 plan 审阅浮窗，四段：① 浮层级 headless（标题 `计划待审 · 1/b`、三动作齐、默认光标在「继续讨论」、正文第一行画出来、尾巴一开始不可见、`↓` 行号 +1、`pgdn` 整页跳、`end` 到底才看见尾巴、`home` 回顶、`3`+回车交回「确认执行」且 kind 不丢、`esc` 取消、`agent_plan_force` 同步 Plan chip、40 列窄终端不超宽不崩、**浮层方框闭合成矩形**（复用 tui-frame 那套量法：左右边界列 + 首尾必须是边框字形 —— 踩坑 42 那类缺陷）、每帧「行 ≤ cols + 正文层无 ESC」）；② headless + agent：注入的键到不了浮层 → 按「解决」处理（转录出现「dismissed the plan review」、**没有** `Plan approved`、`plan_on()` 仍为真、浮层已收掉）；③ **真 PTY**：tab 进 plan 模式 → 浮窗出现 → 三动作齐 → `end` 翻到底看见 `PLAN-TAIL-MARK`（正文真的能滚）→ `3`+回车 → 第二封请求里必须出现 `Plan approved`；④ **真 PTY**：`esc` → 第二封请求里必须是「dismissed the plan review to speak instead」 |
| `tui-access` | 访问模式 chip 三种模式的显示、`shift+tab` 只置请求（主循环据此开浮层）、选择器打开（三行齐 + `✓` 只在当前模式那行 + 圆角框 + esc 取消不变更）、↓+enter 选中 Workspace Write 交给处理器（策略全局 + chip + 转录 notice + **恰好一条** runtime-context 注入且不上屏）、运行中切换时 `cfg.access` 必须跟着走（故意把 cfg 设成旧值）、选 Full access 只翻出确认层（游标默认「取消」→ 回车无变化；↑+enter 才切）；末尾一条**回归**：命令面板里选 `/status` 必须真的派发（浮层结果不许被静默丢掉）；每步都查「每行 ≤ cols、正文层无 ESC」 |
| `tui-diff` | **`/diff` 浮窗（P28）**：假数据注入后逐项断言 —— 圆角框与标题（`/diff · <仓库> · <文件> · +A -D`）、左列表的 `▸` 选中标记与三个文件、右工作区的 `旧 · HEAD` / `新 · 工作区` 两栏列头、**同一行里同时出现旧文本与新文本**（真并排，不是上下拼）、`@@` 说明行跨两栏；**竖线逐行同列**（两栏行 4 根：左右边框 + 列表缝 + 中缝；跨栏说明行 3 根，且落在同样的列上）；`↓` 换文件后 `▸` 跟着走、`→` 之后每栏补 `‹`、`←` 退回 0、`pgdn/pgup` 翻页与夹取、`r` 失败也**不许丢内容**、`esc`/`q` 关闭走「取消」语义；**运行中开浮窗状态区照样在**（浮层重画转录区之后必须把 P18 的状态区补回来，且整帧行数不变）；40×10 判「画不下」→ 不开浮窗（不许看不见还吞键）；agent 层三条「开不了」都要留下可见的话（不是 git 仓库 → git 的原话、空仓库 → `(没有 git 修改)`、终端太小 → 提示，且三条都**不许**开浮窗）；路径里带 ESC/NUL 时列表与标题都要清洗（帧里一个 NUL/ESC 都不许有 —— P27 第一版就把 fixture 标签的 NUL 画进了标题）；TAB/ESC 序列/汉字不破版（`␛` + 合法 UTF-8）；最后**真 PTY** 里敲 `/diff` → 真跑 git → 屏幕上出现列表与两栏 diff → `↓` 重载 → `esc` → `ctrl-d` 退出码 0；**收尾要把画布与任务面板的行预算还原**（`tui_build_chat` 每帧都会 `tasks_set_row_budget`，本轮的 40×10 子段会把预算压到 1~2 行，不还原就会串到后面 `tasks-scroll` 那一轮 —— 测试之间靠全局状态串味的老坑） |
| `diff-parse` | **unified diff → 行表**（P27，纯函数、不碰 git）：`@@` 头与行号解析；上下文两侧同行号；**2 删 3 增 → 2 个 MIX（左删右增）+ 1 个落单 ADD**（两侧 off/len 与文本逐字节）；纯插入 / 纯删除；多 hunk（两个说明行）；`\ No newline at end of file` 落成说明行；CRLF 的 `\r` 不许带进单元格（否则显示成 `·`）；TAB 原样保留（清洗是渲染层的事）；`Binary files … differ` 只留一行说明；mode-only（无 hunk）→ 0 行 + 说明；非 diff 文本（git 报错）整段落成一行说明（宁可看得见，也不给空面板）；空输入 → 0 行；**配对溢出**（> 4096 行的块）放弃配对但**一行不丢、顺序不乱** |
| `diff-git` | **/diff 的真 git 端到端**（P27，离线；fixture 仓用被测的 `gitx_run` 自己建）：`gd_open` 出 3 个文件且带 git 的 XY 码（` M` / `??` / ` D`）与 numstat 计数（`(+1 -1)` / `(new)` / `(+0 -2)`）；改一行的文件左右两栏文本与行号逐字节正确；未跟踪文件整份都是新增（左侧空）；删除的文件整行都在左侧；`↓/↑` 换文件与两端夹取；`gd_refresh` 之后能看到新内容（`r` 键那条路）；滚动/横向滚夹取；`gd_print_text` 的单列回退含 `[diff]` 头、文件数、列表行与两侧内容；非仓库目录 `gd_open < 0` 且文案非空；本机没有 git 时打 `skip`（不假绿） |
| `tui-approve` | read-only 下 bash 逐条批准，两种形态：① headless（注入的键在浮层打开前就被输入行吃了）= 没人回答 → **fail closed**，转录出现逐字拒绝串、命令 stdout 不出现、且不是「没有回答渠道」那条；② **真 PTY**：等 `Read Only：批准这条 bash 命令？` 画出来再送 `↑`+回车 → 命令真的跑（stdout 进转录与下一封请求）、退出码 0 |
| `sig-abi` | `SigxAction` 必须是**宿主 glibc** 布局（152 字节；handler@0 / flags@136 / restorer@144，按字节回读）；恢复序列逐字节四种形状（P22 起）：带备用屏幕 26 字节 / 不带 18 字节 / 带备用屏幕+弹标题栈 31 字节（`ESC[23t` 排在离开备用屏幕**之前**）/ 不带备用屏幕+弹标题栈 23 字节 |
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
| `tasks-render` | 任务状态（P25）纯函数轮：进度条（`2/4`=10 格、`0/4`、`4/4`、`total=0`/`cells=0` 不画）、
百分比四舍五入（`1/3→33%`、`2/3→67%`、`1/200→1%`）、输出体量（`120B`/`1.0K`/`3.2K`/`9.9K`/`10K`/`512K`/`1.0M`/`2.8M`）、
空态三件套**一个字节都不写**（折叠行/箱体/报告）、折叠行四段逐字节 + 首字形三态（`▸`/`✓`/`·`）+
窄终端丢段补 `…` 且恒 1 行、箱体 11 行且**逐行等宽**（含中文/宽字符）、`max_rows` 裁剪补 `… 还有 N 行`、
清单 6 行上限补 `… 还有 N 项`、报告按 进行中→待办→完成 分组（组内原序）、job 三态字形与 `（已截断）`、
同一份输入两次调用逐字节相同 |
| `tasks-scroll` | 滚动模式（`--no-tui`）的活路径（P25）：`tasks_panel_sync → view_panel_push → tty_block_*`
→ `tty_draw_line` 真画一帧 —— 折叠行与 P15 的 agents 箱体**一起**进面板块、提示符在它下面；
展开后换成任务箱体且**每行 98 列**（中文按显示列）；收起即隐；显示层关闭（`--quiet`）时零输出 |
| `tui-tasks` | 常驻任务块（P25）：空态 0 行且状态行仍钉在面板正上方（与 P25 之前逐字节相同）、
装上 fixture 后折叠行（1 行）出现在 agents 箱体之上、状态区之下，层序 = 转录 → 任务块 → agents → 状态区；
`ctrl+t` 只置出 `TUI_REQ_TASKS`（键层不自己改状态），落地后展开成 `┌─ tasks` 箱体（含清单段与计数、
底框、agents 箱体仍在），再切回收起；活体刷新（job 跑完 → 折叠行的 `后台 r/n` 变）；矮终端（80×12）
阶梯退化到 5 行且**保住箱体底框**、先丢 agents 箱体、转录仍留 ≥3 行；窄终端（40 列）每行不超列宽；
P29 起还断言 `/goal` 这条腿：命令面板的**真实清单**（`agent_tui_commands`）里有 `/goal`、
裸 `/goal` 开出 `TUI_OVK_GOAL` 浮层且标题 `目标（esc 关闭）` 画在帧上、正文是无目标时的用法、
`/goal <objective>` 的浮层里 `Goal created` 与 `Objective: …` 真的画出来（list 型浮层 take 回来的
只是选中行，所以正文看**帧**）、`goal.json` 落盘字段（id 1 / revision 1 / armed）与常驻块的
目标投影（`tasks_goal_ref().active_state`）当场刷新、`/goal clear` 之后投影回到「无目标」|
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
| `tasks-e2e` | `make e2e-tasks`（离线，管道喂 REPL）：裸 `/tasks` 打出 `--- 任务 ---` 与空态串、
`/tasks open` / `toggle` 的回显、`/tasks bogus` 报 `未知参数 "bogus"`、`/help` 里能查到 `/tasks` |
| `goal-cmd` | 会话目标人类命令（P29）纯函数轮：空态裸 `/goal` 报「当前没有目标」+ 用法（**返回 0** —— 看状态不会失败）、缺目标时 `pause`/`resume`/`edit` 各自点出是谁缺目标、裸 `edit` 与 `edit` + 纯空白都报「需要替换内容」且**不落盘**、创建后状态块四段（`Status: active` / `Objective: …` / `Rounds: 0/20` / `Activation: armed`）与盘上字段（id/revision/round/phase/objective）逐条对齐、重复创建被拒**且没改盘上 objective**、`edit` 只换 objective（revision 2、phase/armed 不动）、`pause` 关 armed、`resume` 打开、`clear` 删文件且**幂等**（再 clear 报「没得清」）、`pause after verification` 按**字面目标**创建（控制词只在独占整行时才是控制词）、`clearx` 不被当成 `clear`、大写 `CLEAR` 照样命中、`complete` 的目标让位（创建与 `edit` 都换新身份：id +1 / revision 回 1 / 0 轮 / armed）、输出必须以换行收尾 |
| `goal-e2e` | `make e2e-goal`（离线，管道喂真 REPL + 独立 `UYA_AGENT_HOME`）：空态用法、创建、`Rounds: 0/20`、拒绝顶掉、`Goal updated` + 新 objective、`Status: paused` + `Activation: disarmed`、`Goal resumed`、`Goal cleared.`、重复 clear 幂等、字面目标规则、`/help` 里能查到 `/goal` |
| `sess-list` | **/sessions 列表（P32）纯函数轮**：索引 fixture 用真写入端（`sess_open`/`sess_close`）之外的手写索引造出「同 id 两条 + 时间戳乱序 + 缺 `lastActiveAt` + 空标题 + 带控制字节（TAB / `\u0001`）的标题」；断言去重后行数 = 唯一 id 数、重复 id 取的是**最后一条**（被取代那条的标题不许出现）、顺序严格按 `lastActiveAt` 降序且缺字段的排最后；再按 8 档可用列数（198/78/60/59/52/51/44/40）逐行断言 —— 行宽 ≤ 可用列数（只有「连 id 都放不下」那一档允许超宽，因为那份 id 必须完整）、标题列与工作区列的可见性随退化阶梯变化（三列 → 两列丢工作区 → 只剩 id）、每行喂 `agent_tui_sessions_head` 都还得出**完整 id**、正文里一个控制字节都没有；最后验滚动模式的 `sess_rows_clip_into`：窄到 21 列时每行 ≤ 21 且补 `…`，而本来放得下的宽度**一个 `…` 都不许加**（'…' 预算算错会把好端端的 id 截掉 —— 实测踩过） |
| `tui-sessions` | **/sessions 浮层（P32）**：fixture 是三个**真落盘**的会话（`sess_open`/`sess_close`，标题由测试给），`/sessions` 开浮层后断言 kind/标题、100 列下箱体铺开（顶边右边界列 = 97，即宽 `cols-6` + 左边距 3）、方框闭合成矩形（`tui-frame` 那套量法）、三列都可见、**最新那条的标题行在最早那条之上**（`tuis_find_row` 行号比较）；回车 → 选中项里的 id = 最新会话的**完整 id**（不是标题）→ `sess_find` 找得到（`/resume` 走的就是它）；再跑 60 列那一档：工作区列消失、id 列还在，且条目文本里的 id 仍然完整 |
| `sessions-e2e` | `make e2e-sessions`（离线，管道喂真 REPL + 独立 `--agent-home`）：手写索引里三条记录（旧 / 空标题 / 旧 id 的第二次记录），断言输出里最新会话在最上（`grep -n` 比行号）、被取代的旧记录不出现、同一个 id 只出现 1 次、空标题落到 `(无标题)`、`/w/new-a` 与完整 id 排成「工作区在前、id 在行尾」（正则收尾匹配） |
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
| `title-format` | 终端标题的纯函数轮（P22，踩坑 39）：清洗 —— OSC（BEL 收尾 / ST 收尾 / **未终结吃到尾**）、CSI（含 `1;38;5;196m` 这种最长参数形态）、两字节与带中间字节的 ESC 序列**整段消失**，末尾孤立 ESC 也吃掉；C0 与 DEL 丢掉、TAB/LF/CR/VT/FF 与 NBSP/全角空格折叠成**一个**空格并去首尾（全空白 → 空串）；零宽与方向控制符（U+200B/U+202E/U+FEFF/U+2060）丢掉；半截汉字与坏引导字节丢掉且结果 `bufx_utf8_valid` 为真；**40 B 上限切在码点边界**（14 个汉字 42 B → 只留 13 个 = 39 B）。兜底派生 —— 前 5 个词、词没切完就被 40 B 截断（`把 tty-title 写进 note.txt 然后回答 ok` → `把 tty-title 写进 note.txt 然后回`）、单个超长词按字节截断、首条消息里混进 `ESC]2;hacked BEL` 不落地、全空白不产生标题。基标题 —— `/tmp/p22-ws/` → `uya-agent · p22-ws`、`/` 与空路径 → `uya-agent`。上屏编码（管道抓字节、逐字节比对）—— `ESC[22t` 压栈 → `ESC]2;<标题>BEL` → **同标题不重复写** → 空标题不写 → 关通道后一个字节不写 → `ESC[23t` 弹栈；80 B 上限同样切在码点边界（26 个汉字 = 78 B） |
| `tty-title-pty` | 滚动模式（`--no-tui`）的真 PTY 轮（P22）：`tui-pty` 覆盖的是「备用屏幕 + 私有 dup fd」那条接线，这条覆盖 `fd 2 + 没有备用屏幕 + sigx_arm(2,false,true)` 那条 —— 压栈 + 基标题 `uya-agent · selftest_ws_tty_title`、打一行任务后标题变成该行前 5 个词（≤40 B）、跑完这一轮（mock 最终答案出现）、Ctrl-D 退出码 0、退出时弹栈且**弹栈在最后一条标题之后**、全程不进备用屏幕 |

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
* **P22 的验收记录（2026-10-03，对应踩坑 39）**：在真 PTY 里跑**真二进制**逐场景抓字节
  （同一个 `/tmp` 小脚本：fork + `openpty` + 把 slave 挂到 0/1/2，往主设备打字、把主设备
  读到的字节按 `ESC]2;…BEL` 摘出来；网关指向 `http://127.0.0.1:1/v1` = 必然连不上，
  所以这一轮只验标题通道、不依赖真模型）：
  * **全屏 TUI**（默认）：捕获 **2 条** OSC 2 —— `uya-agent · p22-ws`（基标题）→
    打字「把 tty-title 写进 note.txt 然后回答 ok」后 `把 tty-title 写进 note.txt 然后回`
    （前 5 个词、第 5 个词被 40 B 上限切在**码点边界**：39 B）；`ESC[22t` ×1、`ESC[23t` ×1，
  Ctrl-D 退出码 0、进/出备用屏幕各 1 次。
  * **滚动模式**（`--no-tui`）：同两条标题 + 压栈/弹栈各 1 次，且 `ESC[?1049h` **0 次**
    （本来就不该进备用屏幕）。
  * **`--no-title` 与 `UYA_AGENT_TITLE=0`**：捕获里 `ESC]2;` / `ESC[22t` / `ESC[23t` **全为 0**。
  * **一次性运行 / `--print-config` / `--dry-run` / `--tui-demo`**（stdout 都挂在 PTY 上，
    也就是「stdout 是终端」的最坏情况）：OSC 字节 **0**。
  * **`--continue`**：先跑一句「第一句话 alpha beta gamma」（日志里落下 `session/title`：
    `第一句话 alpha beta gamma`），再 `--continue` 并**换一句完全不同的任务** —— 标题依次是
    基标题 → **日志里那条标题**（不是新任务），会话日志里 `session/title` 仍然只有 1 条
    （首条消息定标题，后来的消息不改写，对齐 DSH）。
  * **`SIGTERM`**：TUI 起来后发送，退出码 **143**，恢复序列里带 `ESC[23t`（终端支持标题栈时
    就是「把 shell 原来的标题还回去」），备用屏幕也照旧退出。
  * **`--resume-dsh`**（真 `~/.dsh`，会话 `session-a18046fa…`）：导入 109 条消息，标题取到
    **最后一条** `session/title` 事件（DSH 那边是 provider 生成的 `DeepSeek-Flash 多模态支持改造`，
    不是更早的 fallback 标题）→ 捕获流里两条 OSC 2 = 基标题 + 这条标题，压栈/弹栈各 1 次、
    退出码 0；我们自己的日志里落下 `session/title`（`source.kind = "user"`）。
  * **`/new`**（滚动模式，避开 TUI 的命令面板浮层）：标题依次是 基标题 → `第一句任务 alpha`
    → **基标题**（新会话开了之后回到基标题），压栈/弹栈各 1 次。
  * **真机网关上的 TUI**（零参数启动，配置全来自 `~/.dsh`，工作区 `/tmp/p22-real-ws`）：
    打字「用 bash 跑 echo P22-TITLE-OK，然后只回答这一行」→ 标题从 `uya-agent · p22-real-ws`
    变成 `用 bash 跑 echo P22-TITLE-OK，然后`（前 5 个词、38 B、切在码点边界），模型真的跑了
    命令并回答 `P22-TITLE-OK`，压栈/弹栈各 1 次、退出码 0。
  * 离线回归：新增纯函数轮 `title-format` 与 PTY 轮 `tty-title-pty`，`tui-pty`/`sig-abi` 扩充；
    新增 `make e2e-title`（默认开 / `--no-title` / `UYA_AGENT_TITLE=0` / CLI 压过 env 四条，
    随 `make selftest` 一起跑）；`make check / build / codegen-audit / selftest` 全绿。
  * 顺带修掉两个同源缺陷（都在上面那条记录里能复现）：`--continue` 的标题被 `sess_open`
    清掉（标题栏一直停在基标题）；fork 出来的子进程会把继承到的**上一轮标题**先顶上去
    （屏幕上就是「任务标题 + 基标题」两条 OSC，现在 `agent_title_begin` 只上基标题）。

* **P23 的验收记录（「`/status` 没反应」，对应踩坑 40）**：四条症状都先在**真 PTY**
  （`pty.fork()` + 屏幕仿真，脚本不进仓）里复现、修完再逐条复验：
  * ① 连敲两次：旧 —— 第一次开浮层（输入行留 `/`），esc 关掉再敲 `/status` 得到
    `· 未知命令（/help 看可用命令）；已忽略`，浮层不再出现；新 —— 两次都开浮层，
    输入行始终干净（`❯ ↑ Ask anything...` 占位文案）。
  * ② 运行中：旧 —— 本地慢速 mock（单步流式 15s）里敲 `/status`，回车后 15s 内屏幕上没有
    任何变化，回合结束才弹出浮层。新 —— 两步回合（每步的 SSE 响应前插 1.2s 停顿）里在
    step 1 期间敲 `/status`：浮层在**第 2 步开始时**就画出来了（浮层里的统计与脚注都还是
    「1 轮 · 1 步」），3s 后脚注变「1 轮 · 2 步」浮层仍在，esc 关掉后最终答案回到转录。
    单步长流式（整回合只有一步）仍要等这一步走完 —— 那是 §7 记录的边界（没有函数指针就
    没法在按键当下回调进 agent）。
  * ③ 标题逐字节：旧帧里是 `╭─ 状态（esc 关闭）` + 10 个 `\x00` + `<system-remind` + 破折号
    （声明 46 B / 实际 22 B）；新帧里是 `╭─ 状态（esc 关闭） ↓───…`（`↓` 是溢出指示）。
  * ④ 内容可达：旧 —— 24 行只画 14 行（停在 `输入/输出`），`上下文已用`/`version` 永远看不到；
    新 —— `pgdn` 两次后 `上下文已用`、`占用条`（有采样时）、`version` 依次可见，
    标题栏的 `↑`/`↓` 跟着窗口变。
  * 离线回归：新增 `tui-cmd` 轮（含**真 PTY** 那一段：用 mock 的 SSE 停顿
    `mock_sse_gap_ns` 造出「回合还活着」的窗口）；`tuis_scan_rows` 顺手加了一条全局不变量
    「正文层不许出现 NUL 字节」（字面量长度越界这一类缺陷的通用闸门）。
    `make check / build / codegen-audit / selftest` 全绿（selftest 退出 0），
    `make tui-demo` 的这几屏与本节引用的快照逐字节相同（P26 起 demo 多了第 ⑤ 屏 plan 审阅浮层、P28 起多了第 ⑥ 屏 /diff 浮窗 ——
    它只画在转录区上；命令面板 / 帮助这些**不**在 demo 里，排版没有旁及）。

 * **P24 的验收记录（2026-10-03，对应踩坑 41）**：脚注新增 `内存`（同一次 `/proc` 走查的
   PSS 合计，5 s 一档）、`%cpu` 改名 `cpu`，并修掉首 token 打点那条口径错误。
   * **错在哪（真实数据）**：用户那条 57 步 / 124741 输出 token 的会话（`~/.uya-agent/sessions/`）
     里，旧口径 `60087 tok / 8990 ms = 6684 tok/s`（界面上看到的是 6371），而地面真值
     `Σ输出token / Σ步时长 = 124741 / 786.3s ≈ 158.6 tok/s`（逐步 165–178）。
   * **修完的实测（真网关 `www.autodl.art` / `DeepSeek-V4.1-Flash`，`make e2e`）**：
     ① 长回答（`从 1 数到 200`，1 步）：步时长 4236 ms，其中 prefill（`step/start` → 首个
     delta）1961 ms，解码窗口 2275 ms、660 输出 token → **290 tok/s**（不再是几千的量级）；
     ② 同一个 key 直接拉原始 SSE 做对照（65 帧、首帧 910 ms、末帧 1991 ms）：网关**是渐进
     流式**的，帧按几百毫秒一批到达，这段回答的真实速度就在 200–290 tok/s 量级；
     ③ 两个工具步（各 ~60 token）窗口只有 70/148 ms → 聚合 578 tok/s —— 短回答 + 分块投递
     会让窗口偏小、数字偏高（**这条明写在偏差段**），会话级数字由长回答主导。
   * **离线回归**：新增 5 轮首 token 边界（`stream-firsttok-reasoning` / `-call` / `-none` +
     responses 两条）、1 轮内存解析与显示（`procx-mem`）、`cpu-live` 加内存断言、
     `tui-frame` 改成八种宽度（含右对齐「末尾恰好 3 列空白」与 32 列 `内存` 让位）；
     `make check / build / codegen-audit / selftest` 全绿（selftest 退出 0）。
* **浮层方框右边框（踩坑 42）的验收（2026-10-03）**：用户截图的口径是「命令面板弹窗右边
  没对齐」。先按**用户那一眼的条件**离线复现：headless 把**真实命令表**（`agent_tui_commands`，
  9 条命令，`/permission` 那行 69 列）灌进命令面板，在 100 列画布上逐行量「最后一个非空白
  字符的右边界列」—— 顶边 / 底边 / 其余九行都是第 **80** 列，只有 `/permission` 那行在第
  **81** 列（`│ /permission 切换访问模式（read-only / workspace-write / d…│`，与截图逐字对上）。
  然后在**真 PTY 里跑真二进制**同一场景（`openpty` + `TIOCSWINSZ` + 往主设备打 `/`，
  把读回的字节喂给一个小终端解释器重建屏幕，再按显示列量每行的左右边界）：

  | 画布 | 修前（右边界列集合） | 修后 |
  |---|---|---|
  | 70 列 | `{65, 66}` → 右边参差 | `{65}` → 对齐 |
  | 80 列 | `{70, 71}` → 右边参差 | `{70}` → 对齐 |
  | 100 列 | `{80, 81}` → 右边参差 | `{80}` → 对齐 |
  | 120 列 | `{90, 91}` → 右边参差 | `{90}` → 对齐 |

  每次都是**同一行**（`/permission`）差 1 列、其余行与顶边/底边一致 —— 与「只有被截断的那一行
  多占一列」的根因吻合。回归落在既有轮次 `tui-frame` 里（5 种宽度 × 命令面板 / 帮助 / 确认层
  三类浮层，每行都要左右边界列相同且首尾是边框字形）；把 `src/tui.uya` 的改动临时还原，
  该轮立刻在 5 种宽度全部报红并打出修前那屏，`make build / codegen-audit / selftest` 与
  `UYA_SELFTEST_TUI_ONLY` 全部 PASS。
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
* **P21 的验收记录（2026-10-03，对应访问模式 + 内核沙箱）**：
  ① 离线全套：`make check` / `codegen-audit` / `e2e-config-flags` / `e2e-api` / `e2e-steps` /
  `e2e-permission` / `e2e-sandbox` / `e2e-diff` / `tui-selftest`（P22 起 11 轮）/ `selftest`（`SELFTEST PASS`）全绿；
  新增的 5 轮权限/沙箱轮与 2 轮 TUI 轮都在里面（`perm-modes` / `perm-readonly` / `san-profile` /
  `san-shell` / `san-tool` / `tui-access` / `tui-approve`）。
  ② **沙箱是真的内核边界，不是纸面约定**：`san-shell` 轮直接 fork 出套壳命令实测 ——
  read-only 里写持久路径 `Read-only file system`、`> /dev/null` 仍成功；workspace-write 里
  工作区内写入逐字节正确、`../` 区外写入被拒；`san-tool` 轮再走一遍 bash 工具的真实路径
  （区内落盘、区外不出现）。
  ③ **本机环境事实**（选型的依据，写下来免得下次重猜）：内核 `6.12.65` 的 LSM 列表里**没有
  landlock**、`landlock_create_ruleset` 返回 ENOSYS ⇒ 只做 bwrap 一档；`bubblewrap 0.10.0`
  非特权 userns 可用，profile 与 DSH 文档一致（只读根 + fresh `/dev` + 私有 PID 的 `/proc`，
  workspace-write 另加临时 `/tmp` 与可写 workspace bind）。
  ④ 审批流程用**真 PTY** 验收（`tui-approve` B 段：等 `Read Only：批准这条 bash 命令？` 画出来
  再送 `↑`+回车 → 命令真的跑、stdout 进转录与下一封请求）；headless 那条路只钉「没人回答 =
  fail closed」。
* **P25 的验收记录（对应任务状态 / `/tasks` + 常驻任务块）**：
  ① 离线全套：`make check` / `codegen-audit` / `e2e-config-flags` / `e2e-api` / `e2e-steps` /
  `e2e-permission` / `e2e-sandbox` / `e2e-tasks` / `selftest`（`SELFTEST PASS`，含新加的
  `tasks-render` / `tasks-scroll`）/ `tui-selftest`（10 轮，含新加的 `tui-tasks`）全绿。
  ② **空态零影响是逐字节验的**：`tui-tasks` 先断言「没有任务时块 0 行、状态行仍然落在
  `tui_nrows() - 4`」，`tasks-render` 再断言折叠行与箱体在四类全空时**长度为 0**（报告给一行
  人话：`（没有任务：…）`）；`tui-frame` / `tui-status` / `tui-turn` 那些排版断言（四种尺寸、
  空态居中、对话态底对齐、脚注按宽度退化）逐条照旧通过 —— 任务块为空时 `--tui-demo` 的前三屏
  与 P21 只差脚注版本串（`p21-perm` → `p22-tasks`）。
  ③ **README 引用的三段输出都是真机产物**：`--tui-demo` 的第 ④a（折叠 1 行）/④b（展开箱体 +
  agents 箱体）/④c（`/tasks` 报告）就是上面那三块，`make tui-demo` 一条命令复现；
  箱体逐行等宽是**断言**过的（宽度含中文按显示列算）。
  ④ 键位与命令两条路都验：`tui-tasks` 注入 `\x14` 断言键层只置出 `TUI_REQ_TASKS`（不自己改状态）、
  落地后展开/收起都正确；`e2e-tasks` 用管道喂真 REPL 验 `/tasks`、`/tasks open|toggle`、
  非法参数报错与 `/help` 收录。
  ⑤ 本轮顺带修掉两个**既有**小问题：`/sessions` 与 `/status` 两处 `tui_overlay_list` 的标题长度
  写死了 44/46（真实字面量是 38/22 字节，多读的那截越界）→ 改成 `bufx_cstr_len`；
  `view_agents_sync` 的快照/推送逻辑抽成 `view_panel_push`（任务块与 agents 面板共用一个写者）。
  ⑥ 开发过程踩到的 uya 0.10 语言坑记在 §3 第 43 条（全局初始化式不能调函数、循环里的
  `const = if …`、`match` 是保留字、`tui_puts` 按 cstr 量长度）。
* **P26 的验收记录（2026-10-03，对应 plan 写闸门 + 审阅浮窗）**：
  ① 离线全套：`make check` / `codegen-audit` / `e2e-config-flags` / `e2e-api` / `e2e-steps` /
  `e2e-permission` / `e2e-sandbox` / `tui-selftest`（13 轮）/ `selftest`（`SELFTEST PASS`）全绿；
  新增两轮都在里面（`plan-gate` / `tui-plan`），另有 `UYA_SELFTEST_PERM_ONLY=1` 这条只跑
  P21+P26 的快捷入口。
  ② **闸门不是纸面约定**：`plan-gate` 轮在 `danger-full-access`（全权）下开 plan 模式 ——
  `write`/`edit` 仍被逐字拒绝、`plan-gate.txt` 不存在；把 `plan_blocks_write()` 改成恒 `false`，
  这一轮立刻红（文件会落盘）。
  ③ **浮窗的批准路径用真 PTY 验收**：`tui-plan` C 段等 `计划待审` 画出来 → `end` 翻到底看见
  计划尾巴的标记（证明正文真的可滚动，不是只画了第一屏）→ `3`+回车 → 第二封请求里出现
  `Plan approved`；D 段 `esc` → 第二封请求里是「dismissed the plan review to speak instead」，
  且 headless 段另外钉住「没人回答之后 `plan_on()` 仍为真」（fail closed 不等于批准）。
  ④ **真机现场 → 机制**：用户会话 `session-6918e8ef` 里模型在 plan 模式下直接开工
  （`turn/end reason=aborted`）—— 那是「plan 模式只有提示词没有闸门」的第一手证据（踩坑 44），
  闸门就是按这个现场补的。
* **P29 的验收记录（2026-10-03，对应 `/goal` 人类命令）**：
  ① 离线全套：`make check` / `codegen-audit` / `e2e-config-flags` / `e2e-api` / `e2e-steps` /
  `e2e-permission` / `e2e-sandbox` / `e2e-tasks` / `e2e-goal` / `e2e-diff` / `tui-selftest`
  （含扩写的 `tui-tasks`）/ `selftest`（`SELFTEST PASS`，含新加的 `goal-cmd`）全绿；
  另有 `UYA_SELFTEST_GOAL_ONLY=1` 这条只跑 P29 的快捷入口。
  ② **语法是照 DSH 抄的，不是「差不多」**：控制词大小写不敏感但**必须独占整行** —— `goal-cmd`
  轮断言 `/goal pause after verification` 建出来的是那个**字面目标**、`/goal clearx` 不会被当成
  `clear`、而 `/goal CLEAR` 照样命中；缺目标时 `pause`/`resume`/`edit` 分别点出是**谁**缺目标
  （不是一句笼统的「命令无效」）。
  ③ **目标不许互相顶掉**：已有未完成的 goal 时再 `/goal <objective>` 逐字回
  `A goal is already active. …`，并断言盘上的 objective **没被动过**；`complete` 的 goal 让位时
  换的是**新身份**（id +1、revision 回 1、round 归零、armed 打开）。
  ④ **落盘与显示是同一条链**：`goal-cmd` 轮每条命令之后都用 `goal_load` 回读盘上字段（id /
  revision / phase / objective / round / armed）；`tui-tasks` 轮断言 TUI 里 `/goal` 开的是
  `TUI_OVK_GOAL` 浮层（标题 `目标（esc 关闭）`、正文真的画在帧上 —— list 型浮层 take 回来的
  只是选中行）、`/goal <objective>` 之后常驻任务块的目标投影（`tasks_goal_ref()`）当场刷新、
  `/goal clear` 之后回到「无目标」。
  ⑤ **真二进制那条腿**：`make e2e-goal` 用管道喂**真 REPL**（独立 `UYA_AGENT_HOME`，不碰
  `~/.uya-agent`），把 11 条命令的输出逐条 grep 断言 —— 含 `Rounds: 0/20` 这种「默认值写错就红」
  的字段。
* **P28 的「退不出」在真机上做了 A/B**（2026-10-03，同一台网关 / 同一个模型 `DeepSeek-V4.1-Flash`，
  100×30 PTY + 定时注入按键的脚本）。任务都是「用 bash 工具跑 `sleep 120`，description 必须是
  long-sleep，不要后台运行」，动作在工具跑起来之后：

  | 场景 | 修改前（`main` 那次构建的产物） | 本轮（`p19-tui`） |
  |---|---|---|
  | TUI：跑着按 `ctrl+d`（t=20 s） | 45 s 后**仍然活着**（只能等 sleep 跑完） | 键后 **+2.0 s 退出**（rc 0），转录里 `✗ Bash · long-sleep · killed by signal 9` |
  | TUI：按 `esc`（t=20 s），6 s 后再 `ctrl+d` | 45 s 后仍然活着 | `esc` 后立刻 `✗ … killed by signal 9` + `[interrupted] 已中断本回合（历史保留，可直接继续输入）`；`ctrl+d` **+0.04 s 退出** |
  | TUI：相隔 0.8 s 按两次 `ctrl+c` | 仍然活着 | 第一次落一行「(再按一次 ctrl+c 直接退出；esc 只中断本回合)」，第二次 **+0.03 s 退出** |
  | 滚动模式（`--no-tui`）：t=20 s `ctrl+c`、t=30 s `ctrl+d` | 40 s 后仍然活着 | `ctrl+c` → 工具当场被杀 + `[interrupted] …`；`ctrl+d` → `bye` 后退出 |

  （`ctrl+d` 那 2 秒是「请求已经发出去、TCP 还没回」的那一下；`esc` 那条路把 step 边界的中断
  判定提到发请求之前，所以只剩本地开销。）
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
make e2e-diff                                # /diff：真 git 的列表 + 单列文本回退 + 非仓库报错（离线）
make diff-selftest                           # /diff 的两轮（解析 / 真 git）；浮窗排版在 tui-selftest 里
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

* **P30 的验收记录（2026-10-03，`p30-pump`，对应踩坑 47）**：
  * **现场量化**（真终端 + 假网关：单步长流式，正文停 3 s）：旧实现里运行中敲 `/status`，
    浮层在按键后 **2245 ms** 才出现，而且那一刻回合已经结束（脚注已经是「1 轮 · 1 步」）——
    就是用户说的「`/` 命令卡死」。改完：**103–105 ms**，且那一刻回合仍在跑
    （`make p30-check` 每次跑都会把这三个数字打出来）。
  * **离线回归轮 `tui-p30`**（进 `make selftest`）：headless 段断言「泵点当场派发 `/status`（浮层
    立刻开）/ `/new` 立刻回执 + 置中断标志、结果留给主循环 / `/compact` 泵点**不**落、step 边界才落」；
    真 PTY 段用新加的**单步长流式** mock（`mock_mode = 40` + `mock_send_sse_slow`：响应头与第一帧
    立刻发、正文停 2.5 s）断言「`/status` 浮层 **≤800 ms** 出现，且那一刻正文还没发出来」。
  * **派发点与 P28「退不出」那条线的合流**：阻塞循环里原来各有一处 `tui_abort_check()`（P28 的
    中止检查），现在统一走 `agent_pump_block()` —— 先做中止检查（`ab != TUI_ABORT_NONE` 时由各
    循环杀子进程/收口），再做命令派发。合流前我先在分支上复现过一个 P28 已经修掉的毛病，留个记录：
    「esc 打断一回合之后，第二条任务会立刻回 `[interrupted]`」——**P28 已经用
    `tui_interrupt_clear()`（回合收口 + 新任务开始两处）修掉**，我这边只是用自己的 PTY 脚本又独立
    复现/复核了一遍（脚本的第三项验收就是它）。
  * **非流式路径**（`--no-stream` / `web_search` / 会话导入）：`http_request` 的读到 EOF 循环
    改成 `poll(≤50 ms)` + 泵点，长回答期间界面继续刷新、命令照常派发。
  * **TUI 下的 `ask_user_question`** 不再抢 fd 0：提问落进转录、答案用输入行、esc = 不回答。
  * **线程那一路的实测**（写通了但没采用，留着给后来人）：真终端下 `/status` **69 ms**、
    `/new` 回执 + 中断都成立；但（a）工具链堆在两条线程并发 malloc 时 **8/8 崩**，
    （b）`libc.pthread` 的递归锁在争用下丢唤醒（28 s / CPU 0.04 s 纯阻塞）——
    证据在 `testdata/probe_heap_threads.uya` / `testdata/probe_thx_mutex.uya`，口径见踩坑 47。
  * 顺带被自测抓住的一处自身缺陷：版本串在本分支上改成 8 字节时忘了改手写的 `AGENT_VERSION_LEN`
    （当时是 9），`/status` 浮层末尾就多了一个 NUL —— 「正文层不许出现 NUL」这条不变量当场报红
    （那行常量上现在写了警告）。
  * `make check / build / codegen-audit / selftest` 全绿（`selftest` 现在包含 `p30-check`
    与 `tui-p30` 两处新闸门）；`make tui-demo` 与本节引用的快照一致
    （P30 只动派发时机与几个阻塞循环，排版一个字节没碰，版本串变成 `p30-pump`）。

* **P31 的验收记录（2026-10-03，`p31-wait`，对应踩坑 48）**：现场是用户复测「`/status` 还是慢」。
  先量分布再动手 —— 用**改前的二进制**（同一个 commit `4f9a241` 编出来的 `build/uya-agent`）跑
  新加的三个场景，把「哪一段慢」钉死：

  | 场景（真 PTY + 假网关） | 改前 | 改后 |
  |---|---|---|
  | `status-single-step`（流式中） | 103 ms | 101 ms |
  | `status-header-wait`（请求已发出、响应头压住 3 s） | **2280 ms** | **53 ms** |
  | `status-idle`（空闲） | 242 ms | 62 ms |
  | `status-during-bash`（`bash sleep 8` 跑着） | 103 ms | 102 ms |
  | `status-during-compact`（`/compact` 的摘要请求在飞） | **2833 ms** | **63 ms** |

  * 全部由 `make p30-check`（`testdata/pty_drive.py --suite`，现在 7 个场景）打印，改前那份就是
    「新场景 + 旧二进制」跑出来的红：断言报「等响应头那段太慢 2280 ms」「空闲太慢 242 ms」
    「压缩在飞太慢 2835 ms」（同一次还报了「压缩请求根本没发出去」—— 那是判据自身的坑，见踩坑 48
    最后一条）。**先写测试再修**这条在这一次特别值：光看代码只能猜是「流式还是慢」，一量才知道
    慢的全在「请求在飞」的那三段。
  * 假网关新增两个可编排开关：`HEAD_DELAY_MS`（读完请求体先停再发**响应头**）与
    `TOOL_CMD`（第一次请求回一个 bash 工具调用，用来造长 bash 与「有工具结果的历史」——
    压缩需要 shadow > 0）。既有调用（3 个参数）行为逐字节不变。
  * 离线回归轮 `tui-p31`（headless，已进 `make selftest`）：断言「派发之后**同一次调用里**帧数 +1」
    「不安全命令的回执同样当场出帧且结果仍留给主循环」「泵点上下文登记期间才派发、`end` 之后不吞
    结果」。真 PTY 的四条延迟上限（等响应头 ≤800 ms、空闲 ≤150 ms、bash ≤200 ms、压缩在飞
    ≤300 ms）在 `p30-check` 里。
  * `make check / build / codegen-audit / selftest / p30-check` 全绿（`selftest` 退出 0，其中包含
    `p30-check` 与 `tui-p31`）；`make tui-demo` 与改前**只差脚注版本串**（`p30-pump` → `p31-wait`），
    本节引用的快照已跟着更新 —— 排版一个字节没碰。

* **P32 的验收记录（2026-10-03，`p32-sess`，对应踩坑 49/50）**：
  * **真机数据只读复验**：把 `~/.uya-agent/index.jsonl` 复制到临时 `--agent-home` 里跑
    `--list-sessions`（**只读**，一个字节都没动真机索引）—— 索引 **332 行 / 322 个唯一 id**
    （10 条是同 id 的重复记录），列表打出来正好 **322 行**、每个 id 一次，「最新的在第一行」；
    同一个索引在 200 / 120 / 80 / 40 列下分别是「三列（宽）→ 三列（窄）→ 两列 → 只剩 id」，
    每行显示宽度都 ≤ 终端列数（40 列那档 id 被裁成 `session-…1111…` 并补了 `…`）。
  * 顺带看到的一条**数据事实**：真机索引里 247/332 条记录（当时）的 `title` 是空串 —— 那些是没进过
    用户消息的会话（探针、`--print-config` 空跑、PTY/自测 fixture 等），列表里显示成 `(无标题)`；
    有标题的那 85 条（`怎么默认使用dsh配置` / `跑一下 sleep` …）正常显示，长标题按列宽保头裁剪。
  * 一处**被自测当场抓住**的自身缺陷：`sess_rows_clip_into` 第一版无条件给 `…` 留一列，
    于是「本来就正好 `body` 列」的三列行也被截了一刀（80 列终端上 id 尾巴被吃掉）——
    `sess-list` 轮那条「放得下就不许出现 `…`」的断言把它钉住了（现在只在真的超宽时才裁）。
  * 另一处更值钱的：uya 的 `p[a: b]` 是「偏移 + 长度」（踩坑 50），我第一版按「到 b 为止」写了
    `idx.ptr[lo: lo + ll]`，于是「没有 `lastActiveAt`」的记录被解析成后面那行的值、倒序整体错位，
    `sess-list` 轮 12 条断言一起红。修法是**别用非 0 起点切片**：每行先拷进 scratch Buf 再按
    `[0: len]` 解析（`session.uya` / `agent.uya` / 自测助手三处都改了）。
  * `make check / build / codegen-audit / e2e-sessions / sess-selftest / tui-selftest（18 轮）/
    selftest` 全绿；`make tui-demo` 与本节引用的快照一致（版本串变成 `p32-sess`，
    其余排版一个字节没碰 —— 会话浮层的箱体宽度只对 `TUI_OVK_SESSIONS` 生效，
    默认档 `want_w = 0` 与旧写法逐字节等价）。
---

## 7. 已知限制

* **任务状态（P25）的边界**：
  * 已结束的后台任务/子代理**没有时长**（`Job`/`Deleg` 都只记了开始时刻，没有结束时间戳；
    要显示就得改它们的状态机）；运行中的才有秒数。
  * 常驻块**只列运行中**的后台任务/子代理（跑完即隐，与 P15 的窗口同口径）；完整清单（含已结束的）
    走 `/tasks`。子代理另有自己那块 P15 窗口，所以它不进任务箱体。
  * 刷新是「推」出来的：每个工具结果、step 边界、`deleg` 的等待循环各推一次，TUI 另有 1Hz 心跳。
    **滚动模式下单个长 step 期间秒数会停**（与 P15 的面板同一个限制）。
  * 清单与后台任务/子代理表是**进程状态**（`--resume` 不回填，新进程从空开始）；
    只有目标在盘上（`goal.json`，启动时重读）。
  * 浮层打开时常驻块被浮层盖住（与 P18 的状态区同现象），关掉浮层即回来；块不做鼠标交互、
    点击折叠、跨会话记忆（`/tasks close` 只影响当前进程）。
* **会话目标（P11 存储 + P29 人类命令）的边界**：
  * `goal.json` 目前只是**会话级记录**：uya-agent **没有自动续跑的驱动器**（`goal_tick` 已实现但
    没有调用点），所以 `armed` 是给 `/tasks`、`/goal` 看的字段，**不会**自己再开一轮；要对齐 DSH 的
    goal round driver 得另做一条线。
  * 人类命令没有 `complete` 动词（与 DSH 一致）：把目标标成完成由模型工具
    `update_goal action=complete` 负责，人的手段是 `edit`（改目标）或 `clear`（清掉）。
  * `/goal clear` 是**删文件**：没有 tombstone，清掉之后 id 从 1 重新开始（DSH 保留持久历史与
    tombstone，本仓库没有那层历史）。
  * 目标按 `agent_home` 落盘（`--agent-home` / `UYA_AGENT_HOME` / `~/.uya-agent`），
    与「会话」是同一层，所以 `/new` 之后仍是同一个目标（目标不随会话切换，见 P25 那条同源说明）。
* **回合运行中的界面命令（P23 提出、P30 铺开、P31 收口）**：只读命令（`/status`、`/help`、
  `/tasks`、`/sessions`、`/goal`、`/diff`）在**每个泵点**当场派发（流式每 ≤50 ms 一次；bash /
  后台任务 / 子代理 / 搜索 / workflow 的轮询循环各一次；P31 起还包括「等响应头」与「写请求体」
  这两段以前没有泵点的阻塞路），派发或给出回执之后**当场画一帧**（不再等下一次 tick）。
  P23 那条「单步长流式仍要等这一步走完」的边界**已经去掉**（真终端实测 2245 ms → 103 ms），
  P31 又把「请求在飞」那三段补上（等响应头 2280 ms → 53 ms、压缩在飞 2833 ms → 63 ms、
  空闲 242 ms → 62 ms）。有副作用的命令按口径落地：`/new`、`/resume` 立刻回执并**先中断当前
  回合**（历史保留），`/compact` 排 step 边界（压缩请求本身现在也服务键盘，esc 可中断它），
  `/continue`、`/exit` 与 steer 之外的其余命令等回合结束（steer 仍是「运行中输入的文本在下一个
  step 边界被采纳」）。仍然插不进泵点的只有**两段**：**DNS 解析**（≤5 s，工具链的
  `dns_client_resolve_first_ipv4`）与 **TLS 握手**（≤`timeout_ms`，`https_client_handshake`）——
  两者都在工具链调用内部，进程内没有可插桩的循环（能做的只是「踏进去之前先泵一次」，P31 补了）。
  另外：**没有走真线程**（工具链分配器不支持两条线程并发 malloc，见踩坑 47），所以这里仍是
  「协作式」的泵点，不是抢占式 —— 泵点之间最长的一次阻塞就是上面那两段。
  两个小口径：(a) 明文 `http://` 的请求体写入没有分片泵（真机是 https，本地 mock 才用明文）；
  (b) 等响应头那段的超时改按**墙上时间**判 `timeout_ms`（与 SO_RCVTIMEO 同口径，只是比
  「每个分片各给一次 timeout」更严）。
* **浮层（P23）**：框高上限仍是 16 行（内容靠 `↑/↓`、`pgup/pgdn`、`home/end` 滚，标题栏的
  `↑`/`↓` 是溢出指示）；浮层画在转录区上，打开时**转录被它盖住**（只有输入面板与脚注还在），
  esc 关掉就回来。终端高度不够（`panel_top < 5`）时浮层画不出来，那一路由
  `tui_overlay_available()` 的 fail-closed 语义管（审批不会「看不见却仍吞键」）。
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
* **`/diff` 的边界（P22）**：
  * 仓库用 `git -C <工作区> rev-parse --show-toplevel` 定位：工作区是仓库子目录时，列表里会出现
    仓库里**其它目录**的改动（路径一律按仓库根相对显示）——「你所在仓库改了什么」比
    「你所在子目录改了什么」更符合直觉，但确实不是「只看工作区」。
  * 口径只有**一个**：`HEAD ↔ 工作区`（含暂存与未暂存）。不支持与任意 commit/分支比较、
    不支持单独看暂存区、不支持 `--staged`；仓库还没有提交（无 HEAD）时所有文件按「旧 = 空」显示。
  * 重命名按 **删除 + 新增** 显示（`--no-renames`）：这是为了让 `status -z` 的解析只有一种形状；
    代价是看不出「这是同一次重命名」。
  * 上限：文件列表 400 个、单文件 diff 抓取 512 KiB、行表 8192 行、单次增/删块配对 4096 行
    （超过就放弃配对，内容一行不丢但左右不再对齐）。文件太大时先改成 `-U3`（只给改动附近的
    3 行上下文）并提示；`git` 单次调用 10s 墙钟超时（超时就放弃这次查询，界面不会挂死）。
  * 不做行内字符级高亮、不折叠未改动的区段（上下文段照样一行一行列出来，靠 `pgup/pgdn` 滚）。
  * 显示是**截断**的：单元格按显示列裁到栏宽并补 `…`，`←/→` 可以横向滚 8 列；不会自动换行。
  * **同步阻塞**：`gd_open` / `gd_move` / `r` 都会当场 fork git（一次开窗 3–4 个 git 进程，
    换文件 1 个），期间界面不响应按键（有 10s 上限兜底）。没有做异步加载/预取。
  * 执行方式：**不经 bash、不套沙箱、不走 read-only 的逐条批准**（它是用户敲的只读展示命令：
    只用 `status` / `diff` / `rev-parse`，`GIT_OPTIONAL_LOCKS=0` 连 index.lock 都不写）。
  * 非 TUI（`--no-tui` / 管道 / 子代理）只有**单列** unified diff 回退（默认上下文、每文件 120 行、
    总量 400 行、最多展开 20 个文件），没有第二形态；终端太小时 `--no-tui` 是唯一出路。
* 上下文管理很朴素：整个历史每轮重新序列化（没有 token 级增量缓存）。历史**条数默认不限制**，
  内存随会话线性增长，唯一的收敛机制是「按 token 压力的自动压缩」——
  所以**没有配置 contextWindow 时（`--no-dsh-config` 或模型条目里没有 `contextWindow`）压缩不会触发**，
  长会话请显式给 `--context-window N` 或用 `/compact` 手动压一次。单条消息 200 KiB 会在入史时被
  剪枝/截断（会话日志仍是全文）。
* **默认不限步数**：模型若陷入工具循环不会自动停 —— 交互模式 Ctrl-C 中断本回合（历史保留），
  正在跑的工具子进程**当场被杀掉**（P22，见 §2「退出与中断」），想彻底走人就 `ctrl+d` / `/exit`
  （运行中也生效）。脚本/CI 用 `--max-steps N` 或 `UYA_AGENT_MAX_STEPS=N` 熔断
  （`make e2e` 也可 `STEPS=N`）。没做「重复调用检测」这类启发式熔断。
* 退出时**只有前台那一步的子进程会被杀掉**（bash 前台 / 前台子代理 / workflow 脚本 / `rg`）：
  `run_in_background` 的后台任务与后台子代理是独立进程，父进程退出后它们变成孤儿继续跑
  （要停得用 `job_kill` / `interrupt_agent`）。工具循环里的 SIGKILL 打的是**直接子进程**，
  不带进程组：`bash -c 'a | b'` 这种管道里除 bash 之外的进程可能残留（与超时路径口径一致）。
* `ask_user_question` / `exit_plan_mode` 的问答浮层里，`ctrl+c`/`esc` 是「取消这次问答」，
  不是退出程序；要退出先取消（浮层收掉之后 `ctrl+d` 即可）。
* `read_file` 一次最多 64 KiB；`write_file` 是整文件覆盖，没有 diff/patch 工具。
* 滚动模式（`--no-tui`）仍然是纯文本字形、不做 markdown 渲染；TUI 模式下有颜色 + 轻量 markdown
  （围栏代码块、行内 code、标题、列表），但不做完整语法高亮/表格/链接重排。
* **plan 模式（P22）的边界**：闸门只拦 `write`/`edit` —— plan 模式下 `bash` 照访问模式走，
  所以「全权重定向写文件」这条路仍然开着（这也是 DSH 的立场：plan mode 是引导，需要更硬
  的边界就配 `read-only` 沙箱）；fork 出来的子代理会继承 plan 状态（父进程在 plan 模式下，
  子代理也写不了文件）；**非交互会话**（管道/CI）里没有审阅渠道 ⇒ `--plan` 只会产出计划、
  写工具始终被拒，要落地请在交互式会话里批准或去掉 `--plan`；`ask_user_question` 仍是行式
  问答（只有 `exit_plan_mode` 有浮窗）；plan 状态与访问模式一样是**进程级**的，不进会话日志的
  恢复语义（`--resume` 按启动参数重新求值），但每次切换会落一条 `plan/mode` 日志。
* TUI 不做鼠标（滚轮/点击/选择）、图片、可折叠卡片、分屏、主题切换 UI；`--resume` 只回填
  最近 200 条历史（注入类消息不回填），`--resume-dsh` 走同一条回填路径。
* 终端小于 32×8 时自动退回滚动模式；`cols < 66` 时块字 logo 退化成一行标题。
* 统计（P20/P24）是**整会话**口径、只认我们自己的会话日志：`--resume-dsh` 导入的 DSH 会话不计入
  （从 0 开始）；输出 token「没上报」与「上报 0」在日志里分不开，所以只有 `> 0` 才进 tok/s；
  首 token 认**第一个非空 delta**（正文/思考/工具参数），空 delta 与 usage-only 帧不算，
  非流式（`--no-stream`）没有 delta 边界 → 那一组不显示；窗口量的是客户端看到 delta 的区间，
  网关把短回答攒成一批发时数字会偏高（长回答主导会话级数字）。上下文的三段明细是
  「4 字符 ≈ 1 token」的启发式，三项加起来不等于总量（DSH 也是这个性质）。
* `cpu` 只在全屏 TUI 里采样（挂在 TUI 心跳上，1 秒一次；滚动模式不采样），统计的是**机器上
  所有同名进程**（含别的终端/工作区里的实例），不是本会话进程树；单核口径，多进程并行时可以
  > 100%。`内存` 与它同源（同一次走查、同一批进程），但慢一档（**5 秒一次**：算 PSS 要遍历
  页表），值是 **PSS 合计**（内核没有 `smaps_rollup` 时整批退回 `VmRSS`，`/status` 里写明）。
  `/proc` 不可读时这两个字段都直接省略。
* `SIGKILL` 之后终端仍可能停在备用屏幕（不可捕获），用 `reset` / `stty sane` 恢复。
* 终端标题（P22）是「best-effort 的礼貌」：不支持 xterm 标题栈（`CSI 22 t` / `CSI 23 t`）的
  终端会忽略压栈/弹栈，退出后标签页保留我们最后写的那条会话标题（**故意不写空标题**去清屏）；
  会话标题本身取「首条用户消息的前 5 个词 / ≤40 B」，没有 `/title` 之类的改名命令，
  也不会调模型去生成更好的标题（DSH 那边有一个可选的 provider，这里没接）；
  导入 DSH 会话时按 `source.kind = "user"` 记一条 `session/title`（DSH 三种 kind 里
  「显式给定、钉住不再自动改写」的那一种），不是新增事件类型。
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
