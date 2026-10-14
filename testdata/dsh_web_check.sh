#!/bin/sh
# testdata/dsh_web_check.sh — 产品侧 `--dsh-web` 的端到端验收（一条命令自证）。
#
# 验的是**产品二进制**（不是 python 探针）：它起 `--dsh-web`，再用 headless chromium
# + CDP 驱动到「DSH 的界面里渲染出本仓会话的消息」，断言两条只可能来自本仓日志的文本。
#
# 本机没装 DSH 或没有 chromium 时**跳过**（退出 0）—— 别的机器上也该能跑。
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/build/uya-agent
[ -x "$bin" ] || { echo "dsh-web-check: 先 make build"; exit 1; }

log=$(find "$root/build" -name session.jsonl -size +500c 2>/dev/null | head -1)
if [ -z "$log" ]; then
    echo "dsh-web-check: 跳过 —— 找不到真会话日志（先跑一次 make selftest 生成）"
    exit 0
fi
command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 \
    || { echo "dsh-web-check: 跳过 —— 本机没有 chromium"; exit 0; }
ls "$HOME/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html" >/dev/null 2>&1 \
    || { echo "dsh-web-check: 跳过 —— 本机没装 DSH 的 webui"; exit 0; }

ev=$root/build/dshweb_check_events.ndjson
mkdir -p "$root/build"
UYA_SELFTEST_WIRE_FILE="$log" "$bin" --selftest 2>"$ev" >/dev/null
[ -s "$ev" ] || { echo "dsh-web-check: 失败 —— 适配层没翻出事件"; exit 1; }

port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
UYA_AGENT_DSH_WEB_EVENTS="$ev" "$bin" --no-dsh-config --dsh-web "127.0.0.1:$port" \
    >"$root/build/dshweb_check_host.log" 2>&1 &
host=$!
trap 'kill $host 2>/dev/null || true' EXIT

# 等宿主**真的**开始服务（而不是盲等固定秒数）：`--dsh-web` 起来时要读 14 个 bundle
# 算 rev，机器忙的时候 2 秒不够 —— 而它的症状是「页面空着」，看起来像数据没送到。
i=0
while [ $i -lt 40 ]; do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$port/"; then
        break
    fi
    sleep 0.5
    i=$((i+1))
done
curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$port/" \
    || { echo "dsh-web-check: 失败 —— --dsh-web 没起来（看 build/dshweb_check_host.log）"; exit 1; }

# 从译文里挑第一条用户消息的正文当断言（它只可能来自那份日志）
needle=$(python3 - "$ev" <<'PY'
import json,sys
for line in open(sys.argv[1],encoding='utf-8'):
    line=line.strip()
    if not line.startswith('{'): continue
    e=json.loads(line)
    if e.get('type')=='user/message':
        for b in e['data'].get('content',[]):
            if b.get('type')=='text' and b.get('text'):
                print(b['text']); raise SystemExit
PY
)
[ -n "$needle" ] || { echo "dsh-web-check: 失败 —— 日志里没有可断言的用户消息"; exit 1; }

# 起一个有 CDP 的 headless chromium（**用 localhost**：本机 DevTools 只绑 IPv6 回环）
prof=$(mktemp -d)
cdpport=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
chromium --headless --no-sandbox --disable-gpu --remote-debugging-port="$cdpport" \
    --user-data-dir="$prof" about:blank >/dev/null 2>&1 &
chrome=$!
cleanup() {
    kill $host $chrome 2>/dev/null || true
    wait $chrome 2>/dev/null || true
    rm -rf "$prof" 2>/dev/null || true
}
trap cleanup EXIT
ws=""
i=0
while [ $i -lt 40 ]; do
    sleep 0.5
    ws=$(curl -s --max-time 2 "http://localhost:$cdpport/json/list" 2>/dev/null \
        | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d[0]['webSocketDebuggerUrl'] if d else '')
except Exception:
    print('')" 2>/dev/null || true)
    [ -n "$ws" ] && break
    i=$((i+1))
done
[ -n "$ws" ] || { echo "dsh-web-check: 失败 —— chromium 的 CDP 没起来"; exit 1; }

# `set -e` 下不能让断言直接终止：失败时还要把浏览器控制台捞出来
#（「页面只是空」这类故障的唯一线索都在那儿 —— 本仓在 P80 上两次靠它定位）。
rc=0
WIRE_PROBE_URL="http://127.0.0.1:$port/" node "$root/testdata/wire_probe_drive.mjs" \
    "$ws" "" "$needle" || rc=$?
if [ $rc -ne 0 ]; then
    echo "--- 浏览器控制台 ---"
    WIRE_PROBE_URL="http://127.0.0.1:$port/" node "$root/testdata/wire_probe_console.mjs" "$ws" 2>&1 | head -25 || true
    exit $rc
fi
echo "dsh-web-check: 通过 —— 产品二进制 --dsh-web 把本仓会话渲染进了 DSH 的 webui"
