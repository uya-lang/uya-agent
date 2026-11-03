#!/bin/sh
# drama_plugin/p5_selftest.sh — P5 传输层 + LLM Adapter 骨架
#
# 覆盖 DRAMA_TODO §7 的「LLM 传输层」与「LLM Adapter」前几条：
#   * mock Provider：不联网、确定性输出，结构化校验能过；
#   * openai 兼容 Provider：真发 HTTP POST，解析 choices[0].message.content；
#   * 错误分类：非 200 ⇒ UPSTREAM_ERROR、畸形响应 ⇒ BAD_RESPONSE、
#     模型输出不是 JSON ⇒ MODEL_OUTPUT_NOT_JSON、超时 ⇒ TIMEOUT；
#   * 配置来自文件（<root>/llm.json），不依赖环境变量。
#
# 测试用本机 Python 起的 HTTP 服务当"上游"，不联网。
#
# 用法：sh drama_plugin/p5_selftest.sh

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
$HERE/src/story.uya $HERE/src/ops.uya $HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true' EXIT
DATA="$TMP/data"
mkdir -p "$DATA"

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

if ! "$UYA" build $SRC -o "$TMP/drama" > "$TMP/build.log" 2>&1; then
    echo "FAIL: 构建失败"
    tail -10 "$TMP/build.log"
    exit 1
fi
ok "构建通过"

ask() { printf '%s\n' "$1" > "$TMP/q.jsonl"; \
    timeout 120 "$TMP/drama" mcp serve --data-dir "$DATA" \
    < "$TMP/q.jsonl" 2>/dev/null; }

field() { python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
t=json.loads(o['result']['content'][0]['text'])
r=t.get('data',{}).get('result')
print(json.dumps(r if r is not None else t.get('error'), ensure_ascii=False))
"; }

# ---------- 1. 没有 llm.json ⇒ mock ----------
out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.ping","input":{}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('provider') == 'mock', d
print('PASS: 没有配置时默认 mock Provider')" || bad "mock 默认值不对"

out=$(ask '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"写一集"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d.get('content',{})
assert c.get('title') and c.get('scenes'), d
print('PASS: mock 输出的结构化剧本能过校验')" || bad "mock 结构化输出不对"

# ---------- 2. 起一个本机"上游" ----------
cat > "$TMP/srv.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(n)
        if self.path.startswith('/fail500'):
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'boom')
            return
        if self.path.startswith('/bad'):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'not json at all')
            return
        if self.path.startswith('/notjson'):
            body = json.dumps({'choices': [{'message': {
                'content': '抱歉，我不能 JSON'}}]}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith('/slow'):
            import time
            time.sleep(3)
        content = json.dumps({'title': 'upstream-episode',
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
python3 "$TMP/srv.py" "$TMP/port" &
SRV_PID=$!
i=0
while [ ! -s "$TMP/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
PORT=$(cat "$TMP/port" 2>/dev/null || echo '')
if [ -z "$PORT" ]; then
    echo "SKIP: 本机 HTTP 服务没起来"
    exit 0
fi
ok "本机上游服务起在 127.0.0.1:$PORT"

cfg() {
    cat > "$DATA/llm.json" <<JSON
{"provider":"openai","base_url":"127.0.0.1","port":$PORT,"tls":0,
 "path":"$1","model":"test-model","timeout_ms":${2:-2000},"max_retries":0}
JSON
}

code_of() {
    printf '%s' "$1" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('code') or ('OK' if 'content' in d else 'NONE'))"
}

# ---------- 3. 正常路径 ----------
cfg "/v1/chat/completions"
out=$(ask '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"写一集"}}}}')
got=$(code_of "$out")
[ "$got" = "OK" ] && ok "openai 兼容上游：请求发出并解析出内容" \
    || bad "正常路径失败：$got"

printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d.get('content',{})
assert c.get('title') == 'upstream-episode', d
print('PASS: 解析出上游的 title（choices[0].message.content）')" \
    || bad "解析出来的内容不对"

# ---------- 4. 非 200 ----------
cfg "/fail500"
out=$(ask '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"x"}}}}')
got=$(code_of "$out")
[ "$got" = "UPSTREAM_ERROR" ] && ok "上游 500 ⇒ UPSTREAM_ERROR" \
    || bad "500 应回 UPSTREAM_ERROR，实际 $got"

# ---------- 5. 畸形响应 ----------
cfg "/bad"
out=$(ask '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"x"}}}}')
got=$(code_of "$out")
[ "$got" = "BAD_RESPONSE" ] && ok "响应不是 JSON ⇒ BAD_RESPONSE" \
    || bad "畸形响应应回 BAD_RESPONSE，实际 $got"

# ---------- 6. 模型输出不是 JSON ----------
cfg "/notjson"
out=$(ask '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"x"}}}}')
got=$(code_of "$out")
[ "$got" = "MODEL_OUTPUT_NOT_JSON" ] && ok "模型输出不是 JSON ⇒ MODEL_OUTPUT_NOT_JSON" \
    || bad "非 JSON 输出应回 MODEL_OUTPUT_NOT_JSON，实际 $got"

# ---------- 7. 超时 ----------
cfg "/slow" 500
out=$(ask '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.complete","input":{"prompt":"x"}}}}')
got=$(code_of "$out")
case "$got" in
    TIMEOUT|NETWORK_ERROR) ok "上游太慢 ⇒ $got（超时路径生效）" ;;
    *) bad "超时应回 TIMEOUT，实际 $got" ;;
esac

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P5（LLM 传输层 + Adapter 骨架）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
