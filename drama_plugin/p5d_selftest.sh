#!/bin/sh
# drama_plugin/p5d_selftest.sh — P5 第四段（持久任务 / 断点续跑）
#
# 覆盖 DRAMA_TODO §7「Task 接入」的前几条：
#   * `episode.produce(stage=script)` 只落盘建任务、立刻回 queued；
#   * 任务记录可查（task.get / task.list），跨进程仍在；
#   * `task.run` 才真正调模型、存剧本版本；
#   * 重复 `task.run` 不重复干活（resumed=false，剧本版本不再前进）。
#
# 用法：sh drama_plugin/p5d_selftest.sh

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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"任务测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# ---------- 1. produce 只建任务 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e1","stage":"script"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['status'] == 'queued', d
assert d['task_id'] == 't_1', d
print('PASS: episode.produce 立刻回 queued（task_id=t_1）')" \
    || bad "produce 没回 queued"

# 任务记录应当是 pending，且剧本还没生成
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"task.get","input":{"project_id":"$PID","task_id":"t_1"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'queued', d
assert d['steps'][0]['state'] == 'pending', d
assert d.get('script_version') == 0, d
print('PASS: 任务记录里步骤还是 pending，没有提前调模型')" \
    || bad "任务记录不对"

# ---------- 2. task.run 才干活 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"task.run","input":{"project_id":"$PID","task_id":"t_1"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'done' and d['resumed'] is True, d
assert d['script_version'] == 1, d
print('PASS: task.run 执行完成并落剧本版本 1')" || bad "task.run 没跑通"

# ---------- 3. 重复 run 不重复干活 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"task.run","input":{"project_id":"$PID","task_id":"t_1"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'done' and d['resumed'] is False, d
assert d['script_version'] == 1, d
print('PASS: 再跑一次任务直接回放（resumed=false，版本仍是 1）')" \
    || bad "重复 run 又干了一遍活"

# ---------- 4. 列表 & 不存在的任务 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"task.list","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert len(d['tasks']) == 1, d
assert d['tasks'][0]['id'] == 't_1', d
print('PASS: task.list 能看到建过的任务')" || bad "task.list 不对"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"task.get","input":{"project_id":"$PID","task_id":"t_99"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'TASK_NOT_FOUND', d
print('PASS: 不存在的任务 ⇒ TASK_NOT_FOUND')" || bad "不存在的任务没报 TASK_NOT_FOUND"

# ---------- 5. 断点续跑：删掉记录里的 done 状态再跑 ----------
REC="$DATA/projects/$PID/tasks/t_1.json"
python3 - "$REC" <<'PY'
import json
import sys

p = sys.argv[1]
rec = json.load(open(p))
rec['state'] = 'queued'
rec['steps'][0]['state'] = 'pending'
rec.pop('script_version', None)
open(p, 'w').write(json.dumps(rec))
PY
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"task.run","input":{"project_id":"$PID","task_id":"t_1"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'done', d
print('PASS: 记录被回退成 pending 后能续跑（新版本 %d）' % d['script_version'])" \
    || bad "续跑失败"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P5 第四段（持久任务 / 断点续跑）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
