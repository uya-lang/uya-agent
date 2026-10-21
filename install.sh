#!/bin/sh
# install.sh — 把 uya-agent 装成一个单文件命令。
#
#   curl -fsSL https://raw.githubusercontent.com/uya-lang/uya-agent/main/install.sh | sh
#   ./install.sh --dir ~/bin            # 装到别处
#   ./install.sh --version v0.1.0       # 钉一个发布（默认 latest）
#   ./install.sh --local                # 从当前目录的 build/uya-agent 装（自己编译过时）
#
# 它做的事只有三件：判断架构 → 拿那个二进制 → 放好并 chmod。
# **不写 $HOME 下的配置、不改 PATH、不装任何运行时**（整个程序就是一个文件）。
#
# 为什么不用官方 release 之外的下载源：本仓的发布只有 GitHub Releases 一处，
# 这里不引第三方镜像 —— 一个能跑任意代码的 agent，来源必须可核对。
#
# 为什么要**先查一次仓库 API**（而不是直接拼 releases/latest/download 的 URL）：
# 本仓还**没有发过任何 release** 时，那个 URL 的行为极难解释 —— 它会退回一份
# 「最新 tag」的快照页、按 `-o` 写盘，`curl -f` 不一定报 404，于是用户最后拿到的
# 是一份 HTML（或者一句「装好了」但其实没装）。先问一次 API，就能给出**说得清**的
# 三种结果：没发过 release（去从源码构建）／网络不通（查代理）／有就用它的资产名。
# 顺带把资产名**按 API 返回值匹配**：以后给产物改名，安装脚本不会静默 404。
set -eu

REPO="uya-lang/uya-agent"
DIR="${HOME}/.local/bin"
LOCAL=0
VERSION="latest"
API="https://api.github.com/repos/${REPO}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --local) LOCAL=1; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
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

ASSET="uya-agent-${ARCH}"

# 取一个 URL 到文件：有 curl 用 curl，否则 wget，都没有就报错。
fetch_to() {
    if command -v curl >/dev/null 2>&1; then
        # -s（不要进度条）但**不要** -S：404/断网时 curl 会自己打一行
        # `curl: (22) The requested URL returned error: 404` —— 而每一个失败现场
        # 我们都紧跟着给出人话（没有 release / 没有这个 tag / 网络不通），
        # 多这一行只会让人以为出了别的问题。
        curl -fsL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        echo "install.sh: 需要 curl 或 wget" >&2
        return 1
    fi
}

# 把一段 JSON 里所有 `"browser_download_url": "…"` 的 URL 逐行打出来。
# 用 sed 而不是 JSON 解析：安装脚本要在**只有 sh + curl** 的机器上跑（本仓不引 jq，
# 也不假设有 python）。这个字段的格式由 GitHub API 保证，抓取范围足够窄。
json_urls() {
    sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}

# 问一次仓库 API，把「这个版本该下的 URL」写进 $URL、校验和地址写进 $SUMS_URL。
# 返回 0 = 找到；3 = 仓库确实没有任何正式 release；5 = 钉的 tag 不存在（仓库里有的
# release，但不是你要的那个）；4 = 网络/解析失败（说不清）。
#
# 为什么要区分 3 与 4：这两件事给用户的下一步**完全不同** ——
#   * 没发过 release ⇒「去从源码构建」，再试一百次也一样；
#   * 网络不通 ⇒「查代理 / 换个网」，而不是让人以为这个项目没发布。
resolve_release() {
    meta="$1"
    if [ "$VERSION" = "latest" ]; then
        endpoint="${API}/releases/latest"
    else
        endpoint="${API}/releases/tags/${VERSION}"
    fi
    if ! fetch_to "$endpoint" "$meta"; then
        # `/releases/latest` 在「只有 draft / 只打了 tag」时也是 404，而 `/releases`
        # 会给一个空数组。用它把三种 404 分开：真没发过 / 钉的 tag 不存在 / 网络坏了。
        if fetch_to "${API}/releases" "$meta.all" 2>/dev/null; then
            if ! grep -q '"tag_name"' "$meta.all"; then
                return 3
            fi
            if [ "$VERSION" != "latest" ]; then
                # 有 release，但没有你钉的那个 tag —— 把现有的列出来，别让人自己猜。
                echo "install.sh: $REPO 没有 $VERSION 这个发布。现有的：" >&2
                grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$meta.all" \
                    | sed 's/.*"\([^"]*\)"$/             \1/' >&2
                return 5
            fi
            echo "install.sh: $REPO 还没有正式发布" >&2
            echo "           （有 draft / 预发布，但没有可下载的正式版）" >&2
            return 3
        fi
        return 4
    fi
    url=$(json_urls "$meta" | grep -F "/${ASSET}" | head -n 1)
    if [ -z "$url" ]; then
        echo "install.sh: 这个发布里没有 ${ASSET} 这个资产。" >&2
        echo "           这个发布现有的资产：" >&2
        json_urls "$meta" | sed 's|.*/|             |' >&2
        if json_urls "$meta" | grep -q '/uya-agent-windows'; then
            echo "           （只有 Windows 产物 ⇒ Linux 那一段构建失败了）" >&2
        fi
        return 4
    fi
    URL="$url"
    SUMS_URL=$(json_urls "$meta" | grep -F '/SHA256SUMS' | head -n 1)
    return 0
}

mkdir -p "$DIR"
TARGET="$DIR/uya-agent"
TMP="$TARGET.tmp.$$"
META="$TMP.meta"
trap 'rm -f "$TMP" "$META" "$META.all" "$TMP.sums"' EXIT INT TERM

if [ "$LOCAL" = 1 ]; then
    SRC="./build/uya-agent"
    [ -f "$SRC" ] || { echo "install.sh: 没有 $SRC（先跑 make build）" >&2; exit 1; }
    echo "install.sh: 从 $SRC 装"
    cp "$SRC" "$TMP"
else
    URL=""
    SUMS_URL=""
    rc=0
    resolve_release "$META" || rc=$?
    if [ "$rc" = 5 ]; then
        echo "install.sh: 换一个 --version，或者不带这个参数用最新的发布" >&2
        exit 1
    fi
    if [ "$rc" = 3 ]; then
        echo "install.sh: $REPO 还没有发过 release，没有二进制可下。" >&2
        echo "           从源码构建（仓库自带编译器，不需要预装 Uya）：" >&2
        echo "             git clone https://github.com/${REPO}" >&2
        echo "             cd uya-agent && make build" >&2
        echo "             ./build/uya-agent --version" >&2
        exit 1
    fi
    if [ "$rc" != 0 ]; then
        echo "install.sh: 连不上 GitHub API（${API}）。" >&2
        echo "           查一下网络 / 代理；也可以直接钉一个版本：--version v0.1.0" >&2
        exit 1
    fi
    echo "install.sh: 下载 $URL"
    if ! fetch_to "$URL" "$TMP"; then
        echo "install.sh: 下载失败：$URL" >&2
        exit 1
    fi
    # 校验和：发布里带了 SHA256SUMS 就必须对上（release.yml 会一并上传）。
    # 没带的话不拦（老发布可能没有），但要说一句 —— 沉默地不校验才是问题。
    if [ -n "$SUMS_URL" ] && fetch_to "$SUMS_URL" "$TMP.sums" 2>/dev/null; then
        want=$(grep -F " ${ASSET}" "$TMP.sums" | head -n 1 | cut -d' ' -f1)
        if [ -n "$want" ]; then
            got=""
            if command -v sha256sum >/dev/null 2>&1; then
                got=$(sha256sum "$TMP" | cut -d' ' -f1)
            elif command -v shasum >/dev/null 2>&1; then
                got=$(shasum -a 256 "$TMP" | cut -d' ' -f1)
            fi
            if [ -z "$got" ]; then
                echo "install.sh: 没有 sha256sum/shasum，跳过校验" >&2
            elif [ "$got" != "$want" ]; then
                echo "install.sh: 校验和不符（期望 $want，实际 $got）—— 不装" >&2
                exit 1
            else
                echo "install.sh: SHA256 校验通过"
            fi
        fi
    else
        echo "install.sh: 这份发布没带 SHA256SUMS，跳过校验" >&2
    fi
fi

chmod 755 "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT INT TERM
rm -f "$META" "$META.all" "$TMP.sums"

echo "install.sh: 装好了 → $TARGET"
# 自检：先问版本（一行、不要 key、不联网、不依赖 $HOME），再确认它能真画出一屏。
# 用 `--tui-demo` 而不是 `--selftest`：前者不联网、不要 key、**不依赖当前目录**，
# 几毫秒就能证明「这个二进制在这台机器上真的能跑出界面」（静态链接的好处就在这里 ——
# 不会因为目标机的 glibc 太老而在这一步才炸）。
# `--selftest` 是**在仓库根**跑的端到端套件（它要 testdata/ 的夹具与 build/ 下的
# 工作区，换到空目录会红几条），所以不适合当安装自检。
installed=$("$TARGET" --version 2>/dev/null || true)
if [ -n "$installed" ]; then
    echo "install.sh: 自检通过（$installed）"
else
    echo "install.sh: 自检没通过 —— 先跑一次 $TARGET --version 看看" >&2
    exit 1
fi
if ! "$TARGET" --tui-demo >/dev/null 2>&1; then
    echo "install.sh: 界面自检没通过 —— 先跑一次 $TARGET --tui-demo 看看" >&2
    exit 1
fi
case ":${PATH}:" in
    *":${DIR}:"*) ;;
    *) echo "install.sh: 注意 $DIR 不在 PATH 里，自己加一下或直接用绝对路径" ;;
esac
