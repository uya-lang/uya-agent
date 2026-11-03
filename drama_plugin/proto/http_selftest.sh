#!/bin/sh
# drama_plugin/proto/http_selftest.sh
#
# P0 B5（前半）的验收脚本：Uya 写 HTTP 客户端 —— 建连、请求、响应、状态行、
# 404、连接拒绝、以及「对端不回包时按预算放弃」。
#
# TLS 与分块/SSE 不在本脚本范围（见 P0_FINDINGS §4）。
#
# 用法：sh drama_plugin/proto/http_selftest.sh

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

TMP=$(mktemp -d)
PIDS=""
cleanup() {
    for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
    rm -rf "$TMP"
}
trap cleanup EXIT

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

client() {  # client <命令文本>
    printf '%s\nq\n' "$1" | timeout 120 "$UYA" run "$HERE/http_client.ush"
}

# ---------- 起一个正常 HTTP 服务（随机高位端口） ----------
PORT=$((20000 + $$ % 20000))
printf 'hello-drama' > "$TMP/hello.txt"
( cd "$TMP" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
PIDS="$PIDS $!"

# 起一个「接了连接但永不回包」的黑洞服务
BLACK=$((PORT + 1))
python3 - "$BLACK" <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(4)
conns = []
end = time.time() + 60
while time.time() < end:
    try:
        s.settimeout(1.0)
        c, _ = s.accept()
        conns.append(c)   # 收下就不管：不回包
    except Exception:
        pass
PY
PIDS="$PIDS $!"

# 等两个端口真的在听
i=0
while [ "$i" -lt 100 ]; do
    if python3 - "$PORT" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
    then break; fi
    sleep 0.1
    i=$((i + 1))
done

# ---------- 1. 正常 GET ----------
out=$(client "get $PORT /hello.txt")
echo "  get 200 -> $(echo "$out" | tr '\n' ' ')"
if echo "$out" | grep -q '^STATUS 200$'; then
    ok "正常 GET：状态行解析出 200"
else
    bad "正常 GET：状态行不对（$out）"
fi
if echo "$out" | grep -q '^BODY 11$'; then
    ok "正常 GET：正文 11 字节（hello-drama）"
else
    bad "正常 GET：正文长度不对（$out）"
fi
if echo "$out" | grep -q '^HEADERS [1-9][0-9]*$'; then
    ok "正常 GET：header 段边界（\\r\\n\\r\\n）找到了"
else
    bad "正常 GET：没找到 header 边界（$out）"
fi

# ---------- 2. 404 ----------
out=$(client "get $PORT /no-such-file.txt")
echo "  get 404 -> $(echo "$out" | tr '\n' ' ')"
if echo "$out" | grep -q '^STATUS 404$'; then
    ok "404：状态码如实返回（不是抛异常）"
else
    bad "404：状态码不对（$out）"
fi

# ---------- 3. 连接拒绝 ----------
out=$(client "get $((PORT + 5000)) /x")
echo "  refused -> $(echo "$out" | tr '\n' ' ')"
if echo "$out" | grep -q '^ERR connect$'; then
    ok "连接被拒：明确失败，不挂死"
else
    bad "连接被拒：输出不对（$out）"
fi

# ---------- 4. 对端不回包：按预算放弃 ----------
start=$(date +%s)
out=$(client "get $BLACK /x")
end=$(date +%s)
echo "  blackhole -> $(echo "$out" | tr '\n' ' ') after $((end - start))s"
if echo "$out" | grep -q '^TIMEOUT$'; then
    ok "黑洞端口：按预算放弃（$((end - start)) s）"
else
    bad "黑洞端口：没有超时，输出（$out）"
fi
# 用客户端自己报的 ELAPSED 判定（shell 的墙钟含 uya 编译时间，不可信）
budget=$(echo "$out" | sed -n 's/^ELAPSED //p')
if [ -n "$budget" ] && [ "$budget" -ge 2500 ] && [ "$budget" -le 5000 ]; then
    ok "超时预算生效：客户端自报 ${budget} ms（预算 3000 ms）"
else
    bad "超时预算不对：客户端自报 ${budget:-无} ms（预算 3000 ms）"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: B5（HTTP GET / 状态行 / header 边界 / 404 / 拒绝 / 超时）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
