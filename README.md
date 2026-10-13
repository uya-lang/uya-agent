# uya-agent — 纯 Uya 写的极简 CLI 编程 agent

一个**只用 Uya 源码**实现的命令行编程 agent：给它一句话任务，它自己看文件、改文件、跑命令，
多轮 loop 直到给出结论。**不引入任何 C 代码、`@c_import` 或其它语言**，只依赖 Uya 语言与
随编译器分发的标准库。

**P0–P83 全部完成**，主线版本串 `p83-clip-any`（**版本串只在选定要动
`AGENT_VERSION` 的那条线才改** —— 各线都沿用最近一次改动后的版本串，见
`src/agent/ag_tui_sessions.uya` 的编号说明；各阶段做了什么见 [DESIGN.md §19](DESIGN.md)）。

| 文档 | 看什么 |
|---|---|
| **README.md**（本文） | 装、跑、选项与命令、退出码、能力一览、已知限制（§7） |
| [DESIGN.md](DESIGN.md) | **详细设计**：分层与数据流、每处状态与不变量、设计决策的**理由**、踩坑现场（§16）、验收记录（§19） |
| [CODING.md](CODING.md) | 目录/文件/命名约定、文件头模板、验收纪律、编译器的硬约束 |

代码地图（`src/` 按域分目录，一个文件一个职责）见 [DESIGN.md §2](DESIGN.md)；
**为什么这么设计**见 DESIGN.md 各章；**怎么改才不踩坑**见 DESIGN.md §14–§16。

**能力一览**：

* **协议**：流式 SSE、严格工具协议、两种线协议（`openai-responses` 默认 / `openai-completions`），
  `--no-stream` / `--compat-fold` 两条回退路径。
* **DSH 对齐**：直接读 `~/.dsh`（零参数启动即可跑通真机网关）；工具用 DSH 原名；文件观察策略
  （read-before-write / 版本守卫）；system prompt 分节装配；能直接读 DSH 自己的会话（含 zstd）。
* **界面**：纯 Uya 写的全屏 TUI（常驻状态区 + 思考实时行 + 统计行/`ctx`/`cpu`/`内存` + 任务块 +
  `/diff` 浮窗 + markdown 渲染 + 浮层全屏 + 终端标题）；放不下的文本**滚动显示**
  （脚注的工作区路径固定 30 列窗口，装不下就一列一列滚过去；列表浮层那种「一格一条」的
  一组行里**只有光标选中那一行**滚，且命令名钉住、只滑后面的说明 —— 见 DESIGN §11.5）；
  `cpu` / `内存` 统计的是**本会话
  进程树**（本进程 + 子代理，P24b），不是机器上所有 uya-agent；滚动模式（`--no-tui`）退回纯文本转录；
  **web 界面**（`--web`）—— 顶栏列会话标题、标题下就是该会话的**真 TTY**、最右边 `+` 新建会话，
  页面零外部依赖（不引 xterm.js、不走 CDN，终端解释器在服务端，见 §1.3）。
* **能力**：会话落盘可恢复（`--continue` / `--resume` / `/sessions` —— 列表只列**有标题的**会话，
  无标题的仍可 `--resume <id>` 直达）；上下文管理（剪枝 +
  自动压缩）；技能发现 + `skill`；`web_search`；子代理一族（含 `ralph` 与 `/watch` 实时跟随）；
  会话目标；workflow（`.ush` 脚本编排）；三级访问模式 + bwrap 内核沙箱；Git worktree
  （执行 → 合并 → 删除，连带残留回收）；图片附件与剪贴板粘贴（纯 Uya 的 X11 客户端）。
* **项目记忆**（P66–P68）：跨会话记住「这个项目怎么跑、关键文件在哪、上次什么还红着」——
  按**归一化仓库根**归类（worktree 与其主仓同键），只追加分片存储（多写者不丢更新），
  开工包在会话开始时注入**一条独立 user 消息**（不改 system、不打掉前缀缓存）。
  `/memory` 看报告、`/memory off` 关、`/memory forget` 清空；`--no-memory` / `--memory-budget N`。

---

## 1. 构建与运行

需要一个 Uya 编译器（默认用 `/home/winger/uya-0.10`，可在 Makefile 里改）：

```bash
make check         # 词法/语法/类型检查
make build         # 产出 build/uya-agent（**静态链接**，见下）
make link-audit    # 核对产物真是静态链接（无 PT_INTERP / 无 NEEDED）
make selftest      # 离线端到端自测（内置 mock LLM，不需要网络也不需要 key）
make tui-selftest  # 只跑 TUI 那几轮（改界面时最快）
make sess-selftest # 只跑 /sessions 与大日志 meta 那几轮
make diff-selftest # 只跑 src/diff/
make shell-selftest # 只跑 bash 工具的进程侧
make panel-selftest # 只跑子代理面板
make e2e-portable  # 可搬运性：拷一个二进制到「新机器」（空 HOME/无 DSH/无仓库）跑完整功能
make codegen-audit # 扫构建产物：不许出现「切片描述符 → 字节指针」的强转（终端乱码源头）
make doc-audit     # 扫文本文件：不许留 Git 冲突标记（合并残留）
make probe         # 传输层探针：打真实 https 端点，期望 HTTP 401（不需要 key）
# 离线 e2e（不需要网络）：e2e-permission / e2e-sandbox / e2e-tasks / e2e-goal / e2e-sessions /
#   e2e-resume-big / e2e-diff / e2e-ws / e2e-model / e2e-ctxwindow / e2e-worktree / e2e-exec /
#   e2e-accept-nudge / e2e-config-flags / e2e-title* / e2e-api / e2e-steps / e2e-mouse /
#   e2e-watch / e2e-watch-pick / e2e-portable
make e2e TASK="..." PIN=<leaf sha256> [STEPS=N]   # 真实调用（需要 DEEPSEEK_API_KEY）
```

**静态链接（默认开）**：`make build` 产出的 `build/uya-agent` 不依赖 `libc.so.6`、没有
`PT_INTERP`（拷到任何同架构 Linux 上都能跑，不需要目标机有对应的 glibc）。
开关是 Makefile 里的 `STATIC ?= 1`：`make build STATIC=0` 退回动态。

```bash
file build/uya-agent                              # statically linked
readelf -lW build/uya-agent | grep -c INTERP      # 0
readelf -dW build/uya-agent | grep -c NEEDED      # 0
```

**只拷一个二进制就能跑完整功能**（含 web 界面）。两件事为此专门做过（P73）：

* **DSH 标准 preset 已内嵌**（`src/agent/assets/agent.cordis.yml`，编译期 `@embed`）。
  没装 DSH 的机器上，persona 与 **plan 策略段**照常完整 —— 否则 plan 模式下写闸门
  照旧硬拒 write/edit，而模型**收不到**「该调 `exit_plan_mode`」那段引导。
  装了 DSH 时**一律以磁盘上那份为准**（内嵌只是「没装」的兜底）。
  来源可证：`--print-config` 报 `knobs (source: preset | embedded | defaults)`。
* **`--web` 的会话子进程继承父进程的命令行配置**（靠环境变量）：`--permission` /
  `--workspace` / `--agent-home` / `--base-url` / `--model` / `--tls-verify` …
  都会跟着进会话。以前它们一条都不传，症状是「服务端好好的、标签页里权限却变成
  Full access」或「自建网关变成打 api.deepseek.com」。
  少数**没有环境变量口径**的开关（`--plan` / `--no-dsh-config` / `--quiet` /
  `--no-shell` / `--tool-lines` / `--no-save` / `--skill-dir` / `--no-stream` …）
  不会传下去，`--web` 启动时会**逐条点名**，不静默。

判据是 `make e2e-portable`：把二进制拷到空目录、`HOME` 也是空目录、**没有 DSH、
没有仓库**，再断言上面两条。细节见 [DESIGN.md §16 踩坑 124](DESIGN.md)。

为什么开关必须写在 Makefile 的**行内赋值**里、为什么命令行的 `LDFLAGS=-static` 不算数、
为什么文档里的 `LINK_MODE=static` 无效 —— 见 [DESIGN.md §16 踩坑 90](DESIGN.md)。

不带 make 的等价命令（关键点：**显式导出 `UYA_ROOT`**、**显式给 `LDFLAGS=-static`**，
并尽量用编译器的绝对路径）：

```bash
export UYA_ROOT=/home/winger/uya-0.10/lib/
export UYA_SPLIT_C_DIR=$PWD/build/uyacache      # 多文件 C 缓存别丢在仓库根目录
# 文件清单以 Makefile 的 SRC 为准（按域分目录；手抄的清单一定会过期）
LDFLAGS=-static \
  /home/winger/uya-0.10/bin/uya build $(make -s print-src) -o build/uya-agent
readelf -lW build/uya-agent | grep -c INTERP    # 0 = 真静态
```

**用法**：

```bash
./build/uya-agent "任务..."          # 一次性执行
./build/uya-agent                    # REPL：逐行输入任务，空行 / exit / Ctrl-D 退出
./build/uya-agent --selftest         # 离线自测
./build/uya-agent --probe            # 传输层探针
./build/uya-agent --help
```

### 1.1 命令行选项

| 选项 | 说明 |
|---|---|
| `--base-url URL` | 默认 `https://api.deepseek.com/v1`（也支持 `http://127.0.0.1:11434/v1` 这类本地明文端点） |
| `--model NAME` | 默认 `deepseek-chat`。走模型目录收口 —— 命中就把该模型的 provider / contextWindow / maxTokens / input / compat **一起**搬过来（`/model` 同口径），目录里没有就只换名字并告警（能力保持不动）。**同名模型跨提供方**（两家都发布同一个 id）时用 `--model 提供方/名字` 指定是哪一家；只给名字时用当前提供方，并在回执里点出同名的那一家。**命令行是一次性的**：它不会改 `settings.yaml`（要改默认用 `/model`） |
| `--provider NAME` | 提供方键（可省略）：`settings.yaml` 里 `providers.<key>` 的那个 key，配 `--model` 用；省略时由目录反查。显式给的这个键**当场生效**（端点 / 凭据 / 线协议一起解析），与 `--model` 谁先谁后都一样；**显式优先** —— 该提供方没发布这个名字时不会跨提供方回退（不会把你点的键悄悄换掉） |
| `--effort V` | 推理强度（`--reasoning-effort` 的别名）：先按当前模型公布的档位校验，不在集合里则拒绝（`--reasoning-effort` 不校验、原样透传）。与 `--model` 一样是**一次性**的，不写回设置 |
| `--reasoning-effort V` | 推理强度：**completions 发顶层 `reasoning_effort`，responses 发 `reasoning.effort`**（`compat.supportsReasoningEffort=false` 或 `off`/`none` = 不发），默认取 DSH 的 `agent-default-model.reasoningEffort` |
| `--workspace DIR` | 工具的活动目录，默认当前目录；恢复会话时默认跟随会话记录的工作区，显式指定优先 |
| `--max-steps N` | **熔断上限**：最多几轮工具调用，**默认 0 = 不限** —— 一直跑到模型给出最终答案（对齐 DSH：它没有步数上限） |
| `--max-response N` | 响应体上限，默认 256 KiB |
| `--timeout-ms N` | 单次 HTTP 超时，默认 120 s |
| `--no-shell` | 不提供 `bash` 工具（tools schema 里也不会出现） |
| `--no-stream` | 关闭流式，回退一次性响应（老端点兼容） |
| `--api=MODE` | 线协议：`openai-responses`（**默认**）/ `openai-completions`（也接受 `responses` / `chat` / `completions`）。**不写 = 未声明**：先打 `/responses`，只有 404/405/501 才回退 `chat/completions`（每进程一次） |
| `--no-stream-options` | 不发送 `stream_options.include_usage` |
| `--compat-fold` | 工具结果折叠成一条 user 消息（旧协议） |
| `--show-reasoning` | 显示思考行。滚动模式下运行中在提示符那一行滚动、结束落一行；TUI 下另有一条默认就显示的实时行，这个开关在 TUI 里只管「额外把思考收进转录条目」。全文始终进会话日志 |
| `--show-usage` | 每轮打印 token 用量（in/out/cache/reasoning）。提供方没回缓存明细时 `cache_read=?`（**不是 0** —— 「没读数」与「命中 0」是两件事，见 DESIGN §16 踩坑 123） |
| `--tool-lines N` | 工具正文：默认 `0` = 只留一行；`N>0` = 首尾各 N 行（含 diff / todo 清单） |
| `--quiet` | 关闭工具内容块（回退到旧的最小转录：只有正文流） |
| `--max-tokens N` / `--temperature N` | `--max-tokens` 覆盖**输出上限**（口径见 §「输出上限」条）；`--temperature` 默认不发送（对齐 DSH）。真被截断时（`finish_reason=length` / `incomplete`+`max_output_tokens`）**不派发工具调用、正文留在对话里**，直接发「继续」接着做；退出码见 §1.1 的 `5` |
| `--exec-effort V` / `--exec-after N` | **低思考执行态**：前 N 步用 `--reasoning-effort` 把方案想清，第 N+1 步起切到 V 执行（**默认关**；人运行中 `/effort` 改过就不自动切）。设计取舍与实测方差见 [DESIGN.md §5.5](DESIGN.md) |
| `--grace-steps N` | **收工预算**：验收类命令在改动之后首次跑绿起，还允许再走 N 步；`0` = 只提醒不截断（**默认**） |
| `--api-retry-max N` | **传输层重试上限**：连接失败 / IO / 超时 / SSE 早断 / HTTP 408·425·429·5xx 会退避 **0.5–3 s 随机**后重发同一请求。**不给 = 不限次数**（直到成功或你 esc/ctrl+c）；`0` = 一次都不重试（逐字节回到旧行为，CI/排障用）；`N>0` = 最多发 N 次。`UYA_AGENT_API_RETRY_MAX` 同口径 |
| `--plan` | 以 plan 模式启动（先出计划、批准后再执行）；plan 模式**真的拦写**，非交互会话（管道/CI）里没有审阅渠道 ⇒ 只产出计划、写工具始终被拒 |
| `--permission MODE` | **访问模式**：`read-only` / `workspace-write` / `danger-full-access`（默认）。也收 `--permission=<MODE>`；非法值**报错退出**。来源优先级 CLI > `UYA_AGENT_PERMISSION` > DSH `permission.defaultPreset` |
| `--no-sandbox` | 关掉 bash 的内核沙箱（bwrap）：confined 模式不再套壳、也不再 fail closed（启动打一行警告） |
| `--bwrap PATH` | 指定 bwrap 可执行文件（默认探测 `/usr/bin/bwrap`、`/bin/bwrap`、`/usr/local/bin/bwrap`） |
| `--worktree` / `--no-worktree` | **独立工作区执行**：会话开始建 git worktree + `dsh/<slug>` 分支，干完用 `worktree` 工具 `finish` 提交/合并/删除；DSH `agent-presets.default=git-worktree` 会自动开 |
| `--skill-dir DIR` | 额外的技能根（冒号分隔，可多次） |
| `--mcp-server SPEC` | 加一个 MCP 插件 server（可多次）。`SPEC = name=command [args…] [K=V…]`，例：`--mcp-server "fs=npx -y @mcp/server-filesystem ."`。见 [§2.1](#21-插件mcp) |
| `--no-mcp` | 不读不连任何 MCP 插件（`UYA_AGENT_MCP=0` 同口径） |
| `--list-plugins` | 打印插件与工具的诊断后退出（排查「为什么工具数是 0」的第一个入口） |
| `--uya-bin PATH` | 跑 workflow 脚本的解释器（默认 `$UYA_BIN` 或 `uya`） |
| `--no-compact` / `--context-window N` | 关闭自动上下文压缩 / 指定压缩判定的**上下文窗口**（纯十进制正整数，非法值报错退出）。只认这四档来源，从高到低：`--context-window` > `UYA_AGENT_CONTEXT_WINDOW` > `settings.yaml` 的 `uya-agent.contextWindows` 映射 > DSH 模型条目的 `contextWindow`；一条都没有就**沿用**（一次都没人给过时是 `-1` = 未知，此时自动压缩不触发）。前两档是**显式**的：本会话里切模型也不动它。见 §7「上下文窗口」 |
| `--input-image` / `--no-input-image` | 这个模型**收不收图**（`/image`、`ctrl+v`、`/paste` 挂不挂得上）。**默认支持** —— 只有明确了「不支持」才关：目录条目写了 `input:` 但不含 `image`（如 `[text]`），或这两个 flag / `UYA_AGENT_INPUT_IMAGE=0`。两个 flag 是**显式**的：本会话里切模型也不动它。见 §7「图片能力位」 |
| `--no-memory` / `--memory-budget N` | 关掉项目记忆（不读不写不注入）/ 开工包的字节预算（默认 3072） |
| `--agent-home DIR` | 会话与索引的根目录（默认 `~/.uya-agent`） |
| `--no-save` | 不写会话日志（只跑不记） |
| `--continue` | 接着当前目录最近一条会话继续 |
| `--resume ID` | 恢复指定会话（`ID` 或 `last`） |
| `--list-sessions` | 列出本机**有标题的**会话后退出（无标题的不进列表；`--resume <id>` 仍可直达） |
| `--dsh-home DIR` | DSH 用户目录（默认 `$DSH_HOME` 或 `~/.dsh`） |
| `--no-dsh-config` | 完全不读 DSH 设置（也因此**不写回**） |
| `--no-dsh-writeback` | `/model`、`/effort` 切完**不写回** `settings.yaml`（`UYA_AGENT_DSH_WRITEBACK=0` 同口径）。注意这与 `--no-dsh-config` 不同：那个连模型路线与权限预设都不读 |
| `--strict-dsh-config` | 读不到 DSH 设置就报错退出 |
| `--dsh-root DIR` | packaged preset 根（读 persona / plan 段文案） |
| `--print-config` | 打印生效配置、preset 旋钮与**来源**后退出（含 `tls_verify` / `tls_pin`） |
| `--list-dsh-sessions` | 列出 DSH 自己的会话（`<DSH_HOME>/sessions`，含 zstd） |
| `--resume-dsh ID` | 导入 DSH 会话并继续（id 前缀 ≥8 字符即可） |
| `--yaml-dump FILE` | 打印该 YAML 的解析结果（诊断） |
| `--dry-run` | 只组装请求并打印（不可打印字节转义成 `\xNN`，排查脏字节） |
| `--debug-dump FILE` | 诊断的**原始字节**（网关错误体 / 坏 payload 头部等）追加落盘；默认关：转录里只有转义预览，全文仍进会话日志 `diag/dump` |
| `--tui` / `--no-tui` | 全屏 TUI（**TTY 交互模式默认**）/ 退回滚动转录；`UYA_AGENT_TUI=0\|1` 同口径 |
| `--tui-demo [WxH]` | 打印 TUI 若干屏的纯文本快照后退出（诊断 + 文档；也是 markdown 排版与浮层全屏的自测基准） |
| `--web [ADDR]` | **web 界面**：起一个本地 HTTP 服务，浏览器里用（默认 `127.0.0.1:8787`；`127.0.0.1:0` = 内核分配端口；`UYA_AGENT_WEB=1` / `UYA_AGENT_WEB_ADDR` 同口径）。每个会话是一个**真 PTY 上的 agent 子进程**，跑的就是全屏 TUI；见 §1.3。**会话继承父进程的命令行配置**（`--permission` / `--workspace` / `--agent-home` / `--base-url` / `--model` / `--tls-*` …）；少数没有环境变量口径的开关会由启动日志逐条点名 |
| `--title` / `--no-title` | 交互模式把**终端标题**写成当前会话标题（**默认开**） |
| `--title-auto` / `--no-title-auto` | 让**模型给会话起标题**（**默认开**）。一条会话只起一次：首次提示词之后、第一个 step 跑完就在回合里发那一个小请求（收尾不更新标题） |
| `--mouse` / `--no-mouse` | TUI 的**鼠标上报**开关（**默认开**，滚轮要靠它）。`--no-mouse` 让终端重新接管拖选 ⇒ **能选中文字复制**（同时失去滚轮翻转录，改用 `ctrl+↑/↓` 或 `pgup/pgdn`）；运行中还有 `F2` 与 `/mouse on\|off` |
| `--color=MODE` | `auto`（默认）/ `always` / `never` / `16` / `256`；`NO_COLOR` 也认 |
| `--tls-verify=tofu\|chain\|pin\|none` | TLS 信任策略，**默认 `tofu`**（首次记录 leaf 指纹、之后强制相符），见 §4 |
| `--tls-pin HEX` | `pin` 模式要求的 leaf 证书 SHA-256（小写 hex） |
| `--tls-debug` / `--http-debug` | 保留 `lib/tls` 的握手调试输出 / 打印每轮响应的头与体首字节 |

### 1.2 斜杠命令

`/help` `/status` `/tasks [open|close|toggle]` `/goal [<objective>|edit <objective>|pause|resume|clear]`
`/compact` `/plan` `/permission [预设]` `/model [名字|提供方/名字]` `/effort [档位]` `/workspace [目录]`
`/worktree [on|off|start|status|finish|discard|list|reclaim]`（TUI 里裸命令开**动作选择框**，
打开就回车 = `status`；`finish`/`discard` 选定后再过一道确认，`reclaim` 只清确定的垃圾、不确认）
`/sessions` `/resume <id>` `/new` `/continue` `/diff` `/title [新标题]` `/image [路径]`
`/paste` `/fullscreen [on|off]` `/mouse on|off` `/exit`（`/quit` 同义）。

### 1.3 web 界面（`--web`）

```bash
uya-agent --web                    # http://127.0.0.1:8787/
uya-agent --web 127.0.0.1:9000     # 指定端口（端口写 0 = 内核分配，启动时打印真实端口）
```

页面上：

* **顶栏**：一条会话一个标签，标签上是**会话标题**（模型 `set_title` / `/title` 起的 →
  兜底用首条人类消息的前 3 个词 → 再兜底「会话 N」）；标题栏**最右边是 `+`**，点它新建会话。
* **标题下面是该会话的终端**：那就是**真 TTY** —— 键盘、`tab` 切计划、`/status` 浮层、
  `esc` 打断、`↑/↓` 历史都与在终端里跑一模一样（因为服务端跑的就是同一个全屏 TUI，
  只是外面套了一层 PTY）。**中文可以直接输入**：页面里有一个透明的代理输入框接输入法
  （候选期间不上屏、回车确认候选词不会被当成提交），粘贴走括起粘贴（粘多行只出现换行，
  不会一行提交一次）。
* 标签上的 `x` 结束该条会话；最多同时 8 条。新建的会话**按你浏览器窗口的尺寸**起
  （页面把量到的格子数报给服务端），所以第一个画面就是对的宽度。
* **`/exit`（或 `ctrl+d`）之后标签自动消失**，页面自动切到剩下最后一条；服务端顺手把
  那条会话的子进程收掉。

**已知限制**（都写进 §7）：

* **没有任何认证**，默认只绑 `127.0.0.1`。用 `0.0.0.0:PORT` 是**显式**决定，启动时会打警告。
* **没有 HTTPS**（本地单用户够用）。
* 终端解释器是**白名单**实现（只解这个 TUI 实际会发的那些序列），所以它是"够用"的而不是
  通用终端：在里面跑一个需要滚屏区/字符集切换的全屏程序不会正确显示 —— 但 `uya-agent`
  自己的 TUI 与它的 `bash` 工具不受影响。
* 图片附件（`/image`）会显示在正文里；**文本粘贴**（浏览器原生 `ctrl+v`）可以把剪贴板
  文本插进输入行（走括起粘贴）。服务端那侧的剪贴板（图片附件、`/paste`）请回终端用 ——
  那是纯 Uya 的 X11 客户端，只在服务端有 X 连接时才有意义。
* 会话子进程（那条 TUI）**正常退出**（`/exit` / `ctrl+d`）时标签自动摘掉；若是**崩掉/
  被杀**的，标签**留着**、屏幕上是它的最后一帧，点标签上的 `x` 把它摘掉。判据是服务端
  已经关掉 master、回收子进程（P69 修掉的那条「子进程死了之后主循环空转、页面上打不进字」
  见 DESIGN §16 踩坑 105；「`exit` 之后标签不关」见踩坑 115）。
* 实时刷新按**帧**推：文本变、光标动（在输入行里按 ←/→ 只动光标）、**选中项移动**
  （只有样式变、一个字符都不改）都会推；真的什么都没变就一个字节都不发。同一会话开多个
  页面都收得到（P70 修掉的那条「首帧之后页面再也不刷新」见 DESIGN §16 踩坑 106；
  「按键选择后没有高亮」那两个叠在一起的原因见踩坑 113；「关掉前面一条会话后剩下的
  标签不动了」见踩坑 114）。
* 输入分**两条路**：控制键/功能键走按键事件（ESC 序列），可打印文本（含中文）走那个
  透明代理输入框的 IME 事件 —— 中文与表情因此都能输入（踩坑 116）。
* 新建会话的尺寸是**页面报上来的**（`POST /api/sessions?cols=&rows=`）：不会先起一屏
  100 列的界面（踩坑 117）。

---

### 1.4 环境变量

`UYA_AGENT_BASE_URL`、`UYA_AGENT_MODEL`、`UYA_AGENT_WORKSPACE`、
`UYA_AGENT_MAX_STEPS`（步数熔断上限，`0` = 不限，也是默认值；非法值告警后按「不限」处理）、
`UYA_AGENT_API`（非法值告警后按「未声明」处理，即仍会先试 responses）、
`UYA_AGENT_REASONING_EFFORT`（`off`/`none` = 不发）、
`UYA_AGENT_CONTEXT_WINDOW`（压缩判定的上下文窗口，纯十进制正整数；非法值告警后忽略）、
`UYA_AGENT_INPUT_IMAGE=1\|0`（模型收不收图；**默认支持**，只有 `=0` 才关 ——
认不出的一律告警后忽略，绝不静默当开）、
`UYA_AGENT_EXEC_EFFORT` / `UYA_AGENT_EXEC_AFTER` / `UYA_AGENT_GRACE_STEPS`、
`UYA_AGENT_API_RETRY_MAX`（同 `--api-retry-max`：`0` = 不重试）、
`UYA_AGENT_PERMISSION`（三档访问模式，非法值告警后忽略）、
`UYA_AGENT_SANDBOX`（`0`/`off` = 等价于 `--no-sandbox`）、`UYA_AGENT_BWRAP`（bwrap 路径）、
`UYA_AGENT_TITLE` / `UYA_AGENT_TITLE_AUTO`（`0` = 关，其它非空值 = 开；CLI 优先）、
`UYA_AGENT_MOUSE`（`0` = 关鼠标上报、可直接拖选复制；CLI 优先）、
`UYA_AGENT_MCP`（`0` = 不读不连 MCP 插件，等价 `--no-mcp`）、
`UYA_AGENT_WEB_TLS_VERIFY` / `UYA_AGENT_WEB_TLS_PIN`（搜索主机的信任策略，默认继承 cfg）、
`UYA_AGENT_DNS`（**显式指定 DNS 解析器**，`IP` 或 `IP:端口`，例如 `1.1.1.1` 或
`127.0.0.53:53`；不写时本进程自己**整份**读 `/etc/resolv.conf` 取第一个 IPv4 的
`nameserver` —— **改文件/要 root 不再是排障的前提**，`--print-config` 的 `dns = …`
会打印实际会用的那一台与它的来源）、
以及 key（三选一）：`UYA_AGENT_API_KEY` / `DEEPSEEK_API_KEY` / `OPENAI_API_KEY`。

**退出码**：`0` 成功 · `1` 用法/配置错 · `2` 传输错（DNS/TCP/TLS/超时）· `3` 模型或协议错
（**只在你显式给了 `--max-steps N` 时**才包含「步数熔断」）· `4` 工具/工作区错 ·
`5` **模型输出到达 token 上限被截断**（`finish_reason=length`）：这一轮没跑到最终答复，
但**不是错误** —— 截断前的正文已经留在对话里，`--continue` 之后发一句「继续」即可接着做
（工具调用一律丢弃：参数可能是半截的）。交互形态（REPL / TUI）里不按「异常」处理。
退出码 2 这类失败**会自己说清是哪一段坏的**：名字没解开（DNS）会说域名、用的哪台解析器、
为什么（超时/拒绝/文件里没有 nameserver 行…）以及 `UYA_AGENT_DNS` 这条自救路；
TCP 连不上会打出目标 `主机:端口`；TLS 握手失败再单独一档。三种情形以前共用一句
「请求失败（网络或 TLS 校验）」，等于把答案丢掉（见 DESIGN §16 踩坑 133）。

> `2` / `3` 现在只在**重试预算用尽**时才会出现：瞬时失败（连接不上、5xx、限流、流早断）
> 先退避重发，默认不限次数，直到成功或你中断（`--api-retry-max 0` 可关掉重试，让脚本
> 立刻拿到旧行为）。**失败种类不因重试而混同**：传输错始终是 `2`、非 200/协议错始终是 `3`。

---

## 2. 工具

模型可调用的 29 个工具（顺序固定，跨模式恒定可见）：

| 组 | 工具 |
|---|---|
| 文件 | `read` `write` `edit` `glob` `grep` |
| 执行 | `bash` `job_list` `job_output` `job_kill`（`--no-shell` 时整组不出现） |
| 会话与交互 | `workspace` `worktree` `set_title` `todo_write` `exit_plan_mode` `ask_user_question` |
| 技能与搜索 | `skill` `uya_notes` `web_search` |

`uya_notes`（P63）返回 **Uya 语言速查表**：入口与打印、显式类型（没有 `let`/`mut`/`i++`）、
只有 `while` 没有 `for`、`!T` 错误处理与 `defer`、定长数组与结构体字面量、build/check 命令。
它**原来是一节 system 提示词**，每轮请求都要付那 467 B；现在只在模型真要写 / 改 `.uya` / `.ush`
时按需取 —— 每请求净省 ~224 B（system 少 469 B、工具表多 245 B）。工具是只读、零参数的，
read-only 与 plan 模式下照常可用。
| 子代理 | `subagent` `subagent_fork` `list_agents` `subagent_output` `send_message` `interrupt_agent` `ralph` |
| 目标 | `create_goal` `get_goal` `update_goal` |
| 编排 | `workflow` |
| 插件（P70） | `mcp`（元工具：看/重载插件状态）+ 每个 MCP 插件自己的工具（配了才出现） |

每个工具的参数与结果形状见 [DESIGN.md §6.2](DESIGN.md)；
实现要点（路径守卫、版本守卫、bash 的进程与标记、glob/grep 的上限）见
[DESIGN.md §6](DESIGN.md) 与 [§17](DESIGN.md)。

### 2.1 插件（MCP）

**MCP server 就是插件，可以用任意语言写** —— Uya、Python、Node、shell，或者别人发布好的
现成 server。宿主只认 stdio 上的一问一答 JSON，不关心对面是什么。

为什么选 MCP 而不是自造一套协议：**DSH 自己的进程外插件路径就是 MCP**
（`@deepseek-ai/dsh-mcp-client`），所以同一份配置、同一个 server，DSH 与本仓都能吃；
自造一套只会多一层适配，还拿不到生态。协议细节见 [DESIGN.md](DESIGN.md) 的「插件系统」一节。

配置（三种挑一种，都能直接跑）：

```bash
# ① 命令行：SPEC = name=command [args…] [K=V…]
uya-agent --mcp-server "fs=npx -y @modelcontextprotocol/server-filesystem ."

# ② $DSH_HOME/settings.yaml（字段与 DSH 逐字相同，一份配置两边都能用）
#   uya-agent:
#     mcp:
#       fs:
#         transport: stdio
#         command: npx
#         args: ["-y", "@modelcontextprotocol/server-filesystem", "."]

# ③ <projectRoot>/.dsh/mcp.json（生态通用 mcpServers 形状）
#   {"mcpServers":{"fs":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","."]}}}
```

先看装上了没有（每个 server 一行结论；失败会说明为什么）：

```bash
uya-agent --list-plugins
```

三条要知道的口径：

| 事项 | 说明 |
|---|---|
| 工具名 | 模型看到的是 `mcp__<serverName>__<原名>`；非法字符换成 `_`，名字太长（或发生过替换）时截到 51 字符再补 `_` + 12 位 sha256。**与 DSH 同一套规则**，所以同一个 server 在两边叫同一个名字 |
| 权限 | `read-only` 下一律拒绝（且钩子不跑）；`workspace-write` 每次调用问你一次 + bwrap 沙箱；`danger-full-access` 放行。`command` **不做 PATH 查找** |
| 失败 | server 崩了 / 超时 / 回非法 JSON，都是一句**工具结果文本**（与 `bash` 工具同口径），不会把整轮打断 |

**三种语言的可跑示例**在 [`examples/mcp-plugins/`](examples/mcp-plugins/)：
`wordcount.ush`（Uya）、`greet.py`（Python）、`echo.sh`（POSIX shell）——
同一件事的三种实现，可以直接照着写自己的。

`--no-mcp`（或 `UYA_AGENT_MCP=0`）完全不读不连插件；一份 server 都没配时，
工具表与没这个功能时**逐字节相同**。

#### 接本机 aigw（ai-gateway）的 MCP

aigw 自己就是 MCP server（`aigw mcp-serve`：11 个查询工具；令牌 scope 是
`admin_read`/`admin` 时另有 3 个后台入口）。有一个**必须知道**的坑：它读的
是**它自己那份** `config.yaml`，而那里 `database.path` 多半是相对路径
（`./data/aigw.db`）—— 所以要么把子进程的 cwd 定在 aigw 部署根，要么用
`GW_DATABASE_PATH` 给绝对路径。两样都没有时，它会按**当前工作区**去开库，
于是报 `account not found`（或建出一个空库、一个工具都登记不上），
而症状只是「配了 server 却没有工具」。

```bash
# ① CLI：用 GW_DATABASE_PATH 钉住（--mcp-server 没有 cwd 语法）。
#    K=V 形状的 token 归 env，所以直接写在 SPEC 末尾即可。
uya-agent --mcp-server "aigw=/media/winger/_dde_data/aigw/bin/aigw mcp-serve \
--config /media/winger/_dde_data/aigw/config.yaml --account local \
GW_DATABASE_PATH=/media/winger/_dde_data/aigw/data/aigw.db"

# ② settings.yaml：用 cwd 指向 aigw 部署根（推荐；配置里不带环境变量）
#   uya-agent:
#     mcp:
#       aigw:
#         transport: stdio
#         command: /media/winger/_dde_data/aigw/bin/aigw
#         args: [mcp-serve, --config, /media/winger/_dde_data/aigw/config.yaml,
#                --account, local]
#         cwd: /media/winger/_dde_data/aigw

# ③ 转发到运行中的网关（走令牌，scope 决定工具面：query 只有 11 个查询工具，
#    admin_read/admin 另有 3 个后台入口）。令牌用「配置里的 env」交给子进程 ——
#    父进程的环境**不会**继承进去（MCP server 是第三方进程，只给白名单
#    HOME/LOGNAME/PATH/SHELL/TERM/USER + 配置显式给的 env）。
uya-agent --mcp-server "aigw=/media/winger/_dde_data/aigw/bin/aigw mcp-serve \
--endpoint http://127.0.0.1:8088/mcp --token-env GW_MCP_TOKEN \
GW_MCP_TOKEN=aigw_mcp_xxx"

uya-agent --list-plugins      # 核对：`aigw: 11 tool(s)`
```

③ 也可以走 settings.yaml（令牌不落在命令行上，推荐）：

```yaml
# uya-agent:
#   mcp:
#     aigw:
#       transport: stdio
#       command: /media/winger/_dde_data/aigw/bin/aigw
#       args: [mcp-serve, --endpoint, http://127.0.0.1:8088/mcp,
#              --token-env, GW_MCP_TOKEN]
#       env: {GW_MCP_TOKEN: "aigw_mcp_xxx"}
```

`--account <name>` 是**本地 stdio 模式**：本机信任、不走令牌，只给 11 个只读
工具（账户名可在控制台看，或 `sqlite3 <db> "select name from accounts"`）。
要用后台工具就用 ③ 的转发模式配一个 scope 够的令牌 —— 令牌明文只在创建时
出现一次，别写进仓库里的配置文件。

接上以后，模型侧的工具名是 `mcp__aigw__get_balance`、
`mcp__aigw__get_dashboard`、`mcp__aigw__list_requests` 这类
（`mcp__<serverName>__<原名>`，同一个 server 在 DSH 里也这么叫）。

---

## 3. 自测与验收

`make selftest` **完全离线**（在 `127.0.0.1:0` 上 fork 一个纯 Uya 写的 mock LLM），
跑真实 agent 循环并逐项断言；`make e2e` 打真实网关。

```bash
make selftest              # 全量：清缓存重编 + link-audit + codegen-audit + doc-audit + 全部离线轮次
make tui-selftest          # 分域快速轮：只跑 TUI
make sess-selftest         # 只跑 /sessions 与大日志
make diff-selftest         # 只跑 src/diff/
make web-selftest          # 只跑 web 界面（服务端终端解释器 / HTTP 侧 / 页面 / 分派语义 / PTY 收口 / 段表单位 / 新建尺寸 / 退出收摊）
make pm-selftest           # 只跑 src/pm/（项目记忆）
make e2e-memory-live       # 项目记忆的**真机接线**：跑真二进制，断言分片真的落盘
                           # （带真 stat 锚点）+ 跨会话注入 + 改→STALE + 删→GONE
                           # （纯函数自测覆盖不到接线层，见 DESIGN §16 踩坑 129）
make mcp-selftest          # 只跑 src/plugin/（MCP 插件：公开名 / 握手 / 派发 / 降级）
make UYA_SELFTEST_ONLY=x,y # 只跑指定的几轮
```

**逐轮覆盖点**（§19 的轮次表共 **171 行 / 170 个不重名**的轮次 —— `tui-model` 记了两条）
见 [DESIGN.md §19](DESIGN.md) —— 那里也是**逐阶段的验收记录**
（P1–P76 的 before/after 命令、真机对照实验、被自测当场抓住的自身缺陷）。

**验收纪律**（改完必须做，见 [CODING.md §5](CODING.md)）：

```bash
rm -rf build && make build      # 清缓存重编：函数表敏感的改动只有这样才看得出来
make check                      # 类型检查（看「AST 合并完成，共 N 个声明」）
make selftest                   # 离线端到端
```

**换编译器**：`make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...`
（0.11 与本仓的差异见 [DESIGN.md §15.1](DESIGN.md)）。

---

## 4. TLS 信任策略

`lib/tls` 是**真 TLS 1.2 客户端**，但它的**链校验在真实站点上根本不可用**（`ctx.peer_leaf`
恒为 NULL —— 详见 [DESIGN.md §18](DESIGN.md)），所以本项目在 agent 侧提供四档策略。

**默认档是 `tofu`**（Trust On First Use）：第一次连某主机就把它的 leaf 证书 SHA-256 记进
`<agent home>/tls_pins`，之后每次都必须逐字节相符，不符即拒。**开箱即用**，不需要 CA 库、
也不需要人手抄指纹 —— 新机器（没有 DSH 设置）第一次跑就能连上，同时还有中间人防护。

要更强的保证（指纹完全由你定）就先探一次再钉死：

```bash
./build/uya-agent --probe --tls-verify=none                 # 记下 leaf_sha256
DEEPSEEK_API_KEY=sk-xxx ./build/uya-agent \
  --tls-verify=pin --tls-pin 30d82529d19c5da6175a80db1c5522ac3ba5b42589212405cdc8783a1bf047fa \
  "创建 hello.uya，编译并运行它"
```

四档的语义、为什么 `chain` 在真实站点上**必然**失败（三条标准库缺陷，逐条实测）、
leaf 指纹怎么算、指纹库放哪儿 —— 见 [DESIGN.md §18](DESIGN.md)。

本地明文端点（ollama / llama.cpp 的 OpenAI 兼容接口）不走 TLS，直接
`--base-url http://127.0.0.1:11434/v1` 即可。

---

## 5. 配置来源

三个来源，**优先级从低到高**：DSH 设置文件 → 环境变量 → 命令行。

| 来源 | 位置 |
|---|---|
| DSH 设置 | `$DSH_HOME/settings.yaml`（模型路线 / 权限 `defaultPreset` / 技能根 / preset 旋钮）、`.credentials.yaml`（凭据）、`.env` |
| **本仓自己的设置** | 同一份 `settings.yaml` 的 `uya-agent:` 节 —— 目前只有 `contextWindows:`（模型 → 上下文窗口，见 §7） |
| 环境变量 | `UYA_AGENT_*`（见 §1.3） |
| 命令行 | `--xxx`（最高优先级） |

`--print-config` 会把**生效值与来源**一起印出来（每个取值带 `cli` / `env` / `dsh-settings` /
`uya-agent` / `default` 标签）—— 这是「配置到底生效了没有」唯一可证的出口。
`--dsh-home` / `--dsh-root` / `--no-dsh-config` / `--strict-dsh-config` 在**读设置之前**预扫，
所以它们不会被设置覆盖；`--no-dsh-config` 时 `uya-agent:` 那一节（连同模型目录）**都不读**。

---

## 6. 能力细节索引

| 想了解 | 去哪 |
|---|---|
| 启动顺序、主循环、step 边界检查、历史模型 | [DESIGN.md §3](DESIGN.md) |
| 传输栈、SSE、两种线协议、协议协商、错误分层 | [DESIGN.md §4](DESIGN.md) |
| system prompt 分节 / 剪枝 / 压缩 / 退化响应 / 执行期纪律 / 技能 | [DESIGN.md §5](DESIGN.md) |
| 工具契约与实现要点 | [DESIGN.md §6](DESIGN.md)、[§17](DESIGN.md) |
| 权限三级 / bwrap 沙箱 / 三道写闸门 / 审批通道 | [DESIGN.md §7](DESIGN.md) |
| 会话日志格式、崩溃裁剪、索引、恢复数据流 | [DESIGN.md §8](DESIGN.md) |
| 子代理 / goal / todo / plan / workflow / 任务面板 | [DESIGN.md §9](DESIGN.md) |
| Git worktree 与残留回收 | [DESIGN.md §10](DESIGN.md) |
| TUI 架构（单线程 + 泵点）、帧、键位、浮层、markdown | [DESIGN.md §11](DESIGN.md) |
| `/diff` 浮窗与写工具 diff 正文 | [DESIGN.md §12](DESIGN.md) |
| 图片附件（内联 base64）与剪贴板（X11 客户端） | [DESIGN.md §13](DESIGN.md) |
| 全部上限常量与不变量清单 | [DESIGN.md §14](DESIGN.md) |
| 明确不做的事 | [DESIGN.md §15](DESIGN.md) |
| 用 Uya 写这类程序踩过的坑（95 条） | [DESIGN.md §16](DESIGN.md) |
| 逐阶段验收记录与对照实验 | [DESIGN.md §19](DESIGN.md) |
| 代码结构（按域的文件地图） | [DESIGN.md §2](DESIGN.md)、[CODING.md §1](CODING.md) |

---

## 7. 已知限制

本节保留在 README（改动频繁、与使用者直接相关）；**详细设计理由**见
[DESIGN.md §15「边界：明确不做的事」](DESIGN.md)，那里按「架构 / 会话与界面 / markdown /
协议与模型 / 平台」分组，并给出每一条**为什么不做**。

按主题列出「做不到 / 故意不做 / 边界在哪」。

**会话与界面**

* **web 界面（`--web`）没有任何认证，也没有 HTTPS**：默认只绑 `127.0.0.1`；
  `--web 0.0.0.0:PORT` 是**显式**决定（启动时会打一行警告）。同一个用户在自己机器上用，
  不做多用户/权限隔离。
* **web 的终端解释器是白名单实现**：只解 `uya-agent` 自己的 TUI 实际会发的那些序列
  （光标定位 / 清屏 / 清行 / SGR / 备用屏幕 / 鼠标上报 / 括起粘贴 / 终端标题）。
  所以它是"够用"而不是"通用终端"——在里面跑一个需要**滚屏区、字符集切换、sixel/kitty
  图形协议**的全屏程序不会正确显示。`uya-agent` 自己的 TUI 与它的 `bash` 工具不受影响
  （后者本来就没有终端）。**为什么不引 xterm.js**：它要么走 CDN（而自测是离线的），
  要么把几十万行压缩 JS vendored 进仓 —— 与「只用 Uya 源码实现」冲突；而且解释器放在
  服务端才能吃到本仓最贵的那条判据（见 DESIGN §11.8.2）。
* **web 端不做「读服务端剪贴板」那种粘贴**（终端的 `ctrl+v` / `/paste`）：那几条来源
  读的都是**跑着服务端的那台机器**的剪贴板（终端协议那条尤其：web 子进程的 stdin 是
  服务端自己持有的 PTY，没有「用户的终端」），所以图片附件贴不进来，请回终端用。
  **浏览器自己的剪贴板**（原生 `ctrl+v`）可以把文本插进输入行 —— 走 IME 代理输入框，
  包成括起粘贴。图片附件（`/image`）会正常显示在正文里。
* **web 最多同时 8 条会话**（`WEB_MAX_SESSIONS`），每条一个子进程 + 一块终端网格
  （约 2.3 MiB）。

* **换会话只换「当前会话的」那段屏幕**：TUI 里 `/new`、`/resume <id>` 会把转录清成
  「只剩新会话」（`/resume` 再把历史回放一遍），但滚动模式（`--no-tui`）不重画 —— 那边的正文是
  终端自己滚出去的。回放复用启动时那一份口径（最近 200 条 + 一条「更早的会话记录已省略」提示，
  注入类消息不回放），所以换会话后的屏幕与 `--resume` 起一个新进程是同一份。
* **会话目标与自动续跑（P58）**：`goal.json` 里的 `phase=active` + 授权 = 会自动开下一轮。
  四条硬边界：① **只在有人看的前台会话里跑** —— 管道 / CI / 子代理不驱动（那儿没人叫停，而每一轮
  都是真的发请求）；② **用户一动键盘就让行**（TUI 里 fd 0 上还有待读字节就不驱动，滚动模式先驱动
  一轮再等输入），按了退出/中断也不会再开新轮；③ **授权不跨进程** —— `/new`、`--resume`、fork 之后
  目标还在盘上但自动续跑停着，接着跑要人明确 `/goal resume`；④ **异常不自动重试**：某一轮以网络/
  协议错收场就停下（DSH 同口径），修好后 `/goal resume`。`round >= maxRounds` 时把盘上的 phase
  改成 `blocked` + `blocker=round-limit`（是终态，不是悄悄停下）。**每轮一轮就是一条 `<goal_round>`
  user 消息**进同一个会话（不 fork、不开新 agent），所以历史会一直长 —— 长目标仍要靠 `/compact`。
  `send_message` 时的任务或催促，只取首行、空白折叠、超长贴尾）；子代理的 stdout **只在跑完时**
  才回传管道，所以「它刚刚说了什么」得等终态或 `subagent_output`（面板上那个 `· N` 是已收输出
  行数，运行中通常是 0）。贴尾只收窄**显示**，`Deleg.prompt` 本身一个字节不动。
* **`/watch` 的实时粒度是「事件」，不是 token 级**：它读的是子代理的会话日志，而
  `assistant/reasoning` 与 `assistant/message` 都在**步末**才落盘 —— 所以单个长 step 内部
  （模型正在流式吐字的那几秒到几十秒）日志不增长，屏幕上不会长出新行。那段时间能看到的实时
  信号是「正在跑哪个工具」（`tool/call` 在工具**执行前**写）以及面板上的秒数。想逐字看流式，
  只有在前台跑（交互模式）才有。
  另外：`/watch` 是**进程状态**（`--resume` 不回填）；被跟随的子代理跑完或槽位被回收时跟随自动
  结束；`ralph` 跟随的是**当前轮**的日志，换轮时插一行 `[轮次切换]` 并从新日志头开始读。
* **回合运行中的界面命令**：只读命令（`/status`、`/help`、`/tasks`、`/memory`、`/sessions`、
  `/goal`、`/diff`、`/watch`（**含** `/watch sub-N`））在每个泵点当场派发并当场画一帧；`/model` 与
  `/effort`（裸命令开浮层、`/model <名字>` 这类带参形态都算）同样在泵点当场生效 ——
  它们在浮层里选完/敲完就改状态并落一条 `session/model`，**下一个 step 的请求**已经是新模型；
  `/title <新标题>` 早已同路。`/new`、`/resume`
  立刻回执并先中断当前回合（历史保留），`/compact` 排 step 边界，`/continue`、`/exit` 与其余命令
  等回合结束（steer 仍是「运行中输入的文本在下一个 step 边界被采纳」）。**插不进泵点的只有两段**：
  DNS 解析（≤5 s）与 TLS 握手（≤`timeout_ms`），都在工具链调用内部。
  仍是**协作式**而非抢占式 —— 没走真线程（工具链分配器不支持两条线程并发 malloc，见
  [DESIGN.md §11.2](DESIGN.md)）。
  两个小口径：明文 `http://` 的请求体写入没有分片泵；等响应头那段按墙上时间判 `timeout_ms`。
* **浮层**：框高上限 16 行（`↑/↓`、`pgup/pgdn`、`home/end` 滚，标题栏 `↑`/`↓` 是溢出指示）；
  浮层画在转录区上，打开时转录被它盖住，esc 关掉就回来。终端高度不够（`panel_top < 5`）时浮层
  画不出来，由 `tui_overlay_available()` 的 fail-closed 语义管（审批不会「看不见却仍吞键」）。
* **浮层全屏只吃转录区**：`ctrl+f` / `F11` 把浮层放大到「终端列数 × `panel_top`」，上限
  （列表 16 行 / reader 与 ask 20 行）随之解除，但**面板、状态区、脚注不参与** —— 不做「盖住整屏」
  的真全屏，也不做鼠标拖拽缩放、鼠标点击边框、每个形态各自记住全屏偏好。全屏只改**画出来多大**，
  不改「画不画得出来」：终端太矮时该回落（提问弹窗回输入行）与 fail-closed（审批）照旧。
  `input` 型（`/title` 输入框）全屏后仍是 4 行高（单行输入的语义），全屏给它的是宽度。
  `/diff` 本来就占满转录区，全屏态对它无意义。滚动模式没有浮层，`/fullscreen` 只回一行说明；
  `/fullscreen` 与快捷键都不进历史、不改会话。
* **TUI 不做**鼠标点击/拖选/选择（滚轮做了）、可折叠卡片、分屏、主题切换 UI。
  **图片**能挂给多模态模型（`/image` / `ctrl+v` / `/paste`），但**终端里不渲染** —— 屏幕上只有
  一行占位（格式 + 宽高 + 大小 + 文件名）。收不收图按 §7「图片能力位」那条链（**默认支持**：
  纯 env 路线零配置可挂图；目录写了 `input: [text]` 或 `--no-input-image` 才关）。超预算的
  **JPEG 会自动缩小**（DESIGN §13.1.1），PNG/GIF/WebP 仍只能拒（纯 Uya 没有 zlib，
  也没有这三种格式的编码器）。
  但**「选中文字复制」是终端自己的事**：TUI 默认开着鼠标上报，一开终端的拖选就被我们吃掉 ⇒
  想拖选复制得按 `F2` / `/mouse off` 关掉（或开着时按住 shift 拖选）。
  `--resume` 只回填最近 200 条历史（注入类消息不回填），`--resume-dsh` 走同一条回填路径。
  终端小于 32×8 时自动退回滚动模式；`cols < 66` 时块字 logo 退化成一行标题。
* **滚动模式（`--no-tui`）**是纯文本字形、不做 markdown 渲染；TUI 有颜色 + markdown 渲染。
  滚动模式下每次工具调用只有一行（正文要看就得 `--tool-lines N`），思考同理：
  **非交互（管道）下没有实时行**，只有块结束时落的那一行。
* **markdown 渲染的边界**：不做代码**语法高亮**、引用式链接 `[x][ref]`、脚注、HTML 块、
  自动链接 `<url>`、setext 标题；换行仍是「一个逻辑行一段」，不做 CommonMark 的软换行合并。
  表格单元格**不折行**，列数 > 8 或收不下时**整块退回普通行**（内容不丢）。
  删除线靠终端的 SGR 9。助手正文与 plan 审阅浮层共用这份渲染；**`/watch` 跟随浮层不套 markdown**。
* **终端标题是 best-effort 的礼貌**：不支持 xterm 标题栈的终端会忽略压栈/弹栈，退出后保留我们
  最后写的会话标题（故意不写空标题）。**会话标题由模型总结**：首次提示词之后、第一个 step
  跑完就在回合里起一次（一条会话只起一次，模型给的结果按 3 词 / ≤45 B = 15 字以内收口），
  首条消息派生的那串「前 3 个词」只在模型起不出来时兜底；`set_title` 工具与 `/title` 手填
  仍可用满 80 B。
* **起标题的三条硬边界**：**首发在回合里**（待办挂在回合入口、第一个 step 跑完的 step 边界发）——
  收尾才发的话，长回合与被打断的回合在 aigw 那边就是**空标题**（踩坑 127）；它是**同步**请求
  （单线程），所以**用户一动键盘就中止自己**（那一轮不更新，待办留给下一次机会），模型一步就
  答完的单步回合则由收尾之后空闲那条路补发（带两段 900 ms 静默）。要彻底关掉用 `--no-title-auto`；
  **非交互（管道/CI）与子代理不跑**；**滚动模式裸 `/title` 只报建议**。
* **`SIGKILL` 之后终端仍可能停在备用屏幕**（不可捕获），用 `reset` / `stty sane` 恢复。
* `ask_user_question` / `exit_plan_mode` 的问答浮层里 `ctrl+c`/`esc` 是「取消这次问答」而不是退出
  程序；要退出先取消（浮层收掉之后 `ctrl+d`）。
* **提问弹窗只有「TUI 且浮窗放得下」这一条路**：终端太矮（`panel_top < 6`）时回落输入行问答 ——
  与审批类浮层**故意不同**（审批是「看不见就不许做」的 fail closed，提问是「换个地方问」，回落
  永远比丢渠道好）；管道 / CI / 子代理仍然只能拿到 `no answer channel`。
  题目一次只画一题（多题逐题弹、标题带 `第 i/共 n 问`）；问题正文按框宽**折行**，选项行仍是
  **一行**；框宽随内容在 `[34, 终端宽−6]` 之间伸缩（**只量内容**）；一题最多 16 个选项、
  最多 9 个数字直选键；自定义回答是**单行**；`space` 只在多选且未进入输入态时是勾选。
  回答语义对齐 DSH：单选自定义回答排他、多选 `selected` 与 `custom` 可同时带、跳过 = 空
  `selected`、取消 = dismissed 文案（与 `no answer channel` 分开）。
* **提问弹窗的自定义回答行有可见插入点**（P63，修「能打字却看不见光标」）：真终端光标在
  「运行中 + 浮层开着」时是被藏起来的（那时键全归浮层），而提问弹窗正是在跑工具时打开的 ——
  所以这一行**自己画一格插入点**（反显，与 `/title` 那个单行输入框同口径）。它在文本之后
  （自定义回答只在尾部追加/退格），未打字时也画。见 [DESIGN.md §16 踩坑 100](DESIGN.md)。
* **提问弹窗的长内容不再跑出框外**（踩坑 81）：正文折行、多行全画，放不下才在末行补 `…`。

**任务状态与目标**

* **任务状态**：已结束的后台任务/子代理**没有时长**（只记了开始时刻）；常驻块**只列运行中**的
  （完整清单走 `/tasks`，子代理另有窗口，不进任务箱体）；刷新是「推」出来的，滚动模式下单个长
  step 期间秒数会停；清单与后台任务/子代理表是**进程状态**（`--resume` 不回填，只有目标在盘上
  `goal.json`、启动时重读）；**清单按会话清理**（`/new`、`/resume` 与启动一样清零），后台任务/
  子代理表随 `/new` 复位，目标跨会话；浮层打开时常驻块被盖住，块不做鼠标交互、点击折叠。
  （**跨会话记忆**是另一套东西，见上面的「项目记忆」与 DESIGN §20。）
* **会话目标**：`goal.json` 是**会话级记录**，同时由**同会话续跑驱动器**消费（P58，对齐 DSH 的
  `goal-round-driver`）：主循环空闲时，`phase=active` 且有授权的目标会自动开下一轮 —— 往**同一个
  会话**追加一条 `<goal_round>` user 消息（不开新 agent、不 fork 历史）。人类命令没有 `complete`
  动词（标完成由模型工具负责），人的手段是 `edit` / `pause` / `resume` / `clear`；
  `/goal clear` 是删文件、没有 tombstone（清掉后 id 从 1 重新开始）；目标按 `agent_home` 落盘，
  与「会话」同一层，所以 `/new` 之后仍是同一个目标，**但续跑授权不跨会话**（见 §7 的续跑条目）。

**模型、工作区与 worktree**

* **模型选择与推理强度**：目录**只读本地 `settings.yaml`**（不远程拉取提供方目录，也不读
  `modelOverrides`）。目录外的模型名**只换名字**（provider / contextWindow / maxTokens /
  compat 一律保持不动，只打警告）—— 静默清空 `contextWindow` 会让自动压缩失效，比「名字换了
  能力没跟上」更坏。`/effort` **不发明档位**：只接受当前模型公布的档位，模型没写
  `reasoningEfforts`（或 `false`）时不开浮层，`--effort` / `--reasoning-effort` 原样透传
  （不 clamp、不报错），`/status` 与 `--print-config` 会标成「不是模型公布的档位」。
  **档位表必须按上游实测填，不要照抄全集**：模型/网关的「支持思考」是布尔的，装不下
  「只认哪几档」——真机 `GLM-5.3-flash` 就只认 `low`/`high`/`max`，`none`/`minimal`/
  `medium`/`xhigh` 一律 400，而网关侧 `degradation: strip` 只标记不剥离，请求照样带出去、
  错误原样透出。写全集等于给用户几个必然失败的选项（见 [DESIGN.md §16 踩坑 112](DESIGN.md)）。
  **切模型不做上下文迁移**：历史原样保留，`{{model}}` 是建会话时求值的，所以 persona 里仍是旧
  模型名。选择进会话日志（`session/model`）但不进索引独立字段；子代理继承父的
  provider/model/强度，但**不能自己切**。
* **上下文窗口**（P81）：压缩与剪枝的判定基准，四档来源从高到低 ——

  | 档 | 来源 | 写法 | `--print-config` 的 source |
  |---|---|---|---|
  | ① | 命令行 | `--context-window N` | `cli` |
  | ② | 环境变量 | `UYA_AGENT_CONTEXT_WINDOW=N` | `env` |
  | ③ | 本仓设置节 | `settings.yaml` 的 `uya-agent.contextWindows` 映射 | `uya-agent` |
  | ④ | DSH 模型条目 | `providers.<p>.models[].contextWindow` | `dsh-settings` |

  一条都没有时**沿用**现有值（一次都没人给过就是 `-1` = 未知）。五条硬边界：
  * ①② 是**显式**的 —— 本会话里谁都不许覆盖，切模型也不动（`/model` 报告里的
    `ctx` 行会显示当前值 + 来源）；③ 压过 ④（映射就是为「目录里没写 `contextWindow`
    的路线」准备的：autodl 那种纯 env 部署连目录都没有，映射照样管用）；
  * 键是 `提供方/名字` 或裸名字，**整串精确匹配**（不做前缀、不折大小写）：同名模型跨提供方时
    用 `提供方/名字` 指定，裸名字是「这一家都这样」的粗口径；
  * 值必须是**纯十进制正整数**（1..999999999）。`256K` / `0x100000` / 负数**一律拒绝**——
    `256K` 那种写法按「读到第一个非数字为止」会静默变成 256，比拒绝坏得多。拒绝的粒度分三处：
    `--context-window abc` **报错退出**（usage）；`UYA_AGENT_CONTEXT_WINDOW=256K` 告警后**忽略**；
    设置里那条**跳过并计数**（`--print-config` 印 `skipped N entry/entries`，启动时也有一行 warning）；
  * **`--model` 与 `--context-window` 的先后顺序无关**（定稿在所有 CLI 解析之后做一次）。
    以前是「谁在后面谁赢」：`--context-window 99999 --model m` 会把刚给的值换成目录里的值；
  * `--no-dsh-config` 时 ③④ 都不读（与模型目录同一条口径）；`-1`（未知）时自动压缩不触发
    （`floor(window × 0.8)` 恒 0），剪枝走「保守剪」那一支 —— 所以窗口配错是**静默**的行为变化，
    这也是给它一个可证出口的原因。
* **人的出口是 `/model` 报告的那一行 `ctx`**（`--print-config` 是机器那一侧）：切到一个既没写
  映射、目录条目也没写窗口的模型时，它会明确说「沿用上一个模型的值」——沿用可以，但不说等于
  让人以为配置生效了。
* **图片能力位**（P84）：`/image`、`ctrl+v`、`/paste` 收不收图，口径是「**默认支持**」——
  出厂就是开，只有**明确说不支持**才关：

  | 档 | 来源 | 写法 | `--print-config` 的 source |
  |---|---|---|---|
  | ① | 命令行 | `--no-input-image` / `--input-image` | `cli` |
  | ② | 环境变量 | `UYA_AGENT_INPUT_IMAGE=0\|1` | `env` |
  | ③ | DSH 模型条目 | `input:` **存在**但不含 `image`（如 `[text]`） | `dsh-settings` |
  | ④ | 以上都没有 | —— | `default`（**支持**，就是出厂值） |

  * **纯 env 部署不用配任何东西**：`UYA_AGENT_MODEL=my-vlm` 这种路线（目录里连这条都没有）
    直接就能挂图 —— 这正是加这一档的起因；
  * ①② 是**显式**的：本会话里切模型也不动它（`=0` 能把目录里乐观的 `true` 压回去 ——
    网关不认图时用这个，免得每挂一张吃一个 400）；
  * ③ 是**新增的一半**：以前这一位只会被写成 `true`、从不清零，于是切到纯文本模型照收图，
    收下的**必然 400**（见 [DESIGN.md §16 踩坑 143](DESIGN.md)）；
  * **信息不足一律当支持**：条目**没写** `input:`（与「写了不含」是两件事）、目录里没这个名字、
    `--no-dsh-config`、设置读不到 —— 全部沿用现状。沿用可以，但**不许静默**：`/model` 会印
    `image  on  (source: default，没有声明过（默认支持）)`，关掉时还会带上怎么打开；
  * 代价（故意选的）：模型真不吃图时拿到的是网关 **400**，不是本地那句拒绝 ——
    出口就是 ①② 与目录里写 `input: [text]`，拒绝话术与 `/model` 的 `image` 行会点名它们；
  * `--print-config` 印 `input_image = true|false  (source: …)`（与 `context_window` 同形）。
* **人切完的选择会写回 DSH 设置**（P71）：`/model <名字>` 与 `/effort <档位>`（含 TUI 浮层里
  选中）成功之后，把 `provider` / `model` / `reasoningEffort` **三样一起**写回
  `$DSH_HOME/settings.yaml` 的 `agent-default-model` —— 于是**下次启动**的默认就是刚选的这条
  路线。这与 DSH 自己的行为一致（它的 `selectModel` 会调 `agentDefaultModel.saveSelection`）。
  四条纪律：
  * **只改那三行**：注释、`!!js` 行、块标量、别的节（`llm-pi-ai` / `permission` / `ui-theme`…）
    逐字节不变；**叶级替换**，行数都不变。写前会自己解析一遍并核对三项值，不过就不写。
  * **原子提交 + 跨进程写锁**（与 DSH 的 `dsh-atomic-write` 同一协议）：`<file>.lock` 独占创建，
    抢不到就**让位**（DSH 正在写是正常并发），临时文件 + rename 覆盖，别人的锁**绝不删**。
  * **写失败不回滚**：那只是「下次启动的默认」没跟上，本次会话的选择照常生效；原因有一行回执。
    「文件里本来就是这份选择」与「用户显式关掉」两种情况**不留回执**（那是噪音）。
  * **边界，一律不写**：`--model` / `--effort`（命令行是**一次性**的，与 DSH 的 entry-point
    同口径）、`--resume` 的会话记录、`--exec-effort` 自动降档、`--no-dsh-config`、
    `--no-dsh-writeback`（`UYA_AGENT_DSH_WRITEBACK=0` 同口径）。设置文件是 flow 写法
    （`agent-default-model: {…}`）时**拒绝并留一行说明**（不猜、也不整份重写）；目录里没有
    `settings.yaml` 时**不替你新建**。
* **同名模型按「提供方 + 名字」选**（P62）：DSH 的模型 id 通常全局唯一，但两家提供方发布**同一个
  id** 是合法的（真机 `DeepSeek-V4.1-Flash` 就同时挂在 `aigw-local` 与 `autodl-api` 下）。这种
  情况下「模型」是一个**二元组**，所以：
  * `/model` 浮层每行都标出提供方（`✓ <名字> · <提供方>  effort: …`），`✓` **只挂在当前那一
    条**上 —— 同名两行不会都像「正在用的那个」；
  * 浮层里选中哪一行就切到**那一行那一家**（不再拿当前提供方去反查 —— 那会把「选另一家的同名
    模型」解析回当前条，然后被幂等吞掉，表现为「回车之后什么都没发生」）；
  * 文本与命令行用 **`提供方/名字`** 指定：`/model autodl-api/DeepSeek-V4.1-Flash`、
    `--model autodl-api/DeepSeek-V4.1-Flash`。拆分只在**这一对确实在目录里**时才认，所以
    `Qwen/Qwen3-32B` 这类 id 自带 `/` 的模型名不会被误拆成提供方；
  * 只给名字时用**当前提供方**，并在回执里点出「另有提供方发布同名模型：<那几家>」以及
    `提供方/名字` 的写法 —— 同名歧义不静默。切模型本身仍走上面那条「连端点与凭据一起跟随」；
  * **显式优先**：`--provider P` / `/model P/名字` 给过的 P 不会被「跨提供方按名字回退」换掉
    （P 下没有这个名字时按目录外的老口径处理：只换名字，能力与端点保持 P 的）。
* **切模型会连端点与凭据一起跟随**（P37）：目录故意不存 `baseURL`（存了就要把凭据链复制成
  第二份），所以换提供方时**重新解析**那条路线 —— `base_url` / `apiKeyEnv` 解出来的密钥 /
  `api` 线协议三样一起换，并**逐 step 重建请求头**（否则 URL 走了、`Authorization` 还是旧
  提供方的）。三条硬边界：**显式优先**（`--base-url` / `--api-key` / `--api` 或对应的 env 给过
  的值一律不被覆盖，来源码在 `--print-config` 里印成 `cli`/`env`）；**绝不把旧密钥发给新主机**
  （新提供方解析不出凭据就清空 key 并告警，而不是沿用上一把）；**没声明 `baseURL` 的提供方**
  不动端点，只留一行说明（静默清空比「没跟上」更坏）。`--resume` 跟随会话记录的 provider 时
  走同一条路。见 [DESIGN.md §16 踩坑 96](DESIGN.md)。
* **输出上限总是发**（P61）：`max_tokens`（completions）/ `max_output_tokens`（responses）
  **每个请求都带**，口径是 `--max-tokens` > 模型目录的 `maxTokens` > 默认 **256000**
  （照抄 DSH 自己的 `dsh-llm-deepseek`：`config.maxTokens ?? 256e3`，且它经 `defaultMaxTokens`
  真的会随请求发出去）。**「不发」不再是这条路** —— 不发等于把上限的决定权交给中间那一跳，
  而网关的兜底值往往比模型真实能力小得多：真机现场 `aigw` 的 `default_max_output_tokens: 8192`
  顶上，DeepSeek-V4.1-Flash 写一个大文件时 8192 被思考吃光（网关日志实测
  `output=8192, reasoning=8192`）→ `incomplete/max_output_tokens` → 半截工具调用只能整块丢掉
  （P59），一轮白跑。上限是**上限不是配额**，给大了不会多花钱；实测超过上游能力也不会 400
  （aigw 与 autodl 都照常 200，按真实上限截）。`--print-config` 印的是**线上真正会发的值**与来源。
* **推理强度两条协议都发**：completions 走顶层 `reasoning_effort`（字段排在 `max_tokens`
  之后，保住前缀缓存），responses 走 `reasoning.effort`；`compat.supportsReasoningEffort=false`
  或 `off`/`none` 时不发。此前只有 responses 发，默认路由是 completions ⇒ 配置被静默丢弃
  （见 [DESIGN.md §16 踩坑 67](DESIGN.md)）。
* **`off` 的真实语义**：`off`/`none` 不是「不发字段」，而是按 provider 的映射发线上值 `none`
  （实测：不发字段 755 tok vs 发 `none` 214）。见 [DESIGN.md §5](DESIGN.md) 与
  [§16 踩坑 95 一族](DESIGN.md)。
* 不做 DSH 的 `reasoningEfforts` **模型级 clamp**：`reasoning.effort` 原样透传设置里的值
  （网关不认就 `--reasoning-effort off` 或 `--api=chat`）。
* **Responses 下不回放 reasoning item**（不发 `include: ["reasoning.encrypted_content"]`，
  也不发 `prompt_cache_key` / `prompt_cache_retention`）；历史按「外来消息」重放，只带文本与
  工具调用。工具 schema 不带 `strict`，也不做 404 之外的协议自动探测（换协议请显式 `--api=`）。
* **会话身份照发**（与上面「不发 `prompt_cache_key`」是两件事）：每个请求都带
  `x-deepseek-harness-session-id`（DSH 原样口径）+ `Session-Id`（`~/ai-gateway` 实读的那个）
  两个头，正文再带一份 `client_metadata.session_id`（responses）/ `metadata.session_id`
  （chat）。运行时上下文里另有 `session workspace: "<JSON 路径>"` 机读句。网关据此把请求
  归到一次会话、取到工作区，并把标题调用认成 `call_kind=title` —— 见 [DESIGN.md](DESIGN.md) §15.4。
* **客户身份靠 User-Agent**（P71）：发 `uya-agent/0.1 (deepseek-harness-compatible)` ——
  网关（`~/ai-gateway`）的客户端词表是封闭的 `dsh | codex | console | unknown`，只有
  UA 这条接缝；认不出客户端时它**连工作区一起丢**（那条维度只在 dsh/codex 分支里取）。
  代价：控制台上本仓与真 DSH 同桶。机读句 `session workspace:` 报的是**归类键** ——
  Git worktree 会话折回**主工作区**（否则每个会话一条唯一 worktree 路径，工作区维度会
  退化成会话维度）；人读的 `Current workspace:` 仍是会话真正的路径。
* **起标题的提示词与 DSH 逐字同形**（唯一偏离是词数句「15 字以内」）：system 段以 `Create a concise title for an AI
  coding-assistant session` 开头，user 段以 `Generate the session title from this JSON array
  of human messages:` 开头（后跟人类消息的 JSON 数组），且带**同一个**会话 id —— 网关按
  这两个前缀识别标题行并抓标题。
* **工作区**：「会话现在在哪」= 日志里最后一条 `session/workspace`（append-only、**权威**）；
  header 的 `cwd` 是创建时在哪（不再改写），索引里的 `cwd` 是「最后已知」缓存。恢复时定序
  `--workspace`/env > 最后一条 `session/workspace` > header `cwd` > 当前目录；记录的工作区不存在
  时留在当前工作区、留一行话、记一条 `source:"fallback"`（worktree 合并后就删是常态）。
  `/diff` 的**改动列表范围**仍以仓库根为准，标题写工作区。非全权模式下**模型**切工作区要用户
  逐次批准（等于扩权），没有回答渠道就 fail closed；人敲 `/workspace <目录>` 不再弹审批；
  plan 模式不拦。运行中切工作区是**真 `chdir`**，所以启动时 `--agent-home` / `--dsh-home` /
  `--workspace` 先规范化成绝对路径。`--continue` 仍只接当前工作区里最近一条会话；
  `--resume-dsh` 是导入、记当前工作区。子代理在 spawn 时刻继承父的工作区，父进程之后切
  **不影响**已派生的子代理。切完 `skills` 会按新工作区重扫，但技能目录那条主动消息不补推
  （AGENTS.md 与运行时上下文会补推）。
* **Git worktree**：**是工具层栅栏，不是内核边界**（写闸门只拦 `write` / `edit` 的目标路径与
  bash 里**认得出**的 git 变更子命令；`g=git; $g commit` 认不出来，与 DSH 的 `GIT_MUTATION`
  同一分界，要更硬就配 `read-only`）；不含内核沙箱（bwrap 档仍是那套）；**一个会话一个
  worktree**（不支持并行/嵌套，`finish`/`discard` 只认本会话建的那个，`finish` 后要再来一轮得
  重新 `worktree start`）；**合并策略只有 `merge`（`--no-ff`）**，preset 的 `squash` 没做，
  冲突时中止合并并把主干恢复原状、不做自动冲突解决；**`--resume` 不重建 worktree**（按最后一条
  `session/workspace` 落位，worktree 已被 `finish` 删掉就走 fallback）；DSH preset 自动开是一把
  双刃剑 —— 真机 `agent-presets.default=git-worktree` 会让**每个**新会话都建 worktree，不想要就
  `--no-worktree` 或 `/worktree off`。
* **`/worktree` 的选择框与二次确认**：TUI 里裸 `/worktree` 是**底对齐选择框**，八个动作一行
  一个、`✓` 标当前模式、游标**默认停在 `status`**；带参数的 `/worktree on|off|…` 仍是文本命令。
  `finish` / `discard` 会**删掉目录与分支**，所以选定不生效、先翻第二道确认框且游标默认停在
  「取消」——彩排过：只按回车不会把 worktree 合掉/删掉。`reclaim` 也删目录，但**不翻确认框**：
  它只清「干净 + 零提交 + 没人在用」的确定垃圾。动作的执行结果走**滚动模式同一份**文本，
  所以两条路的措辞永远一致。这是工具层护栏，不是安全边界：模型自己调 `worktree` 工具走的是
  同一条路径，不经过这道确认框。
* **残留回收的边界**：只在**会话退出**与**显式 `/worktree reclaim`** 两处跑，没有后台定时器；
  退出时回收的那条路**只碰本会话自己的 worktree**（不会顺手扫全仓 —— 那是显式动作）；
  **回收「确定垃圾」四条判据缺一不动**（干净 + 零提交 + 没人在用 + 只碰 `dsh/` 前缀），
  详见 [DESIGN.md §10.5](DESIGN.md)。

**协议与模型**

* **步数默认不限**：`--max-steps 0` 是默认值，一直跑到模型给出最终答案（对齐 DSH）。
  只有显式给了正整数才是熔断上限。
* **不发 `temperature`（默认）**：用网关默认值 ⇒ **轨迹是随机的**，A/B 对照要跑 ≥3 发才敢下结论
  （见 [DESIGN.md §5.5.3](DESIGN.md) 的实测与方差）。
* **tool 输出不落盘 spill**：DSH 会 spill，本项目只保留内存尾部 1 MiB（长输出任务的后半段会
  永久丢失）；文件观察表也**不持久化**（恢复会话后要重新 `read` 才能 `edit`）。
* **执行期两条纪律默认关**：`--exec-effort`/`--exec-after`（低思考执行态）与 `--grace-steps`
  （收工预算）默认都不生效；实测方差很大，**结论待测**（见 [DESIGN.md §5.5.3](DESIGN.md)）。
* **传输层重试默认不限次数（P82）**：两条要留意的边界。① **网关彻底挂死时它会一直重试**
  （这正是设计：一次 5xx 不该让整个任务作废，而实测口径下本仓曾因此丢掉本来能解的题）；
  退避期间每 ≤50 ms 服务一次键盘，**esc / ctrl+c / ctrl+d 立刻收口**；CI/脚本里想要
  fail fast 就 `--api-retry-max 0` 或 `UYA_AGENT_API_RETRY_MAX=0`。
  ② **中途断流的重发会在屏幕上留下半截正文** —— 终端没法回退，那一段是失败那次的残影；
  失败那次的正文**不进历史**（所以下一发是干净的、正确性不受影响），转录里会明说
  「上一次失败前已显示 N 字节正文」。分类表（哪些重试、哪些绝不重试）见
  `src/net/retryx.uya` 的文件头与 [DESIGN.md §19.3](DESIGN.md)。

**平台与编译器**

* 目标平台是 Linux x86-64（代码里的 syscall / 常量按这个平台写）。
* **剪贴板有三条来源**（P83，按优先级）：① **终端协议**（kitty 的 OSC 5522，ghostty
  同款）—— **SSH 下唯一能读到你本地剪贴板的路**；② X11 unix socket（本机 X11、
  终端不支持 5522 时用）；③ 外部 helper（Wayland 的 `wl-paste`、macOS 的 `pbpaste`）。
  **读的是哪一块会写在回执里**，SSH 下标明「远端」。局限：终端不支持 5522 时 SSH 里
  贴不了（另两条读的是远端）；不做 OSC 52 读取、不做 5522 的 paste-event 模式、
  不做 tmux/screen 的 DCS 透传。用 `--clip` / `UYA_AGENT_CLIP` 可以钉死来源或关掉。
* 换到 `uya-0.11`：`tls/https.uya`、`std/json/*`、`x509/verify.uya` 与 0.10 逐字节相同，
  但 `libc/syscall.uya`、`std/runtime/runtime.uya`、`tls/ssl/context.uya` 有差异，需要重新验证。
* **文件数上限 64 与函数表容量**（uya 0.10.1 的两条硬约束）：**都已在 0.10.3 解除**
  （输入文件表改为可增长、checker 的五张定长表改动态哈希表）；本仓现在是 113 个构建文件、
  函数可以净增。换/降编译器前先读 [CODING.md §1.2.1 / §6](CODING.md) —— 症状与最小复现都记在那里。
