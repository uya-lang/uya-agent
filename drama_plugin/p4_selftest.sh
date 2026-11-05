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

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P4（Canon 提交 / 不变量 / 锁 / 恢复）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
