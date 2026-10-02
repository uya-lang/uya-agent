# /home/winger/uya-agent/Makefile — 仅构建胶水；agent 本体全部是 Uya 源码
#
# 用法：
#   make check      # 只做词法/语法/类型检查
#   make build      # 产出 build/uya-agent
#   make selftest   # 离线端到端自测（内置 mock LLM，无需网络与 key）
#   make probe      # 传输层探针（默认打 api.deepseek.com，期望 HTTP 401）
#   make e2e TASK="..." PIN=<leaf sha256> [STEPS=N]   # 真实调用（需要 DEEPSEEK_API_KEY；STEPS 不给就不限步数）
#   make e2e-steps  # 步数默认值回归（离线，不联网）
#   make clean
#
# 换编译器（例如 0.11，未实测）：make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...

UYA_ROOT ?= /home/winger/uya-0.10/lib/
UYA      ?= /home/winger/uya-0.10/bin/uya

SRC := src/bufx.uya src/jsonx.uya src/httpc.uya src/httpstream.uya src/sse.uya src/llm.uya src/tty.uya src/inbox.uya src/session.uya src/yamlcfg.uya src/dshcfg.uya src/dshsess.uya src/prompt.uya src/instr.uya src/compact.uya src/skill.uya src/webx.uya src/deleg.uya src/goal.uya src/workflow.uya src/todo.uya src/plan.uya src/askuser.uya src/fsx.uya src/search.uya src/jobs.uya src/shellx.uya src/tools.uya src/diffx.uya src/view.uya src/agent.uya src/selftest.uya
OUT := build/uya-agent

BASE ?= https://api.deepseek.com/v1
PIN  ?=
TASK ?= 创建 hello.uya，编译并运行它

# 编译器按 UYA_ROOT 找标准库，按 UYA_SPLIT_C_DIR 放多文件 C 缓存
export UYA_ROOT
export UYA_SPLIT_C_DIR := $(CURDIR)/build/uyacache

.PHONY: all check build selftest codegen-audit probe e2e e2e-config e2e-config-flags e2e-steps e2e-dsh clean

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

selftest: build codegen-audit e2e-config-flags e2e-steps
	UYA_BIN=$(UYA) $(OUT) --selftest

probe: build
	$(OUT) --probe --tls-verify=none --base-url $(BASE)

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

clean:
	rm -rf build
