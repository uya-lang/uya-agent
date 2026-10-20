# uya-agent 的镜像是 `FROM scratch` —— 里面只有**一个文件**。
#
# 这不是炫技，是这份 Dockerfile 想说清的那件事：本仓的二进制是静态链接的
# （无 `PT_INTERP`、无 `NEEDED`，`make link-audit` 每次构建都核），所以镜像里
# 不需要基础发行版、不需要 glibc、不需要 shell。`docker run` 起来的就是那个
# 9 MB 的可执行文件本身。
#
#   docker build -t uya-agent .
#   docker run -it --rm -e DEEPSEEK_API_KEY -v "$PWD:/work" uya-agent
#
# 想先确认它真的能跑（不要 key、不联网）：
#   docker run --rm uya-agent --tui-demo
#
# 注意：TUI 需要 TTY，跑交互界面请带 `-it`；`--web` 的默认绑定是 127.0.0.1
# （容器里等于只有容器自己能访问），要从宿主访问就显式给
#   docker run -it --rm -p 8787:8787 ... uya-agent --web 0.0.0.0:8787
# 并且**自己**在它前面套一层鉴权 —— 本仓的 web 界面没有任何认证（README §7）。

# ── 阶段 1：构建 ────────────────────────────────────────────────────────────
# 仓库自带编译器与标准库（uya/bin/uya + uya/stdlib），这一步不需要装 Uya、
# 也不需要预装任何语言运行时。唯一的外部依赖是一个 C 编译器 —— Uya 编译到 C
# 再交给宿主 cc 链接（生成的 build/uyacache/Makefile 用的是 `CC`）。
FROM debian:stable-slim AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gcc libc6-dev make ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# 静态链接是本仓的默认（Makefile 里 `STATIC ?= 1`），这里显式写出来，免得
# 将来默认值改了之后镜像悄悄依赖 glibc。
# `make link-audit` 放在 strip **之前**：它是这一步唯一关心的事，红就要当场红。
# strip 只去符号表（8.98 MB → 8.27 MB），产物照样能跑（实测）。
RUN make build STATIC=1 \
    && make link-audit \
    && strip --strip-all build/uya-agent

# ── 阶段 2：运行时 —— 空 ────────────────────────────────────────────────────
FROM scratch
COPY --from=build /src/build/uya-agent /uya-agent
# 会话与索引默认落在 ~/.uya-agent。scratch 里没有 $HOME，所以钉一个可写的路径；
# 想留住会话就 `-v uya-agent-home:/home/uya/.uya-agent`。
ENV HOME=/home/uya
WORKDIR /work
ENTRYPOINT ["/uya-agent"]
# 不给参数时进入 REPL —— 但容器里没有 TTY 会立刻退出，所以默认给一句帮助。
CMD ["--help"]
