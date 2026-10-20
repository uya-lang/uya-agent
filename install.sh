#!/bin/sh
# install.sh — 把 uya-agent 装成一个单文件命令。
#
#   curl -fsSL https://raw.githubusercontent.com/uya-lang/uya-agent/main/install.sh | sh
#   ./install.sh --dir ~/bin            # 装到别处
#   ./install.sh --local                # 从当前目录的 build/uya-agent 装（自己编译过时）
#
# 它做的事只有三件：判断架构 → 拿那个二进制 → 放好并 chmod。
# **不写 $HOME 下的配置、不改 PATH、不装任何运行时**（整个程序就是一个文件）。
#
# 为什么不用官方 release 之外的下载源：本仓的发布只有 GitHub Releases 一处，
# 这里不引第三方镜像 —— 一个能跑任意代码的 agent，来源必须可核对。
set -eu

REPO="uya-lang/uya-agent"
DIR="${HOME}/.local/bin"
LOCAL=0
VERSION="latest"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --local) LOCAL=1; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "install.sh: 不认识的参数 $1" >&2; exit 1 ;;
    esac
done

case "$(uname -s)" in
    Linux) ;;
    Darwin) echo "install.sh: macOS 上还没有产物（本仓目前只发 Linux 与 Windows）" >&2
            echo "           从源码构建见 README §1（仓库自带编译器）。" >&2; exit 1 ;;
    *) echo "install.sh: 不支持的系统：$(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64) ARCH="linux-x86_64" ;;
    aarch64|arm64) echo "install.sh: 还没有 aarch64 产物（只发了 x86_64）" >&2; exit 1 ;;
    *) echo "install.sh: 不支持的架构：$(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$DIR"
TARGET="$DIR/uya-agent"
TMP="$TARGET.tmp.$$"
trap 'rm -f "$TMP"' EXIT INT TERM

if [ "$LOCAL" = 1 ]; then
    SRC="./build/uya-agent"
    [ -f "$SRC" ] || { echo "install.sh: 没有 $SRC（先跑 make build）" >&2; exit 1; }
    echo "install.sh: 从 $SRC 装"
    cp "$SRC" "$TMP"
else
    if [ "$VERSION" = "latest" ]; then
        URL="https://github.com/${REPO}/releases/latest/download/uya-agent-${ARCH}"
    else
        URL="https://github.com/${REPO}/releases/download/${VERSION}/uya-agent-${ARCH}"
    fi
    echo "install.sh: 下载 $URL"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$TMP" "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$TMP" "$URL"
    else
        echo "install.sh: 需要 curl 或 wget" >&2; exit 1
    fi
fi

chmod 755 "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT INT TERM

echo "install.sh: 装好了 → $TARGET"
# 自检用 `--tui-demo` 而不是 `--selftest`：前者不联网、不要 key、**不依赖当前目录**，
# 几毫秒就能证明「这个二进制在这台机器上真的能跑出界面」（静态链接的好处就在这里 ——
# 不会因为目标机的 glibc 太老而在这一步才炸）。
# `--selftest` 是**在仓库根**跑的端到端套件（它要 testdata/ 的夹具与 build/ 下的
# 工作区，换到空目录会红几条），所以不适合当安装自检。
if "$TARGET" --tui-demo >/dev/null 2>&1; then
    echo "install.sh: 自检通过（--tui-demo 渲染出了一屏，没联网）"
else
    echo "install.sh: 自检没通过 —— 先跑一次 $TARGET --tui-demo 看看" >&2
    exit 1
fi
case ":${PATH}:" in
    *":${DIR}:"*) ;;
    *) echo "install.sh: 注意 $DIR 不在 PATH 里，自己加一下或直接用绝对路径" ;;
esac
