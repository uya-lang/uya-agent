#!/bin/sh
# drama_plugin/p13_selftest.sh — P13 第一段（规模与产能的第一次测算）
#
# 用 mock Provider 连跑 N 集，量三件事（默认 N=10）：
#   1. 每集"生成 + 批准"的墙钟耗时（控制面开销，不含模型与 GPU）；
#   2. 审计在 N 集规模下的耗时（闭环检查不能随集数爆炸）；
#   3. 状态体积（canon.json 大小），看百集会不会撑爆缓冲。
# 可用 EPISODES=100 做百集控制面压力；它不替代完整视频 M4 验收。
#
# 这不是产能承诺：真实产能取决于模型与 GPU（P0_FINDINGS §1.4 有实测基线）。
# 这里量的是**本插件自身的开销**。
#
# 用法：sh drama_plugin/p13_selftest.sh

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
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/index.uya $HERE/src/series.uya $HERE/src/ops.uya \
$HERE/src/media_ops.uya \
$HERE/src/verify_ops.uya \
$HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"
EPISODES=${EPISODES:-10}
case "$EPISODES" in
    ''|*[!0-9]*) echo "FAIL: EPISODES must be an integer"; exit 1 ;;
esac
[ "$EPISODES" -gt 0 ] || { echo "FAIL: EPISODES must be positive"; exit 1; }

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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"规模测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# ---------- 连跑 N 集，量耗时 ----------
START=$(date +%s%N)
i=1
while [ "$i" -le "$EPISODES" ]; do
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((100 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID","target_seconds":90}}}}
JSON
)" > /dev/null
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((200 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":$i}}}}
JSON
)")
    rev=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('revision', d.get('code','ERR')))")
    if [ "$rev" != "$i" ]; then
        bad "第 $i 集提交失败：$rev"
        break
    fi
    i=$((i + 1))
done
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
PER_MS=$(( ELAPSED_MS / EPISODES ))
ok "$EPISODES 集全部提交，控制面总耗时 ${ELAPSED_MS} ms（每集约 ${PER_MS} ms）"

[ "$PER_MS" -lt 3000 ] && ok "单集提交检查 < 3 s（实测 ${PER_MS} ms）" \
    || bad "单集提交检查超过 3 s：${PER_MS} ms"

# ---------- 审计耗时 ----------
A_START=$(date +%s%N)
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":900,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$PID"}}}}
JSON
)")
A_END=$(date +%s%N)
AUDIT_MS=$(( (A_END - A_START) / 1000000 ))
printf '%s' "$out" | field > "$TMP/audit.json"
python3 - "$TMP/audit.json" "$EPISODES" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


check(d['revision'] == n, '%d 集后 canon revision = %d' % (n, n))
check(d['commits'] == n, '提交记录 %d 条' % n)
check(d['replay_ok'] is True, '%d 条提交重放全部一致' % n)
check(d['ledger']['promises_overdue'] == 0, '没有逾期承诺')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

[ "$AUDIT_MS" -lt 3000 ] && ok "$EPISODES 集审计耗时 ${AUDIT_MS} ms（< 3 s）" \
    || bad "审计太慢：${AUDIT_MS} ms"

# ---------- 状态体积 ----------
CANON_BYTES=$(wc -c < "$DATA/projects/$PID/canon.json")
[ "$CANON_BYTES" -lt 65536 ] \
    && ok "canon.json ${CANON_BYTES} B（小于 64 KB 缓冲）" \
    || bad "canon.json 涨到 ${CANON_BYTES} B，快撑爆缓冲"

# 按当前斜率外推百集
python3 - "$CANON_BYTES" "$EPISODES" <<'PY'
import sys

size = int(sys.argv[1])
n = int(sys.argv[2])
per = size / n
hundred = int(per * 100)
print('PASS: 按当前斜率外推，100 集 canon 约 %d B（每集约 %d B）'
      % (hundred, int(per)))
PY

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P13 第一段（${EPISODES} 集规模测算）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
