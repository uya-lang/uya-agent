# uya-agent — 纯 Uya 写的极简 CLI 编程 agent

一个**只用 Uya 源码**实现的命令行编程 agent：给它一句话任务，它自己看文件、改文件、跑命令，
多轮 loop 直到给出结论。46 个 `.uya` 文件，**不引入任何 C 代码、`@c_import` 或其它语言**，
只依赖 Uya 语言与随编译器分发的标准库。

**P0–P43 全部完成**，主线版本串 `p43-ask`。本节之后按能力域分节，各节标题保留对应的阶段号
（P0…P43）；设计取舍、踩坑记录与逐阶段验收分别见 §3 与 §6，代码地图见 §2。

真机转录节选（`--show-reasoning`；`✻ 思考` 交互模式下先在提示符那一行滚动、块结束才落成一行，
非交互（管道）没有实时行，只有结算的那一行）：

```bash
$ ./build/uya-agent --show-reasoning "在当前工作目录写 p15-demo.txt，三行 alpha / beta / gamma；然后用 bash 打印它，并告诉我第二行。"
[task] 在当前工作目录写 p15-demo.txt，三行 alpha / beta / gamma；然后用 bash 打印它，并告诉我第二行。

✻ 思考 · The user wants me to write a file p15-demo.txt with three lines alph…    # Think 行：折叠就是一行
✗ Write · build/p15_ws/p15-demo.txt · 1 lines                                     # 每次工具调用一行（失败是 ✗）
✻ 思考 · The write failed with an error. Let me try with the absolute path or…
✓ Bash · Check working directory and contents · exit 0                            # bash 摘要 = description
✻ 思考 · The write tool failed. Maybe it needs absolute path? Let's try absol…
✓ Write · /home/winger/…/build/p15_ws/p15-demo.txt · +3 -0
✓ Bash · Print file and second line · exit 0

第二行是 `beta`。
```

中间那次 `✗` 是模型自己把路径写错了，显示层照实记下。默认（P16）每次工具调用只有一行，
正文要看就得 `--tool-lines N`（即 P14 的正文块：write/edit 的 diff、结果首尾各 N 行、todo 清单）。

**功能一览**（阶段号 = 实现顺序，细节在对应小节）：

* **协议**：流式 SSE（增量 chunked 解码 + `tool_calls` 按 `index` 分片累积）；严格工具协议
  （`assistant.tool_calls` 原样回灌 + 每条结果一条 `role:"tool"` + `tool_call_id`）；
  两种线协议（`openai-responses` 默认 / `openai-completions`），并有 `--no-stream` /
  `--compat-fold` 两条回退路径。
* **DSH 对齐**：直接读 `~/.dsh`（`--print-config` 显示 base_url / model / api_key /
  contextWindow 的来源，实测零参数启动即可跑通真机网关）；工具用 DSH 原名
  （`read`/`write`/`edit`/`glob`/`grep`/`bash`/`job_*`）+ 文件观察策略（read-before-write /
  版本守卫）；system prompt 分节装配（persona / `{{model}}` / `{{cwd}}` / AGENTS.md / 运行时上下文，
  空节丢弃）；`todo_write` / `exit_plan_mode` / `ask_user_question`；能直接读 DSH 自己的会话
  （`--list-dsh-sessions` / `--resume-dsh`，含 zstd）。
* **界面**：真 TTY（termios raw + 行编辑器，UTF-8 按字符编辑、按显示列定位）；P17 起是纯 Uya
  写的全屏 TUI（对齐 opencode 观感），P18 的常驻状态区 + 思考实时行、P20/P24 脚注的统计行与
  `ctx` / `cpu` / `内存`、P25 的任务块、P27/P36 的 `/diff` 浮窗、P22 的终端标题；
  P40 起子代理面板的状态行把最新消息**贴尾**显示（`…` + 最新一段）；P41 起 `/worktree` 也是
  底对齐选择框（七个动作一行一个，`finish`/`discard` 再过一道确认）；P43 起 `ask_user_question`
  是**提问弹窗**（问题 + 编号选项 + 一行自定义回答，方向键/数字/空格/直接打字作答）；
  踩坑 68 起浮层条目与 reader 折行正文各挂一张行偏移表（取第 i 行 O(1)，会话索引也换成
  O(n log n) 归并）—— 真机 842 个会话下 `/sessions` 打开 1617 → 46 ms、按一次 ↑ 1617 → 10 ms。
* **能力**：会话落盘可恢复（`--continue` / `--resume` / `/sessions`）；上下文管理（tool 结果
  超 8192 码点剪枝 + 压力超窗口 80% 自动压缩成 checkpoint）；技能发现 + `skill` 工具；
  `web_search`；子代理一族（`subagent` / `subagent_fork` / `list_agents` / `subagent_output` /
  `send_message` / `interrupt_agent` / `ralph`）；会话目标（`create_goal` / `get_goal` /
  `update_goal`）；workflow（`.ush` 脚本编排 + 钩子代理回父进程）；三级访问模式 + bwrap 内核沙箱；
  Git worktree 独立工作区（执行 → 合并 → 删除）。
* **运行**：`make selftest` 完全离线（内置 mock LLM）；`make e2e` 一条命令跑真实网关
  （步数默认不限，`STEPS=N` 可显式熔断）。

---

## 1. 构建与运行

需要一个 Uya 编译器（默认用 `/home/winger/uya-0.10`，可在 Makefile 里改）：

```bash
make check         # 词法/语法/类型检查
make build         # 产出 build/uya-agent
make selftest      # 离线端到端自测（内置 mock LLM，不需要网络也不需要 key）
make tui-selftest  # 只跑 TUI 那几轮（改界面时最快）
make sess-selftest # 只跑 /sessions 与大日志 meta 那几轮
make codegen-audit # 扫构建产物：不许出现「切片描述符 → 字节指针」的强转（终端乱码源头）
make probe         # 传输层探针：打真实 https 端点，期望 HTTP 401（不需要 key）
# 离线 e2e（不需要网络）：e2e-permission / e2e-sandbox / e2e-tasks / e2e-goal / e2e-sessions / e2e-resume-big / e2e-watch

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
./build/uya-agent                    # REPL：逐行输入任务，空行 / exit / Ctrl-D 退出
./build/uya-agent --selftest         # 离线自测
./build/uya-agent --probe            # 传输层探针
./build/uya-agent --help
```

| 选项 | 说明 |
|---|---|
| `--base-url URL` | 默认 `https://api.deepseek.com/v1`（也支持 `http://127.0.0.1:11434/v1` 这类本地明文端点） |
| `--model NAME` | 默认 `deepseek-chat`。P37：走模型目录收口 —— 命中就把该模型的 provider / contextWindow / maxTokens / input / compat **一起**搬过来（`/model` 同口径），目录里没有就只换名字并告警（能力保持不动） |
| `--provider NAME` | 提供方键（P37，可省略）：`settings.yaml` 里 `providers.<key>` 的那个 key，配 `--model` 用；省略时由目录反查 |
| `--effort V` | 推理强度（P37，`--reasoning-effort` 的别名）：先按当前模型公布的档位校验，不在集合里则拒绝（`--reasoning-effort` 不校验、原样透传） |
| `--workspace DIR` | 工具的活动目录，默认当前目录；恢复会话时默认跟随会话记录的工作区，显式指定优先 |
| `--max-steps N` | **熔断上限**：最多几轮工具调用，**默认 0 = 不限** —— 一直跑到模型给出最终答案（对齐 DSH：它没有步数上限） |
| `--max-response N` | 响应体上限，默认 256 KiB |
| `--timeout-ms N` | 单次 HTTP 超时，默认 120 s |
| `--no-shell` | 不提供 `run_shell`（tools schema 里也不会出现） |
| `--no-stream` | 关闭流式，回退一次性响应（老端点兼容） |
| `--api=MODE` | 线协议：`openai-responses`（**默认**）/ `openai-completions`（也接受 `responses` / `chat` / `completions`）。**不写 = 未声明**：先打 `/responses`，只有 404/405/501 才回退 `chat/completions`（每进程一次），见「流式协议要点」一节 |
| `--reasoning-effort V` | 发 `reasoning.effort`（只有 responses 发；`off`/`none` = 不发），默认取 DSH 的 `agent-default-model.reasoningEffort` |
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
| `--worktree` / `--no-worktree` | **独立工作区执行**（P37）：会话开始建 git worktree + `dsh/<slug>` 分支，干完用 `worktree` 工具 `finish` 提交/合并/删除；DSH `agent-presets.default=git-worktree` 会自动开，`--no-worktree` 关掉 |
| `--skill-dir DIR` | 额外的技能根（冒号分隔，可多次） |
| `--uya-bin PATH` | 跑 workflow 脚本的解释器（默认 `$UYA_BIN` 或 `uya`） |
| `--no-compact` | 关闭自动上下文压缩 |
| `--context-window N` | 压缩判定的窗口（默认取 DSH 模型条目） |
| `--dsh-root DIR` | packaged preset 根（读 persona / plan 段文案） |
| `--dry-run` | 只组装请求并打印（不可打印字节转义成 `\xNN`，排查脏字节） |
| `--debug-dump FILE` | 诊断的**原始字节**（网关错误体 / 坏 payload 头部等）追加落盘（设路径时先清空）；默认关：转录里只有转义预览，全文仍进会话日志 `diag/dump`（见踩坑 33） |
| `--compat-fold` | 工具结果折叠成一条 user 消息（旧协议） |
| `--no-stream-options` | 不发送 `stream_options.include_usage` |
| `--show-reasoning` | 显示思考行（P16 单行口径：滚动模式下运行中在提示符那一行滚动、结束落一行 `✻ 思考 · …`；全文始终进会话日志）。TUI 下另有一条默认就显示的实时行（P18），这个开关在 TUI 里只管「额外把思考收进转录条目」 |
| `--show-usage` | 每轮打印 token 用量（in/out/cache/reasoning） |
| `--tool-lines N` | 工具正文：默认 `0` = 只留一行（P16）；`N>0` = 首尾各 N 行（含 diff / todo 清单，即 P14 的正文块） |
| `--tui` | 全屏 TUI（**TTY 交互模式默认**）；`--no-tui` 退回滚动转录；`UYA_AGENT_TUI=0\|1` 同口径 |
| `--title` / `--no-title` | 交互模式把**终端标题**写成当前会话标题（**默认开**）；`UYA_AGENT_TITLE=0` 同口径；一次性运行与非 TTY 路径本来就不写 |
| `--color=MODE` | `auto`（默认）/ `always` / `never` / `16` / `256`；`NO_COLOR` 也认 |
| `--tui-demo` | 打印 TUI 的 home / chat / 运行中 三屏 + 常驻任务块两帧（折叠 / 展开）+ plan 审阅浮窗一帧的纯文本快照后退出（诊断 + 文档） |
| `--max-tokens N` | 发送 `max_tokens`（默认不发送） |
| `--temperature N` | 发送 `temperature`（默认不发送，对齐 DSH） |
| `--tls-verify=chain\|pin\|none` | TLS 信任策略，默认 `chain`，见第 5 节 |
| `--tls-pin HEX` | `pin` 模式要求的 leaf 证书 SHA-256（小写 hex） |
| `--quiet` | 关闭工具内容块（回退到旧的最小转录：只有正文流） |
| `--tls-debug` | 保留 `lib/tls` 的握手调试输出（默认静音，见第 3 节第 21 条） |
| `--http-debug` | 打印每轮响应的头与体首字节（排查网关怪异响应用） |

REPL / TUI 内的斜杠命令：
`/help` `/status` `/tasks [open|close|toggle]` `/goal [<objective>|edit <objective>|pause|resume|clear]`
`/compact` `/plan` `/permission [预设]` `/model [名字]` `/effort [档位]` `/workspace [目录]`
`/worktree [on|off|start|status|finish|discard|list]`（TUI 里裸命令开**动作选择框**，
打开就回车 = `status`；`finish`/`discard` 选定后再过一道确认）`/sessions` `/resume <id>` `/new`
`/continue` `/diff` `/exit`。

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
src/bufx.uya       字节层：Buf、拼接、进制、UTF-8 计数与切片
src/jsonx.uya      JSON：Writer 组装、Value 取值、`sv_unescape` 反转义
src/httpc.uya      传输层：URL/DNS/TLS、请求构造、leaf 指纹
src/httpstream.uya 流式传输：只读响应头，body 增量解码
src/sse.uya        SSE 分帧：字段行、多行 data、空行 dispatch
src/llm.uya        两种协议归一成 ChatOut（chat/completions 与 /v1/responses）
src/tools.uya      P0 死代码：read_file / write_file / run_shell
src/tty.uya        终端层：termios raw、行编辑器、面板块、标题栈、诊断转义
src/sigx.uya       信号层：自绑 sigaction、终止信号先还终端、SIGWINCH 置标志
src/tui.uya        全屏 TUI：帧 diff、转录、浮层、状态区、任务块、翻看
src/sigselftest.uya 信号自测轮：sig-abi / sig-basic / sig-term-restore / sig-child-reset
src/shellselftest.uya bash 进程侧自测：bash-detach / bash-stop-recover / bash-kill-tree
src/tuiselftest.uya TUI 自测轮：tui-frame / tui-keys / tui-sink / tui-turn / tui-status / tui-cmd / tui-plan / tui-exit / tui-quit / tui-tasks / tui-diff / tui-scroll / tui-pty / tty-title-pty / tui-switch
src/inbox.uya      输入收件箱：steer（step 边界领取）+ keepInbox
src/yamlcfg.uya    自带 YAML 子集解析器（`yt_key` 取 map 键名）
src/modelx.uya     模型目录 P37：settings.yaml → McEntry，只认公布的档位
src/fsx.uya        文件工具：路径守卫、版本表、流式窗口 read
src/shellx.uya     bash 工具：bash -c / workdir / timeoutMs / run_in_background、bwrap、DSH_* 注入
src/jobs.uya       后台任务表：job_list / job_output / job_kill，尾部 1 MiB
src/search.uya     glob / grep：rg 子进程、VCS 排除、条数与行长上限
src/dshsess.uya    读 DSH 会话：扫 <DSH_HOME>/sessions、zstd 走 /usr/bin/unzstd
src/dshcfg.uya     读 DSH 设置：settings.yaml、.credentials.yaml、.env、permission.defaultPreset
src/workflow.uya   workflow：.ush 脚本 + 自包含 hooks.uya + 127.0.0.1 钩子端口
src/deleg.uya      子代理：fork 不 exec、增量读、send_message、ralph
src/goal.uya       会话目标：goal.json、id+revision 校验、blocked ≥3 轮、goal_cmd_run
src/skill.uya      技能：5 个发现根、SKILL.md front-matter、注入模板
src/webx.uya       web_search：Anthropic 兼容 Messages API + web_search 工具
src/compact.uya    上下文管理：剪枝 8192/4096/1024 码点、压缩、checkpoint
src/prompt.uya     system prompt 分节装配（order / 空节丢弃 / 变量替换）
src/instr.uya      AGENTS.md / CLAUDE.md 发现与 65536 字节预算截断
src/todo.uya       todo_write：整表替换、去重与状态校验
src/plan.uya       plan 状态机 + 写闸门 plan_blocks_write + exit_plan_mode
src/perm.uya       访问模式 P21：read-only / workspace-write / danger-full-access
src/sandboxx.uya   内核沙箱 P21：bwrap 探测与 profile、不可用 fail closed
src/askuser.uya    ask_user_question（P43 TUI 弹窗 + 三条回落通道）/ ask_approve_action
src/session.uya    会话日志：追加写、索引、崩溃裁剪、sess_open_resume
src/stats.uya      统计折叠 P20：sessionStats / tokenUsage / StatsLine
src/procx.uya      进程采样 P20/P24：/proc 算 CPU（USER_HZ=100）与 PSS
src/gitx.uya       只读跑 git P28：10s 超时、双管道收取
src/worktreex.uya  Git worktree P37：wt_provision / finish / discard、写闸门
src/gitdiff.uya    /diff 数据模型 P28：status --porcelain -z + diff -U100000 HEAD
src/diffx.uya      行级 diff（只服务显示）：LCS 60×60、截断
src/tasks.uya      任务状态 P25：四表折叠成折叠行 / 箱体 / `/tasks` 文本
src/watch.uya      P42 /watch：事件渲染（纯函数）+ 子代理会话日志的增量读
src/view.uya       显示层：标题/参数/后缀表、单行转录、思考行、agents 面板
src/agent.uya      CLI、历史、主循环、工具分发、REPL、会话事件
src/selftest.uya   mock LLM + 126 轮断言 + --probe
```

> 两处已知死代码（P14 起未清理）：`src/tools.uya` 的 `read_file`/`write_file`/`run_shell`、`agent.uya` 的 `dispatch_tool`（无调用者）。

### 显示内容（P14 + P16 单行转录）

* 工具行 `<字形> <Title> · <摘要><后缀>`：`✓` 成功 / `✗` 失败 / `●` 运行中。
* 标题按工具映射（`Read` / `Bash` / `Subagent` / `WebSearch` / `Workflow`…），`bash` 摘要优先取 `description`。
* 后缀如 `· exit 1`、`· timed out`、`· +4 -0`，兜底 `· N lines`；失败看 `Error: ` 前缀或 `[exit code: N≠0]`。
* 正文默认关闭，`--tool-lines N`（N>0）才 append；diff 在 `src/diffx.uya`（LCS 上限 60×60）。
* 思考只显示一行（`latestLine` / `firstLine`），全文进 `assistant/reasoning`；宽度按 `tty_body_width()`（40–200 列）。

### 子代理窗口面板（P15）

* 输入行上方常驻面板块：每个运行中子代理 2 行、最多最后 4 个，共享边框。
* 第 1 行 `● sub-<id> [subagent|ralph] <description>`（超宽**贴左**、丢尾巴）；第 2 行 = **锚**
  （`● running` + 秒数固定 5 列 + 已收输出行数，一个字节都不截）+ `·` + prompt 首行预览。
* **预览贴尾（P40）**：放不下就丢开头、前置 `…`，屏幕上留**最新的一段**（与运行中的 Think 行
  同口径）—— 这一行要回答「它现在在按哪句话干活」；`VIEW_AG_MSG_MAX = 320 B` 只兜内存，
  可见列数由 `view_ag_msg` 按**显示列**算（200 列终端 → 面板 198 列、内容行 194 列正好顶满）。
* 只收 `status == DELEG_RUNNING`，跑完即隐并补 `[agents] sub-2 [ralph] ✓ idle 27s — ralph loop`。
* 擦除用逐行 `ESC[2K`（不用 `ESC[J`）；`deleg_agents_refresh` 是唯一刷新入口。

### `/watch`：跟随子代理的实时过程消息（P42）

* **为什么需要**：子代理进程的 fd 1/2 指向 `/dev/null`，管道只承载**终态答复**（P11 的口径），
  所以面板上那列「已收输出行数」对普通 `subagent` 恒为 0 —— 运行中从管道看不到任何过程消息。
* **怎么做**：子代理把每个事件都实时（无 stdio 缓冲）落进了自己的会话日志；`/watch sub-N`
  **按需**去读那份日志，增量渲染成一行一条的过程消息（TUI 浮层 / 滚动模式追加进转录）。
* **事件**（`watch_render_event` 纯函数，逐字节可断言）：`[turn 开始|结束]`、`[step N]`、
  `▸ <工具> <参数首行>`、`  ← <结果首行>`、`✻ 思考 · <首行>`、`⏺ <正文首行>`、`[started · 标签]`；
  未知类型静默跳过（与 `--resume` 的 reader 同口径）。
* **路径解析**：`subagent` / `subagent_fork` 用父进程预生成的 `d.sid`；`ralph` 第 N 轮的 id 是
  父子约定的 `<基名>-rN`（`deleg_spawn` 生成基名、`deleg_child_main` 每轮拼 id），轮号由管道里
  已收的 `[round N]` 推出（marker 是一轮跑完才写的，所以运行时看的是「已见最大 + 1」）。
* **按键**：`↑/↓` / `pgup/pgdn` / `home/end` 滚正文；默认**贴尾跟随**，一旦上滚就停跟随，
  `f` 或 `End` 恢复；`esc`/`q` 关闭。子代理进终态时补一行 `[已结束 · <status> <n>s]` 并停止轮询。
* **三条纪律**：不看不读（没有 active 的 watch 时一个字节都不读盘）；只读（绝不消费 `d.buf`，
  `subagent_output` 的增量游标不受影响）；内容没变就不重推。

### preset 旋钮与 make 目标（P13）

* 旋钮读 `<DSH_ROOT>/config/agent-presets/standard/agent.cordis.yml` 的 `agent-instructions.maxBytes`、`tool-result-pruner.*`、`tool-fs.*`、`tool-bash.timeoutMs`、`compaction-basic.*`。
* `--print-config` 打每一项与来源（`preset` / `defaults`）；`--list-dsh-sessions` 列 `<DSH_HOME>/sessions/**`。
* `--resume-dsh <id 前缀>` 把 DSH 会话转成我们的历史并开自己的会话；make 目标有 `check` / `build` / `selftest` / `probe` / `e2e TASK=… [PIN=…]` / `tui-selftest` / `tui-demo`。

### workflow：Uya 脚本 + 钩子代理（P12）

* 脚本是 Uya `.ush`（`uya run` 执行），`agent()` / `phase()` / `log()` / `done()` 在父进程真实执行。
* 参数 `script` / `meta`（name/description/phases）/ `args`；父进程写 `/tmp/uya-wf-<ms>/main.ush` + 自包含 `hooks.uya`。
* 父进程监听 `127.0.0.1:0`，`fork+exec <uya-bin> run main.ush`；脚本钩子 `wf_args()` / `wf_phase(t)` / `wf_log(m)` / `wf_agent()` / `wf_done()`，`--uya-bin PATH` 可换解释器。

### 子代理与目标（P11）

* 派生方式 fork 不 exec（同二进制跑 `agent_run`），`UYA_AGENT_DEBUG_SUBAGENT=1` 保留 stderr。
* `subagent` / `subagent_fork`（继承父已完成轮次），`run_in_background` 默认 true；配套 `list_agents` / `subagent_output`（增量，`wait=true`）/ `send_message` / `interrupt_agent`（SIGKILL）。
* `ralph` 每轮新会话，报告以 `RALPH: COMPLETE|BLOCKED|CONTINUE` 结尾；`create_goal` / `get_goal` / `update_goal` 落 `<agent_home>/goal.json`。

### 技能与联网搜索（P10）

* 技能发现根：`<项目根>/.dsh/skills` → `.agents/skills` → `--skill-dir` → `$DSH_HOME/skills` → `$DSH_AGENTS_HOME|~/.agents/skills`。
* front-matter 必填 `name` 与 `description`；`disable-model-invocation: true` 不可被工具调用；错误串 `Error: invalid skill name "…"`。
* `web_search`：`queries` 1–4 条去重，走 Anthropic 兼容 Messages API + `web_search_20250305`，最多 8 条来源；凭据 `DEEPSEEK_API_KEY`，缺失回 `WEB_PROVIDER_CREDENTIAL_MISSING`。

### 上下文管理（P9）

* tool 结果超 8192 码点 → 前 4096 + `\n\n[... tool result middle pruned ...]\n\n` + 后 1024，只在构请求时生效。
* 压力取最近一次 `prompt_tokens`（拿不到按字节/4 估），达 `floor(contextWindow × 0.8)` 触发压缩；开关 `--no-compact` / `--context-window N` / `/compact`。

### 提示词与上下文状态（P8）

* system prompt 分节 persona(0) → plan 策略(50) → 工具引导(100–106)；persona 可来自 DSH preset。
* 运行时上下文是一条 user 消息，开头 `Current runtime context. This snapshot supersedes earlier runtime-context snapshots.`。
* AGENTS.md：`$DSH_HOME/AGENTS.md` → 项目根到 cwd 逐级，按 `AGENTS.md → CLAUDE.md → AGENTS.local.md`；预算 65536 字节。
* `todo_write` 回显 `Updated todo list: N pending, N in progress, N completed.`；非 plan 模式调 `exit_plan_mode` 报 `exit_plan_mode is only available in plan mode`。

### bash 与后台任务（P7）

* `bash`：`command` / `description` 必填，另有 `timeoutMs` / `workdir` / `run_in_background`；stderr 归 `[stderr]` 段。
* 尾部标记 `[exit code: N]` / `[timed out after Nms]` / `[killed by signal: N]` / `[stopped by signal: N]` / `[output truncated]`；无输出 → `(no output)`。
* `job_output` 增量读、`wait=true` 最多 30 s（上限 600 s）；`job_kill` 回 `requested cancellation of job N`；命令无终端（stdin `/dev/null` + `setsid()`），收口按进程组 `sh_kill_tree`。

### 文件系统工具（P6）

* `read`：`file_path` / `offset`（1 基）/ `limit`（默认 2000，上限 2000）；流式窗口，一次输出最多 51200 字节。
* `read` footer 三种：`(End of file - total N lines)` / `(Showing lines a-b of T. Use offset=b+1 to continue.)` / `(Output capped. …)`；行长 > 2000 截断。
* `write` 没读过 → `write requires reading "x" first — read the file, then retry`；版本变了 → `FS_STALE_VERSION … re-read the file, then retry`。
* `glob` 空 → `No files found`（默认前 100 条）；`grep` 空 → `No matches found`（最多 250 条、预览 2000 字节）。

### DSH 设置文件兼容（P5）

* 读 `$DSH_HOME/settings.yaml`、`.credentials.yaml`、`<cwd>/.env`、`$DSH_HOME/.env`；`$DSH_HOME` = `--dsh-home` > `$DSH_HOME` > `$HOME/.dsh`。
* `api:` 决定线协议：`openai-responses` → `/responses`，`openai-completions` → `/chat/completions`；`--api=` / `UYA_AGENT_API` 覆盖。
* `compat` 三键 `supportsDeveloperRole` / `supportsStore` / `supportsReasoningEffort`；优先级 CLI > `UYA_AGENT_*` > DSH 设置 > 内置默认。
* `--no-dsh-config` 关闭、`--strict-dsh-config` 读不到就退出；`--yaml-dump FILE` 打配置树；TLS 可写 `uya-agent: tls: { verify: pin, pin: <leaf sha256> }`。

### 会话持久化与恢复（P4）

* 布局 `<agent-home>/sessions/--<normalized-cwd>--/<session-id>/session.jsonl` + `index.jsonl`；`<agent-home>` = `--agent-home` > `$UYA_AGENT_HOME` > `$HOME/.uya-agent`。
* 每行 `{"type":…,"seq":N,"time":N,"data":{…}}` 追加-only；事件名 `user/message`、`assistant/message`、`assistant/reasoning`、`tool/call`、`tool/result`、`turn/start|end`、`step/start`、`session/title`、`diag/dump`、`permission/mode`、`plan/mode`、`session/model`、`session/workspace`。
* 崩溃恢复丢弃不完整末行；`tool_calls` 原样还原；反转义用 `jsonx.uya::sv_unescape`。
* 入口 `--continue` / `--resume <id|last>` / `--list-sessions` / `--no-save`，REPL `/sessions` / `/resume <id>` / `/new`；列表三列 = 标题 / 工作区 / session id，最新在最后一行。

### TTY 交互（P3）

* raw 模式：`ioctl(0, TCGETS)` 成功即 TTY；清 `ICANON|ECHO|ISIG|IEXTEN` 与 `IXON|ICRNL`，保留 OPOST。
* Ctrl-C 运行中=中断本回合并杀掉工具子进程；Ctrl-D 运行中=退出；↑/↓ 历史 32 条；slash 命令 `/help` / `/continue` / `/status` / `/exit`。
* 编辑按字符（1 汉字 = 3 字节 = 2 列），擦除 = 上移回块首 → `ESC[J`；步数默认不限（`--max-steps 0`），非 TTY 回退行式 REPL。

### 全屏 TUI（P17）

* TTY 交互默认全屏（`--no-tui` 退回滚动；非 TTY / `--quiet` / 子代理自动退回）；`UYA_AGENT_TUI=0|1`、`--color=auto|always|never|16|256`、`--tui-demo [COLSxROWS]`。
* 键位：`enter` 发送、`ctrl+j` / `alt+enter` 换行、`esc` 中断、`ctrl+c` 中断（2 秒内再按退出）、`ctrl+d` 退出、`shift+tab` 访问模式、`tab` plan、`ctrl+t` 任务块、`ctrl+p` 面板。
* 浮层：命令面板 / 会话列表 / 帮助 / `/status` / `/goal` / `/watch` 跟随 / 访问模式 / bash 批准 / plan 审阅 / **提问弹窗（P43）**；`/` 触发面板后连 `/` 一起收走。
* **提问弹窗（P43，`ask_user_question`）**：模型在执行中问问题时弹一个浮窗（标题 = `header`，
  多题时带 `第 i/共 n 问`）——问题正文一行、编号选项（`▸ 1) label — description`）、一行
  `✎ 自定义回答`、一行按键提示。键位：`↑/↓`（`tab`/`shift+tab` 同效）移光标、`1-9` 直选、
  `space` 多选勾选（`[x]`）、**直接打字 = 自己回答**、`backspace` 退格、`enter` 提交、`esc`/`ctrl+c`
  取消这次问答（**不顺带中断回合**）。**只有它在 TUI 里**：终端太矮画不出浮窗时回落输入行问答，
  滚动模式仍是 `> ` 行式问答，管道 / CI / 子代理仍是 `no answer channel`；
  回答语义对齐 DSH：单选有自定义回答就覆盖选项、多选两者都带、什么都不选直接回车 = 空 `selected`（跳过）、
  取消回的是 dismissed 文案（与 `no answer channel` 分开，模型才知道是「人不答」还是「渠道不通」）。
* 数据流：`tty_write` 变 sink，通道 1/2/3 全进转录、fd 1 不写；帧走 `sys_dup(1)` 私有 fd。
* 光标（修复，踩坑 66）：**运行中输入行照样显示光标并闪动** —— 运行中插入点仍是活的打字目标（敲进去的文本走 steer 收件箱；P43 起 `ask_user_question` 是提问弹窗，浮窗放不下、回落输入行问答时也走这里）；只有「运行中且浮层开着」才隐藏（浮层把键全吃掉，插入点不在输入行上）。口径在 `tui_cursor_place()`：`run == IDLE || !tui_overlay_open()`。
* 记忆上限：条目 ≤ 512、正文 ≤ 4 MiB、单条 ≤ 256 KiB；思考条目尾部 4 KiB、实时行尾部 1 KiB。

### 运行中的状态区与思考实时行（P18）

* 常驻状态区：运行中 1–2 行、空闲 0 行；视口先扣 `status_h` 再收转录。
* 思考实时行默认开、与 `--show-reasoning` 解耦，喂 `view_think_pick(running=true)` 的最新一行，按显示列从左边截断补 `…`。
* 收尾走 `agent_note_reasoning → view_think_end → tui_think_clear()`。

### 统计行、上下文占用、cpu 与内存（P20）

* 脚注左半 `ctx` / `cpu` / `内存`，右半是 DSH `StatsLine` 的整会话统计行（右边缘固定 `cols − 3`）。
* 5 组：`{turns} 轮 · {steps} 步`、`LLM {d}` · `工具调用 {d}`、`首 token 平均 {d}` · `{tps} tok/s`、`缓存命中 {p}%`、`输入 {n} tok`。
* 整会话口径：折叠输入是**会话日志**，`--resume` 逐行回放喂进同一份状态机 ⇒ 数字与整行逐字节相同（`stats-log`）。
* token 记法 `999 / 12.2K / 238K / 1.2M`；缓存全命中才 100（有 miss 打 `99.9…x`）；时长 < 60 s 一位小数，否则 `2m42s`；tok/s ≥ 10 取整。
* `ctx N%` = `min(100, round(used / contextWindow × 100))`，`used` = 最近一次请求的 prompt 规模 + 表层增量；**两者缺一就不显示**。`/status` 里有 `上下文已用 46%` + `~238K / 517K` + 20 格分段条 + 三行明细（`4 字符 ≈ 1 token` 启发式，三项之和 ≠ 总量）。
* `cpu` 取 `/proc/<pid>/stat` 的 `utime + stime`（**不取** cutime/cstime，否则父子双计），`USER_HZ = 100` 是常数；`pct = Δticks × 1000 / Δms`，单核口径（并行可 > 100%，显示钳 0…999）；1 秒一次、只在 TUI 活跃时。
* `内存` 取 `smaps_rollup` 的 `Pss:` 之和（子代理 fork 共享页不双计；无 `smaps_rollup` 时**整批**退回 `VmRSS:`），5 秒一次（算 PSS 要遍历页表），显示 `312M` / `1.2G`。
* 采样与排版：`src/stats.uya` + `src/procx.uya` + `tui.uya` + `agent.uya` 的 `agent_bound_*`（同一毫秒值既进日志又进折叠）。

**已知偏差**（`src/stats.uya` 里 `out_tokens <= 0` 那条分支）：输出 token「未上报」与「上报 0」在日志里不可区分，所以只有 `> 0` 才进解码与 tok/s；空串 delta、`delta:{}`、usage-only 帧不算首 token；解码窗口量的是客户端**看到** delta 的区间，网关把短回答攒成一批发时会偏小、数字偏高（会话级数字由长回答主导）；非流式（`--no-stream`）没有 delta 边界 ⇒ 第 3 组自然隐藏；`--resume-dsh` 导入的 DSH 会话事件形状不同，不折叠、统计从 0 开始。

**脚注退化表**（`--tui-demo` 八种画布下的真实脚注，cwd 是短路径 `~/uya-agent:main`）：统计行按 `" | "` 拆组、从**尾部**丢组并补 `…`；`ctx` / `cpu` **不参与丢组**，`内存` 只在放得下时才带，cwd 是唯一弹性字段，右半区 < 16 列时退回版本号。

```
200 列：~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s | 221 tok/s | 缓存命中 71% | 输入 238K tok · 输出 12K tok
160 列：~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M    1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s | 221 tok/s | 缓存命中 71%…
120 列：~/uya-a… · ctx 21% · cpu 37% · 内存 312M 1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s | 首 token 平均 1.5s | 221 tok/s…
100 列：~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M   1 轮 · 12 步 | LLM 50.7s · 工具调用 4.1s…
 80 列：~/uya-agent:main · ctx 21% · cpu 37% · 内存 312M   1 轮 · 12 步…     ← 内存占 12 列之后，
 60 列：~/uya-agent:ma… · ctx 21% · cpu 37% · 内存 312M  p43-ask            统计行在 80 列就只剩
 40 列：ctx 21% · cpu 37% · 内存 312M                                       第一组了；版本号那两行是
 32 列：ctx 21% · cpu 37%                                                   右半区整条让位的形态
```

### 访问模式（P21）

* 三级机器名对齐 DSH：`read-only`（`Read Only`）/ `workspace-write`（`Workspace Write`）/ `danger-full-access`（`Full access`）。
* read-only 下 write/edit 硬拒、bash 逐条批准；workspace-write 允许写工作区并在沙箱里跑 bash；full access 不受限。
* 批准通道：TUI 浮层（光标默认「拒绝」）、滚动模式 `执行？（y = 批准 / n = 拒绝）`、无渠道 fail closed（`bash needs per-command approval in read-only mode …`）。
* `shift+tab` 开选择浮层，选 Full access 再过 `确认启用 Full access？`；`/permission <preset>` 直接切；切换落 `permission/mode`。

### 沙箱（P21）

* 只覆盖 spawn 出去的 shell；进程内 write/edit 只是工具层栅栏。
* `read-only`：`bwrap --ro-bind / / --dev /dev --proc /proc --unshare-pid --die-with-parent`（写持久路径 → `Read-only file system`）。
* `workspace-write`：上述 + `--tmpfs /tmp --bind <workspace> <workspace>`；`danger-full-access` 不套壳；不可用则 fail closed（`the file sandbox is unavailable on this host …`），`--no-sandbox` / `UYA_AGENT_SANDBOX=0` 是逃生门。

### 任务状态与 /tasks（P25）

* 汇合 todo 清单、后台任务（`jobs.uya`）、子代理（`deleg.uya`）、会话目标（`goal.uya`）。
* 入口：`/tasks`（TUI 浮层 / 滚动模式打 `tasks_report`）、`/tasks open|close|toggle`、`ctrl+t`。
* 层序：转录 → 任务块 → agents 箱体 → 状态区 → 面板；折叠态 1 行，箱体最多 6 行。
* 状态字形 `✓ 完成 / ▸ 进行中 / · 待办`；后台任务 `● running` / `✓ completed` / `✗ completed` / `■ killed`。
* 面板块上限 8192 字节，超了静默丢弃；文本生成是纯函数（`now_ms` 显式传参）。

### 跟随子代理的实时消息与 /watch（P42）

* 子代理的过程消息走**会话日志**（事件粒度实时），不走管道（管道只有终态答复）。
* 入口：`/watch sub-N` 开始/切换跟随、`/watch off` 停、裸 `/watch` 列现役子代理。
* TUI 里是正文浮层（`TUI_OVK_WATCH`，复用 reader 型的滚动与按键，多一个贴尾跟随开关）；
  滚动模式 `--no-tui` 把新行**追加进转录**（append-only，等同 `tail -f`）。
* 刷新挂在 1Hz 心跳、阻塞泵点与 TUI 空闲主循环三处；内容逐字节比，没变就不重画。

### 运行中的命令不再等 step 边界（P30，版本串 `p30-pump`）

* 统一泵点 `agent_pump_light()` = `tui_poll_tick()` + `agent_tui_poll_pending_cmd()`，流式每 ≤50 ms 一次。
* `/status`、`/help`、`/tasks`、`/sessions` 当场派发；`/new`、`/resume` 回 `已收到 …：先中断当前回合，随后执行`。
* `/compact` 回 `已排队 …：当前 step 结束后执行`；非流式 `http_request` 也改 `poll(≤50 ms)` + 泵点。

### 请求在飞的那段也不再是空白（P31，版本串 `p31-wait`）

* `hc_open` 读响应头改 `poll(≤50 ms)` + `agent_pump_light()`，超时按墙上时间 `timeout_ms`。
* `tls_write_all` 每条 16 KiB TLS 记录后泵一次；压缩请求可被 esc/ctrl+c 中断（`[compact] 已中断（历史未改动）`）。
* 派发后当场 `tui_render()`；插不进泵点的只剩 DNS 解析（≤5 s）与 TLS 握手。

### 会话目标与 /goal（P29）

* `/goal` 报 `Status` / `Objective` / `Rounds: r/m` / `Activation: armed|disarmed`。
* `/goal <objective>` 创建（revision 1），已有未完成目标时回 `A goal is already active. Use /goal edit <objective> …`。
* 另有 `/goal edit` / `/goal pause` / `/goal resume` / `/goal clear`（幂等）；控制词只在独占整行时生效；TUI 结果是浮层 `TUI_OVK_GOAL`。

### 终端标题（P22）

* 交互模式下终端标题跟会话标题走（OSC 2）；没标题时写基标题 `uya-agent · <工作目录名>`。
* 标题源是 `session/title`；兜底取前 5 个词（`fallbackMaxWords`）并按 ≤40 B（`fallbackMaxBytes`）在码点边界截断。
* 清洗用 `tty_title_clean_into`（丢 OSC/CSI/ESC、C0/C1、零宽与方向控制符、非法 UTF-8）；压栈 `ESC [ 2 2 t`、弹栈 `ESC [ 2 3 t`；开关 `--no-title`。

### plan 模式：写闸门与审阅浮窗（P26）

* plan 下 `write` 回 `Error: write is refused in plan mode (no file changes before the user approves the plan).`（`edit` 同款）。
* `read` / `glob` / `grep` / `bash` / `todo_write` 都不拦；plan 模式是进程级，子代理继承。
* 审阅三动作：`继续讨论`（默认）、`解决`（`esc`）、`确认执行`，对应 DSH `Keep planning` / `Chat about it` / `Approve`。
* 无渠道回 `no user-questions channel is available to review the plan; …` 且不退模式；滚动模式仍是 `批准这个计划并退出 plan 模式？[y/N]`。
* 浮窗高 `min(panel_top-2, 20)`、宽 78 列；`1/2/3` 直选；运行中切模式落 `plan/mode`。

### 退出与中断：任何时刻都退得出去（P28）

* 五处阻塞循环统一问 `tui_abort_check()`：`TUI_ABORT_NONE=0` / `TUI_ABORT_TURN=1` / `TUI_ABORT_QUIT=2`。
* 接到非 0 就 SIGKILL 子进程，结果补 `[aborted by user]`（workflow 退出码 `137`）。
* `tui_is_exit_command()` 是唯一退出判定；`ctrl+d` 空行、`/exit`、`/quit` 都退出。
* `ctrl+c` 运行中第一次中断、2 秒内再按退出；`esc` 运行中杀掉工具子进程。
* 子代理一进 `deleg_child_main` 就 `tui_child_detach()`，不画帧、不读键。

### 模型选择与推理强度（P37）

* 一次选择是 provider + model + reasoning effort 三元组，事实源是 DSH `settings.yaml`。
* 目录 `src/modelx.uya` 把 `llm-pi-ai.providers.<prov>.models[]` 与 `llm-deepseek.models[]` 摊平成 `McEntry`。
* 档位只认模型公布的键，固定七档 `off`/`minimal`/`low`/`medium`/`high`/`xhigh`/`max`（`none` == `off`）。
* `reasoningEfforts: false` = 非推理模型，界面不显示 Effort 行；`/effort` 只列公布的档位；`/model <名字>` 直接切，每次选择追一条 `session/model`。

### Git worktree（P37）

* 会话在 worktree + 新分支里干活，共享 checkout 只读；`finish` 合并后删 worktree 与分支。
* 默认值：`baseBranch=''`（探测 `main` → `master` → HEAD）、`branchPrefix='dsh/'`、`worktreeRoot='.git/dsh-worktrees'`。
* `--worktree` / `--no-worktree`；`/worktree on|off|start|status|finish|discard|list`。
* 建：`git worktree add -b dsh/<slug> <repo>/.git/dsh-worktrees/<slug> <base>`（幂等）；不是 git 仓库 ⇒ `phase=skipped`。
* 写闸门：write/edit 或 bash 的 git 变更子命令落在共享 checkout 被拒，只读放行。
* `finish` = `add -A` + commit → base → `merge --no-ff` → `worktree remove --force` + `branch -D`；落 `session/worktree`。

### 流式协议要点（P1）

* `hc_open()` 读到 `\r\n\r\n` 就返回；`hc_fill()` 返回 `1=有新体字节 / 2=还没解出体 / 0=结束`。
* chunked 解码是状态机（SIZE→DATA→CRLF→TRAILER→DONE），TCP 任意切分都兜住。
* `tool_calls` 按 wire `index` 归并，`arguments` 片段逐个反转义再拼接。
* `finish_reason=length` 丢弃全部 `tool_calls`；缺 `[DONE]` 报 `STREAM_CLOSED`；坏帧报 `MALFORMED_RESPONSE`。

### Responses 接口（`/v1/responses`）

* 默认先按 Responses 发，只有 HTTP 404/405/501 才回退 `chat/completions` 并记住；`api:` 显式声明则不协商。
* 请求体 `{ "model", "input", "stream": true, "store": false, "tools", "max_output_tokens", "reasoning" }`。
* 历史转换：system → `developer`（或 `system`）、user → `input_text`、assistant → `output_text`、tool 结果 → `function_call_output`。
* 工具 schema 用扁平形状，形状不对报 `error: tool schema constant is not in the expected chat shape`。
* 流式事件：`response.output_text.delta`、`response.reasoning_text.delta`、`response.function_call_arguments.delta`、`response.completed/incomplete/failed`。
* 终局映射：`completed` → stop、`incomplete` + `max_output_tokens` → max-tokens、`failed` → error。

### 严格工具协议要点（P2）

* assistant 的 `tool_calls` 原样回灌（`jw_raw` 内联），随后每个调用一条 `role:"tool"` + `tool_call_id`；空结果发 `"(no output)"`。
* 裁剪不拆散配对；历史不允许以 tool 消息开头；受保护区域之上绝不触碰。
* `History` 是堆数组、默认不限条数；push 失败整组回滚，不留半截历史。
* 单条消息超 200 KiB 先按剪枝规则缩，仍超就按 UTF-8 边界硬截断（`hist_fit_text`）。
* `--compat-fold` 回旧协议，`--no-stream` 回一次性响应。

### 对话协议是刻意「极简」的

* 工具结果拼成一条 `user` 消息回灌，不回灌 `tool_calls` 原样 JSON，绕开 `tool_call_id` 配对要求。
* 想升级成严格 `tool` 角色消息，只需把 `tool_calls` 的 `id` 存进历史（`agent.uya` 的 `has_calls` 分支）。

---

## 3. 用 Uya 写这类程序踩过的坑

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
13. **从已解析 JSON 取字段还要再反转义（最隐蔽）**：内层 `content`/`path`/`command` 仍是未解码视图，`write_file` 把 `\n` 当两字符写文件；std.json 交出的字符串用前必过 `sv_unescape`。
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
28. **`libc.signal.signal()` 处理器一收信号就 SIGSEGV**：裸 `rt_sigaction` 传 `sa_flags=0`/`sa_restorer=null`，缺 `SA_RESTORER = 0x04000000`；`src/sigx.uya` 声明宿主 `sigaction`（152 字节，`sig-abi` 断言）；工具链已修 `fad26acd`。
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
57. **C 字符串参数：`Buf.ptr` 没有尾 NUL**：`worktreex` 把 `repo_root`/`branch` 等当 argv，git 报 `fatal: cannot change to '...'` 多出半截，用 `wt_nul(&buf)`；`agent_models_ensure` 拼 `$DSH_HOME+"/settings.yaml"` 没补 NUL 导致建目录失败。
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

---

## 4. 工具实现要点

| 工具 | 实现 | 限制 |
|---|---|---|
| `read_file` | `sys_open` + `sys_read` 循环读进堆缓冲 | 单次最多 64 KiB，超出附 `[truncated]` |
| `write_file` | `sys_open(O_WRONLY\|O_CREAT\|O_TRUNC, 0644)`；父目录缺失时 `mkdir` 一层后重试 | 整文件覆盖写 |
| `run_shell` | `pipe` → `fork` → 子进程 `dup2`+`chdir(workspace)`+`execve("/bin/sh", ["sh","-c",cmd], envp)` → 父进程 `poll` 读 stdout+stderr → 墙钟超时 `SIGKILL` → `waitpid` | 输出上限 64 KiB；默认超时 120 s；`--no-shell` 关闭 |
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

## 5. TLS 信任策略（重要，和标准库现状有关）

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

## 6. 自测与验收

`make selftest` 完全离线（在 `127.0.0.1:0` 上 fork 一个纯 Uya 写的 mock LLM），跑两轮真实 agent 循环并逐项断言；`make e2e` 则打真实网关。

| 轮次 | 覆盖点 |
|---|---|
| `shell` | schema 有 `run_shell`；一轮两个 tool_calls；第二轮请求含 `wrote … note.txt`/`SELFTEST-SHELL-OK`/`exit=0`；落盘逐字节 |
| `no-shell` | 请求不出现 `"name":"run_shell"`，其余同 `shell` |
| `tools` | 4 调用：write_file（换行/引号）、read_file 回读、`../escape.txt` 被拒、`sleep 5 timeout=300` 被 SIGKILL；`esc.txt` 逐字节 |
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
| `tui-turn` | headless 端到端：用户条目、`✓ Write`/`✓ Bash(`、最终答案、状态区收掉无残影；脚注含 `1 轮 · ` |
| `tui-status` | 常驻状态区 + 思考实时行：铺满后仍钉住、只显示 `latestLine`、空闲 0 行、窄终端退化 |
| `tui-caret` | 踩坑 66：运行中（思考/输出/工具）输入行有光标（标志位 + 字节级 1×`?25h`/0×`?25l`）；空闲与「空闲+浮层」两格不变；运行中开浮层仍隐藏（1×`?25l`/0×`?25h`） |
| `tui-p30` | 泵点当场派发只读命令、`/new` 立刻回执、`/compact` 留 step 边界；真 PTY `/status` ≤800 ms（`mock_mode=40`） |
| `tui-p31` | 派发后同一次调用帧数 +1、结果留给主循环；真 PTY ≤800/≤150/≤300 ms |
| `tui-cmd` | 面板 ↔ `/status` 浮层：输入行不留 `/`、标题逐字节、正文层无 NUL、运行中 step 边界派发 |
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
| `tui-ask` | P43 提问弹窗四段：① headless 排版与按键（标题/问题/编号选项/`▸`/`✎`/提示/方框闭合/每行 ≤ cols/无 ESC-NUL；`↓`、`1-9` 直选、打字进自定义、`backspace` 退、单选自定义排他、多选 `[x]` 交回两个下标、0 选项只画自定义行、40 列不越界、`esc` 取消）；② 终端太矮 `tui_ask_wait` 返回 0（回落输入行，不 fail closed）；③ headless+agent 真调 `ask_user_question`：没人答 = dismissed + 空 `selected`，绝不假装有人答、浮层收干净；④ 真 PTY：弹窗把问题原文画上屏（不是输入行那条提示）、`2`+回车后模型收到的工具结果里是第二个选项的 label |
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
| `goal-cmd` | P29 `/goal` 纯函数：控制词独占整行、状态块四段、`clear` 幂等 |
| `goal-e2e` | `make e2e-goal`：真 REPL 11 条命令逐条 grep |
| `sess-list` | 去重取最后一条、按 `lastActiveAt` 降序、8 档列宽退化、完整 id |
| `sess-list-big` | 踩坑 68：6000 行大索引 —— 归并排序与「金标准（未修的插入排序）」逐行等价、两把键各自有序、排两次结果相同、去重 2000 条、行尾 id 完整（抽查首/中/末） |
| `tui-switch` | P39 换会话：清转录 → 回放 → 回执、脚注保留、滚动模式不动 |
| `tui-sessions` | `/sessions` 浮层：箱体铺开、默认游标在最后一项、完整 id |
| `tui-sessions-big` | 踩坑 68：2000 项 —— 取行查表 vs 线性扫描**差分逐字节相同** + 取末项 20000 次的自校准比值（查表 ≪ 扫描）+ 第 0/中/末项文本正确 + home/end/↑/↓ 与 sel_set 自洽 + 列表与 reader 成帧各 < 1 s + 正文层无 ESC/NUL |
| `tui-model` | P37 `/model`/`/effort` 浮层：按提供方分组、只列公布的档位、反解、非推理模型不开浮层 |
| `tui-worktree` | P41 `/worktree` 动作选择浮层：标题/七个动作/✓ 标当前模式、反解只认动作行（「取消」不认）、默认游标 = `status`；`finish`/`discard` 选定不生效、先翻确认框（默认游标 = 取消）；**真 git**：确认前 worktree 目录与 phase 一个字节不动、确认后才合并 + 删除 |
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
| `session-log` | 控制字节按字节往返、半条记录 `dropped_tail`、重建历史 |
| `json-escape` | `0x00…0x1f` 全转义、无裸控制字节、`jw_key` 同规则 |
| `ctrl-bytes` / `ctrl-bytes-resp` | mock mode 23：`printf 'A\000B'` 以 `\u0000` 回请求；判定码 240 |
| `diag-preview` | cap 停字符边界、`\xNN`、`out_diag` ≤512 B |
| `diag-echo-400` / `diag-echo-400-ns` | mock mode 24：400 回显 → fd 2 一行转义预览、无裸 CR/NUL/ESC |
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
- 离线配套：`make check`（A1 类型检查）/ `build`（A2 产出 `build/uya-agent`）/ `codegen-audit` / `tui-selftest` / `shell-selftest` / `e2e-config-flags` / `e2e-api` / `e2e-steps` / `e2e-permission` / `e2e-sandbox` / `e2e-tasks` / `e2e-goal` / `e2e-sessions` / `e2e-resume-big` / `e2e-title` / `e2e-model` / `e2e-worktree` / `e2e-diff` / `e2e-watch` / `diff-selftest` / `panel-selftest` / `e2e-ws`。
- PTY 场景：`make p30-check`（`testdata/pty_drive.py --suite`，8 个场景；P41 那场 `worktree-menu` 走
  两条入口 —— 命令面板里选中 `/worktree` 与裸 `/worktree` —— 到选择框 → ↓ 到 `finish` → 确认框 →
  回车取消，`PTY_DUMP=1` 会把两张框打出来）；
  `make tui-demo` 是排版基准，各阶段只差脚注版本串（`p22-tasks` … `p39-switch`）。
- 只跑子集的开关：`UYA_SELFTEST_TUI_ONLY`、`UYA_SELFTEST_PERM_ONLY=1`（P21+P26）、`UYA_SELFTEST_GOAL_ONLY=1`（P29）、`UYA_SELFTEST_SHELL_ONLY=1`（P38）、`UYA_SELFTEST_PANEL_ONLY=1`（P15+P40，`make panel-selftest`）。
- 探针：`make probe BASE=https://api.deepseek.com/v1` 期望 HTTP 401 + leaf 指纹。

**load-bearing 硬指标**

- PTY 延迟预算：`/status` 浮层 ≤800 ms、空闲 ≤150 ms、bash 跑着 ≤200/300 ms、压缩在飞 ≤300 ms。P30 实测 103–105 ms（旧 2245 ms）；P31 五场景 101/53/62/102/63 ms（旧 103/2280/242/103/2833 ms）；P39 `new-mid-turn` 回执 112 ms、中断 172 ms。
- 退出码：正常 0；401 / 熔断 / `tool_calls` 序列化失败 3；崩溃 139；`SIGTERM` 143；`SIGKILL` 137。`resume-big-e2e` 未修 139 → 修后 0。
- 结构尺寸：`sig-abi` 152 字节；`sig-term-restore` 恢复序列 26 字节（P22 四形状 26/18/31/23）；`tty-editor` termios 60 B；P32 四形状 42/34/47/39；`--title` 40 B / 80 B 上限切码点边界。
- 容量：`unlimited-steps` 14 轮；`history-long` 40×2 ≈124 条 / 80 条工具结果；`toolcalls-*` 9849 / 9618 字节（旧固定 8192）；`read-window` 4000 行 / 160 KB（读缓冲 116736）。
- 逐字节不变量：每行显示列 ≤ cols 且正文层无 ESC / 无 NUL；diff 两栏竖线同列、改动行左右边界列相同；请求体无裸控制字节（判定码 240）；NUL 必须往返成 `\u0000`；SGR 编码 `ADD`=`38;5;42`、`ADD_BG`=`48;5;22`、`DEL_HL`=`48;5;124`；`stats-format` 缓存命中 12.5%→13%。
- 真机：`autodl-api` / `DeepSeek-V4.1-Flash`，pin 指纹 `d0265eff…42538`；A5 任务 `write_file → run_shell → 结论` 3 步、产物 `hello` 独立运行输出 `Hello, Uya!`。`~/.dsh/.credentials.yaml` 那把 key 402 `Insufficient Balance`，故走 autodl 网关。Responses 真机只验到 `--print-config` 读对 `api = openai-responses (source: dsh-settings)` 且请求真打到 `/v1/responses`（`tirisen` 502、`aigw` DNS 失败）。

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
- 其它：自测幂等（连跑两次都 PASS）；A1–A6 全部通过；技能与 `web_search`、自动压缩、后台任务、文件工具、DSH 零参数启动、跨进程会话恢复（记住 4271）都在真机验收过。

> 分阶段验收记录的详细现场（P1–P43 的 before/after 命令与截图、真机对照实验、被自测当场抓住的自身缺陷）已在此压缩，原始描述保留在 §3 踩坑 33–68 与各版本提交说明中。

---

## 7. 已知限制

按主题列出「做不到 / 故意不做 / 边界在哪」，括号里是引入该边界的阶段号。

**会话与界面**

* **换会话只换「当前会话的」那段屏幕（P39）**：TUI 里 `/new`、`/resume <id>` 会把转录清成
  「只剩新会话」（`/resume` 再把历史回放一遍），但滚动模式（`--no-tui`）不重画 —— 那边的正文是
  终端自己滚出去的。回放复用启动时那一份口径（最近 200 条 + 一条「更早的会话记录已省略」提示，
  注入类消息不回放），所以换会话后的屏幕与 `--resume` 起一个新进程是同一份。
* **子代理面板里那条「最新消息」是父进程发给它的那句话（P40）**：预览取 `Deleg.prompt`（spawn /
  `send_message` 时的任务或催促，只取首行、空白折叠、超长贴尾）；子代理的 stdout 按 P11 的口径
  **只在跑完时**才回传管道，所以「它刚刚说了什么」得等终态或 `subagent_output`（面板上那个
  `· N` 是已收输出行数，运行中通常是 0）。贴尾只收窄**显示**，`Deleg.prompt` 本身一个字节不动。
* **`/watch` 的实时粒度是「事件」，不是 token 级（P42）**：它读的是子代理的会话日志，而
  `assistant/reasoning` 与 `assistant/message` 都在**步末**才落盘 —— 所以单个长 step 内部
  （模型正在流式吐字的那几秒到几十秒）日志不增长，屏幕上不会长出新行。那段时间能看到的实时
  信号是「正在跑哪个工具」（`tool/call` 在工具**执行前**写）以及面板上的秒数。想逐字看流式，
  只有在前台跑（交互模式）才有。
  另外：`/watch` 是**进程状态**（`--resume` 不回填）；被跟随的子代理跑完或槽位被回收时跟随自动
  结束；`ralph` 跟随的是**当前轮**的日志，换轮时插一行 `[轮次切换]` 并从新日志头开始读。
* **回合运行中的界面命令（P23 → P30 → P31）**：只读命令（`/status`、`/help`、`/tasks`、
  `/sessions`、`/goal`、`/diff`、裸 `/watch`）在每个泵点当场派发并当场画一帧；`/new`、`/resume` 立刻回执并
  先中断当前回合（历史保留），`/compact` 排 step 边界，`/continue`、`/exit` 与其余命令等回合结束
  （steer 仍是「运行中输入的文本在下一个 step 边界被采纳」）。**插不进泵点的只有两段**：
  DNS 解析（≤5 s）与 TLS 握手（≤`timeout_ms`），都在工具链调用内部。
  仍是**协作式**而非抢占式 —— 没走真线程（工具链分配器不支持两条线程并发 malloc，见踩坑 47）。
  两个小口径：明文 `http://` 的请求体写入没有分片泵；等响应头那段按墙上时间判 `timeout_ms`。
* **浮层（P23）**：框高上限 16 行（`↑/↓`、`pgup/pgdn`、`home/end` 滚，标题栏 `↑`/`↓` 是溢出指示）；
  浮层画在转录区上，打开时转录被它盖住，esc 关掉就回来。终端高度不够（`panel_top < 5`）时浮层
  画不出来，由 `tui_overlay_available()` 的 fail-closed 语义管（审批不会「看不见却仍吞键」）。
* **TUI 不做**鼠标点击/拖选/选择（滚轮做了，见 P32）、图片、可折叠卡片、分屏、主题切换 UI；
  `--resume` 只回填最近 200 条历史（注入类消息不回填），`--resume-dsh` 走同一条回填路径。
  终端小于 32×8 时自动退回滚动模式；`cols < 66` 时块字 logo 退化成一行标题。
* **滚动模式（`--no-tui`）**是纯文本字形、不做 markdown 渲染；TUI 有颜色 + 轻量 markdown
  （围栏代码块、行内 code、标题、列表），但不做完整语法高亮/表格/链接重排。
  P16 起滚动模式下每次工具调用只有一行（正文要看就得 `--tool-lines N`），思考同理：
  **非交互（管道）下没有实时行**，只有块结束时落的那一行 —— 想边跑边看就用交互模式。
* **终端标题（P22）是 best-effort 的礼貌**：不支持 xterm 标题栈（`CSI 22 t` / `CSI 23 t`）的终端会
  忽略压栈/弹栈，退出后保留我们最后写的会话标题（故意不写空标题）；标题取「首条用户消息的前 5 个词
  / ≤40 B」，没有 `/title` 改名命令，也不调模型生成标题。导入 DSH 会话时按 `source.kind = "user"`
  记一条 `session/title`，不是新增事件类型。
* **`SIGKILL` 之后终端仍可能停在备用屏幕**（不可捕获），用 `reset` / `stty sane` 恢复。
* `ask_user_question` / `exit_plan_mode` 的问答浮层里 `ctrl+c`/`esc` 是「取消这次问答」而不是退出
  程序；要退出先取消（浮层收掉之后 `ctrl+d`）。
* **提问弹窗（P43）只有「TUI 且浮窗放得下」这一条路**：终端太矮（`panel_top < 6`）时回落输入行
  问答 —— 与审批类浮层**故意不同**（审批是「看不见就不许做」的 fail closed，提问是「换个地方问」，
  回落永远比丢渠道好）；管道 / CI / 子代理仍然只能拿到 `no answer channel`。题目一次只画一题
  （多题逐题弹、标题带 `第 i/共 n 问`）；问题正文与选项行都是**一行**（超长按显示列截断补 `…`，
  不做折行/滚动）；一题最多 16 个选项、最多 9 个数字直选键；自定义回答是**单行**（`enter` 提交，
  没有多行输入）；`space` 只在多选且未进入输入态时是勾选（单选时是普通字符）。回答语义对齐 DSH：
  单选自定义回答排他、多选 `selected` 与 `custom` 可同时带、跳过 = 空 `selected`、取消 = dismissed
  文案（与 `no answer channel` 分开）。

**任务状态与目标**

* **任务状态（P25）**：已结束的后台任务/子代理**没有时长**（只记了开始时刻）；常驻块**只列运行中**
  的（完整清单走 `/tasks`，子代理另有 P15 窗口，不进任务箱体）；刷新是「推」出来的，滚动模式下
  单个长 step 期间秒数会停（与 P15 面板同一限制）；清单与后台任务/子代理表是**进程状态**
  （`--resume` 不回填，只有目标在盘上 `goal.json`、启动时重读）；浮层打开时常驻块被盖住，
  块不做鼠标交互、点击折叠、跨会话记忆（`/tasks close` 只影响当前进程）。
* **会话目标（P11 存储 + P29 人类命令）**：`goal.json` 只是**会话级记录**，uya-agent **没有自动续跑
  的驱动器**（`goal_tick` 已实现但没有调用点），`armed` 只给 `/tasks`、`/goal` 看；人类命令没有
  `complete` 动词（与 DSH 一致，标完成由模型工具负责），人的手段是 `edit` / `clear`；
  `/goal clear` 是删文件、没有 tombstone（清掉后 id 从 1 重新开始）；目标按 `agent_home` 落盘，
  与「会话」同一层，所以 `/new` 之后仍是同一个目标。

**模型、工作区与 worktree**

* **模型选择与推理强度（P37）**：目录**只读本地 `settings.yaml`**（不远程拉取提供方目录，也不读
  `modelOverrides`）；设置里没写 `contextWindow` 时目录条目是 -1，这种路线请显式 `--context-window N`。
  目录外的模型名**只换名字**（provider / contextWindow / maxTokens / compat 一律保持不动，只打警告）
  —— 静默清空 `contextWindow` 会让自动压缩失效，比「名字换了能力没跟上」更坏。`/effort` **不发明
  档位**：只接受当前模型公布的档位，模型没写 `reasoningEfforts`（或 `false`）时不开浮层，
  `--effort` / `--reasoning-effort` 原样透传（不 clamp、不报错），`/status` 与 `--print-config`
  会标成「不是模型公布的档位」。**切模型不做上下文迁移**：历史原样保留，`{{model}}` 是建会话时
  求值的，所以 persona 里仍是旧模型名。选择进会话日志（`session/model`）但不进索引独立字段；
  子代理继承父的 provider/model/强度，但**不能自己切**。
* **工作区（P34）**：「会话现在在哪」= 日志里最后一条 `session/workspace`（append-only、权威）；
  header 的 `cwd` 是创建时在哪（不再改写），索引里的 `cwd` 是「最后已知」缓存。恢复时定序
  `--workspace`/env > 最后一条 `session/workspace` > header `cwd` > 当前目录；记录的工作区不存在
  时留在当前工作区、留一行话、记一条 `source:"fallback"`（worktree 合并后就删是常态）。
  `/diff` 的**改动列表范围**仍以仓库根为准（P22 口径），标题写工作区。非全权模式下**模型**切工作区
  要用户逐次批准（等于扩权），没有回答渠道就 fail closed；人敲 `/workspace <目录>` 不再弹审批；
  plan 模式不拦。运行中切工作区是**真 `chdir`**，所以启动时 `--agent-home` / `--dsh-home` /
  `--workspace` 先规范化成绝对路径（否则相对路径会被带到新工作区下面）。`--continue` 仍只接当前
  工作区里最近一条会话；`--resume-dsh` 是导入、记当前工作区。子代理在 spawn 时刻继承父的工作区，
  父进程之后切**不影响**已派生的子代理。切完 `skills` 会按新工作区重扫，但技能目录那条主动消息
  不补推（AGENTS.md 与运行时上下文会补推）。
* **Git worktree（P37）**：**是工具层栅栏，不是内核边界**（写闸门只拦 `write` / `edit` 的目标路径与
  bash 里**认得出**的 git 变更子命令；`g=git; $g commit` 认不出来，与 DSH 的 `GIT_MUTATION` 同一分界，
  要更硬就配 `read-only`）；不含内核沙箱（bwrap 档仍是 P21 那套）；**一个会话一个 worktree**
  （不支持并行/嵌套，`finish`/`discard` 只认本会话建的那个，`finish` 后要再来一轮得重新
  `worktree start`）；**合并策略只有 `merge`（`--no-ff`）**，preset 的 `squash` 没做，冲突时中止合并
  并把主干恢复原状、不做自动冲突解决；`finish` 会先看共享 checkout 在不在 base 分支上，不在就
  `checkout base`；**`--resume` 不重建 worktree**（按最后一条 `session/workspace` 落位，worktree 已被
  `finish` 删掉就走 P34 的 fallback）；DSH preset 自动开是一把双刃剑 —— 真机
  `agent-presets.default=git-worktree` 会让**每个**新会话都建 worktree，不想要就 `--no-worktree`
  或 `/worktree off`。
* **`/worktree` 的选择框与二次确认（P41）**：TUI 里裸 `/worktree` 是**底对齐选择框**（与
  `/permission`、`/model`、`/effort` 同一套观感），七个动作一行一个、`✓` 标当前模式、游标
  **默认停在 `status`** —— 所以「打开就回车」与 P37 的裸命令逐字节同效（老手感不变）；带参数的
  `/worktree on|off|…` 仍是文本命令（与 `/model <名字>` 同一口径）。`finish` / `discard` 会**删掉
  目录与分支**，所以选定不生效、先翻第二道确认框且游标默认停在「取消」（与 Full access 的风险
  确认同一态度）—— 彩排过：只按回车不会把 worktree 合掉/删掉。动作的执行结果走**滚动模式同一份**
  文本（`wt_cmd_run`），TUI 里以一条 notice 落进转录，所以两条路的措辞永远一致。这是工具层护栏，
  不是安全边界：模型自己调 `worktree` 工具走的是同一条 `wt_tool_worktree`，不经过这道确认框。

**访问模式、沙箱与 plan**

* **访问模式/沙箱（P21）**：沙箱只覆盖 spawn 出去的 shell 代码；进程内 write/edit 靠工具层栅栏，
  不是内核边界（DSH 的 `dsh-fs-sandbox` 同一分界）。没有「沙箱拒绝 → 升级审批重试」那条链：
  read-only 的审批是「允不允许跑这条命令」，不是「允不允许写这个文件」。后端**只有 bwrap**，
  Landlock 没实现（本机内核 LSM 里没有它，`landlock_create_ruleset` 返回 ENOSYS），没有 bwrap 的
  机器上 confined 模式只能 `--no-sandbox`（显式承担）或退回 `danger-full-access`。workspace-write 用
  `--tmpfs /tmp` + 整棵工作区可写，做不到工作区内细粒度授权；网络与进程级效果不在权限词汇里。
  访问模式是**进程级**状态：不进会话日志的恢复语义，只在切换时记一条 `permission/mode` 审计事件；
  子代理在 spawn 时刻继承父的模式。沙箱拒绝提示（`[sandbox] the <mode> file sandbox denied a file
  effect …`）是**按 stderr 签名**追加的提示，不改任何强制。
* **plan 模式（P22）**：闸门只拦 `write`/`edit` —— 所以「全权重定向写文件」这条 bash 路仍然开着
  （DSH 的立场也是 plan mode 是引导，要更硬就配 `read-only`）；fork 出来的子代理继承 plan 状态；
  **非交互会话**（管道/CI）没有审阅渠道 ⇒ `--plan` 只会产出计划、写工具始终被拒；
  `ask_user_question` 在 TUI 里是**提问弹窗**（P43；浮窗画不出来则回落输入行，管道/子代理仍无渠道）；
  plan 状态与访问模式一样是
  **进程级**的，但每次切换会落一条 `plan/mode` 日志。

**默认行为与进程**

* **默认不限步数**：模型若陷入工具循环不会自动停 —— 交互模式 Ctrl-C 中断本回合（历史保留），
  正在跑的工具子进程**当场被杀掉**，想彻底走人就 `ctrl+d` / `/exit`（运行中也生效）。脚本/CI 用
  `--max-steps N` 或 `UYA_AGENT_MAX_STEPS=N` 熔断（`make e2e` 也可 `STEPS=N`）。
  没做「重复调用检测」这类启发式熔断。
* 退出时**只有前台那一步的子进程会被杀掉**（bash 前台 / 前台子代理 / workflow 脚本 / `rg`）：
  `run_in_background` 的后台任务与后台子代理是独立进程，父进程退出后变成孤儿继续跑（要停得用
  `job_kill` / `interrupt_agent`）。工具循环里的 SIGKILL 打的是**直接子进程**、不带进程组：
  `bash -c 'a | b'` 这种管道里除 bash 之外的进程可能残留。
* **bash 命令没有终端（P38）**：stdin 是 `/dev/null`、子进程自成会话 —— 这是有意的（见踩坑 60），
  代价是需要交互的命令（`git` 要凭据、`vi`、`ssh` 要密码、`apt` 要确认）会**当场失败**。要真 PTY 就
  自己套 `script -qec "…" /dev/null`。命令**退出就返回**：它留下的后台子孙不由工具负责，
  只有中止/超时/被停住这三条路径会把整组收干净。
* `read_file` 一次最多 64 KiB；`write_file` 是整文件覆盖，没有 diff/patch 工具。

**上下文与统计**

* **上下文管理很朴素**：整个历史每轮重新序列化（没有 token 级增量缓存）；历史**条数默认不限制**，
  内存随会话线性增长，唯一的收敛机制是「按 token 压力的自动压缩」—— 所以**没有配置 contextWindow
  时压缩不会触发**，长会话请显式给 `--context-window N` 或用 `/compact` 手动压一次。单条消息
  200 KiB 会在入史时被剪枝/截断（会话日志仍是全文）。
* **统计（P20/P24）是整会话口径、只认我们自己的会话日志**：`--resume-dsh` 导入的 DSH 会话不计入
  （从 0 开始）；输出 token「没上报」与「上报 0」在日志里分不开，所以只有 `> 0` 才进 tok/s；
  首 token 认**第一个非空 delta**（正文/思考/工具参数），空 delta 与 usage-only 帧不算，
  非流式（`--no-stream`）没有 delta 边界 → 那一组不显示；窗口量的是客户端看到 delta 的区间，
  网关把短回答攒成一批发时数字会偏高。上下文的三段明细是「4 字符 ≈ 1 token」的启发式，
  三项加起来不等于总量（DSH 也是这个性质）。
* `cpu` 只在全屏 TUI 里采样（挂在 TUI 心跳上，1 秒一次），统计的是**机器上所有同名进程**
  （含别的终端/工作区里的实例），不是本会话进程树；单核口径，多进程并行时可以 > 100%。
  `内存` 与它同源但慢一档（**5 秒一次**：算 PSS 要遍历页表），值是 **PSS 合计**（内核没有
  `smaps_rollup` 时整批退回 `VmRSS`，`/status` 里写明）。`/proc` 不可读时两个字段都省略。

**`/diff`**

* **`/diff`（P22 / P36）**：仓库用 `git -C <工作区> rev-parse --show-toplevel` 定位 —— 工作区是仓库
  子目录时列表里会出现仓库里**其它目录**的改动（「你所在仓库改了什么」比「你所在子目录改了什么」
  更符合直觉）。口径只有**一个**：`HEAD ↔ 工作区`（含暂存与未暂存），不支持与任意 commit/分支比较、
  不支持单独看暂存区/`--staged`；重命名按**删除 + 新增**显示（`--no-renames`，代价是看不出是同一
  次重命名）。上限：文件列表 400 个、单文件 diff 抓取 512 KiB、行表 8192 行、单次增/删块配对
  4096 行（超过就放弃配对，内容一行不丢但左右不再对齐）；文件太大时先改成 `-U3` 并提示；
  `git` 单次调用 10 s 墙钟超时。不做行内字符级高亮、不折叠未改动的区段。显示是**截断**的
  （按显示列裁到栏宽并补 `…`，`←/→` 横向滚 8 列，不自动换行）。**同步阻塞**：`gd_open` / `gd_move` /
  `r` 都当场 fork git（开窗 3–4 个进程，换文件 1 个），期间不响应按键（10 s 上限兜底），没有异步
  加载/预取。执行上**不经 bash、不套沙箱、不走 read-only 逐条批准**（只用
  `status`/`diff`/`rev-parse`，`GIT_OPTIONAL_LOCKS=0` 连 index.lock 都不写）。非 TUI 只有**单列**
  unified diff 回退（默认上下文、每文件 120 行、总量 400 行、最多 20 个文件）。
* diff 是行级的、面向显示：中间段两侧超过 60 行就退化为两行汇总（不做 Myers 全量 diff），
  也不高亮词级改动。

**网络与协议**

* 只做 IPv4（`dns_client_resolve_first_ipv4`），不做 IPv6、不走代理。
* Responses 协议只做 `openai-responses`：`anthropic` / `azure-openai-responses` /
  `openai-codex-responses` 不支持（前者认证与端点都不同，Azure 还要 `api-version` 与 `api-key` 头，
  Codex 走 OAuth），设置里写了会告警并退回「未声明」处理。
* 未声明协议时**首次请求可能多一次 404**（先用 `/responses` 探一次），只留一行 `[api]` 提示；
  协商结果只存在于进程内，不写设置也不写会话（换进程会重新探一次）。
* 不做 DSH 的 `reasoningEfforts` 模型级 clamp：`reasoning.effort` 原样透传设置里的值
  （网关不认就 `--reasoning-effort off` 或 `--api=chat`）。
* Responses 下不回放 reasoning item（不发 `include: ["reasoning.encrypted_content"]`，也不发
  `prompt_cache_key` / `prompt_cache_retention`）；历史按「外来消息」重放，只带文本与工具调用。
  工具 schema 不带 `strict`，也不做 404 之外的协议自动探测（换协议请显式 `--api=`）。

**平台与编译器**

* 目标平台是 Linux x86-64（代码里的 syscall/常量按这个平台写）。
* 换到 `uya-0.11`：`tls/https.uya`、`std/json/*`、`x509/verify.uya` 与 0.10 逐字节相同，
  但 `libc/syscall.uya`、`std/runtime/runtime.uya`、`tls/ssl/context.uya` 有差异，需要重新验证
  （`make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...`）。

