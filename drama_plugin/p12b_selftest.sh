#!/bin/sh
# drama_plugin/p12b_selftest.sh — P12 第二段：反例库六条（DESIGN §13.5）
#
# 每条 fixture = 一个小项目 + 一个期望错误码；检查器不报对应码就算失败。
#   1 道具瞬移            PROP_TELEPORT
#   2 知识越界            KNOWLEDGE_LEAK
#   3 场景穿帮            SCENE_DRIFT
#   4 伏笔落空            PROMISE_OVERDUE
#   5 时间悖论            TIMELINE_CONFLICT
#   6 外观漂移            CHARACTER_DRIFT
#
# 用法：sh drama_plugin/p12b_selftest.sh

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
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/ops.uya \
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
code_of() { printf '%s' "$1" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('code') or 'OK')"; }

new_project() {
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"$1"}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])"
}

# 世界初始化：客厅/厨房 + 爸爸 + 遥控器
init_world() {
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$1","base_revision":0,"events":[{"type":"scene.define","scene":"living_room","time_of_day":"day"},{"type":"scene.define","scene":"kitchen","time_of_day":"day"},{"type":"character.place","character":"dad","scene":"living_room"},{"type":"prop.define","prop":"remote","scene":"living_room","holder":"dad"}]}}}}
JSON
)" > /dev/null
}

# ---------- 1. 道具瞬移 ----------
P1=$(new_project "反例-道具瞬移")
init_world "$P1"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P1","base_revision":1,"events":[{"type":"prop.move","prop":"remote","at_scene":"kitchen","to_scene":"living_room"}]}}}}
JSON
)")
[ "$(code_of "$out")" = "PROP_TELEPORT" ] && ok "反例 1：道具瞬移 ⇒ PROP_TELEPORT" \
    || bad "反例 1 没报 PROP_TELEPORT（$(code_of "$out")）"

# ---------- 2. 知识越界 ----------
P2=$(new_project "反例-知识越界")
init_world "$P2"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P2","base_revision":1,"events":[{"type":"knowledge.grant","character":"dad","fact":"kitchen_secret","at_scene":"kitchen"}]}}}}
JSON
)")
[ "$(code_of "$out")" = "KNOWLEDGE_LEAK" ] && ok "反例 2：知识越界 ⇒ KNOWLEDGE_LEAK" \
    || bad "反例 2 没报 KNOWLEDGE_LEAK（$(code_of "$out")）"

# ---------- 3. 场景穿帮 ----------
P3=$(new_project "反例-场景穿帮")
init_world "$P3"
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P3","base_revision":1,"events":[{"type":"scene.set","scene":"living_room","field":"variant","value":"sofa_A"}]}}}}
JSON
)" > /dev/null
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P3","base_revision":2,"events":[{"type":"scene.define","scene":"living_room","variant":"sofa_B"}]}}}}
JSON
)")
[ "$(code_of "$out")" = "SCENE_DRIFT" ] && ok "反例 3：场景换陈设 ⇒ SCENE_DRIFT" \
    || bad "反例 3 没报 SCENE_DRIFT（$(code_of "$out")）"

# ---------- 4. 伏笔落空 ----------
P4=$(new_project "反例-伏笔落空")
init_world "$P4"
i=1
while [ "$i" -le 3 ]; do
    base=$((i))
    extra=''
    if [ "$i" = "1" ]; then
        extra=',{"type":"promise.open","promise":"p1"}'
    fi
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((20 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P4","base_revision":$base,"events":[{"type":"timeline.advance","minutes":10}$extra]}}}}
JSON
)" > /dev/null
    i=$((i + 1))
done
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$P4"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
codes={v['code'] for v in d['violations']}
assert 'PROMISE_OVERDUE' in codes, d
print('PASS: 反例 4：伏笔落空 ⇒ PROMISE_OVERDUE')" \
    || bad "反例 4 没报 PROMISE_OVERDUE"

# ---------- 5. 时间悖论 ----------
P5=$(new_project "反例-时间悖论")
init_world "$P5"
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P5","base_revision":1,"events":[{"type":"scene.set","scene":"living_room","field":"time_of_day","value":"night"}]}}}}
JSON
)" > /dev/null
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P5","base_revision":2,"events":[{"type":"scene.set","scene":"living_room","field":"time_of_day","value":"night"}]}}}}
JSON
)")
[ "$(code_of "$out")" = "TIMELINE_CONFLICT" ] \
    && ok "反例 5：同一晚入夜两次 ⇒ TIMELINE_CONFLICT" \
    || bad "反例 5 没报 TIMELINE_CONFLICT（$(code_of "$out")）"

# ---------- 6. 外观漂移 ----------
P6=$(new_project "反例-外观漂移")
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$P6","bible":{"characters":[{"id":"dad"}]},"locks":{"dad":"短寸头，深灰夹克"}}}}}
JSON
)" > /dev/null
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$P6","bible":{"characters":[{"id":"dad"}]},"locks":{"dad":"长发，深灰夹克"}}}}}
JSON
)")
[ "$(code_of "$out")" = "CHARACTER_DRIFT" ] \
    && ok "反例 6：冻结文本被改 ⇒ CHARACTER_DRIFT" \
    || bad "反例 6 没报 CHARACTER_DRIFT（$(code_of "$out")）"

# 显式允许后可以改（豁免通道）
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$P6","bible":{"characters":[{"id":"dad"}]},"locks":{"dad":"长发，深灰夹克","_allow_drift":true}}}}}
JSON
)")
[ "$(code_of "$out")" = "OK" ] && ok "外观漂移有显式豁免通道（allow_drift）" \
    || bad "豁免通道不通（$(code_of "$out")）"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P12 第二段（反例库六条）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
