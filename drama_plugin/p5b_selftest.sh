#!/bin/sh
# drama_plugin/p5b_selftest.sh — P5 第二段（剧本生成 / 审核 / 批准入 Canon）
#
# 覆盖 DRAMA_TODO §7 的「剧本生成」「剧本审核」「验收」前几条：
#   * episode.generate 产出结构化剧本并存成版本，**不改 Canon**；
#   * 时长估算走确定性口径（同一份剧本两次算出同一个数）；
#   * 审核失败（缺 hook / 缺 scenes / 场景字段不全）不能批准；
#   * 批准后候选事件才进 Canon，revision 前进；
#   * 不存在的剧本版本 ⇒ NOT_FOUND。
#
# 用法：sh drama_plugin/p5b_selftest.sh

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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"剧本测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# ---------- 1. 生成：不改 Canon ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID","target_seconds":120}}}}
JSON
)")
got=$(code_of "$out")
[ "$got" = "OK" ] && ok "episode.generate 产出剧本" || bad "生成失败：$got"
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['script_version'] == 1, d
assert d['duration_ms'] > 0, d
assert d['canon_revision'] == 0, d
print('PASS: 剧本版本 1、时长 %d ms、Canon 仍是 revision 0' % d['duration_ms'])
" || bad "生成结果字段不对"

python3 - "$DATA/projects/$PID/scripts/v1.json" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
sp = d.get('screenplay', d)
assert sp['theme'] and sp['conflict'] and sp['twist'], sp
assert sp['comedy']['setup'] and sp['comedy']['payoff'], sp
sc = sp['scenes'][0]
assert sc['action'] and sc['dialogue'][0]['line'], sp
print('PASS: 剧本带主题/冲突/反转/喜剧结构 + 对白/动作')
PY
[ $? -eq 0 ] || fails=$((fails + 1))


out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.inspect","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['revision'] == 0 and not d['scenes'], d
print('PASS: 生成剧本没有污染 Canon')
" || bad "生成后 Canon 被改了"

# ---------- 2. 时长确定性 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID","target_seconds":120}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['duration_ms'] > 0, d
print('PASS: 同样输入再生成，时长仍是 %d ms（确定性口径）' % d['duration_ms'])
" || bad "第二次生成的时长不对"

# 版本只增不改：第二次生成另起一版，旧版字节不动
V1_HASH=$(md5sum "$DATA/projects/$PID/scripts/v1.json" | cut -d' ' -f1)
nver=$(ls "$DATA/projects/$PID/scripts" | grep -c '^v[0-9]*\.json$' || true)
[ "$nver" -ge 2 ] && ok "第二次生成另起一版（现有 $nver 个版本）" \
    || bad "第二次生成没有保留旧版本"
[ "$V1_HASH" = "$(md5sum "$DATA/projects/$PID/scripts/v1.json" | cut -d' ' -f1)" ] \
    && ok "旧版本 v1 未被覆盖（字节不变）" || bad "旧版本被改写了"

# ---------- 2b. 审查报告：问题清单 + 审核版本 ID ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"call","arguments":{"operation":"story.review","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/review.json"
RID=$(python3 -c "
import json
d = json.load(open('$TMP/review.json'))
assert d['ok'] is True, d
assert len(d['review_id']) == 16, d
assert d['scenes'] >= 1, d
assert d['candidate_events'] >= 1, d
assert d['issues'] == [], d
print(d['review_id'])")
[ -n "$RID" ] && ok "审查报告 ok + review_id=$RID" || bad "审查报告不对"

# ---------- 3. 审核失败不能批准 ----------
mkdir -p "$DATA/projects/$PID/scripts"
printf '%s' '{"format_version":1,"version":3,"content_hash":"x","screenplay":{"title":"bad","scenes":[{"no":1,"action":"a"}]}}' \
    > "$DATA/projects/$PID/scripts/v3.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":3}}}}
JSON
)")
got=$(code_of "$out")
[ "$got" = "SCHEMA_INVALID" ] && ok "缺 hook 的剧本不能批准（SCHEMA_INVALID）" \
    || bad "审核失败剧本应被拒，实际 $got"

# ---------- 4. 不存在的版本 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":99}}}}
JSON
)")
got=$(code_of "$out")
[ "$got" = "NOT_FOUND" ] && ok "不存在的剧本版本 ⇒ NOT_FOUND" \
    || bad "不存在的版本应回 NOT_FOUND，实际 $got"

# ---------- 5. 批准：候选事件进 Canon ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
got=$(code_of "$out")
if [ "$got" = "OK" ]; then
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['revision'] == 1, d
assert d['events_applied'] >= 1, d
print('PASS: 批准后候选事件进 Canon（revision 1，%d 个事件）' % d['events_applied'])
" || bad "批准后的提交结果不对"
else
    bad "批准失败：$got"
fi

python3 - "$DATA/projects/$PID/scripts/approved.json" "$RID" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
assert d['review_id'] == sys.argv[2], d
print('PASS: 批准记录带上 review_id（%s）' % d['review_id'])
PY
[ $? -eq 0 ] || bad "批准记录没带 review_id"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.inspect","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['revision'] == 1, d
assert d['timeline'] > 0, d
print('PASS: Canon 里能看到剧本带来的时间推进（timeline=%d）' % d['timeline'])
" || bad "Canon 没收到剧本事件"

# ---------- 6. 重复批准同一版本应当幂等或明确拒绝 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
got=$(code_of "$out")
if [ "$got" = "OK" ]; then
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('duplicate') is True and d.get('events_applied') == 0, d
print('PASS: 重复批准回放上次结果（duplicate=true，不重复应用事件）')
" || bad "重复批准没有回放上次结果"
else
    bad "重复批准应回 OK+duplicate，实际 $got"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P5 第二段（剧本生成 / 审核 / 批准）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
