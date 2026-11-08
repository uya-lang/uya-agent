#!/bin/sh
# drama_plugin/proto/selftest.sh
#
# P0 B1/B2 的验收脚本：拿一段固定 transcript 喂给 mcp_stdio.ush，
# 对 stdout / stderr / 退出码逐条断言。任何一条失败即 exit 1。
#
# 用法：sh drama_plugin/proto/selftest.sh
# 依赖：uya 编译器（UYA_ROOT 指向本仓 uya/stdlib）、python3（只做 JSON 断言）

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

[ -x "$UYA" ] || { echo "FAIL: 找不到 uya 编译器：$UYA" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 固定 transcript：9 条请求，覆盖 4 个方法 + 业务失败 + 未知方法 + 非 ASCII
cat > "$TMP/in.jsonl" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"describe","arguments":{"operation":"episode.produce"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{},"request_id":"req-1"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"describe","arguments":{"operation":"nope.op"}}}
{"jsonrpc":"2.0","id":7,"method":"resources/list"}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{},"request_id":"中文 id"}}}
EOF

# 追加两条：超 1 MiB 的请求（必须被整行丢弃、且不影响后续请求）+ 收尾请求
python3 - "$TMP/in.jsonl" <<'PYBIG'
import json, sys
big = 'x' * (1024 * 1024 + 16)
with open(sys.argv[1], 'a') as f:
    f.write(json.dumps({"jsonrpc": "2.0", "id": 9, "method": "tools/list",
                        "params": {"pad": big}}) + "\n")
    f.write('{"jsonrpc":"2.0","id":10,"method":"tools/list"}' + "\n")
PYBIG

timeout 180 "$UYA" run "$HERE/mcp_stdio.ush" \
    < "$TMP/in.jsonl" > "$TMP/out.jsonl" 2> "$TMP/err.txt"
STATUS=$?
echo "run: exit=$STATUS stdout=$(wc -l < "$TMP/out.jsonl") 行 stderr=$(wc -c < "$TMP/err.txt") 字节"
[ "$STATUS" -eq 0 ] || { echo "FAIL: EOF 后退出码 $STATUS，应为 0" >&2; exit 1; }

python3 - "$TMP/out.jsonl" "$TMP/err.txt" <<'PY'
import json, sys

out_path, err_path = sys.argv[1], sys.argv[2]
raw = open(out_path, 'rb').read()
err = open(err_path, 'rb').read()
fails = []

# 1. 帧格式：每行一条紧凑 JSON，且单条 <= 1 MiB
lines = raw.split(b'\n')
if lines and lines[-1] == b'':
    lines = lines[:-1]
resps = {}
for i, line in enumerate(lines, 1):
    if not line:
        fails.append(f'第 {i} 行是空行（不该有空帧）')
        continue
    if len(line) > 1048576:
        fails.append(f'第 {i} 行 {len(line)} 字节，超过 1 MiB')
    if b'\n' in line or b'\r' in line:
        fails.append(f'第 {i} 行夹带换行')
    try:
        obj = json.loads(line)
    except Exception as e:
        fails.append(f'第 {i} 行不是合法 JSON：{e}')
        continue
    rid = obj.get('id')
    if rid is not None:
        resps[rid] = obj

# 2. 方法覆盖：11 条请求里 1 条通知 + 1 条超限被丢 → 恰好 9 条响应
if len(lines) != 9:
    fails.append(f'响应条数 {len(lines)}，应为 9（通知不回、超限整行丢）')
if 1 not in resps or 'result' not in resps.get(1, {}):
    fails.append('initialize 没有 result')
else:
    pv = resps[1]['result'].get('protocolVersion')
    if pv != '2024-11-05':
        fails.append(f'protocolVersion = {pv!r}，应为 2024-11-05')

# 3. tools/list：恰好三个工具，raw 名不带点
tools = resps.get(2, {}).get('result', {}).get('tools', [])
names = [t.get('name') for t in tools]
if names != ['list', 'describe', 'call']:
    fails.append(f'tools/list = {names}，应为 list/describe/call')
for t in tools:
    if 'inputSchema' not in t:
        fails.append(f'工具 {t.get("name")} 缺 inputSchema')
if any(isinstance(n, str) and '.' in n for n in names):
    fails.append('工具名里出现了点号')

# 4. 工具结果信封：isError 语义 + 文本本身是 JSON
def text_of(rid):
    r = resps.get(rid, {}).get('result')
    if not r:
        return None, None
    return r.get('content', [{}])[0].get('text'), r.get('isError')

for rid in (3, 4, 5, 6, 8):
    t, is_err = text_of(rid)
    if t is None:
        fails.append(f'id={rid} 没有 result')
        continue
    if is_err is not False:
        fails.append(f'id={rid} isError={is_err}，业务结果必须为 false')
    try:
        json.loads(t)
    except Exception as e:
        fails.append(f'id={rid} 的 text 不是合法 JSON：{e}')

# 5. 业务失败：isError=false 且带错误码（模型要能自己纠正）
t, _ = text_of(6)
if t and json.loads(t).get('error', {}).get('code') != 'OPERATION_NOT_FOUND':
    fails.append('describe 不存在的操作没有返回 OPERATION_NOT_FOUND')

# 6. 真·异步语义：call 返回 queued + task_id
t, _ = text_of(5)
if t:
    d = json.loads(t).get('data', {})
    if d.get('status') != 'queued' or not d.get('task_id'):
        fails.append('call(episode.produce) 没返回 queued + task_id')

# 7. 非 ASCII 往返：中文原样透传（不被转义成 \uXXXX）
t, _ = text_of(8)
if t and '中文 id' not in t:
    fails.append('非 ASCII request_id 在返回里丢了')

# 8. 未知方法：-32601（宿主据此放行）
r7 = resps.get(7, {})
code = r7.get('error', {}).get('code')
if code != -32601:
    fails.append(f'未知方法返回 code={code!r}，应为 -32601')

# 8b. 超限行被丢弃，且服务端仍活着（id=10 有回）
if 9 in resps:
    fails.append('超过 1 MiB 的请求居然被响应了（应整行丢弃）')
if 10 not in resps:
    fails.append('超限行之后服务端不再响应（丢弃后必须继续服务）')

# 9. stderr 必须干净：协议跑通时不许有日志/警告混进来
if err.strip():
    fails.append(f'stderr 非空（{len(err)} 字节）：{err[:200]!r}')

if fails:
    print('FAIL:')
    for f in fails:
        print('  -', f)
    sys.exit(1)
print('PASS: B1 闭环（4 方法 + 3 工具） / B2 帧格式（单行紧凑、≤1 MiB、stderr 干净）')
PY
