#!/bin/sh
# drama_plugin/p5f_selftest.sh — 代理与 no_proxy（配置来自 proxy.json）
#
# 覆盖 DRAMA_TODO §7「代理与 no_proxy」：
#   * 代理只能来自 <root>/proxy.json（子进程 env 是白名单，读不到 shell 变量）；
#   * 走代理时请求行必须是 absolute-form：POST http://host:port/path；
#   * no_proxy 命中 ⇒ 直连（这里直连地址是死的，所以必须失败）；
#   * 删掉 proxy.json ⇒ 回到直连；
#   * TLS + 代理 ⇒ PROXY_TLS_UNSUPPORTED（不猜 CONNECT）。
#
# 用法：sh drama_plugin/p5f_selftest.sh

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

SRC="$HERE/src/main.uya $HERE/src/bytes.uya $HERE/src/json_min.uya \
$HERE/src/json_out.uya $HERE/src/registry.uya $HERE/src/schema.uya \
$HERE/src/dispatch.uya $HERE/src/store.uya $HERE/src/project.uya \
$HERE/src/digest.uya $HERE/src/asset.uya $HERE/src/bible.uya \
$HERE/src/canon.uya $HERE/src/httpc.uya $HERE/src/llm.uya \
$HERE/src/story.uya $HERE/src/context.uya $HERE/src/task.uya \
$HERE/src/board.uya $HERE/src/provider.uya $HERE/src/qa.uya \
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/index.uya \
$HERE/src/series.uya $HERE/src/ops.uya $HERE/src/media_ops.uya \
$HERE/src/verify_ops.uya \
$HERE/src/queue_ops.uya $HERE/src/pipeline_ops.uya \
$HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true' EXIT
DATA="$TMP/data"
mkdir -p "$DATA"

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

echo "== 构建 =="
mkdir -p "$TMP/build"
[ -f "$UYA" ] || { echo "FAIL: 找不到 uya: $UYA"; exit 1; }
# shellcheck disable=SC2086
"$UYA" build $SRC -o "$TMP/drama" >"$TMP/build.log" 2>&1 \
    || { echo "FAIL: 构建失败"; tail -20 "$TMP/build.log"; exit 1; }
ok "构建通过"

# ---------- 1. 假代理：记录请求行，回一个合法 chat 响应 ----------
cat > "$TMP/proxy.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(n)
        open(sys.argv[2], 'a').write(self.path + '\n')
        content = json.dumps({'title': 'proxy-episode',
                              'scenes': [{'no': 1, 'action': 'a'}]})
        body = json.dumps({'choices': [{'message': {'content': content}}]})
        raw = body.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


srv = HTTPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/proxy.py" "$TMP/port" "$TMP/seen.txt" &
SRV_PID=$!
i=0
while [ ! -s "$TMP/port" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
PP=$(cat "$TMP/port")
ok "假代理监听 127.0.0.1:$PP"

# 上游地址故意写死端口 1（没人监听）：只有走代理才可能成功
cat > "$DATA/llm.json" <<JSON
{"provider":"openai","base_url":"127.0.0.1","port":1,
 "path":"/v1/chat/completions","model":"m","timeout_ms":2000,
 "max_retries":0}
JSON

ask() {
    printf '%s\n' "$1" | timeout 60 "$TMP/drama" mcp serve --data-dir "$DATA" \
        2>/dev/null | head -1
}
field() {
    python3 -c '
import json, sys
raw = [l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o = json.loads(raw[0])
t = json.loads(o["result"]["content"][0]["text"])
r = t.get("data", {}).get("result")
print(json.dumps(r if r is not None else t.get("error"),
                 ensure_ascii=False))'
}

# ---------- 2. 配好代理 ⇒ 请求走代理 ----------
cat > "$DATA/proxy.json" <<JSON
{"http_proxy":"127.0.0.1:$PP"}
JSON
out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"写一集"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['content']['title'] == 'proxy-episode', d
print('PASS: 配上代理后请求经代理成功（上游 127.0.0.1:1 是死的）')" \
    || bad "代理没被使用"
if grep -qx 'http://127.0.0.1:1/v1/chat/completions' "$TMP/seen.txt"; then
    ok "代理收到的请求行是 absolute-form"
else
    bad "代理收到的请求行不对：$(cat "$TMP/seen.txt")"
fi

# ---------- 3. no_proxy 命中 ⇒ 直连（必须失败） ----------
cat > "$DATA/proxy.json" <<JSON
{"http_proxy":"127.0.0.1:$PP","no_proxy":"127.0.0.1"}
JSON
out=$(ask '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"写一集"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'NETWORK_ERROR', d
print('PASS: no_proxy 命中后直连（上游是死的 ⇒ NETWORK_ERROR）')" \
    || bad "no_proxy 没生效"

# ---------- 4. 没有 proxy.json ⇒ 直连 ----------
rm -f "$DATA/proxy.json"
out=$(ask '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"写一集"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'NETWORK_ERROR', d
print('PASS: 没有 proxy.json 时走直连')" \
    || bad "缺 proxy.json 时行为不对"

# ---------- 5. TLS + 代理 ⇒ PROXY_TLS_UNSUPPORTED ----------
cat > "$DATA/llm.json" <<JSON
{"provider":"openai","base_url":"127.0.0.1","port":1,
 "path":"/v1/chat/completions","model":"m","timeout_ms":2000,
 "max_retries":0,"tls":1}
JSON
cat > "$DATA/proxy.json" <<JSON
{"http_proxy":"127.0.0.1:$PP"}
JSON
out=$(ask '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"写一集"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'PROXY_TLS_UNSUPPORTED', d
print('PASS: TLS 走代理直接拒（PROXY_TLS_UNSUPPORTED）')" \
    || bad "TLS+代理 没被拒"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P5 代理段（proxy.json / absolute-form / no_proxy）"
    exit 0
fi
echo "FAIL: P5 代理段有 $fails 项"
exit 1
