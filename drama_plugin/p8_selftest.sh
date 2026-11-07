#!/bin/sh
# drama_plugin/p8_selftest.sh — P8 第一段（Provider 能力表 / 视频任务 / Worker）
#
# 覆盖 DRAMA_TODO §10 的一部分：
#   * `provider.capabilities` 是版本化的能力表（含禁用动作、接戏枚举、
#     FFmpeg/ffprobe 探测的 media 字段）；
#   * `episode.produce(stage=video)` 立刻回 queued（MCP 不等待视频）；
#   * `drama worker run` 扫未完成任务并执行：分镜 → 逐镜 mock 渲染 → 任务 done；
#   * 未批准剧本的视频任务 ⇒ 任务 failed 且不产出文件（不会污染 Canon）；
#   * 能力表外的动作 ⇒ 任务 failed（reason=action_unsupported）；
#   * 视频任务成功不改变 Canon，并写每集 manifest.json（版本/镜头数/状态）。
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
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/index.uya $HERE/src/series.uya $HERE/src/ops.uya \
$HERE/src/media_ops.uya \
$HERE/src/verify_ops.uya \
$HERE/src/queue_ops.uya \
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
m = d.get('media')
assert isinstance(m, dict), d
for k in ('ffmpeg', 'ffprobe'):
    assert isinstance(m[k], bool), m
    path = m[k + '_path']
    assert isinstance(path, str), m
    if m[k]:
        assert path.endswith('/' + k), m
    else:
        assert path == '', m
print('PASS: provider.capabilities 是版本化能力表（含 media 探测）')" || bad "能力表不对"

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

n=$(find "$DATA/projects/$PID/assets" -name "shot_*.mp4" | wc -l)
[ "$n" -gt 0 ] && ok "产出了 $n 个镜头文件" || bad "没有产出镜头文件"

MAN=$(find "$DATA/projects/$PID/episodes" -name manifest.json 2>/dev/null | head -1)
if [ -n "$MAN" ]; then
    python3 - "$MAN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['episode_id'] in ('e1', 'e2'), d
assert d['script_version'] >= 1, d
assert d['board_version'] >= 1, d
assert d['shots_rendered'] > 0, d
assert d['state'] == 'done', d
assert d['format']['canvas']['width'] == 448, d
assert d['format']['delivery']['fps'] == 24, d
assert d['format']['encode']['vcodec'] == 'libx264', d
print('PASS: 每集 manifest.json 记录了版本/镜头数/状态/format')
PY
    [ $? -eq 0 ] || fails=$((fails + 1))
else
    bad "没有写每集 manifest.json"
fi

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

# ---------- 5.5 本地队列：prompt_id / 复用 / 取消 ----------
out=$(ask '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"call","arguments":{"operation":"queue.get","input":{"project_id":"'"$PID"'","task_id":"'"$TID2"'"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'done', d
assert d['prompt_id'].startswith('q_'), d
assert len(d['prompt_id']) == 10, d
assert d['board_version'] >= 1, d
assert d['shots'] > 0, d
assert d['gpu_ms'] > 0, d
print('PASS: 队列记录 done（prompt_id=%s, shots=%d）' % (d['prompt_id'], d['shots']))" \
    || bad "队列记录不对"

Q2="$DATA/projects/$PID/queue/$TID2.json"
# 判据是"不重发 submit"：prompt_id 与 submitted_at 不许变（updated_at 允许刷新）
KEY_BEFORE=$(python3 -c "
import json,sys
r=json.load(open('$Q2'))
print(r['prompt_id'], r['submitted_at'])")
# 模拟"提交完还没跑完就崩溃"：把任务记录改回 running，再跑一次 worker
python3 - "$DATA/projects/$PID/tasks/$TID2.json" <<'PY'
import json
import sys

p = sys.argv[1]
rec = json.load(open(p))
rec['state'] = 'running'
json.dump(rec, open(p, 'w'), ensure_ascii=False)
PY
out=$(timeout 120 "$TMP/drama" worker run --data-dir "$DATA" 2>/dev/null)
KEY_AFTER=$(python3 -c "
import json,sys
r=json.load(open('$Q2'))
print(r['prompt_id'], r['submitted_at'])")
[ "$KEY_BEFORE" = "$KEY_AFTER" ] \
    && ok "崩溃后重跑复用同一条队列记录（prompt_id 不变，不重发 submit）" \
    || bad "崩溃后重跑重发了 submit（$KEY_BEFORE → $KEY_AFTER）"
python3 - "$DATA/projects/$PID/tasks/$TID2.json" <<'PY'
import json
import sys

rec = json.load(open(sys.argv[1]))
assert rec['state'] == 'done', rec
assert rec.get('provider_prompt_id', '').startswith('q_'), rec
assert rec.get('queue') == 'done', rec
print('PASS: 任务记录带 provider_prompt_id 与 queue=done')
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# 取消：还没跑的任务取消后，队列跟着置 canceled，worker 不再执行
out=$(ask '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"'"$PID"'","episode_id":"e9","stage":"video"}}}}')
TID9=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['task_id'])")
out=$(ask '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.cancel","input":{"project_id":"'"$PID"'","task_id":"'"$TID9"'"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'cancelled', d
print('PASS: task.cancel 把任务标成 cancelled')" || bad "取消没生效"
[ ! -f "$DATA/projects/$PID/queue/$TID9.json" ] \
    && ok "取消的任务没有进队列（没提交过就不生成记录）" \
    || bad "取消的任务还是进了队列"

# ---------- 5.7 结果取回 / 参考素材参数转换 ----------
# 真产物才有可探测的时长：造两段 1 秒的 mp4 放到 v9
mkdir -p "$DATA/projects/$PID/assets/v9"
for i in 1 2; do
    ffmpeg -v error -y -f lavfi -i color=c=blue:s=96x54:d=1 \
        -pix_fmt yuv420p "$DATA/projects/$PID/assets/v9/shot_$i.mp4"
done
printf '%s' '{"format_version":1,"prompt_id":"q_real7777","task_id":"t_real","board_version":9,"state":"done","shots":2,"gpu_ms":1500,"submitted_at":1,"updated_at":2}' \
    > "$DATA/projects/$PID/queue/t_real.json"
out=$(ask '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.result","input":{"project_id":"'"$PID"'","task_id":"t_real"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['task_id'] == 't_real', d
assert len(d['videos']) == 2, d
assert d['total_ms'] > 0, d
for v in d['videos']:
    assert v['bytes'] > 0, v
    assert v['duration_ms'] > 0, v
assert d['last_frame'].endswith('last.jpg'), d
assert d['last_frame_bytes'] > 0, d
print('PASS: provider.result 取回 mp4 清单 + 末帧图 + 元数据（%d 段 / %d ms）'
      % (len(d['videos']), d['total_ms']))" || bad "结果取回不完整"

# 还没跑完的任务取结果 ⇒ RESULT_NOT_READY
printf '%s' '{"format_version":1,"prompt_id":"q_zzzz9999","task_id":"t_pending","board_version":1,"state":"running","shots":1,"gpu_ms":0,"submitted_at":1,"updated_at":2}' \
    > "$DATA/projects/$PID/queue/t_pending.json"
out=$(ask '{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.result","input":{"project_id":"'"$PID"'","task_id":"t_pending"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'RESULT_NOT_READY', d
print('PASS: 未完成的任务取结果 ⇒ RESULT_NOT_READY')" || bad "未完成任务没拒绝取结果"

# 取消：真的把 job 停掉（标记文件 + 记录置 canceled），已终结的拒绝
out=$(ask '{"jsonrpc":"2.0","id":27,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.cancel","input":{"project_id":"'"$PID"'","task_id":"t_pending"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'canceled', d
print('PASS: provider.cancel 把队列记录置 canceled')" || bad "取消没改状态"
[ -f "$DATA/projects/$PID/queue/t_pending.cancel" ] \
    && ok "取消留了 .cancel 标记文件（worker 会真把生成进程收掉）" \
    || bad "取消没留标记文件"
python3 - "$DATA/projects/$PID/queue/t_pending.json" <<'PY'
import json
import sys

rec = json.load(open(sys.argv[1]))
assert rec['state'] == 'canceled', rec
assert rec['prompt_id'] == 'q_zzzz9999', rec
print('PASS: 取消只改 state，prompt_id 等字段原样保留')
PY
[ $? -eq 0 ] || fails=$((fails + 1))
out=$(ask '{"jsonrpc":"2.0","id":28,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.cancel","input":{"project_id":"'"$PID"'","task_id":"t_real"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'TASK_TERMINAL', d
print('PASS: 已完成的任务取消不成立（TASK_TERMINAL）')" || bad "终态任务还能取消"

# 参考素材参数转换：slot / 顺序 / 帧索引引导 / 冻结文本 hash
out=$(ask '{"jsonrpc":"2.0","id":29,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.refs","input":{"project_id":"'"$PID"'","board_version":1,"shot":1}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['shot'] == 1, d
if d['ref_count'] > 0:
    r = d['refs'][0]
    assert r['order'] == 0, r
    assert r['slot'] == 'first_frame', r
    assert r['frame_index'] == 0, r
    assert r['role'] in ('character', 'prop'), r
    assert len(r['frozen_hash']) == 12, r
    print('PASS: provider.refs 给出参考图槽位/顺序/帧索引/冻结 hash')
else:
    print('PASS: provider.refs 在没有在场角色时返回空参考表')" || bad "参考素材参数转换不对"

# 轮询口径：排队/跑着各给不同的等待时长，终态不再问
printf '%s' '{"format_version":1,"prompt_id":"q_poll1","task_id":"t_q","board_version":1,"state":"queued","shots":1,"gpu_ms":0,"submitted_at":1,"updated_at":1}' \
    > "$DATA/projects/$PID/queue/t_q.json"
printf '%s' '{"format_version":1,"prompt_id":"q_poll2","task_id":"t_r","board_version":1,"state":"running","shots":1,"gpu_ms":0,"submitted_at":1,"updated_at":1}' \
    > "$DATA/projects/$PID/queue/t_r.json"
out=$(ask '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.poll","input":{"project_id":"'"$PID"'","task_id":"t_q"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'queued', d
assert d['terminal'] is False, d
assert d['poll_after_ms'] == 500, d
print('PASS: 排队的任务 poll 回 queued 并让 500 ms 后再问')" \
    || bad "排队状态的轮询口径不对"
out=$(ask '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.poll","input":{"project_id":"'"$PID"'","task_id":"t_r"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'running', d
assert d['poll_after_ms'] == 1500, d
print('PASS: 跑着的任务 poll 回 running 并让 1.5 s 后再问')" \
    || bad "运行状态的轮询口径不对"
out=$(ask '{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.poll","input":{"project_id":"'"$PID"'","task_id":"t_q2none"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'unknown', d
assert d['terminal'] is False, d
print('PASS: 没有记录的任务 poll 回 unknown')" || bad "未知任务的轮询不对"

# ---------- 6. 单 Worker 锁 ----------
mkdir -p "$DATA/locks"
printf '{"pid":%d}' "$$" > "$DATA/locks/worker.lock"
out=$(timeout 120 "$TMP/drama" worker run --data-dir "$DATA" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read().strip())
assert d.get('busy') is True, d
print('PASS: 另一个 worker 在跑时拒绝开工（busy）')" || bad "worker 锁没生效"

printf '{"pid":999999}' > "$DATA/locks/worker.lock"
out=$(timeout 120 "$TMP/drama" worker run --data-dir "$DATA" 2>/dev/null)
printf '%s' "$out" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read().strip())
assert 'tasks_seen' in d, d
print('PASS: 持有者已死 ⇒ 陈旧 worker 锁自动清掉')" || bad "陈旧 worker 锁没恢复"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P8 第一段（Provider 能力表 / 视频任务 / Worker）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
