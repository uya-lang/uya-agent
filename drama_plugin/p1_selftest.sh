#!/bin/sh
# drama_plugin/p1_selftest.sh
#
# P1 骨架验收：能构建、CLI 三模式可用、stdio 协议行为与 P0 原型一致。
# 判据全部可判定（字符串/退出码/JSON 结构），失败即 exit 1。
#
# 用法：sh drama_plugin/p1_selftest.sh

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
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/index.uya $HERE/src/ops.uya \
$HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# ---------- 0. 构建 ----------
if ! "$UYA" build $SRC -o "$TMP/drama" > "$TMP/build.log" 2>&1; then
    echo "FAIL: 构建失败"
    tail -10 "$TMP/build.log"
    exit 1
fi
ok "构建通过（6 个源文件 → 单可执行）"
APP="$TMP/drama"

# ---------- 1. version ----------
out=$("$APP" version)
if [ "$out" = "drama 0.1.0" ]; then
    ok "version：$out"
else
    bad "version 输出不对：$out"
fi

# ---------- 2. health ----------
out=$("$APP" health --data-dir /tmp/drama-x)
if echo "$out" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["ok"] is True
assert d["name"] == "drama"
assert d["protocol"] == "2024-11-05"
assert d["data_dir"] == "/tmp/drama-x", d["data_dir"]
'; then
    ok "health：单行 JSON，字段与 --data-dir 一致"
else
    bad "health 输出不对：$out"
fi

# ---------- 3. worker 骨架 ----------
out=$("$APP" worker run --data-dir /tmp/drama-y)
case "$out" in
    *tasks_seen*) ok "worker：扫任务并回计数（没有任务时 0/0/0）" ;;
    *) bad "worker 输出不对：$out" ;;
esac

# ---------- 4. 未知命令：退出码 2 ----------
set +e
"$APP" bogus > "$TMP/bogus.out" 2> "$TMP/bogus.err"
rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q 'unknown command' "$TMP/bogus.err"; then
    ok "未知命令：退出码 2，诊断走 stderr"
else
    bad "未知命令：rc=$rc（应为 2）"
fi

# ---------- 5. stdio 协议 ----------
cat > "$TMP/in.jsonl" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"llm.ping","input":{},"request_id":"req-1"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"describe","arguments":{"operation":"nope.op"}}}
{"jsonrpc":"2.0","id":6,"method":"resources/list"}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"中文项目"},"request_id":"中文 id"}}}
EOF
python3 - "$TMP/in.jsonl" <<'PY'
import json, sys
big = 'x' * (1024 * 1024 + 16)
with open(sys.argv[1], 'a') as f:
    f.write(json.dumps({"jsonrpc": "2.0", "id": 8, "method": "tools/list",
                        "params": {"pad": big}}) + "\n")
    f.write('{"jsonrpc":"2.0","id":9,"method":"tools/list"}' + "\n")
PY

timeout 120 "$APP" mcp serve --data-dir "$TMP/data" \
    < "$TMP/in.jsonl" > "$TMP/out.jsonl" 2> "$TMP/err.txt"
rc=$?
if [ "$rc" -eq 0 ]; then ok "mcp serve：EOF 后退出码 0"; else bad "mcp serve：rc=$rc"; fi

python3 - "$TMP/out.jsonl" "$TMP/err.txt" <<'PY'
import json, sys

raw = open(sys.argv[1], 'rb').read()
err = open(sys.argv[2], 'rb').read()
fails = []

lines = raw.split(b'\n')
if lines and lines[-1] == b'':
    lines = lines[:-1]
resps = {}
for i, line in enumerate(lines, 1):
    if not line:
        fails.append(f'第 {i} 行是空帧')
        continue
    if len(line) > 1048576:
        fails.append(f'第 {i} 行超过 1 MiB')
    try:
        obj = json.loads(line)
    except Exception as e:
        fails.append(f'第 {i} 行不是合法 JSON：{e}')
        continue
    if obj.get('id') is not None:
        resps[obj['id']] = obj

# 10 条请求：1 条通知不回、1 条超限丢弃 ⇒ 8 条响应
if len(lines) != 8:
    fails.append(f'响应 {len(lines)} 条，应为 8')
if resps.get(1, {}).get('result', {}).get('protocolVersion') != '2024-11-05':
    fails.append('initialize 没回 2024-11-05')
names = [t.get('name') for t in resps.get(2, {}).get('result', {}).get('tools', [])]
if names != ['list', 'describe', 'call']:
    fails.append(f'tools/list={names}')

def text(rid):
    r = resps.get(rid, {}).get('result')
    if not r:
        return None, None
    return r['content'][0]['text'], r.get('isError')

for rid in (3, 4, 5, 7):
    t, e = text(rid)
    if t is None:
        fails.append(f'id={rid} 缺 result')
        continue
    if e is not False:
        fails.append(f'id={rid} isError={e}')
    try:
        json.loads(t)
    except Exception as ex:
        fails.append(f'id={rid} 的 text 不是 JSON：{ex}')

t, _ = text(4)
d = json.loads(t)['data'] if t else {}
if 'provider' not in json.dumps(d):
    fails.append('call 没返回 provider')
if t and 'input_hash' not in json.loads(t):
    fails.append('call 没返回 input_hash')
t, _ = text(5)
if t and json.loads(t)['error']['code'] != 'OPERATION_NOT_FOUND':
    fails.append('describe 未知操作没返回 OPERATION_NOT_FOUND')
t, _ = text(7)
if t and '中文 id' not in t:
    fails.append('非 ASCII request_id 丢了')
if resps.get(6, {}).get('error', {}).get('code') != -32601:
    fails.append('未知方法没回 -32601')
if 8 in resps:
    fails.append('超 1 MiB 的请求被响应了（应丢弃）')
if 9 not in resps:
    fails.append('超限行之后服务端不再响应')
if err.strip():
    fails.append(f'stderr 不干净：{err[:120]!r}')

if fails:
    print('FAIL:')
    for f in fails:
        print('  -', f)
    sys.exit(1)
print('PASS: 协议行为（8 响应 / 3 工具 / isError 语义 / -32601 / 超限丢弃 / 非 ASCII）')
PY

# ---------- 6. 宿主真的能连上（有宿主二进制才跑） ----------
HOST_BIN="$ROOT/build/uya-agent"
if [ ! -x "$HOST_BIN" ]; then
    # worktree 里没有 build/，用共享 checkout 的那份
    SHARED=$(git -C "$ROOT" rev-parse --path-format=absolute \
        --git-common-dir 2>/dev/null | sed 's#/.git$##' || true)
    if [ -n "$SHARED" ] && [ -x "$SHARED/build/uya-agent" ]; then
        HOST_BIN="$SHARED/build/uya-agent"
    fi
fi
if [ -x "$HOST_BIN" ]; then
    out=$("$HOST_BIN" --list-plugins --mcp-server "drama=$APP mcp serve" 2>&1 || true)
    if echo "$out" | grep -q 'drama: 3 tool(s)'; then
        ok "宿主连接：uya-agent 认出 3 个工具"
    else
        bad "宿主连接：没认出 3 个工具（$out）"
    fi
else
    echo "SKIP: 没有 $HOST_BIN，跳过宿主连接测试"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P1 骨架（构建 / CLI 三模式 / stdio 协议）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
