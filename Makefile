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
#   make e2e-tasks  # /tasks：报告头 / 空态串 / open / toggle / 非法参数（离线）
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
UYA_ROOT ?= /home/winger/uya/uya/lib/
UYA      ?= /home/winger/uya/uya/bin/uya

STATIC ?= 1
ifeq ($(STATIC),1)
AGENT_LDFLAGS := -static
else
AGENT_LDFLAGS :=
endif

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
       src/net/httpc.uya src/net/httpstream.uya src/net/llm.uya src/net/sse.uya src/net/webx.uya \
       src/term/mdview.uya src/term/tasks.uya src/term/tty.uya \
       src/term/tui/style.uya src/term/tui/keys.uya src/term/tui/frame.uya src/term/tui/entry.uya src/term/tui/screen.uya src/term/tui/overlay.uya src/term/tui/status.uya src/term/tui/ask.uya src/term/tui/watch.uya src/term/tui/diff.uya src/term/tui/hook.uya \
       src/term/view.uya src/term/watch.uya \
       src/tools/askuser.uya src/tools/fsx.uya src/tools/jobs.uya src/tools/perm.uya src/tools/sandboxx.uya src/tools/search.uya src/tools/shellx.uya \
       src/session/dshcfg.uya src/session/dshsess.uya src/session/inbox.uya src/session/modelx.uya src/session/procx.uya src/session/session.uya src/session/sigx.uya src/session/stats.uya \
       src/agent/agent.uya src/agent/ag_config.uya src/agent/ag_title_prompt.uya src/agent/ag_tools_schema.uya src/agent/ag_request_stream.uya src/agent/ag_workspace_model.uya src/agent/ag_worktree.uya src/agent/ag_interactive_tasks.uya src/agent/ag_tui_sessions.uya src/agent/ag_plan_pump.uya src/agent/compact.uya src/agent/deleg.uya src/agent/goal.uya src/agent/instr.uya src/agent/plan.uya src/agent/prompt.uya src/agent/skill.uya src/agent/todo.uya src/agent/workflow.uya \
       src/pm/pm_repo.uya src/pm/pm_store.uya src/pm/pm_ingest.uya src/pm/pm_digest.uya \
       src/vcs/gitx.uya src/vcs/worktreex.uya \
       src/media/clipx.uya src/media/imgx.uya \
       src/selftest/selftest.uya src/selftest/shellselftest.uya src/selftest/sigselftest.uya src/selftest/tuiselftest.uya \
       src/selftest/st_core.uya src/selftest/st_mock_server.uya src/selftest/st_round_driver.uya src/selftest/st_tty_sse.uya src/selftest/st_sessions.uya src/selftest/st_read_window.uya src/selftest/st_view_watch.uya src/selftest/st_responses.uya src/selftest/st_stats_ctx.uya src/selftest/st_title.uya src/selftest/st_tasks_ws.uya src/selftest/st_goal_worktree.uya src/selftest/st_pm.uya \
       src/selftest/tuis_core.uya src/selftest/tuis_title_pty.uya src/selftest/tuis_exit_cmd.uya src/selftest/tuis_diff_scroll.uya src/selftest/tuis_title_ask.uya src/selftest/tuis_sessions_big.uya src/selftest/tuis_tail.uya \
       src/diff/model.uya src/diff/gitcmd.uya src/diff/rows.uya src/diff/view.uya src/diff/render.uya
OUT := build/uya-agent

BASE ?= https://api.deepseek.com/v1
PIN  ?=
TASK ?= 创建 hello.uya，编译并运行它

# 编译器按 UYA_ROOT 找标准库，按 UYA_SPLIT_C_DIR 放多文件 C 缓存
export UYA_ROOT
export UYA_SPLIT_C_DIR := $(CURDIR)/build/uyacache

.PHONY: all check print-src build link-audit selftest codegen-audit doc-audit doc-cover probe e2e e2e-config e2e-exec e2e-accept-nudge e2e-config-flags e2e-title e2e-title-cmd e2e-title-auto e2e-mouse e2e-api e2e-steps e2e-permission e2e-sandbox e2e-tasks e2e-goal e2e-sessions e2e-resume-big e2e-diff e2e-ws e2e-model e2e-model-route e2e-worktree e2e-watch e2e-watch-pick e2e-dsh p30-check tui-demo tui-selftest sess-selftest diff-selftest model-selftest panel-selftest clean shell-selftest pm-selftest

all: build

# 打印源文件清单（一行，空格分隔）。给「不走 make 的手工编译」和脚手架用：
#   uya build $(make -s print-src) -o build/uya-agent
# 清单只在这一个地方维护（SRC），别在 README / 脚本里手抄。
print-src:
	@echo $(SRC)

check:
	@mkdir -p build
	$(UYA) check $(SRC)

build:
	@mkdir -p build
	LDFLAGS="$(AGENT_LDFLAGS)" $(UYA) build $(SRC) -o $(OUT)
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
selftest: build codegen-audit doc-audit doc-cover e2e-exec e2e-accept-nudge e2e-config-flags e2e-title e2e-title-cmd e2e-title-auto e2e-mouse e2e-api e2e-steps e2e-permission e2e-sandbox e2e-tasks e2e-goal e2e-sessions e2e-resume-big e2e-diff e2e-ws e2e-model e2e-model-route e2e-worktree p30-check
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
	echo "e2e-model: 通过（目录/能力跟随/目录外只换名字/REPL 报告与切换/非法档位拒/透传标注/同名跨提供方指定与提示/--provider 顺序无关）"

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
	echo "$$out" | grep -q "tls_verify = chain  (source: default)" \
		|| { echo "FAIL: 读不到 DSH 设置时应回落到内置默认 chain"; exit 1; }; \
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
# 这一条只能拿真终端验。驱动脚本内联在这里（不新增 testdata 脚本）：pty.fork 起真二进制，
# 打一条任务，等「回合 + 静默期 + 起标题请求」都收场，再 ctrl+d 退出。
# 判据：日志里出现 kind=provider 的 session/title，且假网关收到了 ≥2 次请求；
#       --no-title-auto 时两样都没有。
e2e-title-auto: build
	@set -e; \
	ws=build/selftest_title_auto_e2e; rm -rf $$ws; mkdir -p $$ws/home $$ws/home2; \
	python3 testdata/mock_gateway_sse.py 0 1 200 > $$ws/gw.log 2>$$ws/gw.err & \
	gw=$$!; \
	trap "kill $$gw 2>/dev/null || true" EXIT; \
	sleep 1.2; \
	port=$$(awk '/^PORT/{print $$2}' $$ws/gw.log); \
	[ -n "$$port" ] || { echo "FAIL: 假网关没打印端口"; cat $$ws/gw.log; exit 1; }; \
	UYA_BIN="$(CURDIR)/$(OUT)" PORT="$$port" HOME_A="$$ws/home" HOME_B="$$ws/home2" \
		python3 testdata/pty_drive_title.py; \
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
	: "② --no-title-auto：只有主请求，且没有 provider 事件"; \
	if grep -qF '"source":{"kind":"provider"}' $$ws/home2/sessions/*/*/session.jsonl 2>/dev/null; then \
		echo "FAIL: --no-title-auto 下仍然落了 provider 事件"; exit 1; \
	fi; \
	: "③ 三来源都看得出来，CLI 压过 env"; \
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
	echo "e2e-title-auto: 通过（自动起标题发请求+落 provider 事件；--no-title-auto 两样都没有；三来源与 CLI 优先）"

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

# P37：模型选择 / 推理强度 / worktree 的自测轮（改这条线时比整轮 selftest 快）
model-selftest: build
	UYA_SELFTEST_MODEL_ONLY=1 $(OUT) --selftest

# P33：/sessions 列表的自测轮（纯函数排版 + TUI 浮层 + 大索引排序/大列表取行），改会话列表时比整轮 selftest 快
sess-selftest: build
	UYA_SELFTEST_SESS_ONLY=1 $(OUT) --selftest

# P22：/diff 的自测轮（纯解析 + 真 git 端到端），改 /diff 时比整轮 selftest 快
diff-selftest: build
	UYA_SELFTEST_DIFF_ONLY=1 $(OUT) --selftest

# P38：bash 工具的进程侧自测轮（终端收口 / 停住即收口 / 整组收子孙），改 shellx 时比整轮快
shell-selftest: build
	UYA_SELFTEST_SHELL_ONLY=1 $(OUT) --selftest

# P15/P40：子代理窗口面板的自测轮（几何 / 每行等宽 / 消息预览贴尾），改面板排版时比整轮快
panel-selftest: build
	UYA_SELFTEST_PANEL_ONLY=1 $(OUT) --selftest

# P63：项目记忆的自测轮（项目身份归一 / 只追加分片 / 并发归并不丢更新），改 pm/ 时比整轮快
pm-selftest: build
	UYA_SELFTEST_PM_ONLY=1 $(OUT) --selftest

clean:
	rm -rf build
