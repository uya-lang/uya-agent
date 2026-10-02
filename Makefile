# /home/winger/uya-agent/Makefile — 仅构建胶水；agent 本体全部是 Uya 源码
#
# 用法：
#   make check      # 只做词法/语法/类型检查
#   make build      # 产出 build/uya-agent
#   make selftest   # 离线端到端自测（内置 mock LLM，无需网络与 key）
#   make probe      # 传输层探针（默认打 api.deepseek.com，期望 HTTP 401）
#   make e2e TASK="..." PIN=<leaf sha256>   # 真实调用（需要 DEEPSEEK_API_KEY）
#   make clean
#
# 换编译器（例如 0.11，未实测）：make UYA=/home/winger/uya-0.11/bin/uya UYA_ROOT=/home/winger/uya-0.11/lib/ ...

UYA_ROOT ?= /home/winger/uya-0.10/lib/
UYA      ?= /home/winger/uya-0.10/bin/uya

SRC := src/bufx.uya src/jsonx.uya src/httpc.uya src/httpstream.uya src/sse.uya src/llm.uya src/tty.uya src/inbox.uya src/session.uya src/yamlcfg.uya src/dshcfg.uya src/prompt.uya src/instr.uya src/todo.uya src/plan.uya src/askuser.uya src/fsx.uya src/search.uya src/jobs.uya src/shellx.uya src/tools.uya src/agent.uya src/selftest.uya
OUT := build/uya-agent

BASE ?= https://api.deepseek.com/v1
PIN  ?=
TASK ?= 创建 hello.uya，编译并运行它

# 编译器按 UYA_ROOT 找标准库，按 UYA_SPLIT_C_DIR 放多文件 C 缓存
export UYA_ROOT
export UYA_SPLIT_C_DIR := $(CURDIR)/build/uyacache

.PHONY: all check build selftest probe e2e clean

all: build

check:
	@mkdir -p build
	$(UYA) check $(SRC)

build:
	@mkdir -p build
	$(UYA) build $(SRC) -o $(OUT)

selftest: build
	$(OUT) --selftest

probe: build
	$(OUT) --probe --tls-verify=none --base-url $(BASE)

e2e: build
	$(OUT) $(if $(PIN),--tls-verify=pin --tls-pin $(PIN),--tls-verify=none) "$(TASK)"

clean:
	rm -rf build
