#!/bin/sh
# drama_plugin/p12_selftest.sh — P12 第一段（闭环审计：四本账 / 不变量 / 重放）
#
# 覆盖 DRAMA_TODO §13 的一部分：
#   * 重放完整性：提交记录的 state 与索引里的 state_hash 必须对得上；
#   * 四本账计数：props / characters / scenes / promise（open、closed、overdue）
#     / timeline；
#   * 不变量：道具与角色必须停在已知场景、承诺逾期必须为 0、canon 不能落后；
#   * 审计是只读的：跑完不改任何状态。
#
# 用法：sh drama_plugin/p12_selftest.sh

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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"审计测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# ---------- 1. 三集提交（带承诺） ----------
i=1
while [ "$i" -le 3 ]; do
    base=$((i - 1))
    extra=''
    if [ "$i" = "1" ]; then
        extra=',{"type":"promise.open","promise":"p1"}'
    fi
    if [ "$i" = "2" ]; then
        extra=',{"type":"promise.close","promise":"p1"}'
    fi
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((10 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":$base,"events":[{"type":"scene.define","scene":"s$i"},{"type":"character.place","character":"dad","scene":"s$i"},{"type":"prop.define","prop":"remote","scene":"s$i","holder":"dad"},{"type":"timeline.advance","minutes":10}$extra]}}}}
JSON
)" > /dev/null
    i=$((i + 1))
done
ok "三集提交完成"

# ---------- 2. 干净状态的审计 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/audit1.json"
python3 - "$TMP/audit1.json" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


check(d['ok'] is True, '干净状态审计通过')
check(d['replay_ok'] is True, '重放完整性通过（三条提交都对得上）')
check(d['commits'] == 3, '审计看到三条提交')
led = d['ledger']
check(led['props'] == 1 and led['characters'] == 1, '道具/角色账本正确')
check(led['scenes'] == 3, '场景账本正确')
check(led['promises_open'] == 0, '没有未回收的承诺')
check(led['promises_closed'] == 1, '已回收承诺 1 条')
check(led['promises_overdue'] == 0, '没有逾期承诺')
check(led['timeline_ms'] == 30, '时间轴账本 = 30 分钟')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# 再开一条不回收的承诺：跨过 3 个 revision 就该报逾期
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","base_revision":3,"events":[{"type":"promise.open","promise":"p2"}]}}}}
JSON
)" > /dev/null
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
codes={v['code'] for v in d['violations']}
assert d['ok'] is False, d
assert 'PROMISE_OVERDUE' in codes, codes
assert d['ledger']['promises_overdue'] == 1, d
print('PASS: 逾期承诺被记成 PROMISE_OVERDUE 违规')" || bad "逾期没进违规列表"

# ---------- 3. 审计只读 ----------
BEFORE=$(md5sum "$DATA/projects/$PID/canon.json" | cut -d' ' -f1)
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$PID"}}}}
JSON
)" > /dev/null
AFTER=$(md5sum "$DATA/projects/$PID/canon.json" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] && ok "审计是只读的（canon.json 未变）" \
    || bad "审计改了 canon.json"

# ---------- 3.5 九条不变量逐条判定 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"call","arguments":{"operation":"invariant.check","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
preds=d['predicates']
codes=[p['code'] for p in preds]
expect=['PROMISE_OVERDUE','HOOK_UNANSWERED','CHARACTER_DRIFT','KNOWLEDGE_LEAK',
        'PROP_TELEPORT','SCENE_DRIFT','ORPHAN_CHANGE','TIMELINE_CONFLICT',
        'RULE_VIOLATION']
assert codes == expect, codes
bad=[p for p in preds if not p['ok']]
assert all(p['code'] == 'PROMISE_OVERDUE' for p in bad), bad
print('PASS: 九条不变量逐条判定（只有 PROMISE_OVERDUE 红）')" \
    || bad "invariant.check 输出不对"

# ---------- 4. 篡改提交记录 ⇒ 重放告警 ----------
python3 - "$DATA/projects/$PID/commits/2.json" <<'PY'
import json
import sys

p = sys.argv[1]
rec = json.load(open(p))
rec['state']['timeline'] = 999      # 改了历史
open(p, 'w').write(json.dumps(rec))
PY
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
codes={v['code'] for v in d['violations']}
assert d['ok'] is False and d['replay_ok'] is False, d
assert 'AUDIT_REPLAY_MISMATCH' in codes, codes
print('PASS: 改过的提交记录被审计抓出来（AUDIT_REPLAY_MISMATCH）')" \
    || bad "篡改没被发现"

# 重复审计仍须检查旧提交，不能复用可陈旧的成功结果。
req='{"jsonrpc":"2.0","id":25,'\
'"method":"tools/call","params":{"name":"call",'\
'"arguments":{"operation":"canon.audit",'\
'"input":{"project_id":"'"$PID"'"}}}}'
out=$(ask "$req")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['replay_ok'] is False, d
assert any(v['code']=='AUDIT_REPLAY_MISMATCH' for v in d['violations']), d
print('PASS: 重复全历史审计仍检查旧提交')" \
    || bad "重复审计漏掉旧提交篡改"
[ ! -e "$DATA/projects/$PID/audit/last.json" ] \
    && ok "全历史审计不依赖可陈旧缓存" \
    || bad "发现未验证的审计缓存"

# ---------- 5. 道具指向未知场景 ----------
python3 - "$DATA/projects/$PID/canon.json" <<'PY'
import json
import sys

p = sys.argv[1]
st = json.load(open(p))
st['props'][0]['scene'] = 'nowhere'
open(p, 'w').write(json.dumps(st))
PY
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
codes={v['code'] for v in d['violations']}
assert 'PROP_IN_UNKNOWN_SCENE' in codes, codes
print('PASS: 道具指向未知场景被审计抓出来')" || bad "场景不变量没生效"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P12 第一段（闭环审计）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
