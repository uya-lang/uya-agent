#!/bin/sh
# drama_plugin/p5e_selftest.sh — P5 系列层（百集大纲与批准）
#
# 覆盖 DRAMA_TODO §7「系列层规划」的前三条：
#   * series.plan 一次生成完整大纲（这里是 100 集）；
#   * 大纲没批准之前，逐集生成被拒（OUTLINE_NOT_APPROVED）；
#   * 批准后逐集生成恢复正常；重新规划会让批准失效（要重新批）。
#
# 用法：sh drama_plugin/p5e_selftest.sh

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
$HERE/src/series.uya $HERE/src/ops.uya $HERE/src/media_ops.uya $HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"

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
code_of() { printf '%s' "$1" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('code') or 'OK')"; }

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"百集大纲"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PID","bible":{"characters":[{"id":"dad","name":"爸爸"}]},"locks":{"dad":"短寸头"}}}}}
JSON
)" > /dev/null

# ---------- 1. 生成 100 集大纲 ----------
START=$(date +%s%N)
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"series.plan","input":{"project_id":"$PID","total_episodes":100}}}}
JSON
)")
END=$(date +%s%N)
MS=$(( (END - START) / 1000000 ))
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['outline_version'] == 1, d
assert d['total_episodes'] == 100, d
assert d['approved'] is False, d
print('PASS: 一次生成 100 集大纲（v1，未批准）')" || bad "大纲生成失败"
[ "$MS" -lt 3000 ] && ok "100 集大纲生成耗时 ${MS} ms（< 3 s）" \
    || bad "大纲生成太慢：${MS} ms"

# ---------- 2. 大纲内容 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"series.get","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/outline.json"
python3 - "$TMP/outline.json" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
plan = d['plan']
eps = plan['episodes']
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


check(len(eps) == 100, '大纲 100 条')
check([e['episode'] for e in eps] == list(range(1, 101)), '集号连续')
check(eps[0]['pays_off'] == 0, '第 1 集不兑现（没有上一集）')
check(eps[1]['pays_off'] == 1, '第 2 集兑现第 1 集的钩子')
check(all(e['opens_hook'] == e['episode'] for e in eps), '每集开一个新钩子')
check(sum(1 for e in eps if e['comedy_beat']) == 33, '笑点节拍 33 集')
check(eps[0]['lead'] == '爸爸', '主角从 Bible 取（爸爸）')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 3. 未批准 ⇒ 逐集生成被拒 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID"}}}}
JSON
)")
[ "$(code_of "$out")" = "OUTLINE_NOT_APPROVED" ] \
    && ok "大纲没批准时逐集生成被拒（OUTLINE_NOT_APPROVED）" \
    || bad "没批准也能生成（$(code_of "$out")）"

# ---------- 4. 批准后恢复正常 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"outline.approve","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['approved'] is True and d['outline_version'] == 1, d
print('PASS: 大纲批准成功')" || bad "大纲批准失败"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID"}}}}
JSON
)")
[ "$(code_of "$out")" = "OK" ] && ok "批准后逐集生成恢复正常" \
    || bad "批准后仍然生成不了（$(code_of "$out")）"

# ---------- 5. 重新规划会作废旧批准 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"series.plan","input":{"project_id":"$PID","total_episodes":30}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['outline_version'] == 2 and d['approved'] is False, d
print('PASS: 重新规划得到 v2，批准状态被清掉')" || bad "重新规划没作废旧批准"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID"}}}}
JSON
)")
[ "$(code_of "$out")" = "OUTLINE_NOT_APPROVED" ] \
    && ok "改大纲后必须先重新批准" || bad "改大纲后没拦住"

# ---------- 6. 剧本追到批准的大纲 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"call","arguments":{"operation":"outline.approve","input":{"project_id":"$PID"}}}}
JSON
)")
[ "$(code_of "$out")" = "OK" ] && ok "v2 大纲重新批准" || bad "v2 大纲批准失败"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID"}}}}
JSON
)")
SV=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['script_version'])")

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":$SV}}}}
JSON
)")
[ "$(code_of "$out")" = "OK" ] && ok "剧本批准成功" || bad "剧本批准失败"

python3 - "$DATA/projects/$PID/scripts/approved.json" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
assert d['outline_version'] == 2, d
assert d['episode'] == 1, d
assert d['canon_revision'] == 1, d
print('PASS: 剧本记录追到 outline v2 / 第 1 集')
PY
[ $? -eq 0 ] || fails=$((fails + 1))

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P5 系列层（百集大纲与批准）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
