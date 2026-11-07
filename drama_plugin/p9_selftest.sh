#!/bin/sh
# drama_plugin/p9_selftest.sh — P9 第一段（确定性 QA + 生产状态 + 重试）
#
# 覆盖 DRAMA_TODO §11 的一部分：
#   * 静态体检能发现"素材缺失/结构不对"：缺 hook、对白没说话人、空动作镜头；
#   * 正常剧本 + 分镜 ⇒ QA 全绿，报告落 qa/v1.json（不可变、带 hash）；
#   * production.status 能查到任务当前状态和 worker=idle|busy；
#   * episode.retry 把失败任务重置成 queued，worker 能重跑，且**不动 Canon**。
#
# 用法：sh drama_plugin/p9_selftest.sh

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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"QA测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# ---------- 1. 正常链路：生成 → 分镜 → QA 全绿 ----------
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID"}}}}
JSON
)" > /dev/null
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"storyboard.build","input":{"project_id":"$PID","script_version":1}}}}
JSON
)" > /dev/null
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.run","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['ok'] is True, d
assert d['issue_count'] == 0, d
assert d['report_version'] == 1, d
assert d['report']['checked_shots'] > 0, d
print('PASS: 正常剧本 + 分镜 ⇒ QA 全绿（检查了 %d 个镜头）'
      % d['report']['checked_shots'])" || bad "正常链路 QA 没全绿"

# ---------- 2. 缺 hook 的剧本 ⇒ QA 报问题 ----------
mkdir -p "$DATA/projects/$PID/scripts"
printf '%s' '{"format_version":1,"version":2,"content_hash":"x","screenplay":{"title":"bad","scenes":[{"no":1,"action":"a","dialogue":[{"line":"没人说的话"}]}]}}' \
    > "$DATA/projects/$PID/scripts/v2.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.run","input":{"project_id":"$PID","script_version":2}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['ok'] is False, d
codes={i['code'] for i in d['report']['issues']}
assert 'QA_HOOK_MISSING' in codes, codes
assert 'QA_LINE_NO_SPEAKER' in codes, codes
assert 'STALE_BOARD' in codes, codes
print('PASS: 缺 hook / 没说话人的对白都被报出来（%d 条）'
      % d['issue_count'])" || bad "结构问题没被 QA 发现"

# ---------- 3. 生产状态 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e1","stage":"script"}}}}
JSON
)")
TID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['task_id'])")
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.status","input":{"project_id":"$PID","task_id":"$TID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'queued', d
assert d.get('worker') in ('idle', 'busy'), d
print('PASS: production.status 能查到 queued 的任务与 worker 状态')" || bad "status 查不到任务"

# ---------- 3.5 批量投 N 集 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.batch","input":{"project_id":"$PID","episodes":"e10,e11,e12","priority":5,"deadline_s":$(( $(date +%s) + 3600 ))}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['queued'] == 3, d
assert len(d['episodes']) == 3, d
assert len(set(d['episodes'])) == 3, d
assert d['priority'] == 5, d
print('PASS: episode.batch 一次投 %d 集（priority=5）' % d['queued'])" \
    || bad "批量投递不对"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.status","input":{"project_id":"$PID","task_id":"$(printf '%s' "$out" | field | python3 -c "
import json,sys;print(json.load(sys.stdin)['episodes'][0])")"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'queued', d
assert d['priority'] == 5, d
assert d['episode_id'] == 'e10', d
print('PASS: 批量任务记录里带 priority 与 episode_id')" \
    || bad "批量任务记录不对"

# ---------- 3.6 过了截止时间的任务不再跑 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.batch","input":{"project_id":"$PID","episodes":"e13","deadline_s":$(( $(date +%s) - 60 ))}}}}
JSON
)")
TID_LATE=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['episodes'][0])")
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.report","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['tasks_overdue'] == 1, d
print('PASS: 过了截止时间的任务被计为逾期')" || bad "逾期统计不对"

timeout 120 "$TMP/drama" worker run --data-dir "$DATA" > /dev/null 2>&1 || true
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.status","input":{"project_id":"$PID","task_id":"$TID_LATE"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'failed', d
assert d['reason'] == 'deadline_exceeded', d
print('PASS: 逾期任务被 worker 记 failed/deadline_exceeded')" \
    || bad "逾期任务没被拦下"

# ---------- 4. 失败 → 重试 → worker 跑通，且不动 Canon ----------
printf '%s' '{"format_version":1,"version":3,"content_hash":"z","screenplay":{"title":"v3","hook":"h","scenes":[{"no":1,"action":"冰箱爆炸了","dialogue":[]}]}}' \
    > "$DATA/projects/$PID/scripts/v3.json"
printf '%s' '{"version":3}' > "$DATA/projects/$PID/scripts/current.json"
printf '%s' '{"script_version":3,"canon_revision":0}' > "$DATA/projects/$PID/scripts/approved.json"
CANON_BEFORE=$(md5sum "$DATA/projects/$PID/canon.json" 2>/dev/null | cut -d' ' -f1 || echo none)
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e2","stage":"video"}}}}
JSON
)")
TID2=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['task_id'])")
timeout 120 "$TMP/drama" worker run --data-dir "$DATA" > /dev/null 2>&1 || true
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.status","input":{"project_id":"$PID","task_id":"$TID2"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'failed' and d['reason'] == 'action_unsupported', d
print('PASS: 能力表外的动作让任务 failed（action_unsupported）')" \
    || bad "越界动作没让任务失败"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.retry","input":{"project_id":"$PID","task_id":"$TID2"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'queued', d
print('PASS: episode.retry 把失败任务重置成 queued')" || bad "retry 没重置任务"

CANON_AFTER=$(md5sum "$DATA/projects/$PID/canon.json" 2>/dev/null | cut -d' ' -f1 || echo none)
[ "$CANON_BEFORE" = "$CANON_AFTER" ] && ok "重试没有改动 Canon" \
    || bad "重试改了 Canon"

# ---------- 5. 取消：没跑完可以取消，跑完的不能 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e9","stage":"script"}}}}
JSON
)")
TID3=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['task_id'])")
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.cancel","input":{"project_id":"$PID","task_id":"$TID3"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'cancelled', d
print('PASS: 未完成的任务可以取消')" || bad "取消失败"

timeout 120 "$TMP/drama" worker run --data-dir "$DATA" > /dev/null 2>&1 || true
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.status","input":{"project_id":"$PID","task_id":"$TID3"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'cancelled', d
print('PASS: worker 不会把已取消的任务再捡起来')" || bad "worker 重跑了已取消的任务"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.cancel","input":{"project_id":"$PID","task_id":"$TID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'CANNOT_CANCEL', d
print('PASS: 已完成的任务拒绝取消（CANNOT_CANCEL）')" || bad "已完成任务还能被取消"

# ---------- 6. 预算熔断 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"call","arguments":{"operation":"budget.limit","input":{"project_id":"$PID","max_renders":1,"max_gpu_minutes":0}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['max_renders'] == 1, d
print('PASS: 预算上限设置成功（最多 1 次渲染）')" || bad "budget.limit 没生效"

# 这轮项目已经渲染过（p8 里跑过？这里至少 0 次），再产一集应当被熔断
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e10","stage":"video"}}}}
JSON
)")
TID4=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('task_id','ERR'))")
timeout 120 "$TMP/drama" worker run --data-dir "$DATA" > /dev/null 2>&1 || true
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.status","input":{"project_id":"$PID","task_id":"$TID4"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['state'] == 'failed' and d['reason'] == 'budget_exceeded', d
print('PASS: 超预算的任务被熔断（budget_exceeded），没有硬跑')" \
    || bad "预算熔断没生效"

# ---------- 引用与事件核对（场景/道具/事件可追） ----------
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PID","events":[{"type":"scene.define","scene":"kitchen","time_of_day":"day"},{"type":"prop.define","prop":"remote","scene":"kitchen"}]}}}}
JSON
)" > /dev/null
printf '%s' '{"format_version":1,"version":3,"content_hash":"x","screenplay":{"title":"引用","theme":"信任","conflict":"谁动了遥控器","comedy":{"setup":"藏","payoff":"找到"},"twist":"一直在口袋","hook":"遥控器去哪了？","scenes":[{"no":1,"action":"爸爸找遥控器","dialogue":[]}],"candidate_events":[{"type":"timeline.advance","minutes":1},{"type":"prop.move","prop":"tv","at_scene":"kitchen","to_scene":"kitchen"}]}}' \
    > "$DATA/projects/$PID/scripts/v3.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":45,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.run","input":{"project_id":"$PID","script_version":3}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
codes={i['code'] for i in d['report']['issues']}
assert 'QA_PROP_UNKNOWN' in codes, codes
print('PASS: 事件引用了 Canon 里没有的道具 ⇒ QA_PROP_UNKNOWN')" \
    || bad "没报 QA_PROP_UNKNOWN"

# ---------- 人物一致性：说话的人必须在 Bible 角色表里 ----------
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":45,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PID","bible":{"characters":[{"id":"dad"}],"format":{"canvas":"440x800"}},"locks":{"dad":"爸爸：短寸头"}}}}}
JSON
)" > /dev/null
printf '%s' '{"format_version":1,"version":4,"content_hash":"x","screenplay":{"title":"乱说话","theme":"信任","conflict":"谁在说话","comedy":{"setup":"藏","payoff":"找到"},"twist":"一直在家","hook":"谁在说话？","scenes":[{"no":1,"action":"有人开口","dialogue":[{"who":"ghost","line":"我不在家"}]}],"candidate_events":[{"type":"timeline.advance","minutes":1}]}}' \
    > "$DATA/projects/$PID/scripts/v4.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":46,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.run","input":{"project_id":"$PID","script_version":4}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
codes={i['code'] for i in d['report']['issues']}
assert 'QA_WHO_UNKNOWN' in codes, codes
print('PASS: 台词说话人不在 Bible 角色表 ⇒ QA_WHO_UNKNOWN')" \
    || bad "没报 QA_WHO_UNKNOWN"

# ---------- 抽样审批队列 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"call","arguments":{"operation":"review.queue","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert isinstance(d['sample'], list), d
assert isinstance(d['anomalies'], list), d
assert d['decided'] == 0, d
print('PASS: 审批队列（抽样 %d 条 / 异常 %d 条）'
      % (len(d['sample']), len(d['anomalies'])))" \
    || bad "审批队列不对"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"call","arguments":{"operation":"review.decide","input":{"project_id":"$PID","episode_id":"e13","decision":"reject","note":"重看第三镜"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['recorded'] is True and d['decision'] == 'reject', d
print('PASS: 抽样裁决已记录（e13 reject）')" || bad "裁决没记下来"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":53,"method":"tools/call","params":{"name":"call","arguments":{"operation":"review.queue","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['decided'] == 1, d
print('PASS: 队列里能看到已裁决 1 条')" || bad "已裁决计数不对"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":54,"method":"tools/call","params":{"name":"call","arguments":{"operation":"review.decide","input":{"project_id":"$PID","episode_id":"e13","decision":"maybe"}}}}
JSON
)")
got=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('code','OK'))")
[ "$got" = "SCHEMA_INVALID" ] \
    && ok "非法裁决被拒（SCHEMA_INVALID）" \
    || bad "非法裁决没拦住（$got）"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P9 第一段（确定性 QA / 生产状态 / 重试）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
