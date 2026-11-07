#!/bin/sh
# drama_plugin/p13b_selftest.sh — P13 第三段（派生索引与全量重建）
#
# 覆盖 DRAMA_TODO §15「索引与分片」的前两条：
#   * 派生索引 index/episodes.jsonl（一行一集），字段与 episode.get 一致；
#   * **可从真相全量重建**：删掉索引后重建，内容与之前逐字节一致；
#   * 重建耗时与集数线性、10 集规模下 < 200 ms。
#
# 用法：sh drama_plugin/p13b_selftest.sh

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
$HERE/src/verify_ops.uya $HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"
EPISODES=10

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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"索引测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

i=1
while [ "$i" -le "$EPISODES" ]; do
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((100 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID"}}}}
JSON
)" > /dev/null
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((200 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":$i}}}}
JSON
)" > /dev/null
    i=$((i + 1))
done
ok "$EPISODES 集提交完成"

# ---------- 1. 重建索引 ----------
START=$(date +%s%N)
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":300,"method":"tools/call","params":{"name":"call","arguments":{"operation":"index.rebuild","input":{"project_id":"$PID"}}}}
JSON
)")
END=$(date +%s%N)
MS=$(( (END - START) / 1000000 ))
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['episodes'] == $EPISODES, d
print('PASS: 索引重建出 %d 集' % d['episodes'])" || bad "索引重建失败"
[ "$MS" -lt 200 ] && ok "10 集重建耗时 ${MS} ms（< 200 ms）" \
    || bad "重建太慢：${MS} ms"

IDX="$DATA/projects/$PID/index/episodes.jsonl"
[ -f "$IDX" ] && ok "索引文件落盘" || bad "索引文件没落盘"

# ---------- 2. 内容与 episode.get 一致 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":301,"method":"tools/call","params":{"name":"call","arguments":{"operation":"index.list","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/index.json"
python3 - "$TMP/index.json" "$EPISODES" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
eps = d['episodes']
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


check(len(eps) == n, '索引里 %d 集' % n)
check([e['revision'] for e in eps] == list(range(1, n + 1)),
      '集号连续')
check(all(e['script_version'] == e['revision'] for e in eps),
      '剧本版本与集号对齐')
check(all(e['board_version'] == 0 for e in eps),
      '这轮没建分镜，board_version 都是 0')
check(all('renders' in e and 'gpu_ms' in e for e in eps),
      '索引里带成本字段')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 3. 删掉索引 → 重建结果逐字节一致 ----------
cp "$IDX" "$TMP/index.before"
rm -f "$IDX"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":302,"method":"tools/call","params":{"name":"call","arguments":{"operation":"index.list","input":{"project_id":"$PID"}}}}
JSON
)")
if cmp -s "$TMP/index.before" "$IDX"; then
    ok "删掉索引后重建，内容逐字节一致（可从真相重建）"
else
    bad "重建结果与原来不一致"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P13 第三段（派生索引与全量重建）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
