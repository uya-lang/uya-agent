# /home/winger/uya-agent/Makefile — 仅构建胶水；agent 本体全部是 Uya 源码
#
# 用法：
#   make check      # 只做词法/语法/类型检查
#   make build      # 产出 build/uya-agent
#   make selftest   # 离线端到端自测（内置 mock LLM，无需网络与 key）
#   make probe      # 传输层探针（默认打 api.deepseek.com，期望 HTTP 401）
#   make e2e-diff   # /diff：真 git 的改动列表 + 单列文本回退 + 非仓库报错（离线）
#   make e2e-tasks  # /tasks：报告头 / 空态串 / open / toggle / 非法参数（离线）
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

.PHONY: all check build selftest codegen-audit probe e2e e2e-config e2e-config-flags e2e-title e2e-api e2e-steps e2e-permission e2e-sandbox e2e-tasks e2e-diff e2e-dsh tui-demo tui-selftest diff-selftest clean

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

selftest: build codegen-audit e2e-config-flags e2e-title e2e-api e2e-steps e2e-permission e2e-sandbox e2e-tasks e2e-diff
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

# TUI：打印 home / chat 两屏纯文本快照（README 引用的就是它，改动排版时先看这个）
tui-demo: build
	$(OUT) --no-dsh-config --tui-demo

# TUI 相关自测轮（只跑 frame/keys/sink/turn/pty，改动 TUI 时比整轮 selftest 快得多）
tui-selftest: build
	UYA_SELFTEST_TUI_ONLY=1 $(OUT) --selftest

# P22：/diff 的自测轮（纯解析 + 真 git 端到端），改 /diff 时比整轮 selftest 快
diff-selftest: build
	UYA_SELFTEST_DIFF_ONLY=1 $(OUT) --selftest

clean:
	rm -rf build
