# /home/winger/uya-agent/Makefile — 仅构建胶水；agent 本体全部是 Uya 源码
#
# 用法：
#   make check      # 只做词法/语法/类型检查
#   make build      # 产出 build/uya-agent（**静态链接**，见下）
#   make link-audit # 核对产物真是静态链接（无 PT_INTERP / 无 NEEDED）
#   make selftest   # 离线端到端自测（内置 mock LLM，无需网络与 key）
#   make probe      # 传输层探针（默认打 api.deepseek.com，期望 HTTP 401）
#   make e2e-diff   # /diff：真 git 的改动列表 + 单列文本回退 + 非仓库报错（离线）
#   make e2e-ws     # 工作区：恢复时跟随会话记录 + 日志不改挂 + 显式优先 + 记录目录被删（离线）
#   make e2e-portable # 拷一个二进制到「新机器」（空 HOME/无 DSH/无仓库）还能跑完整功能（离线）
#   make e2e-dns    # 名字解析：自家解析器（假 DNS + .invalid 域名）与失败时的人话（离线）
#   make e2e-proxy  # 出站代理：穿过假代理到达上游（绝对形式 + CONNECT 隧道），反腿说人话（离线）
#   make e2e-tasks  # /tasks：报告头 / 空态串 / open / toggle / 非法参数（离线）
#   make e2e-tasks-resume # 清单跨进程恢复：一个进程写、另一个进程 --resume 还看得到（离线）
#   make e2e-goal   # /goal：看状态 / 创建 / 拒绝顶掉 / edit / pause / resume / clear（离线）
#   make e2e-sessions  # /sessions 三列 / 最新的在最后一行 / 同 id 取最后一条 / id 完整（离线）
#   make e2e-resume-big # ~3 MiB 会话日志 --resume 不段错误 + 最后一条 workspace 取到（离线）
#   make e2e TASK="..." PIN=<leaf sha256> [STEPS=N]   # 真实调用（需要 DEEPSEEK_API_KEY；STEPS 不给就不限步数）
#   make e2e-watch  # /watch：子代理实时过程消息（真终端 + 假网关，离线）
#   make e2e-steps  # 步数默认值回归（离线，不联网）
#   make clean
#
# 换编译器（例如 0.11，未实测）：make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...
#
# 静态链接：默认开（`STATIC=0` 退回动态）。开关必须落在 Makefile 里，且**只**加在编译
# 那一条命令上 —— 编译器把环境里的 LDFLAGS 透传给它生成的 build/uyacache/Makefile 的
# 链接行（`$(CC) $(OBJS) -o $(UYA_OUT) $(LDFLAGS) -lm`），所以链路是
# Makefile → 环境变量 → 编译器生成的 make → cc。
# 为什么不 `export`（全局）：那样 LDFLAGS=-static 会漏进**所有** recipe 的环境，包括
# `make selftest`（它内部会 fork bash、由 agent 自己去 `uya build` 编东西），等于悄悄
# 改掉别人的编译行为。行内赋值只作用于那一条命令。
# 为什么不用 `?=`：`?=` 对「已定义（哪怕空串）」的外部变量不生效，调用方环境里的
# LDFLAGS= 会把静态吃掉；行内赋值永远覆盖。命令行的 `LDFLAGS=-static make build`
# 同样不算数（下一次不带它就静默换回动态，见踩坑 90）。
# 0.10 文档里的 `LINK_MODE=static` 对本路径**无效**（实测产物仍是 PIE 动态，那个变量
# 是编译器自身构建脚本 compile.sh 用的）。

# 编译器：用 /home/winger/uya/uya（0.10.3 + 三处「固定表」修复）。
# 为什么不再用 /home/winger/uya-0.10（0.10.1）：
#   ① 0.10.1 的**显式输入文件数硬上限是 64**（第 65 个报「收集模块依赖失败: <编译器路径>」，
#      报错指不到根因）。本仓拆完 17937/12957/11583 三个大文件后有 **90 个构建文件**，
#      0.10.1 直接编不动；
#   ② 0.10.1 的 checker 函数表与 codegen `reachable_function_decls`（4096 槽）都是**定长表**，
#      满了就**静默丢函数**（定义与原型都不发射、调用点还在 ⇒ 宿主 C 报 implicit declaration
#      + invalid initializer / 链接期 undefined reference）。本仓 3600+ 个函数正好踩在边界上。
# 这三处都已在 /home/winger/uya/uya 修掉（提交：`fc577783` checker 五张定长表改动态哈希表、
# `7c49de57` 输入文件表可增长、`1267dbc6` reachable 函数表按实际条数分配）。
# 换别的编译器时请先确认这三条都已修，否则 build 会以看不懂的方式失败。
UYA_ROOT ?= ../uya/lib/
UYA      ?= ../uya/bin/uya

STATIC ?= 1
ifeq ($(STATIC),1)
AGENT_LDFLAGS := -static
else
AGENT_LDFLAGS :=
endif

# 给「无体 extern "libc" fn」（setsid / sigaction）补 C 原型 —— 编译器**故意**不发射
# 这类原型（见 ../uya/src/codegen/c99/function.uya），它假设宿主系统头已声明；而 split-C
# 的每个 .c 只 include uya_*.h，从不 include 系统头，所以调用点在 C 里是隐式声明。
# GCC 14 起隐式函数声明是**错误**（本机 cc = GCC 15.2），不修就构建不过（踩坑 131）。
#
# 这也修「implicit declaration」，但与上面 ② 的**原因完全不同**，别混：
#   上面 ② 是编译器**静默丢函数**（定长表满），修在编译器；
#   这里是编译器**故意不发原型**，修在本仓的 CFLAGS 注入。
#
# 怎么注入：driver 按 `make -C <cache> CC=… CFLAGS=… LDFLAGS=… …` 调生成出来的
# build/uyacache/Makefile（见 ../uya/src/driver/toolchain.uya 的 link_split_with_make），
# **命令行 CFLAGS 压过生成 Makefile 里的 `CFLAGS ?=`** —— 所以 build 那条命令上写的
# `CFLAGS=`（见 AGENT_CFLAGS）才是本次构建真用的宿主档位；生成 Makefile 里那行
# `-std=c99 -Wall -Wextra -pedantic -I.` 对本路径**从不生效**（它只管「有人手跑
# make -C build/uyacache」那一路）。
#
# 于是写回来的是 **driver 的默认值**（toolchain.uya：get_env_or_default("CFLAGS",
# "-std=c99 -O0 -fno-builtin")），而且要写**全**：漏掉 `-std=c99` 会让
# `typedef _Bool bool` 当场报「'bool' cannot be defined via 'typedef'」。
#
# 千万别照抄生成 Makefile 那行 —— 那不是「基线」，是**另一套档位**（丢 -fno-builtin、
# 多开 -Wall -Wextra -pedantic）：这几条旗标落在**编译器生成的** C 上会刷出 1.8 万条
# 告警（uya_part1_types.h 的 `_Atomic` 不算 C99、uya_split_protos.h 与 builtin 原型
# 不匹配、asbang 的 `({})`、生成函数的 unused-function/parameter…），而那些一行都不
# 归本仓修，只会把真告警淹掉。实测：抄它 0 条 → 1.8 万条。
# 换编译器时对齐这里：`uya build` 回显的 cc 命令行里 `-c` 与 `-I.` 之间就是它。
# 换档位用 AGENT_CFLAGS_BASE（`make build CFLAGS=…` 不算数，同踩坑 90 的 LDFLAGS）。
# 原型也必须出现在**出错的那个 .c** 里：单放一个 .c 文件（@c_import）没用 ——
# 那只是另一个翻译单元，看不到本 TU 的隐式声明。
AGENT_C_PROTOS    := $(CURDIR)/src/cshim/uya_agent_libc_protos.h
AGENT_CFLAGS_BASE ?= -std=c99 -O0 -fno-builtin
AGENT_CFLAGS      := $(AGENT_CFLAGS_BASE) -include $(AGENT_C_PROTOS)

# 为什么用行内赋值而不是 export（同踩坑 90 那条 LDFLAGS 的教训）：export 会漏进**所有**
# recipe 的环境，包括 `make selftest`（它内部 fork bash、由 agent 自己去 `uya build` 编
# 东西）—— 那等于把本仓的原型头强加给**别人**的构建。所以只加在编译那一条命令上。

# 源码按**域**分目录（一个域一个子目录，一文件一职责）—— 见 CODING.md。
# Uya 的模块是「目录即模块」，且跨目录**合并命名空间**，所以：
#   ① 搬文件进子目录**不需要**改源代码里的 export / use；
#   ② 但**文件顺序有意义**：checker 按 SRC 顺序扫，`if c { CONST_A } else { CONST_B }`
#      这种表达式要求常量所在文件**排在用它之前**，否则报「期望类型 u8，推断为 void」
#      （实测：把 style.uya 排到 ask/entry/diff 之后，三处当场红）。所以下面
#      term/tui/ 与 diff/ 两块是按**依赖序**排的，不是字母序 —— 加文件别打乱。
#   ③ 显式输入文件数的硬上限是 **64**（uya 0.10.1）：第 65 个开始报「收集模块依赖失败」，
#      报错完全指不到根因。**这条已在 0.10.3 解除**（输入文件表改为可增长，无数量上限），
#      本仓现在 90 个文件；加文件只要守 ①② 与 CODING.md §1.3 的粒度。
#      数文件：`make -s print-src | wc -w`。
# 留在 src/ 根的 tools.uya 是 P50 起就不在构建里的已知死代码，故意不列。
SRC := src/foundation/bufx.uya src/foundation/jsonx.uya src/foundation/yamlcfg.uya \
       src/rt/rtloop.uya src/rt/rtio.uya \
       src/net/tlspin.uya src/net/proxyx.uya src/net/rsav.uya src/net/x509min.uya src/net/cachain.uya \
       src/net/httpc.uya src/net/httpsrv.uya src/net/httpstream.uya src/net/ahttp.uya src/net/llm.uya src/net/allm.uya src/net/retryx.uya src/net/sse.uya src/net/webx.uya \
       src/term/oscin.uya src/term/mdview.uya src/term/tasks.uya src/term/tty.uya \
       src/term/tui/style.uya src/term/tui/keys.uya src/term/tui/frame.uya src/term/tui/entry.uya src/term/tui/screen.uya src/term/tui/queue.uya src/term/tui/sel.uya src/term/tui/overlay.uya src/term/tui/status.uya src/term/tui/ask.uya src/term/tui/watch.uya src/term/tui/diff.uya src/term/tui/hook.uya src/term/tui/inp.uya \
       src/term/view.uya src/term/watch.uya \
       src/ui/ui_port.uya src/ui/be_null.uya src/ui/be_tui.uya src/ui/be_events.uya src/ui/ui_reg.uya src/ui/ui_fwd.uya \
       src/tools/askuser.uya src/tools/fsx.uya src/tools/jobs.uya src/tools/perm.uya src/tools/sandboxx.uya src/tools/search.uya src/tools/shxwait.uya src/tools/shellx.uya \
       src/plugin/mcpcfg.uya src/plugin/mcprun.uya src/plugin/mcp.uya src/plugin/mcptool.uya \
       src/session/dshcfg.uya src/session/dshcred.uya src/session/dshdoc.uya src/session/dshfile.uya src/session/dshsave.uya src/session/dshsess.uya src/session/inbox.uya src/session/modelx.uya src/session/procx.uya src/session/session.uya src/session/sigx.uya src/session/stats.uya \
       src/agent/agent.uya src/agent/ag_config.uya src/agent/ag_title_prompt.uya src/agent/ag_tools_schema.uya src/agent/ag_stream_async.uya src/agent/ag_request_stream.uya src/agent/ag_turn_retry.uya src/agent/ag_workspace_model.uya src/agent/ag_worktree.uya src/agent/ag_bg_notes.uya src/agent/ag_interactive_tasks.uya src/agent/ag_tui_sessions.uya src/agent/ag_plan_pump.uya src/agent/ag_pm.uya src/agent/ag_memory_tui.uya src/agent/compact.uya src/agent/deleg.uya src/agent/goal.uya src/agent/instr.uya src/agent/plan.uya src/agent/prompt.uya src/agent/skill.uya src/agent/todo.uya src/agent/workflow.uya \
       src/pm/pm_repo.uya src/pm/pm_store.uya src/pm/pm_ingest.uya src/pm/pm_seed.uya src/pm/pm_digest.uya \
       src/vcs/gitx.uya src/vcs/worktreex.uya \
       src/web/ttyemu.uya src/web/dshauth.uya src/web/dshget.uya src/web/webui.uya src/web/wsess.uya src/web/dwhchild.uya src/web/dwhmodel.uya src/web/dwhschema.uya src/web/dwhset.uya src/web/whost.uya src/web/websrv.uya src/web/webhttp.uya src/web/webpump.uya \
       src/media/clipx.uya src/media/clipw.uya src/media/clipt.uya src/media/cliphelp.uya src/media/clip.uya src/media/imgx.uya src/media/imgz.uya \
       src/selftest/selftest.uya src/selftest/shellselftest.uya src/selftest/sigselftest.uya src/selftest/tuiselftest.uya \
       src/selftest/st_async_rt.uya src/selftest/st_async_io.uya src/selftest/st_async_keys.uya src/selftest/st_async_net.uya src/selftest/st_async_turn.uya src/selftest/st_async_conc.uya src/selftest/st_core.uya src/selftest/st_mock_server.uya src/selftest/st_round_driver.uya src/selftest/st_turn_retry.uya src/selftest/st_bg_notify.uya src/selftest/st_tty_sse.uya src/selftest/st_sessions.uya src/selftest/st_read_window.uya src/selftest/st_view_watch.uya src/selftest/st_responses.uya src/selftest/st_stats_ctx.uya src/selftest/st_ctxfit.uya src/selftest/st_title.uya src/selftest/st_tasks_ws.uya src/selftest/st_vision.uya src/selftest/st_goal_worktree.uya src/selftest/st_goal_sess.uya src/selftest/st_todo_resume.uya src/selftest/st_pm.uya src/selftest/st_pm2.uya src/selftest/st_mcp.uya \
       src/selftest/tuis_core.uya src/selftest/tuis_title_pty.uya src/selftest/tuis_exit_cmd.uya src/selftest/tuis_diff_scroll.uya src/selftest/tuis_title_ask.uya src/selftest/tuis_sessions_big.uya src/selftest/tuis_tail.uya src/selftest/tuis_marquee_row.uya src/selftest/tuis_sel.uya src/selftest/tuis_mem.uya src/selftest/tuis_mem_menu.uya src/selftest/tuis_queue.uya \
       src/selftest/st_web.uya src/selftest/st_web_childcfg.uya src/selftest/st_web_live.uya src/selftest/st_tls_pin.uya src/selftest/st_tls_ca.uya \
       src/selftest/st_dns.uya src/selftest/st_proxy.uya \
       src/selftest/st_clip.uya src/selftest/st_wire.uya src/selftest/tuis_ui_port.uya src/selftest/tuis_events.uya \
       src/diff/model.uya src/diff/gitcmd.uya src/diff/rows.uya src/diff/view.uya src/diff/render.uya
OUT := build/uya-agent

BASE ?= https://api.deepseek.com/v1
PIN  ?=
TASK ?= 创建 hello.uya，编译并运行它

# 编译器按 UYA_ROOT 找标准库，按 UYA_SPLIT_C_DIR 放多文件 C 缓存
export UYA_ROOT
export UYA_SPLIT_C_DIR := $(CURDIR)/build/uyacache

# 行宽豁免：一条 .PHONY 就是一张全仓目标清单，拆行反而看不清哪条丢了
.PHONY: all check wire-schema wire-probe wire-probe-real dsh-web-check dsh-settings-check print-src print-cflags build link-audit selftest codegen-audit doc-audit lint-size lint-size-all doc-cover ui-audit probe e2e e2e-config e2e-exec e2e-accept-nudge e2e-retry e2e-config-flags e2e-title e2e-title-cmd e2e-title-auto e2e-mouse e2e-api e2e-steps e2e-permission e2e-sandbox e2e-tasks e2e-tasks-resume e2e-goal e2e-memory e2e-memory-live e2e-sessions e2e-resume-big e2e-diff e2e-ws e2e-model e2e-model-save e2e-model-route e2e-provider e2e-ctxwindow e2e-inputimage e2e-worktree e2e-watch e2e-watch-pick e2e-dsh e2e-portable e2e-proxy p30-check tui-demo tui-selftest web-selftest sess-selftest diff-selftest model-selftest panel-selftest clean shell-selftest pm-selftest mcp-selftest proxy-selftest notify-selftest

all: build

# 打印源文件清单（一行，空格分隔）。给「不走 make 的手工编译」和脚手架用：
#   CFLAGS="$(make -s print-cflags)" uya build $(make -s print-src) -o build/uya-agent
# 清单只在这一个地方维护（SRC），别在 README / 脚本里手抄。
print-src:
	@echo $(SRC)

# 打印本仓需要的宿主 CFLAGS（driver 默认档位 + 原型头的 -include）。手工编译时按上面
# 那条命令行带上；少了它，GCC 14+ 会把隐式函数声明当错误（踩坑 131）。
print-cflags:
	@echo $(AGENT_CFLAGS)

check:
	@mkdir -p build
	$(UYA) check $(SRC)

build:
	@mkdir -p build
	CFLAGS="$(AGENT_CFLAGS)" LDFLAGS="$(AGENT_LDFLAGS)" $(UYA) build $(SRC) -o $(OUT)
ifeq ($(STATIC),1)
	@$(MAKE) --no-print-directory link-audit
endif

# 静态链接审计：产物必须**没有** PT_INTERP、没有 NEEDED 项。两条都走 readelf 的
# 结构性 token（`INTERP` / `(NEEDED)`），不解析本机化后的散文（中文环境下 readelf
# 会把「There is no dynamic section」翻掉，但类型名不翻）—— 踩坑 90 的对照实验就
# 靠它，写错了要能当场红。`file` 那行的「statically linked」同样本机化，不采用。
# build 末尾会自己调一次（STATIC=1 时），于是 **build 绿就等于真静态**：这条断言
# 挡的是「LDFLAGS 没传下去」这一路（换了编译器、有人把那条命令前缀挪走、generated
# Makefile 的链接行变了），那几种情况产物会悄悄退回动态而构建全程无异常。
link-audit:
	@if [ "$(STATIC)" != "1" ]; then echo "link-audit: 跳过（STATIC=$(STATIC)，显式要的动态链接）"; exit 0; fi; \
	if [ ! -f $(OUT) ]; then echo "link-audit: $(OUT) 不存在，先 make build"; exit 1; fi; \
	interp=$$(readelf -lW $(OUT) 2>/dev/null | grep -c "INTERP" || true); \
	if [ "$$interp" != "0" ]; then \
		echo "link-audit: 产物有 PT_INTERP（= 动态链接，STATIC=0？）"; \
		readelf -lW $(OUT) | grep "INTERP"; exit 1; \
	fi; \
	needed=$$(readelf -dW $(OUT) 2>/dev/null | grep -c "(NEEDED)" || true); \
	if [ "$$needed" != "0" ]; then \
		echo "link-audit: 产物有 NEEDED 项（= 依赖共享库）"; \
		readelf -dW $(OUT) | grep "(NEEDED)"; exit 1; \
	fi; \
	echo "link-audit: 通过（无 PT_INTERP、无 NEEDED，真静态）"

# 代码生成审计：uya 0.10 把 `&"字面量"[a:b]` 传给 `*const byte` 形参时会生成
# 「切片描述符（{ptr,len} 结构体）地址 → char*」的强转 —— sys_write 于是把描述符里
# 那 8 字节指针的前几字节写到终端，屏幕上就是乱码（实测提示符前挂 `\xb9x\xe0gi`）。
# 构建产物里再出现这种形状就直接失败，防止再写回去。
codegen-audit: build
	@bad=$$(grep -rn "const char \*)(&(struct uya_slice_uint8_t)" $(CURDIR)/build/uyacache/uya-agent 2>/dev/null || true); \
	if [ -n "$$bad" ]; then \
		echo "codegen-audit: 发现「切片描述符强转成字节指针」（输出会乱码）："; \
		echo "$$bad"; \
		exit 1; \
	fi; \
	echo "codegen-audit: 通过（没有切片描述符强转）"

# 文档覆盖审计（CODING.md §2 / §3 的可执行版本）：文件头必须有「本文件 / 不变量 / 依赖 /
# 命名」四行、第 1 行的路径必须与文件实际位置一致，且**每个 fn / export fn 的紧邻上方要有
# `//` 注释**。为什么单开一条：这两件事**没有任何测试看得见** —— 漏一行头注释、少一句函数
# 注释，build / selftest / link-audit / codegen-audit / doc-audit 全绿（与踩坑 94 同族：
# 「全绿」只覆盖被断言过的东西）。只读检查，不动文件。
doc-cover:
	@python3 testdata/doc_cover.py
	@echo "doc-cover: 完成"

# P80 界面后端接缝审计（`testdata/ui_audit.py`）。守的是**结构约束**，不是行为：
#   ① 最要命的一条 —— `&具体struct as &接口`（**能编译、能链接，运行期 SIGSEGV**：
#      codegen 不构造 {vtable, data} 对。实测退出码 139）。编译期与自测都看不见它，
#      只有跑到那条路径才炸；
#   ② 执行层直呼后端私有符号（`betui_` 等）= 绕过了端口，换后端又得改执行核；
#   ③ 端口层依赖执行核（`Config` / `agent_` / `g_sess`）= 后端换不动、也不能独立自测；
#   ④ `be_*.uya` 里的后端忘了写 `: UiBackend`（漏实现**方法**是编译期错误，
#      但整个 struct 忘了标注不报错）；
#   ⑤ 注册表 `g_reg` 槽位没填满（空槽 vtable = null，切过去即崩）。
# 六条判据的机器实现与防假绿对照见 CODING.md §1.4 与 DESIGN.md §11.9。
ui-audit:
	@python3 testdata/ui_audit.py

# P80：形状适配层（本仓日志 → DSH SessionEvent）的**外部** oracle。
# 为什么不能只靠 `selftest[wire-adapt]`：那一轮的断言都是**子串**判据，而「JSON 结构
# 坏掉」能完全绕过它们 —— 实测抓到过两种（`…"time":1{"role":…` 漏收尾引号、
# `"data":{{` 多花括号），两次都是子串全中、只有 schema 判红。
# 所以这条判据交给 **DSH 自己的 zod schema** 来判（我们适配出的东西必须是它认得的
# —— 这就是「不改 DSH 的 webui」的前提）。本机没装 DSH 时**跳过**（不是失败）。
wire-schema: build
	@python3 testdata/wire_schema_check.py

# P80：**阶段 0 探针** —— 「不改 DSH 的 webui 能不能当本仓的前端」这句可证伪的话。
# 它起一个最小宿主（只读服务 DSH 自己那份 dist + 复刻它的 `bootInjections()` +
# 最小 14 包 roster + `/api` 接本仓适配层的输出），再起 headless chromium 用 CDP
# 驱动到「消息渲染出来」，断言标题与正文（两条只可能来自我们的事件流）。
# 本机没装 DSH 或没有 chromium 时**跳过**（不是失败）—— 它在别的机器上也该能跑。
wire-probe:
	@python3 testdata/wire_probe_host.py --selftest-drive

# P80：**真日志**那一腿 —— 用产品适配层（web/wsess.uya）翻一份真的本仓 session.jsonl，
# 再走同一个探针。它与上一条的分工：上一条验「形状与最小面能起来」，这一条验
# 「**一整份真会话**能从头翻到尾并渲染出来」（含本仓那些 DSH 不认识的私有事件）。
# LOG 不给时自动挑 build/ 下第一份真有内容的 session.jsonl。
# P80：**产品侧**的端到端验收 —— 起 --dsh-web（产品二进制，不是 python 探针），
# 再用 headless chromium + CDP 驱动到「DSH 的界面里渲染出本仓会话的消息」。
# 这是本目标（基于 ui_backend 接入 DSH webui）在**产品**上的判据。
# 没装 DSH / 没 chromium 时跳过（退出 0）。
dsh-web-check: build
	@sh testdata/dsh_web_check.sh

# P88：设置页那一簇 RPC 的判据（`--dsh-web` 里「加提供方 / 改 / 删 / 凭据」那几条）。
# 与 `dsh-web-check` 的分工：那条走**真 chromium**（页面真的画出来了没有），这条走
# **RPC + 磁盘字节**（写进去的东西对不对）—— 一次写操作的失败模式往往只在后者可见
# （页面显示成功、文件没变，或者反过来）。
dsh-settings-check: build
	@python3 testdata/dsh_settings_probe.py --bin $(OUT)

wire-probe-real:
	@log="$(LOG)"; \
	if [ -z "$$log" ]; then \
		log=$$(find build -name session.jsonl -size +500c 2>/dev/null | head -1); \
	fi; \
	if [ -z "$$log" ]; then echo "wire-probe-real: 跳过 —— 找不到真会话日志（先跑 make selftest 生成一份）"; exit 0; fi; \
	echo "wire-probe-real: 用 $$log"; \
	python3 testdata/wire_probe_host.py --selftest-drive --real-log "$$log"

# 文档审计：仓库里不许留 Git 冲突标记（`<<<<<<<` / `=======` / `>>>>>>>`）。
# 来历见 §16 踩坑 94：一条合并残留的 `=======` 从 P53 那次合并（3e62301）
# 一直躺到 P56 —— 编译、自测、link-audit 全绿，**没有任何测试看得见它**，所以只能靠这条审计扫。
# 只扫文本（源码 / 文档 / 脚本 / Makefile），跳过 .git 与构建产物；行首锚定，
# 所以源码注释里的 `// ============` 这类分隔线不会误报。
doc-audit:
	@bad=$$(grep -rnE '^(<<<<<<<|=======|>>>>>>>)' \
		--include='*.uya' --include='*.md' --include='*.py' --include='*.sh' --include='*.yml' \
		--include='Makefile' --include='Makefile.*' \
		--exclude-dir=.git --exclude-dir=build --exclude-dir=__pycache__ \
		$(CURDIR) 2>/dev/null || true); \
	if [ -n "$$bad" ]; then \
		echo "doc-audit: 发现冲突标记（合并残留，必须删掉才准提交）："; \
		echo "$$bad"; \
		exit 1; \
	fi; \
	echo "doc-audit: 通过（没有冲突标记）"

# AGENTS.md 三条硬指标：文件 ≤2000 行 / 函数 ≤100 行 / 行宽 ≤80 字符。
# 判据与例外条款见 AGENTS.md；检查器是 scripts/lint_size.py（口径写死在那里）。
#   * `lint-size`     —— **评审门槛**：只看 `git diff` 新增的行 + 未跟踪的新文件。
#     改一行老代码不会因为那个函数本来就超长而红（历史存量不追，见 AGENTS.md）。
#   * `lint-size-all` —— 看存量：全量报，**退出码恒 0**（只用来量进度，不当场红）。
lint-size:
	@python3 scripts/lint_size.py --changed

lint-size-all:
	@python3 scripts/lint_size.py --all

# 函数表容量（0.10.1 里写死的 FUNCTION_TABLE_SIZE，无开关）：**绝对条数**上限，不是「本仓还能加 0 个」。
#   P53 实测：main 6756 声明通过、**+1 个空函数**就报「函数表容量不足」；
#   P54 实测（同一台机器、同一份 uya 0.10）：6792 声明通过，再 +6 个空函数仍通过，+8 个红
#   —— 也就是表容量在 6796 上下，而本仓当时余量约 4 个函数（各线合并后会变）。
#   要命的地方在于增量编译看不出来（缓存），只有 `rm -rf build` 重编才炸，报错点还落在标准库里。
#   变量与常量不占这个额度，只有函数占；整理手段见踩坑 87。
# ⇒ **0.10.3 已解除**：checker 的五张定长表改成通用动态哈希表（编译器提交 `fc577783`）。
#   本仓实测：90 文件树上净增 50 个函数 + `rm -rf build && make build` → 通过（静态链接审计通过）。
#   因此「净增函数按 0 处理」那条纪律作废。这段留下的用处只有一个：**换/降编译器时认得出症状**
#   （报错点落在标准库、`make check` 全绿、只有清缓存重编才炸）。
selftest: build codegen-audit doc-audit doc-cover ui-audit e2e-exec e2e-accept-nudge e2e-retry e2e-config-flags e2e-title e2e-title-cmd e2e-title-auto e2e-mouse e2e-api e2e-steps e2e-permission e2e-sandbox e2e-tasks e2e-tasks-resume e2e-goal e2e-memory e2e-memory-live e2e-sessions e2e-resume-big e2e-diff e2e-ws e2e-model e2e-model-save e2e-model-route e2e-provider e2e-ctxwindow e2e-inputimage e2e-worktree e2e-portable e2e-dns e2e-proxy p30-check
	UYA_BIN=$(UYA) $(OUT) --selftest

probe: build
	$(OUT) --probe --tls-verify=none --base-url $(BASE)

# P21：访问模式的来源链（离线，--print-config 不联网）
#   默认 = danger-full-access；--permission <v> 与 --permission=<v> 都是 cli；
#   UYA_AGENT_PERMISSION 是 env；DSH 设置里的 permission.defaultPreset 是 dsh-settings；
#   非法取值必须报错退出（静默按默认跑会让人以为模式生效了）。
e2e-permission: build
	@set -e; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "permission = danger-full-access  (source: default)" \
		|| { echo "FAIL: 默认访问模式应当是 danger-full-access"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --permission read-only --print-config 2>&1); \
	echo "$$out" | grep -q "permission = read-only  (source: cli)" \
		|| { echo "FAIL: --permission read-only 没生效"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --permission=workspace-write --print-config 2>&1); \
	echo "$$out" | grep -q "permission = workspace-write  (source: cli)" \
		|| { echo "FAIL: --permission=workspace-write 没生效"; exit 1; }; \
	out=$$(UYA_AGENT_PERMISSION=workspace-write $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "permission = workspace-write  (source: env)" \
		|| { echo "FAIL: UYA_AGENT_PERMISSION 没生效"; exit 1; }; \
	rm -rf build/selftest_dsh_perm; mkdir -p build/selftest_dsh_perm; \
	printf 'permission:\n  defaultPreset: read-only\n' > build/selftest_dsh_perm/settings.yaml; \
	out=$$($(OUT) --dsh-home build/selftest_dsh_perm --print-config 2>&1); \
	echo "$$out" | grep -q "permission = read-only  (source: dsh-settings)" \
		|| { echo "FAIL: DSH 的 permission.defaultPreset 没生效"; exit 1; }; \
	if $(OUT) --no-dsh-config --permission bogus --print-config >/dev/null 2>&1; then \
		echo "FAIL: 非法 --permission 应当报错退出"; exit 1; \
	fi; \
	out=$$(printf '/permission\n/permission workspace-write\n/permission\n/permission bogus\n/exit\n' | \
		$(OUT) --no-dsh-config --no-tui --api-key dummy-key --quiet 2>&1); \
	echo "$$out" | grep -q "当前访问模式：Full access（danger-full-access）" \
		|| { echo "FAIL: 裸 /permission 没有报出当前模式"; exit 1; }; \
	echo "$$out" | grep -q "\[permission\] Workspace Write" \
		|| { echo "FAIL: /permission workspace-write 没有切过去"; exit 1; }; \
	echo "$$out" | grep -q "当前访问模式：Workspace Write（workspace-write）" \
		|| { echo "FAIL: 切换之后当前值不对"; exit 1; }; \
	echo "$$out" | grep -q '未知预设 "bogus"' \
		|| { echo "FAIL: 非法预设名应当回未知预设"; exit 1; }; \
	echo "e2e-permission: 通过（四级来源 + 非法值报错 + 行式 REPL /permission 查/切/报错）"

# P21：内核沙箱后端（离线）：探测结果必须可见；--no-sandbox 明确关；指定不存在的 bwrap 判不可用
e2e-sandbox: build
	@set -e; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "^sandbox = " || { echo "FAIL: 没打印 sandbox 行"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --no-sandbox --print-config 2>&1); \
	echo "$$out" | grep -q "sandbox = off  (source: cli, probe: skipped)" \
		|| { echo "FAIL: --no-sandbox 没生效"; exit 1; }; \
	out=$$(UYA_AGENT_BWRAP=/nonexistent $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "sandbox = none" || { echo "FAIL: 指定不存在的 bwrap 应当判不可用"; exit 1; }; \
	echo "e2e-sandbox: 通过（探测结果可见 / --no-sandbox / 显式 bwrap 路径不可用）"

# P22：/tasks 任务状态（离线，不联网）：裸命令出报告、空态串、open/toggle 回显、非法参数报错、
# /help 里能查到它。常驻块的排版与活体刷新在 selftest 的 tasks-render / tui-tasks 两轮里断言。
e2e-tasks: build
	@set -e; \
	out=$$(printf '/tasks\n/tasks open\n/tasks toggle\n/tasks bogus\n/help\n/exit\n' | \
		$(OUT) --no-dsh-config --no-tui --api-key dummy-key --quiet 2>&1); \
	echo "$$out" | grep -qF -- "--- 任务 ---" \
		|| { echo "FAIL: 裸 /tasks 没有打出报告头"; exit 1; }; \
	echo "$$out" | grep -qF "（没有任务：todo 清单为空，也没有后台任务 / 子代理 / 目标）" \
		|| { echo "FAIL: 空态串不对"; exit 1; }; \
	echo "$$out" | grep -qF "[tasks] 常驻块：展开（ctrl+t 同效）" \
		|| { echo "FAIL: /tasks open 没有回显展开"; exit 1; }; \
	echo "$$out" | grep -qF "[tasks] 常驻块：收起" \
		|| { echo "FAIL: /tasks toggle 没有回显收起"; exit 1; }; \
	echo "$$out" | grep -qF '未知参数 "bogus"' \
		|| { echo "FAIL: 非法参数没有报错"; exit 1; }; \
	echo "$$out" | grep -qF "/tasks     任务状态进度" \
		|| { echo "FAIL: /help 里没有 /tasks"; exit 1; }; \
	echo "e2e-tasks: 通过（报告头 / 空态串 / open / toggle / 非法参数 / /help）"

# 清单的**跨进程**恢复（踩坑 155）：一个进程里让模型写一份清单（假网关第一次请求回
# `todo_write`，夹具见 testdata/mock_gateway_sse.py 的 TODO_FIRST=1），**另一个进程**
# `--resume` 那条会话再敲 `/tasks` —— 清单必须还在。
#   为什么必须跨进程：进程内的「折回来对不对」由 selftest 的 todo-resume 轮钉（那边
#   可以直接调 `agent_hist_from_log`）；这一条钉的是**线上那条链**（真二进制 + 真日志 +
#   真 argv 解析），它坏掉时 selftest 可以全绿（同族：P89 的 pair-recover 立的规矩）。
#   判据是夹具里那三条清单的正文与计数行，落在 `/tasks` 打出来的**报告文本**上。
e2e-tasks-resume: build
	@set -e; \
	ws=build/selftest_tasks_resume; rm -rf $$ws; mkdir -p $$ws/ws; \
	python3 testdata/mock_gateway_sse.py 0 1 200 0 "" 1 > $$ws/gw.log 2>&1 & \
	gw=$$!; \
	trap "kill $$gw 2>/dev/null || true" EXIT; \
	sleep 1.2; \
	port=$$(awk '/^PORT/{print $$2}' $$ws/gw.log); \
	[ -n "$$port" ] || { echo "FAIL: 假网关没打印端口"; cat $$ws/gw.log; exit 1; }; \
	( cd $$ws/ws && printf '做一件事\n/exit\n' | \
		UYA_AGENT_HOME=$$PWD/../home ../../../$(OUT) --no-dsh-config --no-tui \
		--api-key dummy-key --quiet --base-url "http://127.0.0.1:$$port/v1" \
		--api=chat --model mock-model >/dev/null 2>&1 ); \
	sid=$$(grep -o '"id":"session-[0-9a-f-]*"' $$ws/home/index.jsonl | head -1 | cut -d'"' -f4); \
	[ -n "$$sid" ] || { echo "FAIL: 没开出会话（index.jsonl 里找不到 id）"; exit 1; }; \
	log=$$(find $$ws/home/sessions -name session.jsonl | head -1); \
	grep -qF '"type":"todo/write"' $$log \
		|| { echo "FAIL: 日志里没有 todo/write（清单没落盘）"; exit 1; }; \
	( cd $$ws/ws && printf '/tasks\n/exit\n' | \
		UYA_AGENT_HOME=$$PWD/../home ../../../$(OUT) --no-dsh-config --no-tui \
		--api-key dummy-key --resume $$sid 2>&1 ) > $$ws/out.txt; \
	grep -qF "在真 PTY 里按 ctrl+t" $$ws/out.txt \
		|| { echo "FAIL: --resume 之后 /tasks 里没有那条清单（恢复会话看不到清单）"; cat $$ws/out.txt; exit 1; }; \
	grep -qF "清单      1/3" $$ws/out.txt \
		|| { echo "FAIL: --resume 之后 /tasks 的计数行不对"; cat $$ws/out.txt; exit 1; }; \
	grep -qF "钉住三条静默路" $$ws/out.txt \
		|| { echo "FAIL: --resume 之后 /tasks 里少了 completed 那条"; cat $$ws/out.txt; exit 1; }; \
	echo "e2e-tasks-resume: 通过（另一个进程 --resume 之后 /tasks 里清单还在，三条与计数都对）"

# P29：/goal（离线，行式 REPL 走真二进制）：空态用法 / 创建 / 拒绝顶掉未完成的 goal /
# edit 只换目标 / pause·resume 翻 armed / clear 幂等 / 字面目标规则 / /help 里查得到。
# TUI 那条腿（浮层 + 常驻块目标段刷新）在 selftest 的 tui-tasks 轮里断言。
e2e-goal: build
	@set -e; \
	home=build/selftest_goal_e2e; rm -rf $$home; mkdir -p $$home; \
	out=$$(printf '/goal\n/goal 把 make release 跑绿\n/goal\n/goal 第二个目标\n/goal edit 改成跑绿全部测试\n/goal pause\n/goal resume\n/goal clear\n/goal clear\n/goal pause after verification\n/help\n/exit\n' | \
		UYA_AGENT_HOME=$$home $(OUT) --no-dsh-config --no-tui --api-key dummy-key --quiet 2>&1); \
	echo "$$out" | grep -qF "No goal is currently set." \
		|| { echo "FAIL: 空态没有报「当前没有目标」"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "Usage: /goal [<objective>|clear|edit <objective>|pause|resume]" \
		|| { echo "FAIL: 空态没有给出用法"; exit 1; }; \
	echo "$$out" | grep -qF "Goal created" || { echo "FAIL: 没有建出目标"; exit 1; }; \
	echo "$$out" | grep -qF "Status: active" || { echo "FAIL: 创建后不是 active"; exit 1; }; \
	echo "$$out" | grep -qF "Rounds: 0/20" || { echo "FAIL: 轮数显示不对"; exit 1; }; \
	echo "$$out" | grep -qF "Objective: 把 make release 跑绿" || { echo "FAIL: 目标正文不对"; exit 1; }; \
	echo "$$out" | grep -qF "A goal is already active." \
		|| { echo "FAIL: 未完成的 goal 被第二个目标顶掉了"; exit 1; }; \
	echo "$$out" | grep -qF "Goal updated" || { echo "FAIL: edit 没生效"; exit 1; }; \
	echo "$$out" | grep -qF "Objective: 改成跑绿全部测试" || { echo "FAIL: edit 没换掉目标正文"; exit 1; }; \
	echo "$$out" | grep -qF "Status: paused" || { echo "FAIL: pause 之后不是 paused"; exit 1; }; \
	echo "$$out" | grep -qF "Activation: disarmed" || { echo "FAIL: pause 没有关掉自动续跑"; exit 1; }; \
	echo "$$out" | grep -qF "Goal resumed" || { echo "FAIL: resume 没生效"; exit 1; }; \
	echo "$$out" | grep -qF "Goal cleared." || { echo "FAIL: clear 没生效"; exit 1; }; \
	echo "$$out" | grep -qF "No goal to clear." || { echo "FAIL: 重复 clear 不幂等"; exit 1; }; \
	echo "$$out" | grep -qF "Objective: pause after verification" \
		|| { echo "FAIL: 带后缀的 pause 应当按字面目标创建"; exit 1; }; \
	echo "$$out" | grep -qF "/goal [<objective>|edit <objective>|pause|resume|clear]" \
		|| { echo "FAIL: /help 里没有 /goal"; exit 1; }; \
	echo "e2e-goal: 通过（用法 / 创建 / 拒绝顶掉 / edit / pause·resume / clear 幂等 / 字面目标 / /help）"

# P68：项目记忆的人类命令面（离线）：/memory 报告 / off / forget + --no-memory 的 print-config。
# 开工包的**内容与注入**由 selftest 的 pm-e2e 轮断言（那边才拿得到历史）。
e2e-memory: build
	@set -e; \
	home=build/selftest_pm_e2e; rm -rf $$home; mkdir -p $$home; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "memory = on  (source: default)" \
		|| { echo "FAIL: 默认应当是开"; exit 1; }; \
	echo "$$out" | grep -q "budget = 3072 (default)" \
		|| { echo "FAIL: 默认预算应当是 3072"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --no-memory --print-config 2>&1); \
	echo "$$out" | grep -q "memory = off  (source: cli)" \
		|| { echo "FAIL: --no-memory 没生效"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --memory-budget 512 --print-config 2>&1); \
	echo "$$out" | grep -q "budget = 512" \
		|| { echo "FAIL: --memory-budget 没生效"; exit 1; }; \
	out=$$(printf '/memory\n/memory bogus\n/memory off\n/memory\n/help\n/exit\n' | \
		UYA_AGENT_HOME=$$home $(OUT) --no-dsh-config --no-tui --api-key dummy-key --quiet 2>&1); \
	echo "$$out" | grep -qF -- "--- 项目记忆 ---" \
		|| { echo "FAIL: 裸 /memory 没有打出报告头"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "（这个项目还没有积累到任何事实" \
		|| { echo "FAIL: 空态串不对"; exit 1; }; \
	echo "$$out" | grep -qF "[memory] 用法：/memory" \
		|| { echo "FAIL: 非法参数应当回用法"; exit 1; }; \
	echo "$$out" | grep -qF "项目记忆：已关闭" \
		|| { echo "FAIL: /memory off 之后报告应当说已关闭"; exit 1; }; \
	echo "$$out" | grep -qF "/memory    记忆" \
		|| { echo "FAIL: /help 里没有 /memory"; exit 1; }; \
	echo "e2e-memory: 通过（print-config 两条 / 报告头 / 空态 / 非法参数 / off / /help）"

# P68 尾巴：项目记忆的**真机接线**回归（离线，靠 testdata/mock_gateway_memory.py）。
#
# 为什么必须单开一轮：`src/selftest/st_pm2.uya` 的 pm-e2e 轮**直接调**摄取函数、并手写正确
# 的参数（`res.ptr` / `res.len`），所以它证明的是「摄取函数本身对」，**不是接线对** ——
# 生产代码里那两处坏调用点它一条都覆盖不到：
#   ① `agent_pm_set_sid` 排在 `agent_pm_begin` 之前 ⇒ 绑定失败 ⇒ `g_pm_ing.enabled` 恒 false；
#   ② 传 `&res.ptr` / `&res.len`（**字段的地址**）而不是 `res.ptr` / `res.len`（值）
#      ⇒ 野指针 + 天文数字长度 ⇒ 段错误。
# 两处叠加的后果是**记忆从来没写进盘过**（现象被读成「记忆一直不失效」，其实盘上是空的），
# 而当时 151 轮 selftest + 6 轮 pm-selftest 全绿。这一轮跑**真二进制**，钉五条腿：
#   ① 摄取真的落盘，且 layout 那条**带真 stat 锚点**（锚点全 0 = 摄取没拿到 stat）；
#   ② 跨会话真的注入（只看 `<pm-memory>…</pm-memory>` 那一小段，不看整包请求）；
#   ③ 改了文件那条真的标 STALE；④ 删了文件那条真的标 GONE；⑤ `--no-memory` 真的不落盘。
e2e-memory-live: build
	@set -e; \
	ws=$(CURDIR)/build/e2e_mem_ws; \
	home=$(CURDIR)/build/e2e_mem_home; \
	home_nm=$(CURDIR)/build/e2e_mem_home_nomem; \
	rm -rf $$ws $$home $$home_nm; mkdir -p $$ws; \
	printf 'build:\n\t@echo MEM-BUILD-OK\n' > $$ws/Makefile; \
	printf 'mem live line one\nmem live line two\n' > $$ws/README.md; \
	: "夹具必须是**自己的** git 仓：否则 pm_repo_root 一路走到本仓的 .git，"; \
	: "项目键会跟真仓库撞上（那就不隔离了，也会污染真记忆目录）"; \
	: "没有 git 也不 skip：项目键会退化成 workspace 路径本身，五条腿照样成立（与 e2e-diff 的 skip 不同）"; \
	( cd $$ws && git init -q . ) || true; \
	dl=$(CURDIR)/build/e2e_mem_d1; d2=$(CURDIR)/build/e2e_mem_d2; \
	d3=$(CURDIR)/build/e2e_mem_d3; d4=$(CURDIR)/build/e2e_mem_d4; \
	d5=$(CURDIR)/build/e2e_mem_d5; \
	: "每会话一个**新**网关进程：脚本按本进程收到的第几次请求推进，复用会错位"; \
	run_sess() { \
		dump="$$1"; h="$$2"; task="$$3"; shift 3; \
		rm -f "$$dump" "$$dump.gw"; \
		UYA_MEM_DUMP="$$dump" python3 testdata/mock_gateway_memory.py 0 README.md "make -n" > "$$dump.gw" 2>&1 & \
		pid=$$!; \
		i=0; \
		while [ ! -s "$$dump.gw" ] && [ $$i -lt 60 ]; do sleep 0.1; i=$$((i+1)); done; \
		port=$$(awk '/^PORT/{print $$2}' "$$dump.gw"); \
		if [ -z "$$port" ]; then \
			echo "FAIL: 假网关没起来"; cat "$$dump.gw"; \
			kill $$pid 2>/dev/null || true; exit 1; \
		fi; \
		rc=0; \
		UYA_AGENT_API_KEY=k $(OUT) --no-dsh-config --no-stream --no-tui --quiet \
			--base-url "http://127.0.0.1:$$port/v1" --api=chat --model mock-model \
			--workspace $$ws --agent-home "$$h" --tls-verify=none "$$@" "$$task" \
			> "$$dump.out" 2>&1 || rc=$$?; \
		kill $$pid 2>/dev/null || true; \
		if [ $$rc -ne 0 ]; then \
			echo "FAIL: agent 退出码 $$rc（139=段错误，通常是把字段地址当值传）"; \
			tail -5 "$$dump.out"; exit 1; \
		fi; \
	}; \
	: "只取注入的那一小段：整包请求里 README.md 还会从工具参数里出现，那是假绿"; \
	mem_block() { grep -o '<pm-memory>.*</pm-memory>' "$$1" | head -1; }; \
	: "---- 会话 1：摄取 ----"; \
	run_sess "$$dl" "$$home" "第一个会话"; \
	shard=$$(find $$home -path '*memory*/obs/*.jsonl' | head -1); \
	if [ -z "$$shard" ]; then \
		echo "FAIL: 一个记忆分片都没落盘（摄取整条死了）"; \
		echo "      先查 agent_pm_set_sid 的绑定时机，再查 note_tool 的传参"; \
		tail -5 "$$dl.out"; exit 1; \
	fi; \
	lg=$$(grep '"kind":"layout"' $$shard | head -1); \
	echo "$$lg" | grep -q '"key":"README.md"' \
		|| { echo "FAIL: layout 事实里没有 README.md"; cat $$shard; exit 1; }; \
	echo "$$lg" | grep -q '"mt":0,' \
		&& { echo "FAIL: layout 的 mtime 锚点是 0（摄取没拿到真 stat）"; exit 1; } || true; \
	echo "$$lg" | grep -q '"mtNs":0,' \
		&& { echo "FAIL: layout 的 mtime_nsec 锚点是 0（摄取没拿到真 stat）"; exit 1; } || true; \
	echo "$$lg" | grep -q '"size":0,' \
		&& { echo "FAIL: layout 的 size 锚点是 0（摄取没拿到真 stat）"; exit 1; } || true; \
	grep -q '"kind":"command"' $$shard \
		|| { echo "FAIL: bash 那条命令没被记成 commands"; cat $$shard; exit 1; }; \
	: "---- 会话 2：跨会话注入（记忆的定义）+ 未改动时不许标 STALE ----"; \
	run_sess "$$d2" "$$home" "第二个会话"; \
	blk2=$$(mem_block "$$d2"); \
	[ -n "$$blk2" ] || { echo "FAIL: 第二个会话没有注入开工包"; tail -5 "$$d2.out"; exit 1; }; \
	echo "$$blk2" | grep -qF 'README.md' \
		|| { echo "FAIL: 开工包里没有上个会话记下的路径"; echo "$$blk2"; exit 1; }; \
	echo "$$blk2" | grep -qF 'make -n' \
		|| { echo "FAIL: 开工包里没有上个会话记下的命令"; echo "$$blk2"; exit 1; }; \
	: "按 'STALE <路径>' 判，不按裸 STALE —— 头一句提示语里本来就有 STALE 这个词"; \
	echo "$$blk2" | grep -qF 'STALE README.md' \
		&& { echo "FAIL: 文件没动却标了 STALE（锚点比对口径不对）"; echo "$$blk2"; exit 1; } || true; \
	: "---- 会话 3：改了文件 → 那条必须降级为 STALE ----"; \
	printf 'mem live line one\nmem live line two\nMOVED\n' > $$ws/README.md; \
	run_sess "$$d3" "$$home" "第三个会话"; \
	blk3=$$(mem_block "$$d3"); \
	[ -n "$$blk3" ] || { echo "FAIL: 第三个会话没有注入开工包"; exit 1; }; \
	echo "$$blk3" | grep -qF 'STALE README.md' \
		|| { echo "FAIL: 改了文件却仍当断言注入（失效校验没生效）"; echo "$$blk3"; exit 1; }; \
	echo "$$blk3" | grep -qF 'README.md' \
		|| { echo "FAIL: 过期那条被整条丢掉了（索引仍有用，应当保留并标 STALE）"; exit 1; }; \
	echo "$$blk3" | grep -qF 'mem live line one' \
		&& { echo "FAIL: 文件正文被注入了（只许给指针，不许给内容）"; exit 1; } || true; \
	: "---- 会话 4：删了文件 → 那条必须标 GONE ----"; \
	rm -f $$ws/README.md; \
	run_sess "$$d4" "$$home" "第四个会话"; \
	blk4=$$(mem_block "$$d4"); \
	[ -n "$$blk4" ] || { echo "FAIL: 第四个会话没有注入开工包"; exit 1; }; \
	echo "$$blk4" | grep -qF 'GONE README.md' \
		|| { echo "FAIL: 删掉的文件没标 GONE"; echo "$$blk4"; exit 1; }; \
	: "---- 会话 5：--no-memory 全程不读不写 ----"; \
	run_sess "$$d5" "$$home_nm" "第五个会话" --no-memory; \
	if [ -d $$home_nm/memory ]; then \
		echo "FAIL: --no-memory 仍然建了记忆目录"; find $$home_nm/memory | head; exit 1; \
	fi; \
	blk5=$$(mem_block "$$d5"); \
	[ -z "$$blk5" ] \
		|| { echo "FAIL: --no-memory 仍然注入了开工包"; exit 1; }; \
	echo "e2e-memory-live: 通过（摄取落盘带真锚点 / 跨会话注入 / 改→STALE / 删→GONE / --no-memory 不落盘）"

# P26：/diff（离线）：在临时仓库里跑**真二进制**（滚动模式的单列文本回退）——
# 必须列出改动文件（含未跟踪）、打出旧/新两侧内容；非仓库目录必须报错而不是静默无事发生。
e2e-diff: build
	@set -e; \
	if ! command -v git >/dev/null 2>&1; then echo "e2e-diff: skip（本机没有 git）"; exit 0; fi; \
	ws=build/selftest_diff_e2e; \
	rm -rf $$ws; mkdir -p $$ws; \
	( cd $$ws && git init -q . && git config user.email t@t && git config user.name t && \
	  printf 'line1\nline2\nline3\n' > a.uya && printf 'gone\n' > c.uya && \
	  git add -A && git commit -qm fixture && \
	  printf 'line1\nCHANGED\nline3\n' > a.uya && printf 'new1\nnew2\n' > b.uya && rm c.uya ); \
	out=$$(cd $$ws && printf '/diff\n/exit\n' | $(CURDIR)/$(OUT) --no-dsh-config --no-tui --quiet --api-key dummy-key 2>&1); \
	echo "$$out" | grep -q "\[diff\] " || { echo "FAIL: /diff 没有输出 [diff] 头"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "3 个文件" || { echo "FAIL: /diff 没报出改动文件数"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "M  a.uya" || { echo "FAIL: 列表里没有改了一行的 a.uya"; exit 1; }; \
	echo "$$out" | grep -q "??  b.uya" || { echo "FAIL: 列表里没有未跟踪的 b.uya"; exit 1; }; \
	echo "$$out" | grep -q -- "-line2" || { echo "FAIL: 没有打出旧内容（-line2）"; exit 1; }; \
	echo "$$out" | grep -q -- "+CHANGED" || { echo "FAIL: 没有打出新内容（+CHANGED）"; exit 1; }; \
	echo "$$out" | grep -q -- "+new1" || { echo "FAIL: 未跟踪文件的正文没打出来"; exit 1; }; \
	out=$$(cd /tmp && printf '/diff\n/exit\n' | $(CURDIR)/$(OUT) --no-dsh-config --no-tui --quiet --api-key dummy-key 2>&1 || true); \
	echo "$$out" | grep -q "not a git repository" || { echo "FAIL: 非仓库目录没有报出「不是 git 仓库」"; echo "$$out"; exit 1; }; \
	echo "e2e-diff: 通过（真 git 的列表 + 单列文本回退 + 非仓库报错）"

# P34：工作区（离线）—— 真二进制跑四条：
#   ① 恢复会话时工作区跟着**会话记录**走，/diff 打的是那个工作区的改动；
#   ② 恢复不去动日志的存放位置（不再造出同 id 的空文件、索引 cwd 不被改写）；
#   ③ 显式 --workspace 优先于会话记录；
# P37：模型选择 + 推理强度（离线，全程不联网）
#   ① 目录来自 DSH 设置：--print-config 要报 provider / 档位清单（构造一份假 settings.yaml）；
#   ② 不认识模型名：只换名字，provider / contextWindow 保持不动（静默清空会让压缩失效）；
#   ③ 行式 REPL：/model 报告 + 切换、/effort 报告 + 合法档位收、非法档位拒并列出可选；
#   ④ 不公布档位的模型：--effort 原样透传（不 clamp），/effort 仍能报出当前值；
#   ⑤ P62 **同名跨提供方**：beta 也发布 a-think ⇒ 用 `beta/a-think` 必须换到 beta（provider 与
#      contextWindow 都跟着走），只给名字时用当前提供方并在回执里点出同名的那一家。
e2e-model: build
	@set -e; \
	home=build/selftest_p37_e2e; rm -rf $$home; mkdir -p $$home; \
	printf 'llm-pi-ai:\n  providers:\n    {\n      alpha:\n        {\n          api: openai-responses,\n          baseURL: https://alpha.example/v1,\n          models:\n            [\n              { id: a-plain, contextWindow: 111000 },\n              { id: a-think, contextWindow: 222000, reasoningEfforts: { off: none, low: low, high: high } }\n            ]\n        },\n      beta:\n        {\n          api: openai-completions,\n          baseURL: https://beta.example/v1,\n          models:\n            [\n              { id: a-think, contextWindow: 444000, reasoningEfforts: { off: none } }\n            ]\n        }\n    }\nagent-default-model:\n  provider: alpha\n  model: a-think\n  reasoningEffort: high\n' > $$home/settings.yaml; \
	run="$(CURDIR)/$(OUT) --dsh-home $$home --no-tui --quiet --api-key dummy-key"; \
	out=$$($$run --print-config 2>&1); \
	echo "$$out" | grep -q "model = a-think  (source: dsh-settings)" || { echo "FAIL: DSH 的默认模型没生效"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "provider = alpha  (source: dsh-settings)" || { echo "FAIL: provider 没解析出来"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "model_catalog = 3 model(s)" || { echo "FAIL: 目录条目数不对"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "^efforts = off, low, high" || { echo "FAIL: 公布的档位清单不对"; echo "$$out"; exit 1; }; \
	out=$$($$run --model not-in-catalog --print-config 2>&1); \
	echo "$$out" | grep -q "model = not-in-catalog" || { echo "FAIL: 目录外的模型名没换上去"; exit 1; }; \
	echo "$$out" | grep -q "provider = alpha" || { echo "FAIL: 目录外的模型不该清掉 provider"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "context_window = 222000" || { echo "FAIL: 目录外的模型不该清掉 contextWindow"; echo "$$out"; exit 1; }; \
	: "⑤ P62：同名 a-think 在 beta 下也有一份 ⇒ provider/名字 必须真的换到那一家"; \
	out=$$($$run --model beta/a-think --print-config 2>&1); \
	echo "$$out" | grep -q "provider = beta" || { echo "FAIL: \`--model beta/a-think\` 没把 provider 换到 beta（同名模型选不中）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "context_window = 444000" || { echo "FAIL: 同名 a-think 换到 beta 之后能力没跟着换"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "base_url = https://beta.example/v1" || { echo "FAIL: 同名 a-think 换到 beta 之后端点没跟过去"; echo "$$out"; exit 1; }; \
	: "⑤b 只给名字 = 用当前提供方（alpha），同名的那一家在 /model 报告里看得见"; \
	out=$$($$run --model a-think --print-config 2>&1); \
	echo "$$out" | grep -q "provider = alpha" || { echo "FAIL: 只给名字时应当用当前提供方"; echo "$$out"; exit 1; }; \
	: "⑤c --provider 与 --model 的先后顺序无关（两条路都要落在 beta 上）"; \
	out=$$($$run --provider beta --model a-think --print-config 2>&1); \
	echo "$$out" | grep -q "provider = beta" || { echo "FAIL: \`--provider beta --model a-think\` 没落在 beta 上"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "base_url = https://beta.example/v1" || { echo "FAIL: \`--provider beta --model a-think\` 的端点没跟着换"; echo "$$out"; exit 1; }; \
	out=$$($$run --model a-think --provider beta --print-config 2>&1); \
	echo "$$out" | grep -q "provider = beta" || { echo "FAIL: \`--model a-think --provider beta\` 没落在 beta 上"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "base_url = https://beta.example/v1" || { echo "FAIL: \`--model a-think --provider beta\` 的端点没跟着换"; echo "$$out"; exit 1; }; \
	: "⑤c2 显式优先：P 下没有这个模型时不许跨提供方回退（否则用户点的 P 会被悄悄换掉）"; \
	out=$$($$run --provider beta --model a-plain --print-config 2>&1); \
	echo "$$out" | grep -q "provider = beta" || { echo "FAIL: 显式 --provider beta + 不在它目录里的模型，provider 被跨提供方回退改掉了"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "model = a-plain" || { echo "FAIL: 显式 --provider beta + a-plain 的模型名不对"; echo "$$out"; exit 1; }; \
	out=$$(printf '/model\n/effort\n/effort bogus\n/effort low\n/effort\n/exit\n' | $$run 2>&1); \
	echo "$$out" | grep -q "model      a-think  ·  provider alpha" || { echo "FAIL: /model 报告不对"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "^efforts    off, low, high" || { echo "FAIL: /model 报告里没有档位清单"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "# alpha" || { echo "FAIL: /model 报告没有按提供方分组"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "a-think · alpha" || { echo "FAIL: /model 报告里同名两行没有各自标出提供方"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "a-think · beta" || { echo "FAIL: /model 报告里同名两行没有各自标出提供方"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "不是这个模型公布的档位" || { echo "FAIL: 非法档位没有报错"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "推理强度已切换" || { echo "FAIL: /effort low 没切过去"; echo "$$out"; exit 1; }; \
	: "⑤d 文本命令 /model beta/a-think 也要能指定同名里的另一家"; \
	out=$$(printf '/model beta/a-think\n/model\n/exit\n' | $$run 2>&1); \
	echo "$$out" | grep -q "模型已切换" || { echo "FAIL: \`/model beta/a-think\` 没切过去"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "model      a-think  ·  provider beta" || { echo "FAIL: \`/model beta/a-think\` 没换到 beta"; echo "$$out"; exit 1; }; \
	: "④ 不公布档位的模型：原样透传"; \
	out=$$($$run --model a-plain --effort xhigh --print-config 2>&1); \
	echo "$$out" | grep -q "reasoning_effort = xhigh" || { echo "FAIL: 不公布档位时应当原样透传"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "not a level this model publishes" || { echo "FAIL: 透传的值应当被标出来（不是模型公布的档位）"; echo "$$out"; exit 1; }; \
	: "⑥ P71：人敲的 /model 切完要写回设置（⑤d 刚切到 beta/a-think 的那一下也落盘）"; \
	grep -q "provider: beta" $$home/settings.yaml || { echo "FAIL: 文本命令 /model beta/a-think 没有写回 settings.yaml"; cat $$home/settings.yaml; exit 1; }; \
	grep -q "model: a-think" $$home/settings.yaml || { echo "FAIL: 写回设置时 model 不对"; cat $$home/settings.yaml; exit 1; }; \
	echo "e2e-model: 通过（目录/能力跟随/目录外只换名字/REPL 报告与切换/非法档位拒/透传标注/同名跨提供方指定与提示/--provider 顺序无关/人敲的 /model 写回设置）"

# P90：**提供方键的 env 档**（`UYA_AGENT_PROVIDER`；离线，真二进制 + 真 settings.yaml）
#   现场：容器 / CI / `--dsh-web` 的对话子进程都只有环境这一条入口，而「换一家提供方跑」
#   以前只能靠命令行，或者改 settings.yaml 里的 `agent-default-model.provider` ——
#   后者顺带改掉的是**用户自己的**默认路线。判据：
#     ① env 压过 settings.yaml，且**路线跟着走**（端点 / `apiKeyEnv` 解出来的密钥 /
#        线协议一起换）；
#     ② cli 压过 env（`--provider`）；
#     ③ 显式优先：env 钉住的提供方不会被 `--model <别家的名字>` 跨提供方回退换掉；
#     ④ env 给全两个（provider + model）时按**二元组**定稿（窗口来自那一条目录条目）；
#     ⑤ 凭据不跨提供方（新提供方解析不出凭据 ⇒ 清空 key + 一行告警）、没声明 `baseURL`
#        的提供方**不动端点**（两件事都不许猜）；
#     ⑥ 反腿：没给 env ⇒ 一切照旧是 dsh-settings；
#     ⑦ 与 `--provider P` **同口径**：同一份设置、两条路，除来源标签外逐字节相同；
#     ⑧ `--resume` 仍跟随会话记录（env 给的是**默认路线**，不是把这一次恢复钉死）。
#   ⚠ 一律 `env -i` 起（宿主导出的 `UYA_AGENT_*` 会把这几条判据搅在一起，同 e2e-ctxwindow）。
e2e-provider: build
	@set -e; \
	home=build/selftest_p90_e2e; rm -rf $$home; mkdir -p $$home; \
	printf 'llm-pi-ai:\n  providers:\n    {\n      alpha:\n        {\n          api: openai-responses,\n          baseURL: https://alpha.example/v1,\n          apiKeyEnv: ALPHA_KEY,\n          models:\n            [\n              { id: a-plain, contextWindow: 111000 }\n            ]\n        },\n      beta:\n        {\n          api: openai-completions,\n          baseURL: https://beta.example/v1,\n          apiKeyEnv: BETA_KEY,\n          models:\n            [\n              { id: a-think, contextWindow: 444000, reasoningEfforts: { off: none, low: low } }\n            ]\n        },\n      gamma:\n        {\n          api: openai-completions,\n          models:\n            [\n              { id: g-one }\n            ]\n        }\n    }\nagent-default-model:\n  provider: alpha\n  model: a-plain\n' > $$home/settings.yaml; \
	bin=$(CURDIR)/$(OUT); \
	cfg="--dsh-home $$home --agent-home $$home/agent --no-dsh-writeback"; \
	: "e = 「干净环境 + 两个假凭据」的包装：所有腿都从它走，别的变量一个都不许漏进来"; \
	e() { env -i PATH=/usr/bin:/bin HOME=$$HOME ALPHA_KEY=alpha-key-1234 BETA_KEY=beta-key-5678 "$$@"; }; \
	: "⑥ 反腿：没给 env ⇒ provider / 端点 / 凭据还是设置里那一条"; \
	out=$$(e $$bin $$cfg --print-config 2>&1); \
	echo "$$out" | grep -q "^provider = alpha  (source: dsh-settings)" || { echo "FAIL: 没给 env 时 provider 应当还是设置里的 alpha"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^api_key = alp…1234  (source: dsh-settings)" || { echo "FAIL: 没给 env 时密钥应当来自设置里的 ALPHA_KEY"; echo "$$out" | head -12; exit 1; }; \
	: "① env 压过设置，且路线（端点 / 凭据 / 协议）跟着这家走"; \
	out=$$(e UYA_AGENT_PROVIDER=beta $$bin $$cfg --print-config 2>&1); \
	echo "$$out" | grep -q "^provider = beta  (source: env)" || { echo "FAIL: UYA_AGENT_PROVIDER=beta 没生效"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^base_url = https://beta.example/v1" || { echo "FAIL: 端点没跟着 env 给的提供方走（请求会打在 alpha 上）"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^api_key = bet…5678" || { echo "FAIL: 凭据没跟着 env 给的提供方走"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^api = openai-completions" || { echo "FAIL: 线协议没跟着 env 给的提供方走"; echo "$$out" | head -12; exit 1; }; \
	: "② cli 压过 env"; \
	out=$$(e UYA_AGENT_PROVIDER=beta $$bin $$cfg --provider alpha --print-config 2>&1); \
	echo "$$out" | grep -q "^provider = alpha  (source: cli)" || { echo "FAIL: --provider alpha 没压过 env 里的 beta"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^base_url = https://alpha.example/v1" || { echo "FAIL: cli 压过 env 之后端点没跟着回 alpha"; exit 1; }; \
	echo "$$out" | grep -q "^api_key = alp…1234" || { echo "FAIL: cli 压过 env 之后凭据没跟着回 alpha"; exit 1; }; \
	: "③ 显式优先：env 钉住的 beta 不许被 --model 跨提供方回退换掉（a-plain 只在 alpha 下）"; \
	out=$$(e UYA_AGENT_PROVIDER=beta $$bin $$cfg --model a-plain --print-config 2>&1); \
	echo "$$out" | grep -q "^provider = beta  (source: env)" || { echo "FAIL: env 给的提供方被 --model 的跨提供方回退改掉了"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^model = a-plain" || { echo "FAIL: --model a-plain 的模型名不对"; exit 1; }; \
	echo "$$out" | grep -q "^base_url = https://beta.example/v1" || { echo "FAIL: 回退发生之后端点也跟着跑了"; exit 1; }; \
	: "④ env 给全两个 ⇒ 按二元组定稿（窗口来自 beta 下那一条）"; \
	out=$$(e UYA_AGENT_PROVIDER=beta UYA_AGENT_MODEL=a-think $$bin $$cfg --print-config 2>&1); \
	echo "$$out" | grep -q "^model = a-think  (source: env)" || { echo "FAIL: UYA_AGENT_MODEL 没生效（或来源没印成 env）"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^context_window = 444000  (source: dsh-settings)" || { echo "FAIL: 窗口没有按 (provider, model) 二元组取（同名模型跨提供方时能力各是各的）"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^efforts = off, low" || { echo "FAIL: 档位清单没按 beta 下的 a-think 取"; exit 1; }; \
	: "⑤ 两处不许猜：解析不出凭据 ⇒ 清空；没声明 baseURL ⇒ 端点一个字节不动"; \
	out=$$(e UYA_AGENT_PROVIDER=gamma $$bin $$cfg --print-config 2>&1); \
	echo "$$out" | grep -q "warning: provider gamma 没解析出凭据" || { echo "FAIL: 新提供方解析不出凭据时没有告警"; exit 1; }; \
	echo "$$out" | grep -q "^api_key = (none)" || { echo "FAIL: 旧提供方的密钥被沿用了（凭据泄露）"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "^base_url = https://alpha.example/v1" || { echo "FAIL: gamma 没声明 baseURL，端点就该保持不动（不许清空也不许猜）"; exit 1; }; \
	: "⑦ 与 --provider P 同口径（除来源标签外逐字节相同）"; \
	e UYA_AGENT_PROVIDER=beta $$bin $$cfg --print-config > $$home/env.txt 2>&1; \
	e $$bin $$cfg --provider beta --print-config > $$home/cli.txt 2>&1; \
	sed 's/^provider = beta  (source: env)$$/provider = beta  (source: PIN)/' $$home/env.txt > $$home/env.norm; \
	sed 's/^provider = beta  (source: cli)$$/provider = beta  (source: PIN)/' $$home/cli.txt > $$home/cli.norm; \
	cmp -s $$home/env.norm $$home/cli.norm || { echo "FAIL: env 与 cli 两条路的 provider 口径不一致"; diff $$home/env.norm $$home/cli.norm | head -20; exit 1; }; \
	: "⑧ --resume 仍跟随会话记录（env 是默认路线，不是钉子）"; \
	sid=session-00000000-0000-4000-8000-000000000090; \
	mkdir -p $$home/agent/sessions/--selftest-p90--/$$sid; \
	printf '{"type":"session","version":0,"id":"%s","createdAt":1790000000000,"cwd":"%s","delegationDepth":0,"agentPreset":"standard","model":"a-plain","provider":"uya-agent"}\n{"type":"user/message","seq":0,"time":1,"data":{"content":[{"type":"text","text":"hello"}]}}\n{"type":"session/model","seq":1,"time":2,"data":{"provider":"alpha","model":"a-plain"}}\n' "$$sid" "$(CURDIR)" > $$home/agent/sessions/--selftest-p90--/$$sid/session.jsonl; \
	out=$$(printf '/model\n/exit\n' | e UYA_AGENT_PROVIDER=beta $$bin $$cfg --no-tui --quiet --resume $$sid 2>&1); \
	echo "$$out" | grep -q "\[session\] 模型跟随会话：a-plain" || { echo "FAIL: --resume 没有跟随会话记录的模型"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "model      a-plain  ·  provider alpha" || { echo "FAIL: 恢复出来的路线不是会话记录那一条（env 不该钉住它）"; echo "$$out" | head -12; exit 1; }; \
	echo "$$out" | grep -q "provider beta" && { echo "FAIL: env 给的提供方把会话记录的路线顶掉了"; echo "$$out" | head -12; exit 1; }; \
	echo "e2e-provider: 通过（env 压过设置且路线跟随 / cli 压过 env / 显式优先不回退 / 二元组定稿能力 / 凭据与端点两处不猜 / 反腿未给 env 照旧 / 与 --provider 同口径 / --resume 仍跟随会话）"

# P81：**上下文窗口的来源链**（离线，真二进制 + 真 settings.yaml）。
# 四档来源：目录条目（dsh-settings）< `uya-agent.contextWindows`（uya-agent）<
# `UYA_AGENT_CONTEXT_WINDOW`（env）< `--context-window`（cli）；都没有就沿用。
# 判据：
#   ① 目录条目；② 映射压过目录条目（含 `提供方/名字` 精确口径）；③ env 压过映射；
#   ④ cli 压过 env；⑤ **两个 flag 的先后顺序无关**（以前是「谁在后面谁赢」，同一对参数
#   结果不同 —— 这条是回归腿）；⑥ 非法值：CLI 报错退出（usage），env 只告警并忽略，
#   设置里那条被跳过并计数；⑦ `--no-dsh-config` 不读映射，什么都没有时是 `-1 (unknown)`；
#   ⑧ 人这一侧的出口：/model 报告的 ctx 行带来源，沿用要说出来。
# ⚠ 一律 `env -i` 起：宿主环境里的 `UYA_AGENT_MODEL` / `UYA_AGENT_BASE_URL` 之类会把这些
#   判据搅在一起（本仓的 e2e 目标里就属它最依赖「干净的机器」）。
e2e-ctxwindow: build
	@set -e; \
	home=build/selftest_p80_e2e; rm -rf $$home; mkdir -p $$home; \
	printf 'llm-pi-ai:\n  providers:\n    {\n      alpha:\n        {\n          api: openai-responses,\n          baseURL: https://alpha.example/v1,\n          apiKeyEnv: ALPHA_KEY,\n          models:\n            [\n              { id: w-one, contextWindow: 111000 },\n              { id: w-two },\n              { id: w-five, contextWindow: 222000 },\n              { id: w-six }\n            ]\n        }\n    }\nagent-default-model:\n  provider: alpha\n  model: w-one\nui-theme:\n  preference: dark\nuya-agent:\n  contextWindows:\n    w-one: 555000\n    alpha/w-two: 666000\n    bad-one: 256K\n' > $$home/settings.yaml; \
	run() { env -i PATH=/usr/bin:/bin HOME=$$HOME $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --print-config "$$@"; }; \
	: "① 映射没写、目录条目写了 ⇒ dsh-settings"; \
	out=$$(run --model w-five 2>&1); \
	echo "$$out" | grep -q "context_window = 222000  (source: dsh-settings)" || { echo "FAIL: 目录条目的 contextWindow 没生效"; echo "$$out"; exit 1; }; \
	: "② 映射压过目录条目（111000 被 555000 盖掉）"; \
	out=$$(run 2>&1); \
	echo "$$out" | grep -q "context_window = 555000  (source: uya-agent)" || { echo "FAIL: uya-agent.contextWindows 没压过目录条目"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "context_window_map = 2 model(s)  (skipped 1 entry/entries" || { echo "FAIL: 映射的条数/跳过计数不对"; echo "$$out"; exit 1; }; \
	out=$$(run --model w-two 2>&1); \
	echo "$$out" | grep -q "context_window = 666000  (source: uya-agent)" || { echo "FAIL: \`提供方/名字\` 那条映射没查到（目录条目里 w-two 没有窗口）"; echo "$$out"; exit 1; }; \
	: "③ env 压过映射；④ cli 压过 env"; \
	out=$$(env -i PATH=/usr/bin:/bin HOME=$$HOME UYA_AGENT_CONTEXT_WINDOW=123456 $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --print-config --model w-two 2>&1); \
	echo "$$out" | grep -q "context_window = 123456  (source: env)" || { echo "FAIL: UYA_AGENT_CONTEXT_WINDOW 没压过映射"; echo "$$out"; exit 1; }; \
	out=$$(env -i PATH=/usr/bin:/bin HOME=$$HOME UYA_AGENT_CONTEXT_WINDOW=123456 $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --print-config --model w-two --context-window 99999 2>&1); \
	echo "$$out" | grep -q "context_window = 99999  (source: cli)" || { echo "FAIL: --context-window 没压过 env"; echo "$$out"; exit 1; }; \
	: "⑤ 顺序无关：同一对参数、两种顺序，整份 --print-config 逐字节相同"; \
	run --model w-two --context-window 99999 > $$home/order-a.txt 2>&1; \
	run --context-window 99999 --model w-two > $$home/order-b.txt 2>&1; \
	cmp -s $$home/order-a.txt $$home/order-b.txt || { echo "FAIL: --model 与 --context-window 的先后顺序会改变结果"; diff $$home/order-a.txt $$home/order-b.txt | head -20; exit 1; }; \
	grep -q "context_window = 99999  (source: cli)" $$home/order-a.txt || { echo "FAIL: 顺序 A 里 cli 的窗口没生效"; exit 1; }; \
	: "⑥ 非法值：CLI 报错退出（usage），env 只告警并忽略"; \
	if run --context-window abc >/dev/null 2>&1; then \
		echo "FAIL: --context-window abc 应当报错退出"; exit 1; \
	fi; \
	out=$$(env -i PATH=/usr/bin:/bin HOME=$$HOME UYA_AGENT_CONTEXT_WINDOW=256K $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --print-config 2>&1); \
	echo "$$out" | grep -q "warning: UYA_AGENT_CONTEXT_WINDOW 不是正整数" || { echo "FAIL: 非法 env 值没有告警"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "context_window = 555000  (source: uya-agent)" || { echo "FAIL: 非法 env 值被忽略之后应当回落到映射"; echo "$$out"; exit 1; }; \
	: "⑦ --no-dsh-config：映射不读；一次都没人给过就是 -1 (unknown)"; \
	out=$$(env -i PATH=/usr/bin:/bin HOME=$$HOME $(CURDIR)/$(OUT) --no-dsh-config --no-dsh-writeback --api-key dummy-key --print-config 2>&1); \
	echo "$$out" | grep -q "context_window = -1 (unknown)  (source: default)" || { echo "FAIL: 没有来源时窗口应当印成 -1 (unknown)（不许把 -1 当 usize 印成天文数字）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "context_window_map = 0 model(s)  (--no-dsh-config: settings not read)" || { echo "FAIL: --no-dsh-config 时不该读 contextWindows（且要说明）"; echo "$$out"; exit 1; }; \
	: "⑧ 人这一侧的出口：/model 报告的 ctx 行带来源，沿用要说出来"; \
	out=$$(printf '/model\n/exit\n' | env -i PATH=/usr/bin:/bin HOME=$$HOME $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --no-tui --quiet 2>&1); \
	echo "$$out" | grep -q "ctx        555000  (source: uya-agent)" || { echo "FAIL: /model 报告没有印出窗口与来源"; echo "$$out"; exit 1; }; \
	out=$$(printf '/model w-six\n/model\n/exit\n' | env -i PATH=/usr/bin:/bin HOME=$$HOME $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --no-tui --quiet 2>&1); \
	echo "$$out" | grep -q "ctx        555000  (source: default，沿用上一个模型的值)" || { echo "FAIL: 切到没有窗口的模型之后应当说清是「沿用」，不许照抄上一个模型的来源"; echo "$$out"; exit 1; }; \
	echo "e2e-ctxwindow: 通过（目录条目 < 映射 < env < cli；顺序无关；非法值 CLI 拒·env 忽略·设置跳过并计数；--no-dsh-config 不读映射；-1 (unknown) 口径；/model 报告的 ctx 行）"

# P84：**收图能力位**（离线，真二进制 + 真 settings.yaml + 真 PNG）。
#   口径是「默认支持」：出厂就是开，只有**明确说不支持**才关 ——
#     ① 目录条目 `input:` 含 image ⇒ 开；**存在但不含**（`[text]`）⇒ **关**（以前只 OR 真、
#        从不清零，切到纯文本模型照收图，收下的必然 400）；**整键没写** ⇒ 沿用（默认支持）；
#     ② 纯 env 路线（`--no-dsh-config` + `UYA_AGENT_MODEL`）**零配置**就能挂图 —— 本轮的正题；
#     ③ `UYA_AGENT_INPUT_IMAGE=0`（env）与 `--input-image` / `--no-input-image`（cli）是**钉子**：
#        压过目录条目、且切模型也不动；
#     ④ 非法值只告警并忽略（绝不静默当开）；
#     ⑤ `--print-config` 的 `input_image = … (source: …)` 四档逐条可证。
#   图是 45 字节的**真 PNG**（IHDR 1×1）：`printf` 八进制写出，不往仓里加二进制夹具。
#   ⚠ 一律 `env -i` 起（宿主导出的 `UYA_AGENT_*` 会把这几条判据搅在一起，同 e2e-ctxwindow）。
e2e-inputimage: build
	@set -e; \
	home=build/selftest_p84_e2e; rm -rf $$home; mkdir -p $$home/att; \
	printf 'llm-pi-ai:\n  providers:\n    {\n      alpha:\n        {\n          api: openai-responses,\n          baseURL: https://alpha.example/v1,\n          apiKeyEnv: ALPHA_KEY,\n          models:\n            [\n              { id: a-vision, input: [ text, image ] },\n              { id: a-plain, input: [ text ] },\n              { id: a-none }\n            ]\n        }\n    }\nagent-default-model:\n  provider: alpha\n  model: a-vision\n' > $$home/settings.yaml; \
	printf '\211PNG\015\012\032\012\000\000\000\015IHDR\000\000\000\001\000\000\000\001\010\002\000\000\000\220wS\336\000\000\000\000IEND\256B\140\202' > $$home/att/one.png; \
	run() { env -i PATH=/usr/bin:/bin HOME=$$HOME $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key "$$@"; }; \
	: "① 目录条目：含 image ⇒ 开；存在但不含 ⇒ 关；整键没写 ⇒ 沿用（默认支持）"; \
	out=$$(run --print-config 2>&1); \
	echo "$$out" | grep -q "^input_image = true  (source: dsh-settings)" || { echo "FAIL: \`input: [text, image]\` 没被认成支持"; echo "$$out"; exit 1; }; \
	out=$$(run --print-config --model a-plain 2>&1); \
	echo "$$out" | grep -q "^input_image = false  (source: dsh-settings)" || { echo "FAIL: \`input: [text]\` 是**明确声明不支持**，必须真的关掉（以前只 OR 真、从不清零）"; echo "$$out"; exit 1; }; \
	out=$$(run --print-config --model a-none 2>&1); \
	echo "$$out" | grep -q "^input_image = true  (source: default；没有声明过 ⇒ 默认支持)" || { echo "FAIL: 整键没写 \`input:\` 时应当沿用「默认支持」，且来源不许冒称 dsh-settings"; echo "$$out"; exit 1; }; \
	: "② 纯 env 路线**零配置**就能挂图（本轮的正题：以前这里必被拒）"; \
	out=$$(printf '/image %s\n/exit\n' "$$home/att/one.png" | env -i PATH=/usr/bin:/bin HOME=$$HOME UYA_AGENT_MODEL=my-vlm $(CURDIR)/$(OUT) --no-dsh-config --agent-home $$home/agent2 --no-dsh-writeback --api-key k --base-url http://127.0.0.1:1/v1 --no-tui --quiet 2>&1); \
	echo "$$out" | grep -q "已挂上：" || { echo "FAIL: 纯 env 路线（默认支持）应当能挂上图，实际被拒了"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "图片 image/png" || { echo "FAIL: 挂上的图没有逐项元数据行"; echo "$$out"; exit 1; }; \
	: "③ 钉子：env=0 压过目录的「支持」；cli 压过 env；--no-input-image 压过目录"; \
	out=$$(env -i PATH=/usr/bin:/bin HOME=$$HOME UYA_AGENT_INPUT_IMAGE=0 $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --print-config 2>&1); \
	echo "$$out" | grep -q "^input_image = false  (source: env)" || { echo "FAIL: UYA_AGENT_INPUT_IMAGE=0 没压过目录条目里的「支持」"; echo "$$out"; exit 1; }; \
	out=$$(env -i PATH=/usr/bin:/bin HOME=$$HOME UYA_AGENT_INPUT_IMAGE=0 $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --print-config --input-image 2>&1); \
	echo "$$out" | grep -q "^input_image = true  (source: cli)" || { echo "FAIL: --input-image 没压过 env"; echo "$$out"; exit 1; }; \
	out=$$(run --print-config --no-input-image 2>&1); \
	echo "$$out" | grep -q "^input_image = false  (source: cli)" || { echo "FAIL: --no-input-image 没压过目录里的「支持」"; echo "$$out"; exit 1; }; \
	: "③b 钉子切模型也不动（显式优先）"; \
	out=$$(env -i PATH=/usr/bin:/bin HOME=$$HOME UYA_AGENT_INPUT_IMAGE=0 $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --print-config --model a-vision 2>&1); \
	echo "$$out" | grep -q "^input_image = false  (source: env)" || { echo "FAIL: env 给的钉子被 --model 的目录条目覆盖了"; echo "$$out"; exit 1; }; \
	: "④ 非法值只告警并忽略（绝不静默当开）」"; \
	out=$$(env -i PATH=/usr/bin:/bin HOME=$$HOME UYA_AGENT_INPUT_IMAGE=maybe $(CURDIR)/$(OUT) --dsh-home $$home --agent-home $$home/agent --no-dsh-writeback --api-key dummy-key --print-config --model a-plain 2>&1); \
	echo "$$out" | grep -q "warning: UYA_AGENT_INPUT_IMAGE 取值须为" || { echo "FAIL: 非法 env 值没有告警"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "^input_image = false  (source: dsh-settings)" || { echo "FAIL: 非法 env 值被忽略之后应当回落到目录条目"; echo "$$out"; exit 1; }; \
	: "⑤ 人这一侧的出口：/model 报告的 image 行（含「要收图」的出口名）」"; \
	out=$$(printf '/model\n/exit\n' | run --no-input-image --no-tui --quiet 2>&1); \
	echo "$$out" | grep -q "^image      off  (source: cli" || { echo "FAIL: /model 报告没有 image 行"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "要收图：--input-image 或 UYA_AGENT_INPUT_IMAGE=1" || { echo "FAIL: 关掉收图时没给出怎么打开的出口"; echo "$$out"; exit 1; }; \
	out=$$(printf '/model\n/exit\n' | run --no-tui --quiet 2>&1); \
	echo "$$out" | grep -q "^image      on  (source: dsh-settings)" || { echo "FAIL: 目录声明支持时 image 行应当印 on + dsh-settings"; echo "$$out"; exit 1; }; \
	echo "e2e-inputimage: 通过（默认支持；目录三态；纯 env 零配置可挂图；env/cli 钉住且切模型不动；非法值告警忽略；--print-config 与 /model 两个出口）"

# P71：**人运行中切模型/强度 ⇒ 这份选择写回 DSH 设置**（离线，真二进制 + 真 settings.yaml）
#   对齐 DSH 自己的行为：`selectModel` → `agentDefaultModel.saveSelection()` → 同一个
#   `agent-default-model` 节。判据都是**文件本身**（textcmp 对照副本），不是回执文案：
#     ① 两个提供方的夹具带注释 + 兄弟节；`/model beta/a-think` 之后：那三行变了，
#        **注释与兄弟节逐字节不变**（`cmp` 只允许差异出现在节里 —— 用「去掉节之后相同」验）；
#     ② `/effort low` 之后 `reasoningEffort` 跟着落；
#     ③ **反腿**：`--model X`（CLI，一次性）一个字节都不写 —— 与 ① 共用同一份夹具快照；
#     ④ **反腿**：`--no-dsh-config` 不写；`--no-dsh-writeback` 不写（且 print-config 说清来源）；
#     ⑤ **反腿**：目录里没有 settings.yaml ⇒ 不新建、只留一行回执；
#     ⑥ **反腿**：flow 写法的节 ⇒ 拒写、文件逐字节不变（不猜、也不整份重写）。
e2e-model-save: build
	@set -e; \
	home=build/selftest_p71_save; rm -rf $$home; mkdir -p $$home; \
	printf '# 顶层注释：写回必须保留它\nui-theme:\n  preference: dark\nagent-default-model:\n  provider: alpha\n  model: a-plain\n  reasoningEffort: high\nllm-pi-ai:\n  providers:\n    {\n      alpha:\n        {\n          api: openai-responses,\n          baseURL: https://alpha.example/v1,\n          models:\n            [\n              { id: a-plain, contextWindow: 111000 },\n              { id: a-think, contextWindow: 222000, reasoningEfforts: { off: none, low: low, high: high } }\n            ]\n        },\n      beta:\n        {\n          api: openai-completions,\n          baseURL: https://beta.example/v1,\n          models:\n            [\n              { id: a-think, contextWindow: 444000, reasoningEfforts: { off: none, low: low, high: high } }\n            ]\n        }\n    }\n' > $$home/settings.yaml; \
	run="$(CURDIR)/$(OUT) --dsh-home $$home --no-tui --quiet --api-key dummy-key"; \
	cp $$home/settings.yaml $$home/snap0; \
	: "① 人敲 /model：三行跟着改，注释与兄弟节逐字节不变"; \
	out=$$(printf '/model beta/a-think\n/effort low\n/exit\n' | $$run 2>&1); \
	echo "$$out" | grep -q "已写回" || { echo "FAIL: /model 之后没有写回回执"; echo "$$out"; exit 1; }; \
	grep -q "^  provider: beta$$" $$home/settings.yaml || { echo "FAIL: provider 没写回"; cat $$home/settings.yaml; exit 1; }; \
	grep -q "^  model: a-think$$" $$home/settings.yaml || { echo "FAIL: model 没写回"; cat $$home/settings.yaml; exit 1; }; \
	grep -q "^  reasoningEffort: low$$" $$home/settings.yaml || { echo "FAIL: reasoningEffort 没写回"; cat $$home/settings.yaml; exit 1; }; \
	grep -q "^# 顶层注释：写回必须保留它$$" $$home/settings.yaml || { echo "FAIL: 顶层注释被写回弄丢了"; cat $$home/settings.yaml; exit 1; }; \
	grep -q "^ui-theme:$$" $$home/settings.yaml || { echo "FAIL: 兄弟节 ui-theme 被写回弄丢了"; cat $$home/settings.yaml; exit 1; }; \
	grep -q "a-plain, contextWindow: 111000" $$home/settings.yaml || { echo "FAIL: llm-pi-ai 那一大块被写回弄丢了"; cat $$home/settings.yaml; exit 1; }; \
	: "①b 行数不变 = 只改了值、没增删任何一行"; \
	a=$$(wc -l < $$home/snap0); b=$$(wc -l < $$home/settings.yaml); \
	[ "$$a" = "$$b" ] || { echo "FAIL: 写回改了行数（$$a → $$b）——叶级替换不该增删行"; exit 1; }; \
	: "② 反腿：CLI 的 --model/--effort 是**一次性**的，一个字节都不许写"; \
	cp $$home/settings.yaml $$home/snap1; \
	$$run --model a-plain --effort high --print-config >/dev/null 2>&1; \
	cmp -s $$home/snap1 $$home/settings.yaml || { echo "FAIL: CLI 的 --model/--effort 把设置写了（那是一次性的）"; exit 1; }; \
	: "③ 反腿：--no-dsh-writeback 之后 /model 不写（且 print-config 说实话）"; \
	out=$$($$run --no-dsh-writeback --print-config 2>&1); \
	echo "$$out" | grep -q "dsh_writeback = off  (source: cli)" || { echo "FAIL: --no-dsh-writeback 没生效"; echo "$$out"; exit 1; }; \
	printf '/model alpha/a-plain\n/exit\n' | $$run --no-dsh-writeback >/dev/null 2>&1; \
	cmp -s $$home/snap1 $$home/settings.yaml || { echo "FAIL: --no-dsh-writeback 之后仍然写了设置"; exit 1; }; \
	out=$$($$run --print-config 2>&1); \
	echo "$$out" | grep -q "dsh_writeback = on  (source: default)" || { echo "FAIL: 默认应当是开"; echo "$$out"; exit 1; }; \
	: "③b env 那一档（UYA_AGENT_DSH_WRITEBACK=0）"; \
	out=$$(UYA_AGENT_DSH_WRITEBACK=0 $$run --print-config 2>&1); \
	echo "$$out" | grep -q "dsh_writeback = off  (source: env)" || { echo "FAIL: UYA_AGENT_DSH_WRITEBACK=0 没生效"; echo "$$out"; exit 1; }; \
	: "④ 反腿：--no-dsh-config 不写（压根没读设置）"; \
	printf '/model alpha/a-plain\n/exit\n' | $$run --no-dsh-config >/dev/null 2>&1; \
	cmp -s $$home/snap1 $$home/settings.yaml || { echo "FAIL: --no-dsh-config 之后仍然写了设置"; exit 1; }; \
	: "⑤ 反腿：目录里没有 settings.yaml ⇒ 不新建、只留一行说明"; \
	none=build/selftest_p71_none; rm -rf $$none; mkdir -p $$none; \
	out=$$(printf '/model a-think\n/exit\n' | $(CURDIR)/$(OUT) --dsh-home $$none --no-tui --quiet --api-key dummy-key 2>&1); \
	echo "$$out" | grep -q "没有 settings.yaml" || { echo "FAIL: 缺设置文件时没有留下可见说明"; echo "$$out"; exit 1; }; \
	[ -z "$$(ls -A $$none)" ] || { echo "FAIL: 缺设置文件时我们新建了东西：$$(ls -A $$none)"; exit 1; }; \
	: "⑥ 反腿：flow 写法的节 ⇒ 拒写且文件逐字节不变"; \
	flow=build/selftest_p71_flow; rm -rf $$flow; mkdir -p $$flow; \
	printf 'agent-default-model: {provider: alpha, model: a-plain}\nllm-pi-ai:\n  providers: { alpha: { api: openai-completions, baseURL: "https://alpha.example/v1", models: [ { id: b-think } ] } }\n' > $$flow/settings.yaml; \
	cp $$flow/settings.yaml $$flow/snap; \
	out=$$(printf '/model b-think\n/exit\n' | $(CURDIR)/$(OUT) --dsh-home $$flow --no-tui --quiet --api-key dummy-key 2>&1); \
	echo "$$out" | grep -q "不是块状写法" || { echo "FAIL: flow 节没有被拒（应当留一行说明）"; echo "$$out"; exit 1; }; \
	cmp -s $$flow/snap $$flow/settings.yaml || { echo "FAIL: 被拒之后文件被改了"; exit 1; }; \
	echo "e2e-model-save: 通过（/model 与 /effort 写回那三行 + 注释与兄弟节逐字节保留 + 行数不变 / CLI 一次性不写 / --no-dsh-writeback 与 env 两档 / --no-dsh-config 不写 / 缺文件不新建 / flow 节拒写）"

# P37：**切模型要连端点与凭据一起跟随**（离线，真终端 + 两个假网关，不联网）
#   用户报的症状是「中途切换不了模型」：切换看起来成功了（信息行/model 报告都变了），
#   但请求**继续发往旧提供方的端点、还带着旧提供方的密钥** —— 于是表现为「切了没反应 /
#   401 / 回答还是旧模型的」。根因是 agent_model_apply 只搬 contextWindow 一类的**能力**，
#   从不重解析 base_url / api_key / api_style（模型目录故意不存 baseURL，见 §16 踩坑 96）。
#   两条腿（`--mode text` 带参命令 / `--mode overlay` 浮层），判据都是**屏幕 + 网关记账**：
#     ① 回合被一条慢 bash 撑住时敲 /model <另一提供方的模型> ⇒ **回合结束前**信息行就变了；
#     ② 之后那条请求打到**新提供方**的网关（旧网关不再收到请求）；
#     ③ 那条请求带的是**新提供方**的 `Authorization`（旧密钥绝不跨提供方发出）；
#     ④ 那一轮的答案是新提供方给的（屏幕上 PROV-B-ANSWER）。
#   对照旧行为：请求继续打到 prov-a（假网关的 stderr 记账里看得见）、带 prov-a 的 key，
#   于是屏幕上永远只有 PROV-A-ANSWER；带参那条还会被当成**给模型的文本**（`/model b-two`
#   出现在请求体里）。两个假网关的记账是各自独立的，所以「打到哪」是硬事实不是推断。
e2e-model-route: build
	@set -e; \
	ws=build/selftest_p37_route; rm -rf $$ws; mkdir -p $$ws; \
	python3 testdata/mock_gateway_route.py 10 > $$ws/gw.log 2>&1 & \
	gw=$$!; \
	trap "kill $$gw 2>/dev/null || true" EXIT; \
	sleep 1.2; \
	pa=$$(awk '/^PORT-A/{print $$2}' $$ws/gw.log); \
	pb=$$(awk '/^PORT-B/{print $$2}' $$ws/gw.log); \
	[ -n "$$pa" ] && [ -n "$$pb" ] || { echo "FAIL: 假网关没打印两个端口"; cat $$ws/gw.log; exit 1; }; \
	UYA_BIN=$(OUT) python3 testdata/pty_drive_model.py --port-a $$pa --port-b $$pb \
		--workspace $$ws/overlay --mode overlay --slow 10; \
	kill -0 $$gw 2>/dev/null || { echo "FAIL: 假网关在第一条腿里就退出了"; cat $$ws/gw.log; exit 1; }; \
	: "② 网关侧硬事实：prov-a 只该收到第一条（撑回合那条），之后全打 prov-b"; \
	a_after=$$(grep -c "^GW-PROV-A #" $$ws/gw.log || true); \
	b_hits=$$(grep -c "^GW-PROV-B #" $$ws/gw.log || true); \
	[ "$$b_hits" -ge 1 ] || { echo "FAIL: prov-b 的网关一条请求都没收到（切换没换端点）"; cat $$ws/gw.log; exit 1; }; \
	: "③ 密钥不跨提供方：prov-b 收到的每一条都必须是 B 的 key"; \
	if grep "^GW-PROV-B #" $$ws/gw.log | grep -qv "auth=Bearer key-of-prov-b"; then \
		echo "FAIL: prov-b 的网关收到了不是它自己的密钥（切完还带着旧提供方的 key）"; \
		grep "^GW-PROV-B #" $$ws/gw.log; exit 1; \
	fi; \
	if grep "^GW-PROV-B #" $$ws/gw.log | grep -q "key-of-prov-a"; then \
		echo "FAIL: prov-a 的密钥被发到了 prov-b 的主机（凭据泄露）"; exit 1; \
	fi; \
	echo "e2e-model-route: 通过（回合运行中切换当场生效 + 请求改打新提供方 + 换用新提供方的密钥）"

# P37：Git worktree（离线，真 git）：独立工作区执行 → 合并 → 删除
#   ① --worktree 开会话：会话里真的有 worktree + dsh/<slug> 分支（状态报告里看得见，
#      而且 `git status` 在它里面跑得通 —— 光有路径说明不了目录真的存在）；
#   ② P49 残留回收：**没干活**就退出（/exit）⇒ 目录与分支当场回收，一个都不留；
#   ③ P49 判据：`/worktree reclaim` 只清「确定的垃圾」—— 干净零提交的清了，
#      带未提交改动的原样留着（那是别人的半成品，不许替他扔）；
#   ④ --no-worktree / 非仓库：不建（fail soft）。
#   数「会话建出来的 worktree」时**不要**用 `git worktree list | grep dsh-worktrees`：从 worktree 会话里
#   跑这轮时，主检出的路径本身就带 `.git/dsh-worktrees/`（CURDIR 在它下面），会把主检出也算进去、数出 2 个
#   （实测）—— 按「非主 worktree 的条数」数（git 保证主检出排第一）才是这条断言的本意。
e2e-worktree: build
	@set -e; \
	if ! command -v git >/dev/null 2>&1; then echo "e2e-worktree: skip（本机没有 git）"; exit 0; fi; \
	ws=build/selftest_p37_e2e_wt; rm -rf $$ws; mkdir -p $$ws; \
	( cd $$ws && git init -q . && git config user.email t@t && git config user.name t && \
	  printf 'base\n' > base.txt && git add -A && git commit -qm init ); \
	run="$(CURDIR)/$(OUT) --no-dsh-config --no-tui --quiet --api-key dummy-key --worktree --no-save"; \
	: "① 会话里真有 worktree（路径 + 分支 + git status 在它里面跑得通）"; \
	out=$$(cd $$ws && printf '/worktree status\n/exit\n' | $$run 2>&1); \
	echo "$$out" | grep -q "worktree: .*\.git/dsh-worktrees/session-" || { echo "FAIL: /worktree status 没报出 worktree 路径"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "branch:   dsh/session-" || { echo "FAIL: /worktree status 没报出会话分支"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "uncommitted: (none)" || { echo "FAIL: 会话里的 worktree 读不到 git status（目录没真建出来？）"; echo "$$out"; exit 1; }; \
	: "② P49：空跑的会话退出 ⇒ 残留当场回收（目录与分支都不留）"; \
	n=$$(cd $$ws && git worktree list | tail -n +2 | wc -l); \
	[ "$$n" = "0" ] || { echo "FAIL: 空跑的会话退出后还留着 worktree（数量=$$n）—— P49 的退出回收没生效"; exit 1; }; \
	b=$$(cd $$ws && git branch --list 'dsh/*' | wc -l); \
	[ "$$b" = "0" ] || { echo "FAIL: 空跑的会话退出后还留着 dsh/* 分支（数量=$$b）"; exit 1; }; \
	: "③ P49：reclaim 只清确定的垃圾（干净零提交清掉 / 带改动留着）"; \
	( cd $$ws && git worktree add -b dsh/junk .git/dsh-worktrees/junk master >/dev/null 2>&1 && \
	  git worktree add -b dsh/half .git/dsh-worktrees/half master >/dev/null 2>&1 && \
	  printf 'half done\n' > .git/dsh-worktrees/half/half.txt ); \
	out=$$(cd $$ws && printf '/worktree reclaim\n/exit\n' | $$run 2>&1); \
	echo "$$out" | grep -q "reclaimed dsh/junk" || { echo "FAIL: 干净零提交的残留没被回收"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "kept dsh/half" || { echo "FAIL: 带改动的残留没被明确留下（要看到 kept 那一行）"; echo "$$out"; exit 1; }; \
	[ ! -d $$ws/.git/dsh-worktrees/junk ] || { echo "FAIL: 该清的残留目录还在"; exit 1; }; \
	[ -f $$ws/.git/dsh-worktrees/half/half.txt ] || { echo "FAIL: 带改动的残留被误删了（那是别人的半成品）"; exit 1; }; \
	[ "$$(cd $$ws && git branch --list 'dsh/half' | wc -l)" = "1" ] || { echo "FAIL: 带改动的残留分支被误删了"; exit 1; }; \
	[ "$$(cd $$ws && git worktree list | tail -n +2 | wc -l)" = "1" ] || { echo "FAIL: reclaim 之后应当只剩带改动的那一个"; exit 1; }; \
	: "④ 非仓库 / --no-worktree：不建"; \
	: "   注意：norepo 必须放在 /tmp —— 放在 build/ 下面它会**继承外层仓库**（git 会往上找）"; \
	: "   跑完要删掉：不删的话每跑一次 make e2e-worktree 就在 /tmp 里留一个（实测 2 天攒了 62 个）"; \
	nr=/tmp/selftest_p37_e2e_norepo_$$$$; rm -rf $$nr; mkdir -p $$nr; \
	out=$$(cd $$nr && printf '/worktree status\n/exit\n' | $$run 2>&1); \
	rm -rf $$nr; \
	echo "$$out" | grep -q "not inside a Git repository" || { echo "FAIL: 非仓库目录没有 fail soft"; echo "$$out"; exit 1; }; \
	[ "$$(cd $$ws && git worktree list | tail -n +2 | wc -l)" = "1" ] || { echo "FAIL: 非仓库那一次把 $$ws 的 worktree 弄丢了"; exit 1; }; \
	: "④b --no-worktree 明确关"; \
	ws2=build/selftest_p37_e2e_wt_off; rm -rf $$ws2; mkdir -p $$ws2; \
	( cd $$ws2 && git init -q . && git config user.email t@t && git config user.name t && printf 'x\n' > x.txt && git add -A && git commit -qm init ); \
	out=$$(cd $$ws2 && printf '/worktree status\n/exit\n' | $(CURDIR)/$(OUT) --no-dsh-config --no-tui --quiet --api-key dummy-key --no-worktree --no-save 2>&1); \
	echo "$$out" | grep -q "worktree mode is off" || { echo "FAIL: --no-worktree 没有关掉"; echo "$$out"; exit 1; }; \
	[ "$$(cd $$ws2 && git worktree list | tail -n +2 | wc -l)" = "0" ] || { echo "FAIL: --no-worktree 还是建了 worktree"; exit 1; }; \
	echo "e2e-worktree: 通过（会话里真建 worktree / 退出回收残留 / reclaim 只清确定的垃圾 / 非仓库 fail soft / --no-worktree 关闭）"

#   ④ 记录的工作区被删（worktree 合并后就删是常态）→ 留在当前工作区 + 留话 + 记一条 fallback。
# 会话日志用 python3 手写（格式与 sess_open 逐字节一致）：这一轮**不联网、不用模型**。
# 两个工作区都用**绝对**路径：切换是真的 chdir，相对路径会被带到新工作区下面去。
# P73：可搬运性 —— 「把 build/uya-agent 拷到别的机器上还能跑完整功能（含 web）」。
# 这一轮把那个说法做成机器判据：**空 HOME + 无 DSH + 无仓库**（真新机器的样子），
# 只带一个二进制。
#
# 两条腿，都是本轮修掉的静默降级：
#   ① **plan 策略段**：以前只在磁盘上的 DSH preset 里，没装 DSH 时整段消失，而写闸门
#      照样硬拒 write/edit（模型被挡住写、又没被告知该调 exit_plan_mode）。现在有
#      编译期内嵌快照兜底 ⇒ 假网关收到的请求里必须出现只在那个文件里才有的句子。
#      判据串在工作树与编译器树里 **0 命中**，所以它不可能假绿。
#   ② **web 会话子进程的配置**：子进程是 fork+execve 出来的、argv 只带 `--tui`，
#      父进程从命令行拿到的配置以前一个都没传 ⇒ 权限被悄悄放宽成 Full access、
#      自建网关被换成默认端点。现在按环境变量注入 ⇒ 会话必须走父进程给的网关，
#      且日志落在父进程给的 --agent-home 下。
# 反向断言（不许夺权）：磁盘上真有 preset 时，**磁盘赢**（内嵌只是「没装」的兜底）。
# 全程离线：假网关在 127.0.0.1，--print-config 不联网。
e2e-portable: build
	@set -e; \
	root=$$(pwd); \
	ws=/tmp/e2e_portable_$$$$; home=$$ws/home; newbin=$$ws/bin; \
	gwlog=$$ws/gw.log; req=$$ws/req.bin; \
	rm -rf $$ws; mkdir -p $$home $$newbin; \
	cleanup() { kill $$gwp 2>/dev/null || true; rm -rf $$ws; }; \
	trap cleanup EXIT; \
	: "新机器：只拷一个二进制过去，HOME 是个空目录"; \
	cp $(CURDIR)/$(OUT) $$newbin/uya-agent; \
	python3 testdata/mock_gateway_portable.py 0 $$req > $$gwlog 2>&1 & \
	gwp=$$!; \
	sleep 0.5; \
	port=$$(awk '/^PORT/{print $$2}' $$gwlog); \
	if [ -z "$$port" ]; then echo "FAIL: 假网关没起来"; cat $$gwlog; exit 1; fi; \
	: "---- ① 内嵌 preset 兜底：没装 DSH 也要有完整的 plan 段 ----"; \
	out=$$(env -u UYA_AGENT_DSH_ROOT HOME=$$home $$newbin/uya-agent --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "knobs (source: embedded)" \
		|| { echo "FAIL: 没装 DSH 时旋钮来源应当是 embedded"; echo "$$out" | grep knobs; exit 1; }; \
	: "旋钮值必须与内置缺省逐字节相同（内嵌只是换来源，不改值）"; \
	echo "$$out" | grep -q "readLimit=2000 readMaxBytes=51200 readMaxLine=2000" \
		|| { echo "FAIL: 内嵌来源下 read 旋钮不是缺省值"; exit 1; }; \
	echo "$$out" | grep -q "prune=8192/4096/1024/0/0 glob=100 grep=250/2000" \
		|| { echo "FAIL: 内嵌来源下剪枝/搜索旋钮不是缺省值"; exit 1; }; \
	: "跑一轮 plan：请求里必须有只存在于上游 preset 里的那句"; \
	: "⚠ 这一发**必须** --api-retry-max 0（P82）：本轮的假网关回的是**非 SSE** 的整段 JSON，"; \
	: "   而客户端要的是流 ⇒ 那是 LlmStreamClosed（分类表里可重试）⇒ 不退避的话它会一直重发"; \
	: "   （实测：req.bin 从几百字节涨到 30 MB，整轮 make selftest 卡死 35 分钟）。"; \
	: "   这一轮的判据是「请求里有没有 plan 段」，不是「网关答得好不好」，所以关掉重试最贴题。"; \
	env -u UYA_AGENT_DSH_ROOT HOME=$$home UYA_AGENT_API_KEY=k \
		$$newbin/uya-agent --no-dsh-config --plan --api=chat --model portable-m \
		--base-url "http://127.0.0.1:$$port/v1" --workspace $$ws --agent-home $$home \
		--api-retry-max 0 \
		--max-steps 1 --quiet "plan something" >/dev/null 2>&1 || true; \
	sleep 0.5; \
	if [ ! -s $$req ]; then echo "FAIL: 假网关没收到请求（内嵌 preset 那一轮没跑起来）"; exit 1; fi; \
	grep -q "Make the plan decision-complete" $$req \
		|| { echo "FAIL: 没装 DSH 时 plan 策略段缺失（内嵌兜底没生效）"; exit 1; }; \
	grep -q "Stay in plan mode" $$req \
		|| { echo "FAIL: plan 段不在请求里"; exit 1; }; \
	: "---- 反向断言：磁盘上有 preset 时磁盘赢 ----"; \
	out=$$(env -u UYA_AGENT_DSH_ROOT HOME=$$home $$newbin/uya-agent \
		--dsh-root testdata/preset-root --print-config 2>&1); \
	echo "$$out" | grep -q "knobs (source: preset)" \
		|| { echo "FAIL: 磁盘上有 preset 时来源应当是 preset（内嵌不许夺权）"; exit 1; }; \
	echo "$$out" | grep -q "readLimit=1777" \
		|| { echo "FAIL: 磁盘预设的旋钮没生效（被内嵌顶掉了）"; exit 1; }; \
	: "---- ② web 会话子进程拿到父进程的命令行配置 ----"; \
	rm -f $$req; webhome=$$ws/agenthome; mkdir -p $$webhome; \
	setsid env -u UYA_AGENT_DSH_ROOT -u UYA_AGENT_BASE_URL -u UYA_AGENT_MODEL \
		HOME=$$home UYA_AGENT_API_KEY=k \
		$$newbin/uya-agent --no-dsh-config --web 127.0.0.1:0 --workspace $$ws \
		--agent-home $$webhome --api=chat --model portable-child \
		--permission read-only --base-url "http://127.0.0.1:$$port/v1" \
		> $$ws/web.log 2>&1 < /dev/null & \
	wpid=$$!; \
	sleep 2; \
	wport=$$(sed -n 's/.*http:\/\/127\.0\.0\.1:\([0-9]*\)\/.*/\1/p' $$ws/web.log | head -1); \
	if [ -z "$$wport" ]; then echo "FAIL: --web 没起来"; cat $$ws/web.log; exit 1; fi; \
	sid=$$(curl -s -X POST "http://127.0.0.1:$$wport/api/sessions" \
		| sed 's/.*"id":"\([^"]*\)".*/\1/'); \
	[ -n "$$sid" ] || { echo "FAIL: 建不了 web 会话"; exit 1; }; \
	sleep 1; \
	printf 'hello\r' > $$ws/keys.bin; \
	curl -s -X POST --data-binary @$$ws/keys.bin \
		"http://127.0.0.1:$$wport/api/input?id=$$sid" >/dev/null; \
	sleep 3; \
	kill $$wpid 2>/dev/null || true; \
	if [ ! -s $$req ]; then \
		echo "FAIL: web 会话没走父进程给的网关（子进程丢配置 / 权限被放宽）"; \
		cat $$ws/web.log; exit 1; \
	fi; \
	grep -q '"model":"portable-child"\|"model": *"portable-child"' $$req \
		|| { echo "FAIL: web 会话子进程没用父进程给的 --model"; exit 1; }; \
	logs=$$(find $$webhome -name session.jsonl 2>/dev/null | wc -l); \
	[ "$$logs" -ge 1 ] \
		|| { echo "FAIL: web 会话日志没落在 --agent-home 下（子进程用了默认 home）"; exit 1; }; \
	grep -q "不会.*传进会话子进程" $$ws/web.log \
		|| { echo "FAIL: 没有把「不传的开关」说出来（--no-dsh-config 应当被点名）"; exit 1; }; \
	echo "e2e-portable: 通过（空 HOME/无 DSH/无仓库：内嵌 preset 兜底 + plan 段在 + 磁盘优先 + web 子进程继承父配置与权限）"

e2e-ws: build
	@set -e; \
	root=$$(pwd); ws=$$root/build/selftest_p31_e2e; home=$$ws/home; a=$$ws/a; b=$$ws/b; c=$$ws/c; \
	sid=session-aaaa1111-2222-3333-4444-555566667777; \
	rm -rf $$ws; mkdir -p $$a $$b $$c; \
	( cd $$a && git init -q . && git config user.email t@t && git config user.name t && \
	  printf 'one\n' > f.txt && git add -A && git commit -qm init && printf 'changed-in-A\n' > f.txt ); \
	( cd $$b && git init -q . && git config user.email t@t && git config user.name t && \
	  printf 'two\n' > g.txt && git add -A && git commit -qm init && printf 'changed-in-B\n' > g.txt ); \
	python3 -c "import json,os,sys;\
home,a,sid=sys.argv[1],sys.argv[2],sys.argv[3];\
d=os.path.join(home,'sessions','--'+a.replace('/','-')+'--',sid);\
os.makedirs(d,exist_ok=True);\
p=os.path.join(d,'session.jsonl');\
rows=[{'type':'session','version':0,'id':sid,'createdAt':1790993000000,'cwd':a,'delegationDepth':0,'agentPreset':'standard','model':'deepseek-chat','provider':'uya-agent'},\
{'type':'user/message','seq':0,'time':1790993000001,'data':{'role':'user','content':[{'type':'text','text':'记住 5150'}],'source':{'kind':'user'}}},\
{'type':'assistant/message','seq':1,'time':1790993000002,'data':{'turn':1,'step':1,'message':{'role':'assistant','content':[{'type':'text','text':'记住了'}]}}},\
{'type':'turn/end','seq':2,'time':1790993000003,'data':{'turn':1,'reason':'completed'}}];\
open(p,'w').write(''.join(json.dumps(r,ensure_ascii=False,separators=(',',':'))+chr(10) for r in rows));\
open(os.path.join(home,'index.jsonl'),'w').write(json.dumps({'id':sid,'cwd':a,'lastActiveAt':1790993000003,'title':'记住 5150','model':'deepseek-chat','delegationDepth':0,'turns':1,'events':3,'path':p},ensure_ascii=False,separators=(',',':'))+chr(10))" $$home $$a $$sid; \
	run="$(CURDIR)/$(OUT) --no-dsh-config --no-tui --quiet --api-key dummy-key --agent-home $$home"; \
	: "① + ② 从 B 恢复 A 的会话"; \
	out=$$(cd $$b && printf '/workspace\n/diff\n/exit\n' | $$run --resume $$sid 2>&1 || true); \
	echo "$$out" | grep -q "工作区跟随会话：$$a" || { echo "FAIL: 恢复会话没有把工作区切到会话记录的那一个"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "workspace: $$a (source: session)" || { echo "FAIL: /workspace 报告的工作区或来源不对"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "\[diff\] .*selftest_p31_e2e/a " || { echo "FAIL: /diff 的头里不是会话的工作区"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q -- "+changed-in-A" || { echo "FAIL: /diff 打的不是工作区 A 的改动"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "changed-in-B" && { echo "FAIL: /diff 里混进了当前目录（B）的改动"; echo "$$out"; exit 1; } || true; \
	n=$$(find $$home/sessions -name session.jsonl | wc -l); \
	[ "$$n" = "1" ] || { echo "FAIL: 恢复之后日志被改挂（session.jsonl 份数=$$n，应当只有 1 份）"; find $$home/sessions -name session.jsonl; exit 1; }; \
	tail -1 $$home/index.jsonl | grep -q "\"cwd\":\"$$a\"" || { echo "FAIL: 索引里的工作区不是会话那一个（被当前目录改写了？）"; tail -1 $$home/index.jsonl; exit 1; }; \
	: "③ 显式 --workspace 优先"; \
	out=$$(cd $$b && printf '/workspace\n/exit\n' | $$run --workspace $$c --resume $$sid 2>&1 || true); \
	echo "$$out" | grep -q "工作区按显式指定" || { echo "FAIL: 显式 --workspace 没有优先于会话记录"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "workspace: $$c (source: cli)" || { echo "FAIL: 显式指定之后报告不对"; echo "$$out"; exit 1; }; \
	: "④ 记录的工作区被删"; \
	mv $$a $$a-gone; \
	out=$$(cd $$b && printf '/exit\n' | $$run --resume $$sid 2>&1 || true); \
	echo "$$out" | grep -q "会话记录的工作区已不存在" || { echo "FAIL: 记录的工作区被删之后没有留话"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "留在当前工作区 $$b" || { echo "FAIL: 被删之后没有留在当前工作区"; echo "$$out"; exit 1; }; \
	grep -q '"source":"fallback"' $$home/sessions/--*--/$$sid/session.jsonl || { echo "FAIL: 日志里没有 fallback 那一条记录"; exit 1; }; \
	echo "e2e-ws: 通过（跟随会话工作区 + 日志不改挂 + 索引 cwd 正确 + 显式优先 + 记录目录被删的退路）"


# 真实网关端到端：默认走 DSH 设置（零参数就能拿到 base-url/model/key），
# 也可以显式覆盖。TLS：给了 PIN 用 pin，否则用 none（真机链校验过不去，见 §18）
# 步数默认不限（跑到模型给出最终答案）；要熔断就 make e2e STEPS=N
e2e: build
	@echo "== e2e: 真实网关（配置来自 DSH 设置，除非显式覆盖）=="
	$(OUT) $(if $(PIN),--tls-verify=pin --tls-pin $(PIN),--tls-verify=none) \
		$(if $(BASE_OVERRIDE),--base-url $(BASE_OVERRIDE),) \
		$(if $(MODEL),--model $(MODEL),) \
		$(if $(STEPS),--max-steps $(STEPS),) "$(TASK)"

# 零参数自检：只用 DSH 设置就能跑（不联网，只打印生效配置与旋钮来源）
e2e-config: build
	$(OUT) --print-config

# P55 执行期两条纪律的开关（低思考执行态 + 收工预算）：默认关、CLI/env 都要在 --print-config
# 上看得见、`--help` 要列出来。三条纪律本身（提醒文案）由 --selftest 的 prompt 钉子守。
e2e-exec: build
	@set -e; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "exec_effort" \
		&& { echo "FAIL: 默认没配也打印了 exec 段（两个机制应当默认关）"; exit 1; } || true; \
	out=$$($(OUT) --no-dsh-config --exec-effort low --exec-after 7 --grace-steps 5 --print-config 2>&1); \
	echo "$$out" | grep -q "exec_effort = low  exec_after = 7  grace_steps = 5" \
		|| { echo "FAIL: --exec-effort/--exec-after/--grace-steps 没有生效"; echo "$$out"; exit 1; }; \
	out=$$(UYA_AGENT_EXEC_EFFORT=medium UYA_AGENT_EXEC_AFTER=3 UYA_AGENT_GRACE_STEPS=2 \
		$(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "exec_effort = medium  exec_after = 3  grace_steps = 2" \
		|| { echo "FAIL: env 口径（UYA_AGENT_EXEC_EFFORT/EXEC_AFTER/GRACE_STEPS）没有生效"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --exec-effort low --exec-after 7 --print-config 2>&1); \
	echo "$$out" | grep -q "grace_steps = 0" \
		|| { echo "FAIL: 没给 --grace-steps 时应当是 0（只提醒、不设硬上限）"; exit 1; }; \
	$(OUT) --help 2>&1 | grep -q -- "--exec-effort" \
		|| { echo "FAIL: --help 里没有 --exec-effort"; exit 1; }; \
	$(OUT) --help 2>&1 | grep -q -- "--grace-steps" \
		|| { echo "FAIL: --help 里没有 --grace-steps"; exit 1; }; \
	echo "e2e-exec: 通过（两个机制默认关；CLI/env 都生效；--help 有；--grace-steps 缺省 0）"; \
	: "低思考执行态的切换与**回合结束还原**（借假网关跑两个回合）"; \
	ws=$(CURDIR)/build/e2e_exec_ws; rm -rf $$ws; mkdir -p $$ws; \
	printf 'build:\n\t@echo EXEC-OK\n' > $$ws/Makefile; \
	home=$(CURDIR)/build/e2e_exec_home; rm -rf $$home; mkdir -p $$home; \
	python3 testdata/mock_gateway_accept.py 0 > $(CURDIR)/build/e2e_exec_gw.log 2>&1 & \
	gw=$$!; \
	sleep 0.4; \
	port=$$(awk '/^PORT/{print $$2}' $(CURDIR)/build/e2e_exec_gw.log); \
	if [ -z "$$port" ]; then echo "FAIL: 假网关没起来"; kill $$gw 2>/dev/null || true; exit 1; fi; \
	: "第二行延迟喂：早喂会被当成运行中的 steer，就不是新回合了（也就测不到还原）"; \
	: "基准档位必须配（--effort xhigh）：没配就没东西可还原，exec-restore 本来就不该出现"; \
	( printf '任务一\n'; sleep 3; printf '任务二\n'; sleep 3; printf '/exit\n' ) | \
		UYA_AGENT_API_KEY=k $(OUT) --no-dsh-config --no-stream --no-tui --quiet \
		--base-url "http://127.0.0.1:$$port/v1" --api=chat --model mock-model \
		--workspace $$ws --agent-home $$home --tls-verify=none \
		--effort xhigh --exec-effort low --exec-after 1 > $(CURDIR)/build/e2e_exec_out.txt 2>&1 || true; \
	kill $$gw 2>/dev/null || true; \
	log=$$(ls $$home/sessions/*/*/session.jsonl 2>/dev/null | head -1); \
	if [ -z "$$log" ]; then echo "FAIL: 执行期降档那两回合没有落会话日志"; cat $(CURDIR)/build/e2e_exec_out.txt; exit 1; fi; \
	grep -q '"source":"exec-effort"' $$log || { echo "FAIL: 没有切档记录（source=exec-effort）"; exit 1; }; \
	grep -q '"source":"exec-restore"' $$log || { echo "FAIL: 第二个回合开始没有把档位还原（source=exec-restore）"; exit 1; }; \
	turns=$$(grep -c '"type":"turn/start"' $$log || true); \
	[ "$$turns" = "2" ] || { echo "FAIL: 期望 2 个回合，实际 $$turns（第二行被当成 steer 了？）"; exit 1; }; \
	echo "e2e-exec: 通过（默认关；CLI/env 生效；--help 有；降档 → exec-effort；回合开始 → exec-restore；2 回合）"

# P82：**传输层失败 → 退避重发**（离线，真二进制 + 假网关，不联网）。
#   现场见 DESIGN §19.1 坑二：上游一次 5xx / 超时 / 掐断流，本仓原来一层重试都没有 ——
#   直接退出码 2，整个任务作废（配对窗口内本仓 163 次请求 2 次失败，丢的全是能解的题）。
#
#   四条腿（判据全落在**网关侧收到的请求体**与退出码上，不只看转录）：
#     ① 默认（不限次数）：503→503→200 ⇒ 退出 0、两条 `[retry]`、日志两条 `llm/retry`、
#        **三次请求逐字节相同**（同一步重发、历史一个字节没动）；
#     ② `--api-retry-max 0`：503 之后**当场**退出，网关只收到 1 次请求（闸门关得掉）；
#     ③ `--api-retry-max 1`：发满 1 次就不再发，网关只收到 1 次请求（上限被尊重）；
#     ④ `--api-retry-max 2`：503→200 ⇒ 退出 0、只有一条 `[retry]`（上限 2 = 最多发 2 次）；
#     ⑤ 死端口（传输错，连不上）：`--api-retry-max 3` ⇒ 退出 **2**（不是 3）+ 两条 `[retry]`
#        —— 第 ⑤ 条专门钉「退出码与失败种类对得上」：非 200 走 AGENT_PROTO(3)，
#        传输错走 AGENT_NET(2)，重试**不许**把这个区别抹平（脚本靠它分辨该不该重跑）。
#   为什么②③要单独成腿：`0` 这一档最要紧（CI 要的 fail fast），而它最容易写错 ——
#   `parse_i32_arg` 把 0 当无效值，照抄过来 `--api-retry-max 0` 会静默变成「无限重试」。
e2e-retry: build
	@set -e; \
	ws=$(CURDIR)/build/e2e_retry_ws; rm -rf $$ws; mkdir -p $$ws; \
	: "规范和值本身（离线，不联网）"; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "api_retry_max = unlimited (-1)  (source: default)" \
		|| { echo "FAIL: 默认应当是「不限次数」"; echo "$$out" | grep api_retry_max; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --api-retry-max 0 --print-config 2>&1); \
	echo "$$out" | grep -q "api_retry_max = 0  (source: cli)" \
		|| { echo "FAIL: --api-retry-max 0 没生效（0 被当成无效值了？）"; echo "$$out" | grep api_retry_max; exit 1; }; \
	out=$$(UYA_AGENT_API_RETRY_MAX=3 $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "api_retry_max = 3  (source: env)" \
		|| { echo "FAIL: UYA_AGENT_API_RETRY_MAX 没生效"; exit 1; }; \
	out=$$(UYA_AGENT_API_RETRY_MAX=zz $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "warning: UYA_AGENT_API_RETRY_MAX" \
		|| { echo "FAIL: 非法 UYA_AGENT_API_RETRY_MAX 没有告警"; exit 1; }; \
	echo "$$out" | grep -q "api_retry_max = unlimited (-1)" \
		|| { echo "FAIL: 非法值应回落到默认（不限）"; exit 1; }; \
	$(OUT) --help 2>&1 | grep -q -- "--api-retry-max" \
		|| { echo "FAIL: --help 里没有 --api-retry-max"; exit 1; }; \
	: "四条端到端腿：每条一个**全新的**网关进程（脚本按收到的请求数推进，复用会错位）"; \
	run_leg() { \
		tag="$$1"; fails="$$2"; maxarg="$$3"; want_rc="$$4"; want_req="$$5"; \
		want_retry="$$6"; \
		home=$(CURDIR)/build/e2e_retry_home_$$tag; rm -rf $$home; mkdir -p $$home; \
		gwlog=$(CURDIR)/build/e2e_retry_gw_$$tag.log; \
		python3 testdata/mock_gateway_retry.py 0 $$fails 503 > $$gwlog 2>&1 & \
		gw=$$!; \
		sleep 0.7; \
		port=$$(awk '/^PORT/{print $$2}' $$gwlog); \
		if [ -z "$$port" ]; then echo "FAIL: $$tag 的假网关没起来"; cat $$gwlog; kill $$gw 2>/dev/null || true; exit 1; fi; \
		rc=0; \
		UYA_AGENT_API_KEY=k $(OUT) --no-dsh-config --no-tui --quiet \
			--base-url "http://127.0.0.1:$$port/v1" --api=chat --model mock-model \
			--workspace $$ws --agent-home $$home --tls-verify=none \
			$$maxarg "say hi" > $(CURDIR)/build/e2e_retry_out_$$tag.txt 2>&1 || rc=$$?; \
		sleep 0.3; kill $$gw 2>/dev/null || true; \
		[ "$$rc" = "$$want_rc" ] \
			|| { echo "FAIL: $$tag 退出码 $$rc（期望 $$want_rc）"; cat $(CURDIR)/build/e2e_retry_out_$$tag.txt; exit 1; }; \
		n=$$(grep -c "^REQ " $$gwlog || true); \
		[ "$$n" = "$$want_req" ] \
			|| { echo "FAIL: $$tag 网关收到 $$n 次请求（期望 $$want_req）"; cat $$gwlog; exit 1; }; \
		: "重发的请求必须与首次**逐字节相同**（same=0 就是有人在中途动了历史/请求）"; \
		bad=$$(grep -c "same=0" $$gwlog || true); \
		[ "$$bad" = "0" ] \
			|| { echo "FAIL: $$tag 有请求与首次不同（重发路径动了请求体）"; cat $$gwlog; exit 1; }; \
		k=$$(grep -c "\[retry\] " $(CURDIR)/build/e2e_retry_out_$$tag.txt || true); \
		[ "$$k" = "$$want_retry" ] \
			|| { echo "FAIL: $$tag 转录里的 [retry] 行数 $$k（期望 $$want_retry）"; cat $(CURDIR)/build/e2e_retry_out_$$tag.txt; exit 1; }; \
		log=$$(ls $$home/sessions/*/*/session.jsonl 2>/dev/null | head -1); \
		if [ -z "$$log" ]; then echo "FAIL: $$tag 没有落会话日志"; exit 1; fi; \
		ev=$$(grep -c '"type":"llm/retry"' $$log || true); \
		[ "$$ev" = "$$want_retry" ] \
			|| { echo "FAIL: $$tag 日志里的 llm/retry 条数 $$ev（期望 $$want_retry）"; grep llm/retry $$log; exit 1; }; \
		st=$$(grep -c '"type":"step/start"' $$log || true); \
		[ "$$st" = "1" ] || { echo "FAIL: $$tag 的 step/start 不是 1 条（重发必须同一步）"; exit 1; }; \
	}; \
	run_leg default 2 "" 0 3 2; \
	run_leg off 2 "--api-retry-max 0" 3 1 0; \
	run_leg one 2 "--api-retry-max 1" 3 1 0; \
	run_leg two 1 "--api-retry-max 2" 0 2 1; \
	: "重试确实等了：那一行的 backoff= 必须在 [0.5s, 3.0s] 区间里"; \
	grep -q "backoff=[0-2]\.[0-9]s" $(CURDIR)/build/e2e_retry_out_default.txt \
		|| { echo "FAIL: 默认腿的退避值不在 0.5–3.0 s 区间里"; grep retry $(CURDIR)/build/e2e_retry_out_default.txt; exit 1; }; \
	grep -q "ctrl+c 中断" $(CURDIR)/build/e2e_retry_out_default.txt \
		|| { echo "FAIL: [retry] 行没有告诉用户怎么停（ctrl+c）"; exit 1; }; \
	: "⑤ 传输错（死端口）：重试了、但退出码仍是 2（不许与「服务端说不行」的 3 混为一谈）"; \
	home=$(CURDIR)/build/e2e_retry_home_dead; rm -rf $$home; mkdir -p $$home; \
	: "端口 1 上不会有人监听（connect 立刻 ECONNREFUSED）—— 用它当「连不上」的稳定现场"; \
	rc=0; \
	UYA_AGENT_API_KEY=k $(OUT) --no-dsh-config --no-tui --quiet --api-retry-max 3 \
		--base-url "http://127.0.0.1:1/v1" --api=chat --model mock-model \
		--workspace $$ws --agent-home $$home --tls-verify=none \
		"say hi" > $(CURDIR)/build/e2e_retry_out_dead.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "2" ] \
		|| { echo "FAIL: 死端口那一次的退出码是 $$rc（期望 2 = 传输错）"; cat $(CURDIR)/build/e2e_retry_out_dead.txt; exit 1; }; \
	k=$$(grep -c "\[retry\] transport" $(CURDIR)/build/e2e_retry_out_dead.txt || true); \
	[ "$$k" = "2" ] \
		|| { echo "FAIL: 死端口那次的重试行数 $$k（期望 2：发了 3 次 = 重试 2 次）"; cat $(CURDIR)/build/e2e_retry_out_dead.txt; exit 1; }; \
	: "  预算用尽之后**要说对是哪一档**（P92 收紧：以前这条腿断言的是那句笼统的"; \
	: "  「网络或 TLS 校验」，而那正是踩坑 133 要消灭的谎 —— 死端口是「连不上」不是 TLS。"; \
	: "  现在断言「连不上服务器」：它同时证了「失败档位跨重试没丢」这条"; \
	grep -q "请求失败（连不上服务器）" $(CURDIR)/build/e2e_retry_out_dead.txt \
		|| { echo "FAIL: 预算用尽后没说清是「连不上服务器」（档位在重试路上丢了）"; \
		cat $(CURDIR)/build/e2e_retry_out_dead.txt; exit 1; }; \
	if grep -q "TLS 校验" $(CURDIR)/build/e2e_retry_out_dead.txt; then \
		echo "FAIL: 死端口却说成了 TLS 校验"; exit 1; fi; \
	echo "e2e-retry: 通过（默认重发到成功 + 0/1/2 三个上限各自生效 + 重发逐字节相同 + 同一步 + 退出码分类不变）"
# CLI flag 回归：--dsh-home / --no-dsh-config / --strict-dsh-config 决定「去哪儿读设置」，
# 必须在下一次加载之前生效（曾经因为完整 CLI 解析排在加载之后而三个 flag 全部静默失效，
# 见 §16 踩坑 25）。离线可跑：--print-config 不联网。
e2e-config-flags: build
	@set -e; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "base_url = https://api.deepseek.com/v1  (source: default)" \
		|| { echo "FAIL: --no-dsh-config 没有生效（仍在读 DSH 设置）"; exit 1; }; \
	out=$$($(OUT) --dsh-home /nonexistent --print-config 2>&1); \
	echo "$$out" | grep -q "dsh_home = /nonexistent  (loaded: no)" \
		|| { echo "FAIL: --dsh-home 没有生效"; exit 1; }; \
	echo "$$out" | grep -q "tls_verify = tofu  (source: default)" \
		|| { echo "FAIL: 读不到 DSH 设置时应回落到内置默认 tofu"; exit 1; }; \
	echo "$$out" | grep -q "tls_tofu_learn = true  (source: default)" \
		|| { echo "FAIL: P92 的学习开关默认应当开且来源是 default"; exit 1; }; \
	echo "$$out" | grep -q "ca_bundle = (auto:" \
		|| { echo "FAIL: P92 没打印系统 CA 库的落点（默认自动找）"; exit 1; }; \
	if $(OUT) --strict-dsh-config --dsh-home /nonexistent --print-config >/dev/null 2>&1; then \
		echo "FAIL: --strict-dsh-config 读不到设置却没有报错退出"; exit 1; \
	fi; \
	out=$$($(OUT) --dsh-root testdata/preset-root --print-config 2>&1); \
	echo "$$out" | grep -q "knobs (source: preset)" \
		|| { echo "FAIL: --dsh-root 没有生效（旋钮仍来自内置默认）"; exit 1; }; \
	echo "$$out" | grep -q "readLimit=1777" \
		|| { echo "FAIL: --dsh-root 指到的 preset 树没被读到（夹具 readLimit=1777 没出现）"; exit 1; }; \
	out=$$($(OUT) --print-config 2>&1); \
	echo "$$out" | grep -q "readLimit=1777" \
		&& { echo "FAIL: 没给 --dsh-root 却读到了夹具的值"; exit 1; }; \
	echo "e2e-config-flags: 通过（--dsh-home / --no-dsh-config / --strict-dsh-config / --dsh-root 都在加载前生效）"

# P55 收工提醒（--grace-steps 的锚点也靠它）：验收类命令在**改动之后**跑绿时，工具结果尾部要出现
# 一行 `[acceptance] …`；三种反例都不该出现 —— 非验收类命令（`ls -la`）、以及**文本里出现过
# make 但没有哪一段以验收命令开头**（`grep -n "make build" Makefile && echo ok`，第一版误报的形状）、
# 以及「还没改动就跑验收」（这里由假网关的第一发 touch 之外的单测覆盖）。
e2e-accept-nudge: build
	@set -e; \
	ws=$(CURDIR)/build/e2e_nudge_ws; \
	rm -rf $$ws; mkdir -p $$ws; \
	printf 'build:\n\t@echo NUDGE-BUILD-OK\n' > $$ws/Makefile; \
	for spec in ACCEPT-NUDGE:1 ACCEPT-CONTROL:0 ACCEPT-FALSEPOS:0; do \
		mode=$${spec%%:*}; want=$${spec##*:}; \
		home=$(CURDIR)/build/e2e_nudge_home_$$mode; \
		rm -rf $$home; mkdir -p $$home; \
		python3 testdata/mock_gateway_accept.py 0 > $(CURDIR)/build/e2e_nudge_gw_$$mode.log 2>&1 & \
		gw=$$!; \
		sleep 0.4; \
		port=$$(awk '/^PORT/{print $$2}' $(CURDIR)/build/e2e_nudge_gw_$$mode.log); \
		if [ -z "$$port" ]; then echo "FAIL: 假网关没起来"; cat $(CURDIR)/build/e2e_nudge_gw_$$mode.log; kill $$gw 2>/dev/null || true; exit 1; fi; \
		UYA_AGENT_API_KEY=k $(OUT) --no-dsh-config --no-stream --no-tui --quiet \
			--base-url "http://127.0.0.1:$$port/v1" --api=chat --model mock-model \
			--workspace $$ws --agent-home $$home --tls-verify=none \
			"任务标记 $$mode" > $(CURDIR)/build/e2e_nudge_out_$$mode.txt 2>&1 || true; \
		kill $$gw 2>/dev/null || true; \
		log=$$(ls $$home/sessions/*/*/session.jsonl 2>/dev/null | head -1); \
		if [ -z "$$log" ]; then echo "FAIL: $$mode 没有落会话日志"; cat $(CURDIR)/build/e2e_nudge_out_$$mode.txt; exit 1; fi; \
		cnt=$$(grep -c "\[acceptance\] 验收命令已通过" $$log || true); \
		[ "$$cnt" = "$$want" ] || { echo "FAIL: $$mode 期望 $$want 条提醒，实际 $$cnt 条"; exit 1; }; \
		grep -q "touch nudge_changed.txt" $(CURDIR)/build/e2e_nudge_gw_$$mode.log || { echo "FAIL: $$mode 的假网关没发改动类命令"; exit 1; }; \
	done; \
	echo "e2e-accept-nudge: 通过（验收类 → 1 条；ls -la / 文本里含 make 的非验收命令 → 0 条）"

# 终端标题开关（P22）回归：默认开；--no-title / UYA_AGENT_TITLE=0 都要在 --print-config 的
# 来源列上看得出来（来源码与 cfg_src_name 同口径：default / env / cli），而且 CLI 压过 env。
e2e-title:
	@set -e; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "title = on  (source: default)" \
		|| { echo "FAIL: 终端标题默认应当是开"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --no-title --print-config 2>&1); \
	echo "$$out" | grep -q "title = off  (source: cli)" \
		|| { echo "FAIL: --no-title 没有生效"; exit 1; }; \
	out=$$(UYA_AGENT_TITLE=0 $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "title = off  (source: env)" \
		|| { echo "FAIL: UYA_AGENT_TITLE 没有生效"; exit 1; }; \
	out=$$(UYA_AGENT_TITLE=0 $(OUT) --no-dsh-config --title --print-config 2>&1); \
	echo "$$out" | grep -q "title = on  (source: cli)" \
		|| { echo "FAIL: --title 应当压过 UYA_AGENT_TITLE=0"; exit 1; }; \
	echo "e2e-title: 通过（默认开；--no-title / UYA_AGENT_TITLE 同口径；CLI 优先）"

# P46：会话标题可在执行过程中修改（离线，行式 REPL 走真二进制）
#
# 两件事：
#   ① 命令语义与措辞：/title 的用法串、改名回执、/status 里的 title 行与开关、/title clear、
#      清洗后为空要报错且**标题不动**、/help 里查得到；
#   ② 落盘：日志里一条 kind=user 的 session/title、index.jsonl 的 title 就是新值。
e2e-title-cmd: build
	@set -e; \
	home=build/selftest_title_cmd_e2e; rm -rf $$home; mkdir -p $$home; \
	run="$(CURDIR)/$(OUT) --no-dsh-config --no-tui --quiet --api-key dummy-key --agent-home $$home"; \
	out=$$(printf '/title\n/title 把中文文件名修好\n/status\n/title clear\n/status\n/title \033[31m\007\n/status\n/help\n/exit\n' | $$run 2>&1); \
	echo "$$out" | grep -qF "用法：/title <新标题> · /title clear（清回基标题）· 裸 /title 让模型起一个建议" \
		|| { echo "FAIL: 裸 /title 没有给出用法"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "[title] 会话标题已更新：把中文文件名修好" \
		|| { echo "FAIL: /title <新标题> 没有生效（措辞也不对）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "title=把中文文件名修好 (pinned" \
		|| { echo "FAIL: /status 里没有新的会话标题（或没标 pinned）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "[title] 已清回基标题" \
		|| { echo "FAIL: /title clear 没有生效"; exit 1; }; \
	echo "$$out" | grep -qF "title=(无标题，终端显示基标题)" \
		|| { echo "FAIL: clear 之后 /status 还挂着标题"; exit 1; }; \
	echo "$$out" | grep -qF "这个标题清洗后是空的" \
		|| { echo "FAIL: 清洗后为空的标题没有报错（静默成功最坏）"; exit 1; }; \
	echo "$$out" | grep -qF "title_auto=on" \
		|| { echo "FAIL: /status 里没有自动起标题的开关"; exit 1; }; \
	echo "$$out" | grep -qF "/title [<新标题>|clear]" \
		|| { echo "FAIL: /help 里没有 /title"; exit 1; }; \
	grep -qF '"title":"把中文文件名修好"' $$home/index.jsonl \
		|| { echo "FAIL: 索引里的标题不是新值（/sessions 的标题列会空着）"; exit 1; }; \
	grep -qF '"source":{"kind":"user"}' $$home/sessions/*/*/session.jsonl \
		|| { echo "FAIL: 显式改名落的 kind 不是 user"; exit 1; }; \
	: "clear 之后索引里的标题要被清空（否则 /sessions 还显示旧标题）"; \
	tail -1 $$home/index.jsonl | grep -qF '"title":""' \
		|| { echo "FAIL: clear 之后索引里的标题没清空"; exit 1; }; \
	echo "e2e-title-cmd: 通过（用法/改名回执/status 行/clear/空标题报错/命令表/索引与日志落盘）"

# P46：自动起标题真的发了一次请求、落了 provider 事件（离线；真 PTY + 假网关）
#
# 为什么必须真 PTY：自动起标题**只服务交互界面**（管道/CI 上 tty_title_set 本来就是空操作，
# 为一个看不见的东西多发请求没有道理）—— 所以行式 REPL 那一路它根本不会跑，
# 这一条只能拿真终端验。驱动脚本见 testdata/pty_drive_title.py（pty.fork 起真二进制）。
# 判据：日志里出现 kind=provider 的 session/title，且假网关收到了 ≥2 次请求；
#       --no-title-auto 时两样都没有。
#
# P74 加第三腿（HOME_C）：打完任务**立刻 esc 中断** —— 首发点在回合里（第一个 step 跑完的
# 边界），不是回合收尾，所以 aborted 的回合同样换得到标题。改前（只在 completed 收尾挂待办）
# 这一腿的日志里一个 provider 事件都没有 —— 控制台的会话标题列正是因此空着的。
e2e-title-auto: build
	@set -e; \
	ws=build/selftest_title_auto_e2e; rm -rf $$ws; mkdir -p $$ws/home $$ws/home2 $$ws/home3; \
	python3 testdata/mock_gateway_sse.py 0 1 200 > $$ws/gw.log 2>$$ws/gw.err & \
	gw=$$!; \
	python3 testdata/mock_gateway_sse.py 0 1 3000 > $$ws/gw2.log 2>$$ws/gw2.err & \
	gw2=$$!; \
	trap "kill $$gw $$gw2 2>/dev/null || true" EXIT; \
	sleep 1.2; \
	port=$$(awk '/^PORT/{print $$2}' $$ws/gw.log); \
	port2=$$(awk '/^PORT/{print $$2}' $$ws/gw2.log); \
	[ -n "$$port" ] && [ -n "$$port2" ] || { echo "FAIL: 假网关没打印端口"; cat $$ws/gw.log $$ws/gw2.log; exit 1; }; \
	UYA_BIN="$(CURDIR)/$(OUT)" PORT="$$port" PORT_SLOW="$$port2" HOME_A="$$ws/home" \
		HOME_B="$$ws/home2" HOME_C="$$ws/home3" python3 testdata/pty_drive_title.py; \
	: "① 默认（--title-auto）：起标题多发一次请求，并落 provider 事件"; \
	n=$$(grep -c "REQ #" $$ws/gw.err || true); \
	[ "$$n" -ge 2 ] || { echo "FAIL: 自动起标题没有多发请求（只看到 $$n 次）"; exit 1; }; \
	grep -qF '"source":{"kind":"provider"}' $$ws/home/sessions/*/*/session.jsonl \
		|| { echo "FAIL: 日志里没有 kind=provider 的 session/title"; exit 1; }; \
	: "①b 网关看得见会话身份与工作区（每一次请求都要带；含标题那次侧路请求）"; \
	sid=$$(grep -oF 'x-deepseek-harness-session-id: session-' $$ws/gw.err | head -1); \
	[ -n "$$sid" ] || { echo "FAIL: 请求头里没有 DSH 口径的会话 id"; grep -F 'HEAD #' $$ws/gw.err | head -5; exit 1; }; \
	[ "$$(grep -cF 'Session-Id: session-' $$ws/gw.err)" -eq "$$n" ] \
		|| { echo "FAIL: 不是每个请求都带 Session-Id（网关实读的那一个）"; exit 1; }; \
	[ "$$(grep -cF 'x-deepseek-harness-session-id: session-' $$ws/gw.err)" -eq "$$n" ] \
		|| { echo "FAIL: 不是每个请求都带 x-deepseek-harness-session-id"; exit 1; }; \
	[ "$$(grep -cF '"session_id":"session-' $$ws/gw.err)" -eq "$$n" ] \
		|| { echo "FAIL: 不是每个请求的正文都带 session_id"; exit 1; }; \
	grep -qF 'session workspace: \"' $$ws/gw.err \
		|| { echo "FAIL: 运行时上下文里没有网关要的 session workspace 机读句"; exit 1; }; \
	: "①c 标题侧路请求用 DSH 的两段式前缀（网关据此认 call_kind=title）"; \
	grep -qF 'Create a concise title for an AI coding-assistant session' $$ws/gw.err \
		|| { echo "FAIL: 标题请求的 system 段不是 DSH 前缀"; exit 1; }; \
	grep -qF 'Generate the session title from this JSON array of human messages:' $$ws/gw.err \
		|| { echo "FAIL: 标题请求的 user 段不是 DSH 前缀"; exit 1; }; \
	grep -qF 'within 15 characters' $$ws/gw.err \
		|| { echo "FAIL: 词数句不是本项目的「15 字以内」口径"; exit 1; }; \
	: "①d 标题请求里带的是人类消息原文（网关据此归组并抓标题）"; \
	grep -qF '写一个 hello' $$ws/gw.err \
		|| { echo "FAIL: 标题请求里没有那条人类消息"; exit 1; }; \
	: "② --no-title-auto：只有主请求，且没有 provider 事件"; \
	if grep -qF '"source":{"kind":"provider"}' $$ws/home2/sessions/*/*/session.jsonl 2>/dev/null; then \
		echo "FAIL: --no-title-auto 下仍然落了 provider 事件"; exit 1; \
	fi; \
	: "③ esc 中断的回合（aborted）同样换得到标题：首发在回合里，不在收尾"; \
	grep -qF '"reason":"aborted"' $$ws/home3/sessions/*/*/session.jsonl \
		|| { echo "FAIL: 中断那一腿的回合不是 aborted（没测到中断回合）"; exit 1; }; \
	grep -qF '"source":{"kind":"provider"}' $$ws/home3/sessions/*/*/session.jsonl \
		|| { echo "FAIL: 被 esc 打断的回合没有起出标题（首发点还在收尾？）"; exit 1; }; \
	t=$$(cat $$ws/gw.err $$ws/gw2.err | grep -cF 'Generate the session title from this JSON array of human messages:' || true); \
	[ "$$t" -eq 2 ] || { echo "FAIL: 标题请求不是 2 次（A 一条 + 中断那条 C 一条；实为 $$t）"; exit 1; }; \
	: "④ 三来源都看得出来，CLI 压过 env"; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "title_auto = on  (source: default)" \
		|| { echo "FAIL: 自动起标题默认应当是开"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --no-title-auto --print-config 2>&1); \
	echo "$$out" | grep -q "title_auto = off  (source: cli)" \
		|| { echo "FAIL: --no-title-auto 没有生效"; exit 1; }; \
	out=$$(UYA_AGENT_TITLE_AUTO=0 $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "title_auto = off  (source: env)" \
		|| { echo "FAIL: UYA_AGENT_TITLE_AUTO 没有生效"; exit 1; }; \
	out=$$(UYA_AGENT_TITLE_AUTO=0 $(OUT) --no-dsh-config --title-auto --print-config 2>&1); \
	echo "$$out" | grep -q "title_auto = on  (source: cli)" \
		|| { echo "FAIL: --title-auto 应当压过 UYA_AGENT_TITLE_AUTO=0"; exit 1; }; \
	echo "e2e-title-auto: 通过（回合里首发+落 provider；中断的回合也有标题；--no-title-auto 两样都没有；三来源与 CLI 优先）"

# 踩坑 72：鼠标上报开关回归（离线，不联网）。默认开（滚轮要靠它）；--no-mouse / UYA_AGENT_MOUSE=0
# 都要在 --print-config 的来源列上看得出来（来源码与 cfg_src_name 同口径），而且 CLI 压过 env。
# 这是「TUI 里不能拖选复制文本」的出口：关掉之后终端重新接管拖选（真 PTY 的字节级验证在
# selftest 的 tui-mouse 轮里；这里只钉配置来源链）。
e2e-mouse:
	@set -e; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "mouse = on  (source: default)" \
		|| { echo "FAIL: 鼠标上报默认应当是开（滚轮依赖它）"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --no-mouse --print-config 2>&1); \
	echo "$$out" | grep -q "mouse = off  (source: cli)" \
		|| { echo "FAIL: --no-mouse 没有生效"; exit 1; }; \
	out=$$(UYA_AGENT_MOUSE=0 $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "mouse = off  (source: env)" \
		|| { echo "FAIL: UYA_AGENT_MOUSE 没有生效"; exit 1; }; \
	out=$$(UYA_AGENT_MOUSE=0 $(OUT) --no-dsh-config --mouse --print-config 2>&1); \
	echo "$$out" | grep -q "mouse = on  (source: cli)" \
		|| { echo "FAIL: --mouse 应当压过 UYA_AGENT_MOUSE=0"; exit 1; }; \
	out=$$(printf '/mouse\n/mouse bogus\n/mouse off\n/exit\n' | \
		$(OUT) --no-dsh-config --no-tui --api-key dummy-key --quiet 2>&1); \
	echo "$$out" | grep -q "滚动模式没开鼠标上报" \
		|| { echo "FAIL: 滚动模式下的 /mouse 应当说明没开鼠标上报"; exit 1; }; \
	echo "e2e-mouse: 通过（默认开；--no-mouse / UYA_AGENT_MOUSE 同口径；CLI 优先；滚动模式 /mouse 有说明）"

# 线协议 flag 回归（离线，--print-config / --dry-run 都不联网）：
#   * 默认（没有任何声明）= 先 responses + 允许一次性协商回退 chat；
#   * --api= / UYA_AGENT_API 显式声明后**不协商**（声明即权威）；
#   * 非法取值必须报错退出（静默按默认跑会让人以为协议生效了）；
#   * 组装出来的请求体也得跟着协议走（--dry-run 直接看 body）。
e2e-api: build
	@set -e; \
	out=$$($(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "api = openai-responses  (source: default, negotiable→chat/completions)" \
		|| { echo "FAIL: 默认协议应当是 responses + 可协商"; exit 1; }; \
	echo "$$out" | grep -q "endpoint = responses" \
		|| { echo "FAIL: 默认端点应当是 /responses"; exit 1; }; \
	out=$$($(OUT) --no-dsh-config --api=chat --print-config 2>&1); \
	echo "$$out" | grep -q "api = openai-completions  (source: cli)" \
		|| { echo "FAIL: --api=chat 没生效"; exit 1; }; \
	if echo "$$out" | grep -q "negotiable"; then echo "FAIL: 显式声明后不该标 negotiable"; exit 1; fi; \
	out=$$(UYA_AGENT_API=responses $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "api = openai-responses  (source: env)" \
		|| { echo "FAIL: UYA_AGENT_API 没生效"; exit 1; }; \
	if $(OUT) --api=bogus --print-config >/dev/null 2>&1; then \
		echo "FAIL: 非法 --api 应当报错退出"; exit 1; \
	fi; \
	out=$$($(OUT) --no-dsh-config --dry-run "x" 2>&1); \
	echo "$$out" | grep -q '\"input\":' \
		|| { echo "FAIL: 默认应当组装 responses 请求体"; exit 1; }; \
	if echo "$$out" | grep -q '\"messages\":'; then echo "FAIL: responses 请求体里不该有 messages"; exit 1; fi; \
	out=$$($(OUT) --no-dsh-config --api=chat --dry-run "x" 2>&1); \
	echo "$$out" | grep -q '\"messages\":' \
		|| { echo "FAIL: --api=chat 应当组装 chat 请求体"; exit 1; }; \
	echo "e2e-api: 通过（默认 responses+一次性协商；--api= / UYA_AGENT_API 显式声明；非法值报错）"

# DNS 解析器发现的端到端（离线，踩坑 133）：全程只打 127.0.0.1。
#   * 正腿：`UYA_AGENT_DNS` 指向假解析器 + `--base-url http://mock-dns-e2e.invalid:…`
#     —— `.invalid` 是 RFC 2606 保留域，任何**真**解析器都一定回 NXDOMAIN，所以这一轮
#     跑绿只可能是本进程把查询发到了假解析器上（判据不可能靠机器上碰巧存在的 DNS 蒙对）；
#   * 反腿：同一个域名、把解析器换成一个没人听的端口 ⇒ 必须是「域名解析失败」+ 退出码 2 +
#     给 `UYA_AGENT_DNS` 这条自救路，**且不许提 TLS**（那正是这条线要修的谎）；
#     流式与非流式**各跑一遍** —— 两条路的档位映射以前是各写一份的（非流式那份连档位
#     都没有，DNS 失败只会说「检查 base-url / 网络」）；
#   * `--print-config` 的 `dns = … (source: …)`：显式解析器与本地文件两个来源各验一条。
e2e-dns: build
	@set -e; \
	ws=$$(pwd)/build/selftest_dns_e2e; req=$$ws/req.bin; \
	rm -rf $$ws; mkdir -p $$ws; \
	dnslog=$$ws/dns.log; gwlog=$$ws/gw.log; \
	cleanup() { kill $$dnsp 2>/dev/null || true; kill $$gwp 2>/dev/null || true; \
		rm -rf $$ws; }; \
	trap cleanup EXIT; \
	python3 testdata/mock_dns.py 0 127.0.0.1 > $$dnslog 2>&1 & dnsp=$$!; \
	python3 testdata/mock_gateway_portable.py 0 $$req > $$gwlog 2>&1 & gwp=$$!; \
	sleep 0.6; \
	dp=$$(awk '/^PORT/{print $$2}' $$dnslog); \
	gp=$$(awk '/^PORT/{print $$2}' $$gwlog); \
	[ -n "$$dp" ] || { echo "FAIL: 假 DNS 没起来"; cat $$dnslog; exit 1; }; \
	[ -n "$$gp" ] || { echo "FAIL: 假网关没起来"; cat $$gwlog; exit 1; }; \
	: "---- ① 正腿：自家解析器 + .invalid 域名（真解析器必然解不出来）----"; \
	: "  假网关回的是整段 JSON，所以两条腿都走 --no-stream（SSE 那条由 selftest 的轮次管）"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_DNS=127.0.0.1:$$dp UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=chat --model dns-m \
		--base-url "http://mock-dns-e2e.invalid:$$gp/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 20000 "hi" \
		> $$ws/out.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "0" ] || { echo "FAIL: 显式解析器那一轮没跑通（rc=$$rc）"; \
		cat $$ws/out.txt; cat $$dnslog; exit 1; }; \
	grep -q "PORTABLE-OK" $$ws/out.txt \
		|| { echo "FAIL: 假网关的答复没上屏（请求没到）"; cat $$ws/out.txt; exit 1; }; \
	[ -s $$req ] || { echo "FAIL: 假网关一个请求都没收到"; exit 1; }; \
	grep -q '"model":"dns-m"\|"model": *"dns-m"' $$req \
		|| { echo "FAIL: 请求里的模型不是父进程给的那个"; head -c 400 $$req; exit 1; }; \
	: "---- ①b 正腿：responses 那条协议上也一样（同一个解析器）----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_DNS=127.0.0.1:$$dp UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=responses --model dns-r \
		--base-url "http://mock-dns-e2e.invalid:$$gp/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 20000 "hi" \
		> $$ws/out2.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "0" ] || { echo "FAIL: responses 那条腿没跑通（rc=$$rc）"; \
		cat $$ws/out2.txt; exit 1; }; \
	grep -q '"model":"dns-r"\|"model": *"dns-r"' $$req \
		|| { echo "FAIL: responses 那次请求没到假网关"; head -c 400 $$req; exit 1; }; \
	: "---- ② 反腿：解析器不通（流式）----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_DNS=127.0.0.1:1 UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --api=chat --model dns-m \
		--base-url "http://mock-dns-e2e.invalid:$$gp/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 5000 "hi" > $$ws/bad.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "2" ] || { echo "FAIL: 解析失败时退出码应当是 2（传输错），实际 $$rc"; \
		cat $$ws/bad.txt; exit 1; }; \
	grep -q "域名解析失败" $$ws/bad.txt \
		|| { echo "FAIL: 没说是域名解析失败"; cat $$ws/bad.txt; exit 1; }; \
	grep -q "UYA_AGENT_DNS" $$ws/bad.txt \
		|| { echo "FAIL: 没给出 UYA_AGENT_DNS 这条自救路"; cat $$ws/bad.txt; exit 1; }; \
	if grep -q "TLS" $$ws/bad.txt; then \
		echo "FAIL: DNS 失败却说成了 TLS（这条线要修的就是这个谎）"; \
		cat $$ws/bad.txt; exit 1; fi; \
	: "---- ③ 反腿：解析器不通（非流式：另一条路也要分类）----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_DNS=127.0.0.1:1 UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=chat --model dns-m \
		--base-url "http://mock-dns-e2e.invalid:$$gp/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 5000 "hi" > $$ws/bad2.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "2" ] || { echo "FAIL: 非流式那条路的退出码应当是 2，实际 $$rc"; \
		cat $$ws/bad2.txt; exit 1; }; \
	grep -q "域名解析失败" $$ws/bad2.txt \
		|| { echo "FAIL: 非流式那条路还在说「网络或 TLS 校验」"; \
		cat $$ws/bad2.txt; exit 1; }; \
	: "---- ④ --print-config 的 dns 行（两个来源）----"; \
	out=$$(env -u UYA_AGENT_DNS $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "^dns = " \
		|| { echo "FAIL: print-config 没有 dns 那一行"; echo "$$out" | grep -i dns; exit 1; }; \
	out=$$(UYA_AGENT_DNS=127.0.0.1:$$dp $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "dns = 127.0.0.1:$$dp  (source: \$$UYA_AGENT_DNS)" \
		|| { echo "FAIL: 显式解析器的来源没报成 env"; echo "$$out" | grep "^dns"; exit 1; }; \
	echo "e2e-dns: 通过（自家解析器跑通 .invalid；流式与非流式都把 DNS 失败说成人话；print-config 两个来源）"

# P92：出站代理（离线，全程只打 127.0.0.1）。
#   判据的形状：
#     * 正腿必须**穿过代理到达上游** —— 断言假网关真收到了请求（`req.bin` 非空）**且**
#       代理日志里那一行是**绝对形式**（`ABS POST http://…`）。只断言「答复上屏」时，
#       直连的实现也能跑绿（那就成了假绿）。
#     * 反腿必须说人话且**不许提 TLS/DNS** —— 配了代理时「连不上」的真原因是代理，
#       而这条线要修的正是「三种失败糊成同一句」（与 e2e-dns 的反腿同形）。
#     * 回环那条腿是「本机目标一律直连」的落点：代理指向一个死端口，请求照样跑通。
e2e-proxy: build
	@set -e; \
	ws=$$(pwd)/build/selftest_proxy_e2e; req=$$ws/req.bin; \
	rm -rf $$ws; mkdir -p $$ws; \
	plog=$$ws/proxy.log; gwlog=$$ws/gw.log; \
	cleanup() { for p in $$pp $$gwp $$rp $$gws $$ps2 $$dp; do \
		kill $$p 2>/dev/null || true; done; rm -rf $$ws; }; \
	trap cleanup EXIT; \
	: "--- 起夹具：网关先起（代理要把它当 --upstream 的目标改写）---"; \
	python3 testdata/mock_gateway_portable.py 0 $$req > $$gwlog 2>&1 & gwp=$$!; \
	python3 testdata/mock_proxy.py 0 $$ws/reject.log --reject 407 \
		> $$ws/reject.port 2>&1 & rp=$$!; \
	sleep 0.6; \
	gport=$$(awk '/^PORT/{print $$2}' $$gwlog); \
	[ -n "$$gport" ] || { echo "FAIL: 假网关没起来"; cat $$gwlog; exit 1; }; \
	: "--- 假代理：目标名（.invalid）只用于断言，真连接经 --upstream 落到假网关 ---"; \
	python3 testdata/mock_proxy.py 0 $$plog --upstream 127.0.0.1:$$gport \
		> $$ws/proxy.port 2>&1 & pp=$$!; \
	: "--- 流式那条路要真的 SSE 上游：另一个网关 + 另一个代理 ---"; \
	python3 testdata/mock_gateway_sse.py 0 1 50 > $$ws/gwsse.log 2>&1 & gws=$$!; \
	sleep 0.8; \
	sport=$$(awk '/^PORT/{print $$2}' $$ws/gwsse.log); \
	[ -n "$$sport" ] || { echo "FAIL: SSE 假网关没起来"; \
		cat $$ws/gwsse.log; exit 1; }; \
	python3 testdata/mock_proxy.py 0 $$ws/proxysse.log \
		--upstream 127.0.0.1:$$sport > $$ws/proxysse.port 2>&1 & ps2=$$!; \
	: "--- 掐断腿的假代理：CONNECT 照收、200 照回，然后把隧道掐断 ---"; \
	python3 testdata/mock_proxy.py 0 $$ws/drop.log --tunnel-drop \
		> $$ws/drop.port 2>&1 & dp=$$!; \
	sleep 0.6; \
	pport=$$(awk '/^PORT/{print $$2}' $$ws/proxy.port); \
	rport=$$(awk '/^PORT/{print $$2}' $$ws/reject.port); \
	sport2=$$(awk '/^PORT/{print $$2}' $$ws/proxysse.port); \
	dport=$$(awk '/^PORT/{print $$2}' $$ws/drop.port); \
	[ -n "$$pport" ] || { echo "FAIL: 假代理没起来"; cat $$ws/proxy.port; exit 1; }; \
	[ -n "$$rport" ] || { echo "FAIL: 拒绝腿的假代理没起来"; \
		cat $$ws/reject.port; exit 1; }; \
	[ -n "$$sport2" ] || { echo "FAIL: 流式那条腿的假代理没起来"; \
		cat $$ws/proxysse.port; exit 1; }; \
	[ -n "$$dport" ] || { echo "FAIL: 掐断腿的假代理没起来"; \
		cat $$ws/drop.port; exit 1; }; \
	: "---- ① 正腿：env 档，请求穿过代理到达上游（明文目标 = 绝对形式）----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_PROXY=127.0.0.1:$$pport UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=chat --model px-m \
		--base-url "http://mock-proxy-e2e.invalid:$$gport/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 20000 "hi" \
		> $$ws/out.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "0" ] || { echo "FAIL: 走代理那一轮没跑通（rc=$$rc）"; \
		cat $$ws/out.txt; cat $$plog; exit 1; }; \
	grep -q "PORTABLE-OK" $$ws/out.txt \
		|| { echo "FAIL: 假网关的答复没上屏"; cat $$ws/out.txt; exit 1; }; \
	[ -s $$req ] || { echo "FAIL: 假网关一个请求都没收到（请求没穿过代理）"; exit 1; }; \
	grep -q '"model":"px-m"\|"model": *"px-m"' $$req \
		|| { echo "FAIL: 请求里的模型不是父进程给的那个"; head -c 400 $$req; exit 1; }; \
	grep -q "^ABS POST http://mock-proxy-e2e.invalid:$$gport/v1" $$plog \
		|| { echo "FAIL: 代理日志里没有绝对形式的请求行（代理模式没生效）"; \
		cat $$plog; exit 1; }; \
	: "---- ② 正腿：流式那条路（hc_open）也走同一个代理 ----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_PROXY=127.0.0.1:$$sport2 UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --api=chat --model px-s \
		--base-url "http://mock-proxy-e2e.invalid:$$sport/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 20000 "hi" \
		> $$ws/out2.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "0" ] || { echo "FAIL: 流式那一轮没跑通（rc=$$rc）"; \
		cat $$ws/out2.txt; exit 1; }; \
	grep -q "SELFTEST_OK" $$ws/out2.txt \
		|| { echo "FAIL: 流式那条路的答复没上屏"; cat $$ws/out2.txt; exit 1; }; \
	grep -q "^ABS POST http://mock-proxy-e2e.invalid:$$sport/v1" $$ws/proxysse.log \
		|| { echo "FAIL: 流式那条路的请求没走代理"; \
		cat $$ws/proxysse.log; exit 1; }; \
	: "---- ③ 凭据腿：user:pass@ 要变成 Proxy-Authorization: Basic … ----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL \
		UYA_AGENT_PROXY="http://user:pass@127.0.0.1:$$pport" UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=chat --model px-c \
		--base-url "http://mock-proxy-e2e.invalid:$$gport/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 20000 "hi" \
		> $$ws/out3.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "0" ] || { echo "FAIL: 带凭据那一轮没跑通（rc=$$rc）"; \
		cat $$ws/out3.txt; exit 1; }; \
	grep -q "^AUTH Basic dXNlcjpwYXNz" $$plog \
		|| { echo "FAIL: 代理没收到 Proxy-Authorization（凭据没发出去）"; \
		cat $$plog; exit 1; }; \
	: "---- ④ CLI 档：--proxy 与 env 同效 ----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL -u UYA_AGENT_PROXY UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=chat --model px-cli \
		--proxy 127.0.0.1:$$pport \
		--base-url "http://mock-proxy-e2e.invalid:$$gport/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 20000 "hi" \
		> $$ws/out4.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "0" ] || { echo "FAIL: --proxy 那一轮没跑通（rc=$$rc）"; \
		cat $$ws/out4.txt; exit 1; }; \
	grep -q '"model":"px-cli"\|"model": *"px-cli"' $$req \
		|| { echo "FAIL: --proxy 那一轮的请求没到上游"; exit 1; }; \
	: "---- ⑤ --no-proxy 压过 env（直连：代理日志里不该再多一行）----"; \
	before=$$(wc -l < $$plog); \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_PROXY=127.0.0.1:$$pport UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=chat --model px-off \
		--no-proxy --base-url "http://127.0.0.1:$$gport/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 20000 "hi" \
		> $$ws/out5.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "0" ] || { echo "FAIL: --no-proxy 那一轮没跑通（rc=$$rc）"; \
		cat $$ws/out5.txt; exit 1; }; \
	after=$$(wc -l < $$plog); \
	[ "$$before" = "$$after" ] \
		|| { echo "FAIL: --no-proxy 之后代理还是被用了"; cat $$plog; exit 1; }; \
	: "---- ⑥ 反腿：代理连不上 ⇒ rc=2、说代理、不许提 TLS/DNS ----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_PROXY=127.0.0.1:1 UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --api=chat --model px-m --api-retry-max 0 \
		--base-url "http://mock-proxy-e2e.invalid:$$gport/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 5000 "hi" > $$ws/bad.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "2" ] || { echo "FAIL: 代理连不上时退出码应当是 2（传输错），实际 $$rc"; \
		cat $$ws/bad.txt; exit 1; }; \
	grep -q "代理没打通" $$ws/bad.txt \
		|| { echo "FAIL: 没说是代理没打通"; cat $$ws/bad.txt; exit 1; }; \
	grep -q "UYA_AGENT_PROXY" $$ws/bad.txt \
		|| { echo "FAIL: 没给出 UYA_AGENT_PROXY 这条自救路"; cat $$ws/bad.txt; exit 1; }; \
	if grep -q "TLS\|域名解析" $$ws/bad.txt; then \
		echo "FAIL: 代理失败却说成了 TLS/DNS（这条线要修的就是这个谎）"; \
		cat $$ws/bad.txt; exit 1; fi; \
	: "---- ⑥b 反腿：代理接了 CONNECT 却把隧道掐断 ⇒ 报握手失败，"; \
	: "  但目标要写**真目标**（不是代理）、且不许印上一次的证书指纹 ----"; \
	: "  P95 用户报的现场：报告里「目标 = 本机代理:端口」与「leaf = 上一个回合那台"; \
	: "  站点的证书」互相矛盾，看的人被指向完全错的方向。"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_PROXY=127.0.0.1:$$dport \
		UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=chat --model px-drop \
		--api-retry-max 0 \
		--base-url "https://mock-proxy-e2e.invalid:443/v1" --workspace $$ws \
		--agent-home $$ws/drophome --timeout-ms 5000 "hi" \
		> $$ws/drop.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "2" ] || { echo "FAIL: 隧道被掐断时退出码应当是 2，实际 $$rc"; \
		cat $$ws/drop.txt; exit 1; }; \
	grep -q "TLS 握手失败" $$ws/drop.txt \
		|| { echo "FAIL: 隧道被掐断没按握手失败报出来"; \
		cat $$ws/drop.txt; exit 1; }; \
	grep -q "目标 = mock-proxy-e2e.invalid:443" $$ws/drop.txt \
		|| { echo "FAIL: 目标写错了（应当是隧道里的真目标，不是代理）"; \
		cat $$ws/drop.txt; exit 1; }; \
	grep -q "（经代理 127.0.0.1:$$dport）" $$ws/drop.txt \
		|| { echo "FAIL: 没把「代理是谁」印出来"; cat $$ws/drop.txt; exit 1; }; \
	grep -q "隧道多半被对端掐断" $$ws/drop.txt \
		|| { echo "FAIL: 经代理那条路的下一步提示没给出来"; \
		cat $$ws/drop.txt; exit 1; }; \
	if grep -q "leaf SHA-256" $$ws/drop.txt; then \
		echo "FAIL: 这一次没拿到证书却印了指纹（那是上一次的，报告在说谎）"; \
		cat $$ws/drop.txt; exit 1; fi; \
	: "---- ⑦ 反腿：CONNECT 被回 407 ⇒ rc=2、文案点名凭据 ----"; \
	: "  目标写成 https://（走 CONNECT 隧道）：隧道被拒时根本不会开始 TLS 握手，"; \
	: "  所以这条腿不需要证书，也不联网 —— 它判的正是「代理拒绝」那一档。"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_PROXY=127.0.0.1:$$rport UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --api=chat --model px-m --api-retry-max 0 \
		--base-url "https://mock-proxy-e2e.invalid:$$gport/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 5000 "hi" > $$ws/bad2.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "2" ] || { echo "FAIL: 407 时退出码应当是 2，实际 $$rc"; \
		cat $$ws/bad2.txt; exit 1; }; \
	grep -q "407" $$ws/bad2.txt \
		|| { echo "FAIL: 407 的文案里没带状态码（用户不知道该改凭据）"; \
		cat $$ws/bad2.txt; exit 1; }; \
	: "---- ⑧ 反腿：取值非法（env 与 CLI 各一次）⇒ rc=1 + 形状提示 ----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_PROXY="socks5://127.0.0.1:1080" \
		UYA_AGENT_API_KEY=k $(OUT) --no-dsh-config --no-tui --print-config \
		> $$ws/bad3.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "1" ] || { echo "FAIL: 非法代理取值应当 rc=1（用法错），实际 $$rc"; \
		cat $$ws/bad3.txt; exit 1; }; \
	grep -q "只支持 http://" $$ws/bad3.txt \
		|| { echo "FAIL: 没点出「只支持 http://」"; cat $$ws/bad3.txt; exit 1; }; \
	grep -q "UYA_AGENT_PROXY" $$ws/bad3.txt \
		|| { echo "FAIL: 没点名来源是 UYA_AGENT_PROXY"; cat $$ws/bad3.txt; exit 1; }; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL -u UYA_AGENT_PROXY UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --proxy=127.0.0.1:70000 --print-config \
		> $$ws/bad4.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "1" ] || { echo "FAIL: 端口越界的 --proxy= 应当 rc=1，实际 $$rc"; \
		cat $$ws/bad4.txt; exit 1; }; \
	grep -q "来源：--proxy" $$ws/bad4.txt \
		|| { echo "FAIL: 没点名来源是 --proxy"; cat $$ws/bad4.txt; exit 1; }; \
	: "---- ⑨ --print-config 的 proxy 行（default / env / cli / --no-proxy）----"; \
	out=$$(env -u UYA_AGENT_PROXY $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "^proxy = (none)  (source: default)" \
		|| { echo "FAIL: 默认应当是 (none)/default"; echo "$$out" | grep "^proxy"; exit 1; }; \
	out=$$(UYA_AGENT_PROXY=127.0.0.1:$$pport $(OUT) --no-dsh-config --print-config 2>&1); \
	echo "$$out" | grep -q "^proxy = 127.0.0.1:$$pport  (source: env)" \
		|| { echo "FAIL: env 档没印成 env"; echo "$$out" | grep "^proxy"; exit 1; }; \
	out=$$(env -u UYA_AGENT_PROXY $(OUT) --no-dsh-config --print-config \
		--proxy 127.0.0.1:$$pport 2>&1); \
	echo "$$out" | grep -q "^proxy = 127.0.0.1:$$pport  (source: cli)" \
		|| { echo "FAIL: cli 档没印成 cli"; echo "$$out" | grep "^proxy"; exit 1; }; \
	out=$$(UYA_AGENT_PROXY=127.0.0.1:$$pport $(OUT) --no-dsh-config --print-config \
		--no-proxy 2>&1); \
	echo "$$out" | grep -q "^proxy = (disabled by --no-proxy)  (source: cli)" \
		|| { echo "FAIL: --no-proxy 没印成「显式关掉」"; echo "$$out" | grep "^proxy"; \
		exit 1; }; \
	: "---- ⑩ 回环绕过：代理指向死端口，本机目标照样直连跑通 ----"; \
	rc=0; \
	env -u UYA_AGENT_BASE_URL UYA_AGENT_PROXY=127.0.0.1:1 UYA_AGENT_API_KEY=k \
		$(OUT) --no-dsh-config --no-tui --no-stream --api=chat --model px-loop \
		--base-url "http://127.0.0.1:$$gport/v1" --workspace $$ws \
		--agent-home $$ws/home --timeout-ms 20000 "hi" \
		> $$ws/out6.txt 2>&1 || rc=$$?; \
	[ "$$rc" = "0" ] || { echo "FAIL: 回环目标没绕过代理（rc=$$rc）"; \
		cat $$ws/out6.txt; exit 1; }; \
	grep -q "PORTABLE-OK" $$ws/out6.txt \
		|| { echo "FAIL: 绕过代理那一轮没拿到答复"; cat $$ws/out6.txt; exit 1; }; \
	echo "e2e-proxy: 通过（请求真穿过代理到上游；流式/凭据/CLI 档各一条；代理失败说人话；非法值 rc=1；回环绕过；隧道掐断时目标/代理分开印且不印旧指纹）"


# 步数默认值回归（离线，--print-config 不联网）：默认不限步数（0）；CLI 与环境变量同口径。
# 默认值从「12 步熔断」改成「不限」是本仓库的显式决策（对齐 DSH：没有步数上限），
# 所以这条常驻守着：默认值、显式值、0、非法值告警四条路径都要对。
e2e-steps: build
	@set -e; \
	out=$$($(OUT) --print-config 2>&1); \
	echo "$$out" | grep -q "max_steps = unlimited (0)" \
		|| { echo "FAIL: 默认不是不限步数"; exit 1; }; \
	out=$$($(OUT) --max-steps 7 --print-config 2>&1); \
	echo "$$out" | grep -q "max_steps = 7" \
		|| { echo "FAIL: --max-steps 7 没有生效"; exit 1; }; \
	out=$$($(OUT) --max-steps 0 --print-config 2>&1); \
	echo "$$out" | grep -q "max_steps = unlimited (0)" \
		|| { echo "FAIL: --max-steps 0 不等于不限步数"; exit 1; }; \
	out=$$(UYA_AGENT_MAX_STEPS=9 $(OUT) --print-config 2>&1); \
	echo "$$out" | grep -q "max_steps = 9" \
		|| { echo "FAIL: UYA_AGENT_MAX_STEPS 没有生效"; exit 1; }; \
	out=$$(UYA_AGENT_MAX_STEPS=0 $(OUT) --print-config 2>&1); \
	echo "$$out" | grep -q "max_steps = unlimited (0)" \
		|| { echo "FAIL: UYA_AGENT_MAX_STEPS=0 不等于不限步数"; exit 1; }; \
	out=$$($(OUT) --max-steps nope --print-config 2>&1); \
	echo "$$out" | grep -q "warning: --max-steps" \
		|| { echo "FAIL: 非法 --max-steps 没有告警"; exit 1; }; \
	echo "$$out" | grep -q "max_steps = unlimited (0)" \
		|| { echo "FAIL: 非法 --max-steps 应回落到默认（不限）"; exit 1; }; \
	echo "e2e-steps: 通过（默认不限步数；--max-steps / UYA_AGENT_MAX_STEPS 同口径）"

# DSH 自己的会话列表（读 ~/.dsh/sessions，含 zstd）
e2e-dsh: build
	$(OUT) --list-dsh-sessions

# P30：运行中的命令不再等 step 边界（真终端 + 假网关；离线，不联网）
#   三条验收（脚本见 testdata/pty_drive.py，假网关见 testdata/mock_gateway_sse.py）：
#     1) 单步长流式里敲 /status：浮层必须 ≤800ms 出现，且那一刻回合还在跑
#        （旧实现要等这一步走完 —— 3s 的单步流实测 2245ms，用户看到的就是卡死）
#     2) 回合运行中敲 /new：立刻回执 + 中断当前回合（随后由主循环开新会话）
#     3) esc 中断一回合之后再发一条任务：必须正常跑完（曾经被粘住的中断标志秒断）
#   P31 起再加四条「请求在飞」的验收（判据与数字见 §19 的 P31 验收记录）：
#     4) 响应头还没回来时敲 /status：≤800ms（旧实现要等头到 —— 3s 的头实测 2280ms）
#     5) 空闲敲 /status：≤150ms（旧实现 242ms = 等下一次 200ms 轮询）
#     6) bash 跑着时敲 /status：≤200ms（且回合仍在跑）
#     7) 压缩的摘要请求在飞时敲 /status：≤300ms（且必须证明压缩真发过请求）
#   P41 起再加一条「选择框」的验收（真终端里的人机路径，本场不发请求、不建 worktree）：
#     8) 命令面板里选中 /worktree（ctrl+p → 过滤 → 回车）与裸 /worktree 都要开出动作选择框
#        （七行 + ✓ 标当前模式）→ ↓ 到 finish → 回车翻出「确认 finish？」→ 再回车
#        （默认游标是「取消」）什么都不做
#   P53 起再加一条「浮层全屏」的验收（真终端里的 ctrl+f / F11，判据全是屏幕几何）：
#     9) /status 开出来是居中框（顶边 > 0 行、左边框 > 0 列）→ ctrl+f 顶到屏幕四边
#        （顶边第 0 行、左右边框正好 0 与 cols-1、标题带 ` · 全屏`）→ **面板与脚注都还在**、
#        底边压在面板之上 → F11 关回居中（顶边 > 0 行）→ 再 ctrl+f、esc 关掉浮层
#   踩坑 114 起再加一条「运行中按 ctrl+t」的验收（真终端；假网关第 6 个参数 todo_first=1
#   让第一次请求回一个 todo_write，于是常驻块的折叠行真的在屏幕上）：
#    10) 回合运行中（第 2 步流式在飞）按 ctrl+t → `┌─ tasks ` ≤1.5s 上屏，且那一刻
#        SELFTEST_OK 还没出现（＝不是「回合跑完才补画」）→ 再按一次收回折叠行
#   PTY_DUMP=1 会把子进程屏幕打出来（P41 那场会多打两张框的屏幕）；单跑一个场景：
#     python3 testdata/pty_drive.py --port <假网关端口> --workspace /tmp/ws status-single-step
p30-check: build
	@python3 testdata/pty_drive.py --suite

# P42：/watch —— 子代理的实时过程消息（真终端 + 假网关；离线，不联网）
#   判据（脚本见 testdata/pty_drive_watch.py，假网关见 testdata/mock_gateway_watch.py）：
#     父代理派一个「先思考、再跑 sleep N 的 bash」的子代理；期间敲 /watch sub-1，
#     `[step …]` 与 `▸ bash …` 必须**在子代理结束之前**就上屏（这才是「实时」）。
#   对照旧行为：子代理的 fd 1/2 → /dev/null，管道只承载终态答复，所以面板上那列
#   「已收输出行数」对普通 subagent 恒为 0 —— 运行中从管道看不到任何过程消息。
e2e-watch: build
	@set -e; \
	ws=build/selftest_p41_watch; rm -rf $$ws; mkdir -p $$ws; \
	python3 testdata/mock_gateway_watch.py 0 8 > $$ws/gw.log 2>&1 & \
	gw=$$!; \
	trap "kill $$gw 2>/dev/null || true" EXIT; \
	sleep 1.2; \
	port=$$(awk '/^PORT/{print $$2}' $$ws/gw.log); \
	[ -n "$$port" ] || { echo "FAIL: 假网关没打印端口"; cat $$ws/gw.log; exit 1; }; \
	UYA_BIN=$(OUT) python3 testdata/pty_drive_watch.py --port $$port --workspace $$ws; \
	echo "e2e-watch: 通过（/watch 在子代理结束前就读到 [step]/▸ bash）"

# P46：/watch 现役清单「选中即跟随」+ 回合运行中当场派发（真终端 + 假网关；离线，不联网）
#   判据（同一条脚本的两条腿，见 testdata/pty_drive_watch.py）：
#     pick    ：裸 /watch → 清单浮层（游标默认落在第一个代理行）→ **一次回车**就开跟随浮层，
#               且 `[step …]` / `▸ bash …` 仍在子代理结束之前上屏；
#     running ：假网关把父代理的收尾按住 12 s（响应头都不发），这段时间里敲 /watch sub-1
#               → 必须**当场**开跟随浮层（屏幕上还没有 PARENT-DONE-OK），而不是等回合结束。
#   对照旧行为：①清单借 /tasks 的 TUI_OVK_TASKS kind ⇒ 回车交出的行没人接、被静默丢掉
#   （「选中一个代理」= 什么都没发生）；②回合运行中敲的 `/watch sub-1` 在 step 边界那条路上
#   整行匹配不上安全集，被当成给模型的文本 —— 两条都是「敲了没反应」。
e2e-watch-pick: build
	@set -e; \
	ws=build/selftest_p46_watchpick; rm -rf $$ws; mkdir -p $$ws; \
	python3 testdata/mock_gateway_watch.py 0 10 0 > $$ws/gw-pick.log 2>&1 & \
	gw1=$$!; \
	python3 testdata/mock_gateway_watch.py 0 10 12 > $$ws/gw-run.log 2>&1 & \
	gw2=$$!; \
	trap "kill $$gw1 $$gw2 2>/dev/null || true" EXIT; \
	sleep 1.2; \
	p1=$$(awk '/^PORT/{print $$2}' $$ws/gw-pick.log); \
	p2=$$(awk '/^PORT/{print $$2}' $$ws/gw-run.log); \
	[ -n "$$p1" ] && [ -n "$$p2" ] || { echo "FAIL: 假网关没打印端口"; cat $$ws/gw-*.log; exit 1; }; \
	UYA_BIN=$(OUT) python3 testdata/pty_drive_watch.py --port $$p1 --workspace $$ws/pick --sleep 10 --mode pick; \
	UYA_BIN=$(OUT) python3 testdata/pty_drive_watch.py --port $$p2 --workspace $$ws/running --sleep 10 --mode running --parent-hold 12; \
	echo "e2e-watch-pick: 通过（清单一次回车即跟随 + 回合运行中当场开跟随浮层）"

# P33/P35：/sessions 列表（离线，行式 REPL 走真二进制）：三列 = 标题 / 工作区 / session id，
# **只列有标题的会话**（空标题的行整条不见），同 id 只留最后一条；
# **P35 起最新的排最后一行**（`--list-sessions` 与 `/sessions` 同一份）。
# TUI 浮层那条腿（宽箱体 / 逐行宽度不变量 / 默认游标落在最新那条 / 选中项取完整 id）
# 在 selftest 的 tui-sessions 轮里断言。
e2e-sessions: build
	@set -e; \
	home=build/selftest_sess_e2e; rm -rf $$home; mkdir -p $$home; \
	ida=session-aaaa1111-1111-4111-8111-111111111111; \
	idb=session-cccc3333-3333-4333-8333-333333333333; \
	idc=session-dddd4444-4444-4444-8444-444444444444; \
	{ \
	  printf '%s\n' "{\"id\":\"$$ida\",\"cwd\":\"/w/old-a\",\"lastActiveAt\":1000,\"title\":\"OLDTITLE-旧会话第一次记录\",\"model\":\"m\",\"delegationDepth\":0,\"turns\":0,\"events\":0,\"path\":\"/x\"}"; \
	  printf '%s\n' "{\"id\":\"$$idb\",\"cwd\":\"/w/none\",\"lastActiveAt\":7000,\"title\":\"CTITLE-中间会话\",\"model\":\"m\",\"delegationDepth\":0,\"turns\":0,\"events\":0,\"path\":\"/x\"}"; \
	  printf '%s\n' "{\"id\":\"$$ida\",\"cwd\":\"/w/new-a\",\"lastActiveAt\":9000,\"title\":\"NEWTITLE-最新会话第二次记录\",\"model\":\"m\",\"delegationDepth\":0,\"turns\":0,\"events\":0,\"path\":\"/x\"}"; \
	  printf '%s\n' "{\"id\":\"$$idc\",\"cwd\":\"/w/notitle\",\"lastActiveAt\":11000,\"title\":\"\",\"model\":\"m\",\"delegationDepth\":0,\"turns\":0,\"events\":0,\"path\":\"/x\"}"; \
	} > $$home/index.jsonl; \
	out=$$(printf '/sessions\n/exit\n' | $(OUT) --no-dsh-config --no-tui --quiet --api-key dummy-key --agent-home $$home 2>&1); \
	echo "$$out" | grep -qF "NEWTITLE" \
		|| { echo "FAIL: 列表里没有最新会话的标题（第一列不是标题？）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "OLDTITLE-旧会话第一次记录" \
		&& { echo "FAIL: 被取代的旧记录还在列表里（同 id 没取最后一条）"; echo "$$out"; exit 1; }; \
	[ "$$(echo "$$out" | grep -c "$$ida")" -eq 1 ] \
		|| { echo "FAIL: 同一个 session id 出现次数 != 1（去重没生效）"; echo "$$out"; exit 1; }; \
	[ "$$(echo "$$out" | grep -c 'session-')" -eq 2 ] \
		|| { echo "FAIL: 列表行数不是 2（空标题的会话应当被过滤掉）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "$$idc" \
		&& { echo "FAIL: 空标题的会话（lastActiveAt 最大）还在列表里"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "(无标题)" \
		&& { echo "FAIL: 空标题的会话还在列表里（占位串又出现了）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "CTITLE-中间会话" \
		|| { echo "FAIL: 有标题的中间会话不在列表里"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qE "/w/new-a +session-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$$" \
		|| { echo "FAIL: 工作区列与完整 session id 没有排成「工作区在前、id 在行尾」"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -q "session-" || { echo "FAIL: 列表里一个会话都没有"; echo "$$out"; exit 1; }; \
	n_new=$$(echo "$$out" | grep -n "NEWTITLE" | head -1 | cut -d: -f1); \
	n_mid=$$(echo "$$out" | grep -n "CTITLE" | head -1 | cut -d: -f1); \
	[ -n "$$n_new" ] && [ -n "$$n_mid" ] && [ "$$n_new" -gt "$$n_mid" ] \
		|| { echo "FAIL: 最新的没有排在最后一行（P35 的展示序）"; echo "$$out"; exit 1; }; \
	last_id=$$(echo "$$out" | grep "session-" | tail -1 | sed 's/.*\(session-[0-9a-f-]*\).*/\1/'); \
	[ "$$last_id" = "$$ida" ] \
		|| { echo "FAIL: 最后一行不是「有标题的会话里 lastActiveAt 最大」的那条（实际 $$last_id）"; echo "$$out"; exit 1; }; \
	first_id=$$(echo "$$out" | grep "session-" | head -1 | sed 's/.*\(session-[0-9a-f-]*\).*/\1/'); \
	[ "$$first_id" = "$$idb" ] \
		|| { echo "FAIL: 第一行不是最旧的有标题会话（实际 $$first_id）"; echo "$$out"; exit 1; }; \
	echo "e2e-sessions: 通过（只列有标题的会话 / 三列 / 最新的在最后一行 / 同 id 取最后一条 / id 完整）"

# P35：恢复会话段错误回归（离线，真二进制）：造一份 ~3 MiB 的会话日志，末尾再补一条
# **没有换行**的残行，然后 --resume --dry-run。未修版本在这里稳定 SIGSEGV（退出码 139），
# 修好后必须 0 且打得出 [dry-run]（语义侧那条断言在 selftest 的 sess-meta-big 轮里）。
# 3 MiB 是有意的：1 MiB 时越界窗口恰好还能落在同一个 mmap 里、侥幸不崩（实测），
# 而 3 MiB 稳定崩 —— 这样这条 e2e 才真的能抓到 139。
e2e-resume-big: build
	@set -e; \
	home=build/selftest_resume_big; rm -rf $$home; mkdir -p $$home; \
	sid=session-b19b19b1-2222-4333-8444-555566667777; \
	python3 testdata/make_big_session.py $$home; \
	set +e; \
	out=$$($(OUT) --no-dsh-config --no-tui --api-key dummy-key --agent-home $$home --resume $$sid --dry-run 2>&1); \
	rc=$$?; \
	set -e; \
	[ "$$rc" -eq 0 ] \
		|| { echo "FAIL: 大日志 --resume 退出码 = $$rc（139 = 段错误，见 §16 踩坑 54）"; echo "$$out" | tail -5; exit 1; }; \
	echo "$$out" | grep -q "\[dry-run\]" \
		|| { echo "FAIL: --dry-run 没打出请求摘要"; echo "$$out" | tail -5; exit 1; }; \
	echo "$$out" | grep -q "/selftest/meta-big/final" \
		|| { echo "FAIL: 恢复出来的工作区不是日志里最后一条 session/workspace"; echo "$$out" | tail -5; exit 1; }; \
	echo "e2e-resume-big: 通过（~3 MiB 日志不崩 / 最后一条 workspace 取到）"

# TUI：打印 home / chat 两屏纯文本快照（本文引用的就是它，改动排版时先看这个）
tui-demo: build
	$(OUT) --no-dsh-config --tui-demo

# TUI 相关自测轮（只跑 frame/keys/sink/turn/pty，改动 TUI 时比整轮 selftest 快得多）
tui-selftest: build
	UYA_SELFTEST_TUI_ONLY=1 $(OUT) --selftest

# P92：出站代理的两段自测（纯函数：形状/默认端口/凭据头字节/回环绕过/七类非法值各指原因；
# 现地假代理：CONNECT 原文与隧道透明 / 绝对形式请求行 / 407 与 502 各自归位 / 回环绕过）。
# 改 net/proxyx 或那条路由时比整轮 selftest 快得多 —— 判据全是线上字节与回环套接字，不联网。
proxy-selftest: build
	UYA_SELFTEST_PROXY_ONLY=1 $(OUT) --selftest

# P37：模型选择 / 推理强度 / worktree 的自测轮（改这条线时比整轮 selftest 快）
model-selftest: build
	UYA_SELFTEST_MODEL_ONLY=1 $(OUT) --selftest

# P60：web 界面（服务端终端解释器 + 页面）的自测轮，改 web 时比整轮快
web-selftest: build
	UYA_SELFTEST_WEB_ONLY=1 $(OUT) --selftest

# P33：/sessions 列表的自测轮（纯函数排版 + TUI 浮层 + 大索引排序/大列表取行），改会话列表时比整轮 selftest 快
sess-selftest: build
	UYA_SELFTEST_SESS_ONLY=1 $(OUT) --selftest

# P22：/diff 的自测轮（纯解析 + 真 git 端到端），改 /diff 时比整轮 selftest 快
diff-selftest: build
	UYA_SELFTEST_DIFF_ONLY=1 $(OUT) --selftest

# P38：bash 工具的进程侧自测轮（终端收口 / 停住即收口 / 整组收子孙），改 shellx 时比整轮快
shell-selftest: build
	UYA_SELFTEST_SHELL_ONLY=1 $(OUT) --selftest

# P104：后台任务/子代理的**异步完成通知**（端到端投递 / 队列语义 / 让路判据），
# 改 agent/ag_bg_notes.uya 或 jobs/deleg 的结算时比整轮快
notify-selftest: build
	UYA_SELFTEST_NOTIFY_ONLY=1 $(OUT) --selftest

# P15/P40：子代理窗口面板的自测轮（几何 / 每行等宽 / 消息预览贴尾），改面板排版时比整轮快
panel-selftest: build
	UYA_SELFTEST_PANEL_ONLY=1 $(OUT) --selftest

# P66：项目记忆的自测轮（项目身份归一 / 只追加分片 / 并发归并不丢更新），改 pm/ 时比整轮快
pm-selftest: build
	UYA_SELFTEST_PM_ONLY=1 $(OUT) --selftest

# P70：MCP 插件的自测轮（公开名规则 / 真子进程握手与工具发现 / 派发与投影 / 降级不留孤儿）。
# 它现场写一个纯 sh 的 MCP server 到 build/selftest_mcp/，不联网、不需要 python/node。
mcp-selftest: build
	UYA_SELFTEST_MCP_ONLY=1 $(OUT) --selftest

clean:
	rm -rf build
