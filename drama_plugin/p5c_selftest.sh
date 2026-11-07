#!/bin/sh
# drama_plugin/p5c_selftest.sh — P5 第三段（上下文组装）
#
# 覆盖 DRAMA_TODO §7「上下文组装」：
#   * 读 Bible 版本号与 Canon 快照；
#   * 带来源 ID（bible:vN / canon:rR）；
#   * 只给未回收的承诺（promise.state == open）；
#   * 最近摘要按预算裁剪，并在 truncated 里说明丢了什么；
#   * 生成剧本时上下文真的进了提示（走 mock 也能看出链路通）。
#
# 用法：sh drama_plugin/p5c_selftest.sh

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
$HERE/src/queue_ops.uya $HERE/src/pipeline_ops.uya $HERE/src/vision_ops.uya \
$HERE/src/server.uya"

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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"上下文测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# ---------- 1. 空项目：来源 ID 齐全 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"context.inspect","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['bible_version'] == 0 and d['canon_revision'] == 0, d
assert d['sources'] == ['bible:v0', 'canon:r0'], d
assert d['characters'] == [] and d['scenes'] == [], d
print('PASS: 空项目的上下文带 bible:v0 / canon:r0 来源')" \
    || bad "空项目上下文不对"

# ---------- 2. 写 Bible 后版本号进上下文 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PID","bible":{"characters":[{"id":"c1"}]},"locks":{"c1":"长发"}}}}}
JSON
)")
code=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d.get('code','OK'))")
[ "$code" = "OK" ] && ok "Bible 写入成功" || bad "Bible 写入失败：$code"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"context.inspect","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['bible_version'] == 1, d
assert d['sources'][0] == 'bible:v1', d
print('PASS: Bible 版本号进上下文（bible:v1）')" || bad "Bible 版本没进上下文"

# ---------- 3. Canon 状态与未回收承诺 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":0,"events":[{"type":"scene.define","scene":"living_room","time_of_day":"day"},{"type":"character.place","character":"dad","scene":"living_room"},{"type":"knowledge.grant","character":"dad","fact":"remote_in_fridge","at_scene":"living_room"},{"type":"prop.define","prop":"remote","scene":"living_room","holder":"dad"},{"type":"promise.open","promise":"p1"},{"type":"promise.open","promise":"p2"},{"type":"promise.close","promise":"p1"}]}}}}
JSON
)")
code=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d.get('code','OK'))")
[ "$code" = "OK" ] && ok "Canon 提交（含承诺开关）成功" || bad "Canon 提交失败：$code"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"context.inspect","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['canon_revision'] == 1, d
names=[c['name'] for c in d['characters']]
assert 'dad' in names, d
props={p['name']: p for p in d['props']}
assert props['remote']['holder'] == 'dad', d
open_ids=[p['id'] for p in d['promises']]
assert open_ids == ['p2'], open_ids
print('PASS: 上下文里有角色/道具状态，承诺只给未回收的（p2）')" \
    || bad "Canon 状态没正确进上下文"

# ---------- 4. 摘要：批准后出现 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID","target_seconds":90}}}}
JSON
)")
code=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d.get('code','OK'))")
[ "$code" = "OK" ] && ok "带上下文生成剧本成功" || bad "生成失败：$code"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
code=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d.get('code','OK'))")
[ "$code" = "OK" ] && ok "批准成功" || bad "批准失败：$code"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"context.inspect","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
s=d['recent_summaries']
assert len(s) == 1, d
assert s[0]['title'] and s[0]['hook'], d
assert d['truncated'] == [], d
print('PASS: 批准后摘要进上下文（%s）' % s[0]['title'])" \
    || bad "摘要没进上下文"

# ---------- 5. 预算裁剪 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"call","arguments":{"operation":"context.inspect","input":{"project_id":"$PID","max_bytes":64}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['truncated'] == ['summaries'], d
assert d['recent_summaries'] == [], d
assert d['canon_revision'] == 2, d
print('PASS: 预算不够时先丢摘要并标 truncated')" || bad "裁剪行为不对"

# ---------- 6. 只带最近 5 集摘要 ----------
for i in 2 3 4 5 6 7; do
    printf '%s\n' "{\"episode\":$i,\"title\":\"第 $i 集\",\"hook\":\"h$i\"}" \
        >> "$DATA/projects/$PID/summaries.jsonl"
done
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"call","arguments":{"operation":"context.inspect","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
s=d['recent_summaries']
assert len(s) == 5, d
assert [x['episode'] for x in s] == [3, 4, 5, 6, 7], d
print('PASS: 摘要窗口只保留最近 5 集（%s）' % [x['episode'] for x in s])" \
    || bad "摘要窗口不对"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P5 第三段（上下文组装）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
