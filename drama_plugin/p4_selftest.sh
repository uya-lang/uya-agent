#!/bin/sh
# drama_plugin/p4_selftest.sh — P4（Canon 提交 / 不变量 / 锁 / 恢复）
#
# 覆盖 DRAMA_TODO §6：
#   * 验收故事「遥控器由爸爸手中转移到冰箱」，重启后状态准确恢复；
#   * 四轴不变量各一个反例：KNOWLEDGE_LEAK / PROP_TELEPORT /
#     TIMELINE_BACKWARD / ORPHAN_CHANGE，都必须拒绝且不改状态；
#   * base_revision 冲突、事件类型未知、道具不存在；
#   * 单写者锁：活着的持有者 ⇒ LOCKED；死掉的持有者 ⇒ 陈旧锁可恢复；
#   * 崩溃恢复：canon.json 丢了也能从提交记录恢复到唯一正确 revision。
#
# 用法：sh drama_plugin/p4_selftest.sh

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

run() { timeout 120 "$TMP/drama" mcp serve --data-dir "$DATA" "$@"; }

# ---------- 1. 建项目 ----------
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"遥控器故事"}}}}' \
    > "$TMP/a.jsonl"
run < "$TMP/a.jsonl" > "$TMP/a.out" 2> "$TMP/a.err" || true
PID=$(python3 - "$TMP/a.out" <<'PY'
import json
import sys
for line in open(sys.argv[1], 'rb').read().split(b'\n'):
    if not line:
        continue
    o = json.loads(line)
    print(json.loads(o['result']['content'][0]['text'])['data']['result']['project_id'])
    break
PY
)
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

ask() { printf '%s\n' "$1" > "$TMP/q.jsonl"; run < "$TMP/q.jsonl"; }

# ---------- 2. 世界初始化 + 遥控器转移 ----------
INIT=$(cat <<JSON
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":0,"events":[{"type":"scene.define","scene":"living_room","time_of_day":"day"},{"type":"scene.define","scene":"kitchen"},{"type":"character.place","character":"dad","scene":"living_room"},{"type":"prop.define","prop":"remote","scene":"living_room","holder":"dad"}]}}}}
JSON
)
out=$(ask "$INIT" 2>/dev/null)
code=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
print(json.loads(o['result']['content'][0]['text']).get('data',{}).get('result',{}).get('revision','ERR'))")
[ "$code" = "1" ] && ok "世界初始化提交到 revision 1" || bad "初始化提交失败：$code"
H1=$(md5sum "$DATA/projects/$PID/commits/1.json" | cut -d' ' -f1)
CID=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
print(json.loads(o['result']['content'][0]['text'])['data']['result'].get('commit_id',''))")
REAL=$(sha256sum "$DATA/projects/$PID/commits/1.json" | cut -d' ' -f1)
[ -n "$CID" ] && [ "$CID" = "$REAL" ] && ok "commit_id 可从提交记录复算（SHA-256）" \
    || bad "commit_id 与记录 hash 不一致：$CID vs $REAL"

MOVE=$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":1,"events":[{"type":"prop.move","prop":"remote","to_scene":"kitchen","to_holder":"fridge"}]}}}}
JSON
)
out=$(ask "$MOVE" 2>/dev/null)
code=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
print(json.loads(o['result']['content'][0]['text']).get('data',{}).get('result',{}).get('revision','ERR'))")
[ "$code" = "2" ] && ok "遥控器由爸爸手中转移到冰箱（revision 2）" || bad "转移提交失败：$code"

# ---------- 3. 重启后状态准确恢复 ----------
INS=$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.inspect","input":{"project_id":"$PID"}}}}
JSON
)
out=$(ask "$INS" 2>/dev/null)
printf '%s' "$out" > "$TMP/ins.json"
python3 - "$TMP/ins.json" "$PID" <<'PY'
import json
import sys

raw = [l for l in open(sys.argv[1]).read().split('\n') if l.strip()]
o = json.loads(raw[0])
st = json.loads(o['result']['content'][0]['text'])['data']['result']
props = {p['name']: p for p in st.get('props', [])}
r = props.get('remote', {})
ok = (st.get('revision') == 2 and r.get('holder') == 'fridge'
      and r.get('scene') == 'kitchen')
print('PASS: 重启后状态准确恢复（remote 在厨房冰箱手里）' if ok
      else 'FAIL: 恢复出来的状态不对：%s' % json.dumps(st, ensure_ascii=False))
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 4. 四轴反例 + 其它拒绝路径 ----------
check_reject() {
    label=$1
    want=$2
    body=$(cat)
    out=$(ask "$body" 2>/dev/null)
    got=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
t=json.loads(o['result']['content'][0]['text'])
print((t.get('error') or {}).get('code','NONE'))")
    if [ "$got" = "$want" ]; then ok "$label ⇒ $want"; else bad "$label 应回 $want，实际 $got"; fi
}

check_reject "角色不在场却获得知识（KNOWLEDGE_LEAK）" KNOWLEDGE_LEAK <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":2,"events":[{"type":"knowledge.grant","character":"dad","fact":"remote_in_fridge","at_scene":"kitchen"}]}}}}
JSON

check_reject "道具无事件被挪动（PROP_TELEPORT）" PROP_TELEPORT <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":2,"events":[{"type":"prop.move","prop":"remote","at_scene":"living_room","to_scene":"kitchen"}]}}}}
JSON

check_reject "时间回退（TIMELINE_BACKWARD）" TIMELINE_BACKWARD <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":2,"events":[{"type":"timeline.advance","minutes":-30}]}}}}
JSON

check_reject "状态变化找不到原因事件（ORPHAN_CHANGE）" ORPHAN_CHANGE <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":2,"events":[]}}}}
JSON

check_reject "base_revision 过期（BASE_REVISION_CONFLICT）" BASE_REVISION_CONFLICT <<JSON
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":1,"events":[{"type":"timeline.advance","minutes":10}]}}}}
JSON

check_reject "未知事件类型（UNKNOWN_OPERATOR）" UNKNOWN_OPERATOR <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":2,"events":[{"type":"world.explode"}]}}}}
JSON

# 拒绝之后状态必须没变
out=$(ask "$INS" 2>/dev/null)
rev=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
print(json.loads(o['result']['content'][0]['text'])['data']['result']['revision'])")
[ "$rev" = "2" ] && ok "所有拒绝都没有改动状态（仍是 revision 2）" \
    || bad "拒绝后 revision 变成 $rev"

# ---------- 5. 锁：活着的持有者 / 陈旧锁 ----------
LOCKDIR="$DATA/projects/$PID/locks"
mkdir -p "$LOCKDIR"
printf '{"pid":%d,"purpose":"canon.commit"}' "$$" > "$LOCKDIR/commit.lock"
check_reject "别的写者持有锁（LOCKED）" LOCKED <<JSON
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":2,"events":[{"type":"timeline.advance","minutes":5}]}}}}
JSON
printf '{"pid":999999,"purpose":"canon.commit"}' > "$LOCKDIR/commit.lock"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":2,"events":[{"type":"timeline.advance","minutes":5}]}}}}
JSON
)" 2>/dev/null)
rev=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
t=json.loads(o['result']['content'][0]['text'])
print(t.get('data',{}).get('result',{}).get('revision','ERR'))")
[ "$rev" = "3" ] && ok "陈旧锁（持有进程已死）可恢复" || bad "陈旧锁没恢复：$rev"

# 锁太老：持有者还活着但 acquired_at 很旧 ⇒ LOCK_STALE（不硬等）
printf '{"pid":%d,"host":"test","acquired_at":%d,"purpose":"canon.commit"}' \
    "$$" "$(( $(date +%s) - 1000 ))" > "$LOCKDIR/commit.lock"
check_reject "锁太老 ⇒ LOCK_STALE" LOCK_STALE <<JSON
{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":3,"events":[{"type":"timeline.advance","minutes":5}]}}}}
JSON

# 锁文件存在但读不出来（这里用目录占位）⇒ LOCK_UNREADABLE
rm -f "$LOCKDIR/commit.lock"
mkdir "$LOCKDIR/commit.lock"
check_reject "锁文件损坏 ⇒ LOCK_UNREADABLE" LOCK_UNREADABLE <<JSON
{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":3,"events":[{"type":"timeline.advance","minutes":5}]}}}}
JSON
rmdir "$LOCKDIR/commit.lock"

# ---------- 6. 崩溃恢复：canon.json 丢了 ----------
rm -f "$DATA/projects/$PID/canon.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.recover","input":{"project_id":"$PID"}}}}
JSON
)" 2>/dev/null)
printf '%s' "$out" > "$TMP/rec.json"
python3 - "$TMP/rec.json" <<'PY'
import json
import sys

raw = [l for l in open(sys.argv[1]).read().split('\n') if l.strip()]
o = json.loads(raw[0])
t = json.loads(o['result']['content'][0]['text'])
r = t.get('data', {}).get('result') or {}
ok = r.get('revision') == 3 and r.get('recovered') is True
print('PASS: 崩溃后从提交记录恢复到 revision 3' if ok
      else 'FAIL: 恢复失败：%s' % json.dumps(t, ensure_ascii=False))
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 6.08 一批事件里有一条不合法 ⇒ 整批不应用 ----------
REV_BEFORE=$(python3 -c "
import json
print(json.load(open('$DATA/projects/$PID/canon.json'))['revision'])")
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":35,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":$REV_BEFORE,"events":[{"type":"scene.define","scene":"hall"},{"type":"prop.move","prop":"不存在","to_scene":"hall"}]}}}}
JSON
)")
REV_AFTER=$(python3 -c "
import json
print(json.load(open('$DATA/projects/$PID/canon.json'))['revision'])")
[ "$REV_BEFORE" = "$REV_AFTER" ] \
    && ok "一批事件有一条不合法 ⇒ 整体回滚到提交前 revision（$REV_AFTER）" \
    || bad "半批事件被应用了：$REV_BEFORE → $REV_AFTER"
grep -q '"hall"' "$DATA/projects/$PID/canon.json" \
    && bad "非法批次里的第一条事件落盘了" || ok "非法批次没有留下任何状态"

# ---------- 6.1 同一批事件重放不会重复应用 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":2,"events":[{"type":"prop.move","prop":"remote","to_scene":"kitchen","to_holder":"fridge"}]}}}}
JSON
)")
printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
t=json.loads(json.loads(raw[0])['result']['content'][0]['text'])
assert t.get('success') is False, t
assert t['error']['code'] == 'BASE_REVISION_CONFLICT', t
print('PASS: 重放已应用的提交 ⇒ BASE_REVISION_CONFLICT（不重复应用）')" \
    || bad "重放提交没有冲突保护"

# ---------- 6.2 状态槽：人物/场景/道具/知识 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.inspect","input":{"project_id":"$PID"}}}}
JSON
)" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
t=json.loads(o['result']['content'][0]['text'])['data']['result']
st=t.get('state',t)
loc={}
for c in st.get('characters',[]):
    loc[c['name']]=c
assert loc['dad']['scene'] == 'living_room', loc['dad']
assert 'knows' in loc['dad'], loc['dad']
props={p['name']:p for p in st.get('props',[])}
assert props['remote']['holder'] == 'fridge', props['remote']
assert props['remote']['scene'] == 'kitchen', props['remote']
scenes={s['name']:s for s in st.get('scenes',[])}
assert scenes['living_room']['time_of_day'] == 'day', scenes['living_room']
print('PASS: 人物位置 / 人物知识槽 / 道具位置 / 场景时段都落盘')" \
    || bad "状态槽不对"

# ---------- 6.5 损坏的 canon.json（缺 revision）也能恢复 ----------
printf '%s' '{"format_version":1}' > "$DATA/projects/$PID/canon.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.recover","input":{"project_id":"$PID"}}}}
JSON
)" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
r=json.loads(o['result']['content'][0]['text']).get('data',{}).get('result',{})
assert r.get('revision') == 3, r
print('PASS: 缺 revision 的 canon.json 被提交记录拉回 revision 3')" \
    || bad "缺 revision 没有故障保护"

printf '%s' 'not json at all' > "$DATA/projects/$PID/canon.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.inspect","input":{"project_id":"$PID"}}}}
JSON
)" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
t=json.loads(o['result']['content'][0]['text'])
assert t.get('success') is False, t
print('PASS: 损坏的 canon.json 不会被当成合法状态（%s）'
      % t['error']['code'])" || bad "损坏文件被当成了合法状态"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.recover","input":{"project_id":"$PID"}}}}
JSON
)" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
o=json.loads(raw[0])
r=json.loads(o['result']['content'][0]['text']).get('data',{}).get('result',{})
assert r.get('revision') == 3, r
print('PASS: 损坏文件可由 canon.recover 修复')" || bad "损坏文件没被修复"

# ---------- 7. 提交目录里没有半个文件 ----------
if ls "$DATA/projects/$PID/commits" | grep -q '\.tmp$'; then
    bad "提交目录里留了 .tmp"
else
    ok "提交目录里没有 .tmp 残留"
fi
commits=$(ls "$DATA/projects/$PID/commits" | grep -c '\.json$' || true)
[ "$commits" = "3" ] && ok "三次提交各留一个不可变记录" \
    || bad "提交记录数量是 $commits（应为 3）"
H2=$(md5sum "$DATA/projects/$PID/commits/1.json" | cut -d' ' -f1)
[ -n "$H1" ] && [ "$H1" = "$H2" ] && ok "后续提交没有改写 1.json（只追加）" \
    || bad "v1.json 被改写了"

# ---------- 6.05 事件唯一 ID ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":3,"events":[{"type":"scene.define","scene":"balcony"},{"type":"character.place","character":"mom","scene":"balcony"}]}}}}
JSON
)")
printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
t=json.loads(json.loads(raw[0])['result']['content'][0]['text'])
r=t['data']['result']
assert r['revision'] == 4, r
assert r['event_ids'] == ['r4#0', 'r4#1'], r
print('PASS: 事件唯一 ID 形如 r<revision>#<序号>（%s）' % r['event_ids'])" \
    || bad "事件 ID 不对"

# ---------- 8. 候选状态差异（canon.diff：预演一遍，不落盘） ----------
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"call\",\"arguments\":{\"operation\":\"canon.diff\",\"input\":{\"project_id\":\"$PID\",\"events\":[{\"type\":\"timeline.advance\",\"minutes\":5}]}}}}" \
    > "$TMP/d1.jsonl"
run < "$TMP/d1.jsonl" > "$TMP/d1.out" 2>/dev/null || true
python3 - "$TMP/d1.out" <<'PY'
import json
import sys

o = json.loads(open(sys.argv[1]).read().strip().split('\n')[0])
t = json.loads(o['result']['content'][0]['text'])
r = t['data']['result']
assert r['ok'] is True, r
assert r['from_revision'] == 4, r
assert r['events'] == 1, r
assert r['delta']['timeline_min'] == 5, r
print('PASS: canon.diff 预演 5 分钟 ⇒ timeline +5 min')
PY
[ $? -eq 0 ] || bad "canon.diff 差异不对"

printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/call\",\"params\":{\"name\":\"call\",\"arguments\":{\"operation\":\"canon.diff\",\"input\":{\"project_id\":\"$PID\",\"events\":[{\"type\":\"no.such.event\"}]}}}}" \
    > "$TMP/d2.jsonl"
run < "$TMP/d2.jsonl" > "$TMP/d2.out" 2>/dev/null || true
python3 - "$TMP/d2.out" <<'PY'
import json
import sys

o = json.loads(open(sys.argv[1]).read().strip().split('\n')[0])
t = json.loads(o['result']['content'][0]['text'])
assert t['error']['code'] == 'UNKNOWN_OPERATOR', t
print('PASS: canon.diff 里非法事件同样被拒（UNKNOWN_OPERATOR）')
PY
[ $? -eq 0 ] || bad "canon.diff 没拦非法事件"

printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"call\",\"arguments\":{\"operation\":\"canon.diff\",\"input\":{\"project_id\":\"$PID\",\"events\":[]}}}}" \
    > "$TMP/d3.jsonl"
run < "$TMP/d3.jsonl" > "$TMP/d3.out" 2>/dev/null || true
python3 - "$TMP/d3.out" <<'PY'
import json
import sys

o = json.loads(open(sys.argv[1]).read().strip().split('\n')[0])
t = json.loads(o['result']['content'][0]['text'])
r = t['data']['result']
assert r['from_revision'] == 4, r
print('PASS: 预演不落盘（revision 仍是 4）')
PY
[ $? -eq 0 ] || bad "canon.diff 动了状态"

# ---------- 9. space 账：场景连通 / 陈设 hash / 时段 ----------
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"call\",\"arguments\":{\"operation\":\"canon.commit\",\"input\":{\"project_id\":\"$PID\",\"base_revision\":4,\"events\":[{\"type\":\"character.place\",\"character\":\"dad\",\"scene\":\"kitchen\"}]}}}}" \
    > "$TMP/s1.jsonl"
run < "$TMP/s1.jsonl" > "$TMP/s1.out" 2>/dev/null || true
python3 - "$TMP/s1.out" <<'PY'
import json
import sys

o = json.loads(open(sys.argv[1]).read().strip().split('\n')[0])
t = json.loads(o['result']['content'][0]['text'])
r = t['data']['result']
assert r['revision'] == 5, r
print('PASS: dad 从客厅走到厨房（revision 5）')
PY
[ $? -eq 0 ] || bad "dad 没走到厨房"

printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"tools/call\",\"params\":{\"name\":\"call\",\"arguments\":{\"operation\":\"space.report\",\"input\":{\"project_id\":\"$PID\"}}}}" \
    > "$TMP/s2.jsonl"
run < "$TMP/s2.jsonl" > "$TMP/s2.out" 2>/dev/null || true
python3 - "$TMP/s2.out" <<'PY'
import json
import sys

o = json.loads(open(sys.argv[1]).read().strip().split('\n')[0])
t = json.loads(o['result']['content'][0]['text'])
r = t['data']['result']
scenes = {s['name']: s for s in r['scenes']}
assert 'living_room' in scenes and 'kitchen' in scenes, r
assert scenes['living_room']['time_of_day'] == 'day', scenes
assert any(s['name'] == 'kitchen'
           for s in r['scenes'] if 'living_room' in s['links']), r
assert any(e['from'] == 'living_room' and e['to'] == 'kitchen'
           or e['from'] == 'kitchen' and e['to'] == 'living_room'
           for e in r['edges']), r
hid = scenes['living_room']['variant_hash']
assert hid == '' or len(hid) == 16, scenes
print('PASS: space.report（场景 %d 个 / 连通边 %d 条）'
      % (len(r['scenes']), len(r['edges'])))
PY
[ $? -eq 0 ] || bad "space.report 不对"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P4（Canon 提交 / 不变量 / 锁 / 恢复）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
