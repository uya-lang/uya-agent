#!/bin/sh
# drama_plugin/p6_selftest.sh — P6（连续三集 / M1 最小闭环）
#
# M1 判据（DRAMA_TODO 台阶表）：3 集连续、四轴不变量零红、重放复现率 100%。
# 这里用 mock Provider（确定性输出）跑完整链路：
#   建项目 → 写 Bible → 三集「生成 → 批准」→ 检查 Canon / 摘要 / 不变量
#   → 换一个数据根重跑同样输入，比对 canon.json 是否逐字节一致。
#
# 用法：sh drama_plugin/p6_selftest.sh

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
$HERE/src/queue_ops.uya $HERE/src/pipeline_ops.uya \
$HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

if ! "$UYA" build $SRC -o "$TMP/drama" > "$TMP/build.log" 2>&1; then
    echo "FAIL: 构建失败"
    tail -10 "$TMP/build.log"
    exit 1
fi
ok "构建通过"

run_at() {
    data=$1
    shift
    printf '%s\n' "$@" > "$TMP/q.jsonl"
    timeout 180 "$TMP/drama" mcp serve --data-dir "$data" \
        < "$TMP/q.jsonl" 2>/dev/null
}

# 一集：生成 + 批准；回 (script_version, canon_revision)
one_episode() {
    data=$1
    pid=$2
    out=$(run_at "$data" "$(cat <<JSON
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$pid","target_seconds":120}}}}
JSON
)")
    ver=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
t=json.loads(json.loads(raw[0])['result']['content'][0]['text'])
print((t.get('data',{}).get('result') or {}).get('script_version','ERR'))")
    out=$(run_at "$data" "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$pid","script_version":$ver}}}}
JSON
)")
    rev=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
t=json.loads(json.loads(raw[0])['result']['content'][0]['text'])
print((t.get('data',{}).get('result') or {}).get('revision','ERR'))")
    echo "$ver $rev"
}

episode3() {
    data=$1
    out=$(run_at "$data" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"三集闭环"}}}}')
    pid=$(printf '%s' "$out" | python3 -c "
import json,sys
raw=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
t=json.loads(json.loads(raw[0])['result']['content'][0]['text'])
print(t['data']['result']['project_id'])")
    run_at "$data" "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$pid","bible":{"characters":[{"id":"dad"},{"id":"kid"}]},"locks":{"dad":"爸爸：中年，短寸头","kid":"孩子：八岁，圆脸"}}}}}
JSON
)" > /dev/null
    n=1
    while [ "$n" -le 3 ]; do
        res=$(one_episode "$data" "$pid")
        echo "  episode $n -> $res"
        n=$((n + 1))
    done
    echo "$pid"
}

# ---------- 1. 第一轮：三集闭环 ----------
echo "== 第一轮 =="
D1="$TMP/d1"
mkdir -p "$D1"
PID1=$(episode3 "$D1" | tail -1)
[ -n "$PID1" ] && ok "三集跑完（项目 $PID1）" || { bad "三集没跑完"; exit 1; }

python3 - "$D1" "$PID1" <<'PY'
import json
import os
import sys

data, pid = sys.argv[1], sys.argv[2]
base = os.path.join(data, 'projects', pid)
canon = json.load(open(os.path.join(base, 'canon.json')))
ok, fails = [], []


def check(cond, msg):
    (ok if cond else fails).append(msg)


check(canon.get('revision') == 3, '正片推进入 3 个 revision')
check(canon.get('timeline', 0) >= 15, '时间轴累计推进（>=15 分钟）')

scene_names = {s['name'] for s in canon.get('scenes', [])}
for p in canon.get('props', []):
    check(p['scene'] in scene_names, '道具 %s 停在已知场景' % p['name'])
for c in canon.get('characters', []):
    check(c['scene'] in scene_names, '角色 %s 在已知场景' % c['name'])

sums = [l for l in open(os.path.join(base, 'summaries.jsonl'),
                        encoding='utf-8').read().split('\n') if l.strip()]
check(len(sums) == 3, '摘要正好三条（每集一条）')
eps = [json.loads(s)['episode'] for s in sums]
check(eps == [1, 2, 3], '摘要里的集号连续')
det = [json.loads(s) for s in sums]
check(all(d.get('scenes', 0) >= 1 for d in det), '摘要记了镜头段数（scenes）')
check(all(d.get('duration_ms', 0) > 0 for d in det), '摘要记了时长（duration_ms）')
check(all(d.get('title') and d.get('hook') for d in det), '摘要带标题与钩子')
prom = canon.get('promises', [])
closed = sorted(p['id'] for p in prom if p.get('state') == 'closed')
opens = sorted(p['id'] for p in prom if p.get('state') != 'closed')
check(closed == ['hook_1', 'hook_2'], '第 2、3 集各兑现上一集钩子')
check(opens == ['hook_3'], '结束时只剩本集新钩子未兑现（回收率 100%）')

bible = json.load(open(os.path.join(base, 'bible', 'current.json')))
check(bible.get('version') == 1, 'Bible 版本没被剧本写坏')

for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 2. 重放：换数据根跑同样输入 ----------
echo "== 重放 =="
D2="$TMP/d2"
mkdir -p "$D2"
PID2=$(episode3 "$D2" | tail -1)

if cmp -s "$D1/projects/$PID1/canon.json" "$D2/projects/$PID2/canon.json"; then
    ok "重放后 canon.json 逐字节一致（复现率 100%）"
else
    bad "重放后 canon.json 不一致"
    diff <(python3 -m json.tool "$D1/projects/$PID1/canon.json" 2>/dev/null || true) \
         <(python3 -m json.tool "$D2/projects/$PID2/canon.json" 2>/dev/null || true) \
         | head -10 || true
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P6（连续三集 / M1 最小闭环）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
