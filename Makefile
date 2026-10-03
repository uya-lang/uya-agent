# /home/winger/uya-agent/Makefile — 仅构建胶水；agent 本体全部是 Uya 源码
#
# 用法：
#   make check      # 只做词法/语法/类型检查
#   make build      # 产出 build/uya-agent
#   make selftest   # 离线端到端自测（内置 mock LLM，无需网络与 key）
#   make probe      # 传输层探针（默认打 api.deepseek.com，期望 HTTP 401）
#   make e2e-diff   # /diff：真 git 的改动列表 + 单列文本回退 + 非仓库报错（离线）
#   make e2e-tasks  # /tasks：报告头 / 空态串 / open / toggle / 非法参数（离线）
#   make e2e-goal   # /goal：看状态 / 创建 / 拒绝顶掉 / edit / pause / resume / clear（离线）
#   make e2e TASK="..." PIN=<leaf sha256> [STEPS=N]   # 真实调用（需要 DEEPSEEK_API_KEY；STEPS 不给就不限步数）
#   make e2e-steps  # 步数默认值回归（离线，不联网）
#   make clean
#
# 换编译器（例如 0.11，未实测）：make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...

UYA_ROOT ?= /home/winger/uya-0.10/lib/
UYA      ?= /home/winger/uya-0.10/bin/uya

SRC := src/bufx.uya src/jsonx.uya src/httpc.uya src/httpstream.uya src/sse.uya src/llm.uya src/tty.uya src/sigx.uya src/inbox.uya src/session.uya src/stats.uya src/procx.uya src/yamlcfg.uya src/dshcfg.uya src/dshsess.uya src/prompt.uya src/instr.uya src/compact.uya src/skill.uya src/webx.uya src/deleg.uya src/goal.uya src/workflow.uya src/todo.uya src/plan.uya src/perm.uya src/sandboxx.uya src/askuser.uya src/fsx.uya src/search.uya src/jobs.uya src/shellx.uya src/gitx.uya src/gitdiff.uya src/tools.uya src/diffx.uya src/view.uya src/tasks.uya src/tui.uya src/agent.uya src/sigselftest.uya src/tuiselftest.uya src/selftest.uya
OUT := build/uya-agent

BASE ?= https://api.deepseek.com/v1
PIN  ?=
TASK ?= 创建 hello.uya，编译并运行它

# 编译器按 UYA_ROOT 找标准库，按 UYA_SPLIT_C_DIR 放多文件 C 缓存
export UYA_ROOT
export UYA_SPLIT_C_DIR := $(CURDIR)/build/uyacache

.PHONY: all check build selftest codegen-audit probe e2e e2e-config e2e-config-flags e2e-title e2e-api e2e-steps e2e-permission e2e-sandbox e2e-tasks e2e-goal e2e-sessions e2e-diff e2e-dsh p30-check tui-demo tui-selftest sess-selftest diff-selftest clean

all: build

check:
	@mkdir -p build
	$(UYA) check $(SRC)

build:
	@mkdir -p build
	$(UYA) build $(SRC) -o $(OUT)

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

selftest: build codegen-audit e2e-config-flags e2e-title e2e-api e2e-steps e2e-permission e2e-sandbox e2e-tasks e2e-goal e2e-sessions e2e-diff p30-check
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


# 真实网关端到端：默认走 DSH 设置（零参数就能拿到 base-url/model/key），
# 也可以显式覆盖。TLS：给了 PIN 用 pin，否则用 none（真机链校验过不去，见 README 第 5 节）
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

# CLI flag 回归：--dsh-home / --no-dsh-config / --strict-dsh-config 决定「去哪儿读设置」，
# 必须在下一次加载之前生效（曾经因为完整 CLI 解析排在加载之后而三个 flag 全部静默失效，
# 见 README 踩坑 25）。离线可跑：--print-config 不联网。
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
	echo "e2e-config-flags: 通过（--dsh-home / --no-dsh-config / --strict-dsh-config 都在加载前生效）"

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
#   P31 起再加四条「请求在飞」的验收（判据与数字见 README §6 的 P31 验收记录）：
#     4) 响应头还没回来时敲 /status：≤800ms（旧实现要等头到 —— 3s 的头实测 2280ms）
#     5) 空闲敲 /status：≤150ms（旧实现 242ms = 等下一次 200ms 轮询）
#     6) bash 跑着时敲 /status：≤200ms（且回合仍在跑）
#     7) 压缩的摘要请求在飞时敲 /status：≤300ms（且必须证明压缩真发过请求）
#   PTY_DUMP=1 会把子进程屏幕打出来；单跑一个场景：
#     python3 testdata/pty_drive.py --port <假网关端口> --workspace /tmp/ws status-single-step
p30-check: build
	@python3 testdata/pty_drive.py --suite

# P33：/sessions 列表（离线，行式 REPL 走真二进制）：三列 = 标题 / 工作区 / session id，
# 按 lastActiveAt 倒序、同 id 只留最后一条。TUI 浮层那条腿（宽箱体 / 逐行宽度不变量 /
# 选中项取完整 id）在 selftest 的 tui-sessions 轮里断言。
e2e-sessions: build
	@set -e; \
	home=build/selftest_sess_e2e; rm -rf $$home; mkdir -p $$home; \
	ida=session-aaaa1111-1111-4111-8111-111111111111; \
	{ \
	  printf '%s\n' "{\"id\":\"$$ida\",\"cwd\":\"/w/old-a\",\"lastActiveAt\":1000,\"title\":\"OLDTITLE-旧会话第一次记录\",\"model\":\"m\",\"delegationDepth\":0,\"turns\":0,\"events\":0,\"path\":\"/x\"}"; \
	  printf '%s\n' '{"id":"session-cccc3333-3333-4333-8333-333333333333","cwd":"/w/none","lastActiveAt":7000,"title":"","model":"m","delegationDepth":0,"turns":0,"events":0,"path":"/x"}'; \
	  printf '%s\n' "{\"id\":\"$$ida\",\"cwd\":\"/w/new-a\",\"lastActiveAt\":9000,\"title\":\"NEWTITLE-最新会话第二次记录\",\"model\":\"m\",\"delegationDepth\":0,\"turns\":0,\"events\":0,\"path\":\"/x\"}"; \
	} > $$home/index.jsonl; \
	out=$$(printf '/sessions\n/exit\n' | $(OUT) --no-dsh-config --no-tui --quiet --api-key dummy-key --agent-home $$home 2>&1); \
	echo "$$out" | grep -qF "NEWTITLE" \
		|| { echo "FAIL: 列表里没有最新会话的标题（第一列不是标题？）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "OLDTITLE-旧会话第一次记录" \
		&& { echo "FAIL: 被取代的旧记录还在列表里（同 id 没取最后一条）"; echo "$$out"; exit 1; }; \
	[ "$$(echo "$$out" | grep -c "$$ida")" -eq 1 ] \
		|| { echo "FAIL: 同一个 session id 出现次数 != 1（去重没生效）"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qF "(无标题)" \
		|| { echo "FAIL: 空标题没有落到占位串上"; echo "$$out"; exit 1; }; \
	echo "$$out" | grep -qE "/w/new-a +session-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$$" \
		|| { echo "FAIL: 工作区列与完整 session id 没有排成「工作区在前、id 在行尾」"; echo "$$out"; exit 1; }; \
	n_new=$$(echo "$$out" | grep -n "NEWTITLE" | head -1 | cut -d: -f1); \
	n_old=$$(echo "$$out" | grep -n "(无标题)" | head -1 | cut -d: -f1); \
	[ -n "$$n_new" ] && [ -n "$$n_old" ] && [ "$$n_new" -lt "$$n_old" ] \
		|| { echo "FAIL: 不是时间倒序（最新的必须在上面）"; echo "$$out"; exit 1; }; \
	echo "e2e-sessions: 通过（三列 / 时间倒序 / 同 id 取最后一条 / 空标题占位 / id 完整）"

# TUI：打印 home / chat 两屏纯文本快照（README 引用的就是它，改动排版时先看这个）
tui-demo: build
	$(OUT) --no-dsh-config --tui-demo

# TUI 相关自测轮（只跑 frame/keys/sink/turn/pty，改动 TUI 时比整轮 selftest 快得多）
tui-selftest: build
	UYA_SELFTEST_TUI_ONLY=1 $(OUT) --selftest

# P33：/sessions 列表的自测轮（纯函数排版 + TUI 浮层），改会话列表时比整轮 selftest 快
sess-selftest: build
	UYA_SELFTEST_SESS_ONLY=1 $(OUT) --selftest

# P22：/diff 的自测轮（纯解析 + 真 git 端到端），改 /diff 时比整轮 selftest 快
diff-selftest: build
	UYA_SELFTEST_DIFF_ONLY=1 $(OUT) --selftest

clean:
	rm -rf build
