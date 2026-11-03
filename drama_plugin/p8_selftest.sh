#!/bin/sh
# drama_plugin/p8_selftest.sh — P8 第一段（Provider 能力表 / 视频任务 / Worker）
#
# 覆盖 DRAMA_TODO §10 的一部分：
#   * `provider.capabilities` 是版本化的能力表（含禁用动作、接戏枚举）；
#   * `episode.produce(stage=video)` 立刻回 queued（MCP 不等待视频）；
#   * `drama worker run` 扫未完成任务并执行：分镜 → 逐镜 mock 渲染 → 任务 done；
#   * 未批准剧本的视频任务 ⇒ 任务 failed 且不产出文件（不会污染 Canon）；
#   * 能力表外的动作 ⇒ 任务 failed（reason=action_unsupported）；
#   * 视频任务成功不改变 Canon。
#
# 用法：sh drama_plugin/p8_selftest.sh

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
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/index.uya $HERE/src/ops.uya \
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

# ---------- 1. 能力表 ----------
out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.capabilities","input":{}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['capability_version'] == 'mock-video-cap-1', d
assert '跳切' in d['forbidden_actions'], d
assert d['supports'] == ['anchor','hard_cut'], d
print('PASS: provider.capabilities 是版本化能力表')" || bad "能力表不对"

out=$(ask '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"视频任务测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# ---------- 2. 未批准剧本的视频任务 ⇒ failed ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e1","stage":"video"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['status'] == 'queued' and d['task_id'] == 't_1', d
print('PASS: 视频任务立刻回 queued（MCP 不等视频）')" || bad "produce 没回 queued"

out=$(timeout 120 "$TMP/drama" worker run --data-dir "$DATA" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read().strip().split(chr(10))[-1])
assert d['tasks_seen'] == 1 and d['tasks_failed'] == 1, d
print('PASS: 未批准剧本时 worker 把任务判失败')" || bad "未批准剧本没被拦"

REC="$DATA/projects/$PID/tasks/t_1.json"
python3 - "$REC" <<'PY'
import json
import sys

rec = json.load(open(sys.argv[1]))
assert rec['state'] == 'failed', rec
assert rec['reason'] == 'script_not_approved', rec
print('PASS: 失败原因写进任务记录（script_not_approved）')
PY
[ $? -eq 0 ] || fails=$((fails + 1))

if ls "$DATA/projects/$PID/assets"/*.mp4 >/dev/null 2>&1; then
    bad "未批准就产出了视频文件"
else
    ok "未批准时不产出任何视频文件"
fi

# ---------- 3. 批准后重跑视频任务 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID"}}}}
JSON
)")
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('revision') == 1, d
print('PASS: 剧本批准并推进到 revision 1')" || bad "批准失败"

CANON_BEFORE=$(md5sum "$DATA/projects/$PID/canon.json" | cut -d' ' -f1)
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e2","stage":"video"}}}}
JSON
)")
TID2=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['task_id'])")

out=$(timeout 120 "$TMP/drama" worker run --data-dir "$DATA" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read().strip().split(chr(10))[-1])
assert d['tasks_done'] >= 1, d
print('PASS: worker 把视频任务跑完（done=%d）' % d['tasks_done'])" || bad "worker 没跑完视频任务"

python3 - "$DATA/projects/$PID/tasks/$TID2.json" <<'PY'
import json
import sys

rec = json.load(open(sys.argv[1]))
assert rec['state'] == 'done', rec
assert rec['shots_rendered'] > 0, rec
print('PASS: 任务记录里 shots_rendered=%d' % rec['shots_rendered'])
PY
[ $? -eq 0 ] || fails=$((fails + 1))

n=$(ls "$DATA/projects/$PID/assets"/*.mp4 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && ok "产出了 $n 个镜头文件" || bad "没有产出镜头文件"

CANON_AFTER=$(md5sum "$DATA/projects/$PID/canon.json" | cut -d' ' -f1)
[ "$CANON_BEFORE" = "$CANON_AFTER" ] && ok "视频任务没有改动 Canon" \
    || bad "视频任务改了 Canon"

# 再跑一次 worker：已 done 的任务不该重做
out=$(timeout 120 "$TMP/drama" worker run --data-dir "$DATA" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read().strip().split(chr(10))[-1])
assert d['tasks_seen'] == 0, d
print('PASS: 已完成的任务不会被重复执行')" || bad "worker 重复执行了已完成的活"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P8 第一段（Provider 能力表 / 视频任务 / Worker）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
