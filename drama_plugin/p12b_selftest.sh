#!/bin/sh
# drama_plugin/p12b_selftest.sh — P12 第二段：反例库六条（DESIGN §13.5）
# 另补两条同类：抹掉知识来源、改动冻结文本（各断言具体错误码）
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
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/index.uya $HERE/src/series.uya $HERE/src/ops.uya \
$HERE/src/media_ops.uya \
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

# 抹掉知识来源（少写 at_scene）：同样按 KNOWLEDGE_LEAK 拒
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P2","base_revision":1,"events":[{"type":"knowledge.grant","character":"dad","fact":"kitchen_secret"}]}}}}
JSON
)")
[ "$(code_of "$out")" = "KNOWLEDGE_LEAK" ] \
    && ok "反例 2b：抹掉知识来源 ⇒ KNOWLEDGE_LEAK" \
    || bad "反例 2b 没报 KNOWLEDGE_LEAK（$(code_of "$out")）"

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

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.batch","input":{"project_id":"$P4","episodes":"e1"}}}}
JSON
)")
[ "$(code_of "$out")" = "AUDIT_FAILED" ] \
    && ok "审计不绿时批量推进被拒（AUDIT_FAILED）" \
    || bad "红审计还能批量推进（$(code_of "$out")）"

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

# ---------- 6.5 错误定位（对象 ID） ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":70,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P1","base_revision":1,"events":[{"type":"prop.move","prop":"ghost_prop","to_scene":"living_room"}]}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['code'] == 'PROP_UNKNOWN', d
assert d.get('object') == 'ghost_prop', d
print('PASS: 事件错误带对象定位（object=ghost_prop）')" \
    || bad "事件错误没带对象定位"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":71,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$P1"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'violations' in d, d
for v in d['violations']:
    assert 'object' in v or v['code'] != 'PROP_IN_UNKNOWN_SCENE', v
print('PASS: 审计违规结构里带 object 字段（%d 条违规）' % len(d['violations']))" \
    || bad "审计违规没带对象字段"

# 显式允许后可以改（豁免通道）
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$P6","bible":{"characters":[{"id":"dad"}]},"locks":{"dad":"长发，深灰夹克","_allow_drift":true}}}}}
JSON
)")
[ "$(code_of "$out")" = "OK" ] && ok "外观漂移有显式豁免通道（allow_drift）" \
    || bad "豁免通道不通（$(code_of "$out")）"

# ---------- 7. 世界规则被推翻 ----------
P7=$(new_project "反例-规则被推翻")
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P7","base_revision":0,"events":[{"type":"rule.define","rule":"r1","text":"冰箱门关上以后没人能打开"}]}}}}
JSON
)" > /dev/null
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P7","base_revision":1,"events":[{"type":"rule.define","rule":"r1","text":"冰箱门随时能打开"}]}}}}
JSON
)")
[ "$(code_of "$out")" = "RULE_VIOLATION" ] \
    && ok "反例 7：世界规则被推翻 ⇒ RULE_VIOLATION" \
    || bad "反例 7 没报 RULE_VIOLATION（$(code_of "$out")）"

# 同一条规则重复定义（文本一样）是幂等的
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":62,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P7","base_revision":1,"events":[{"type":"rule.define","rule":"r1","text":"冰箱门关上以后没人能打开"}]}}}}
JSON
)")
[ "$(code_of "$out")" = "OK" ] && ok "同一规则重复定义是幂等的" \
    || bad "重复定义被误拒（$(code_of "$out")）"

# ---------- 8. 承诺回收率 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":63,"method":"tools/call","params":{"name":"call","arguments":{"operation":"promise.report","input":{"project_id":"$P4"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['open'] >= 1, d
assert d['overdue'] >= 1, d
assert 0 <= d['collected_permille'] <= 1000, d
print('PASS: promise.report 给出回收率（open=%d closed=%d overdue=%d %.1f%%）'
      % (d['open'], d['closed'], d['overdue'],
         d['collected_permille'] / 10.0))" || bad "promise.report 不对"

# 显式延期（原因 + 新 due_ep）后不再算逾期
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$P4","base_revision":4,"events":[{"type":"promise.waive","promise":"p1","reason":"留到下一集揭","due_ep":5}]}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['revision'] == 5, d
print('PASS: promise.waive 记下原因与新 due_ep（revision 5）')" \
    || bad "promise.waive 没提交"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$P4"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
codes={v['code'] for v in d['violations']}
assert 'PROMISE_OVERDUE' not in codes, d
print('PASS: 延期后的承诺不再算逾期')" || bad "延期没有生效"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.inspect","input":{"project_id":"$P4"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
p1=[p for p in d['promises'] if p['id'] == 'p1'][0]
assert p1['waived'] is True, p1
assert p1['due_ep'] == 5, p1
assert p1['reason'] == '留到下一集揭', p1
print('PASS: 承诺状态里能看到 waived/due_ep/reason')" || bad "承诺状态没落盘"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"call","arguments":{"operation":"promise.report","input":{"project_id":"$P4"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['overdue'] == 0, d
print('PASS: 延期后 promise.report 的 overdue 归零')" || bad "延期后回收账不对"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P12 第二段（反例库六条）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
