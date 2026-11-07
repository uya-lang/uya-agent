#!/bin/sh
# drama_plugin/p11_selftest.sh — P11 第一段（端到端一条龙）
#
# 从零跑到成片：建项目 → 写 Bible → 三集「生成 → 批准 → 视频任务 → worker →
# 分镜 → 合成 → QA → 审计」，每一步都断言状态与账本。
# 这是「插件能独立跑完一集」的可执行证明（P11 的第一条验收）。
#
# 用法：sh drama_plugin/p11_selftest.sh

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

# ---------- 1. 项目 + Bible ----------
out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"端到端"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PID","bible":{"characters":[{"id":"dad"},{"id":"kid"}],"format":{"canvas":"440x800"}},"locks":{"dad":"爸爸：短寸头，深灰夹克","kid":"孩子：八岁，圆脸"}}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('version') == 1, d
print('PASS: Bible v1 写入（两个角色 + 冻结文本）')" || bad "Bible 没写进去"

# ---------- 2. 三集完整链路 ----------
i=1
while [ "$i" -le 3 ]; do
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((10 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID","target_seconds":90}}}}
JSON
)" > /dev/null
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((20 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":$i}}}}
JSON
)")
    rev=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('revision', d.get('code','ERR')))")
    if [ "$rev" = "$i" ]; then
        ok "第 $i 集批准 → Canon revision $i"
    else
        bad "第 $i 集批准失败：$rev"
    fi
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((30 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e$i","stage":"video"}}}}
JSON
)" > /dev/null
    i=$((i + 1))
done

timeout 180 "$TMP/drama" worker run --data-dir "$DATA" > "$TMP/worker.out" 2>&1 || true
python3 - "$TMP/worker.out" <<'PY'
import json
import sys

raw = [l for l in open(sys.argv[1]).read().split('\n') if l.strip()]
d = json.loads(raw[-1])
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


check(d['tasks_done'] == 3, 'worker 跑完三个视频任务')
check(d['tasks_failed'] == 0, '没有失败任务')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 3. 分镜 → 成片 ----------
i=1
while [ "$i" -le 3 ]; do
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((40 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"task.get","input":{"project_id":"$PID","task_id":"t_$i"}}}}
JSON
)")
    bv=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('board_version','ERR'))")
    [ "$bv" != "ERR" ] && [ "$bv" -gt 0 ] \
        && ok "第 $i 集视频任务绑定 board v$bv" \
        || bad "第 $i 集任务记录没有 board_version：$bv"
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":$((50 + i)),"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.assemble","input":{"project_id":"$PID","board_version":$bv}}}}
JSON
)")
    sz=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('size', d.get('code','ERR')))")
    [ "$sz" != "ERR" ] && [ "$sz" -gt 0 ] \
        && ok "第 $i 集成片合成（board v$bv，$sz 字节）" \
        || bad "第 $i 集合成失败：$sz"
    i=$((i + 1))
done

# ---------- 4. QA + 审计 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.run","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['ok'] is True, d
assert d['report']['board_version'] == 1, d
assert d['report']['script_version'] == 1, d
print('PASS: 第 1 集 QA 全绿（自动选了映射到剧本 v1 的分镜 v1）')" \
    || bad "第 1 集 QA 没绿"

# ---------- 4.5 final.approve：QA 绿才放行，且不动 Canon ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":62,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.approve","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['approved'] is True, d
assert d['script_version'] == 1, d
assert d['board_version'] == 1, d
assert d['assembly_version'] == 3, d
assert d['canon_revision'] == 3, d
print('PASS: 第 1 集成片通过 final.approve（Canon 仍 r3）')" \
    || bad "final.approve 没放行"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":63,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.approve","input":{"project_id":"$PID","script_version":2}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['code'] == 'QA_FAILED', d
print('PASS: 没有 QA 报告的剧本版本被 final.approve 拒（QA_FAILED）')" \
    || bad "QA 未过的版本被标成 final approved"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.audit","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['replay_ok'] is True, d
assert d['revision'] == 3, d
assert d['commits'] == 3, d
codes={v['code'] for v in d['violations']}
assert not codes, codes
print('PASS: 审计干净（三条提交、重放一致、零违规）')" || bad "审计没通过"

# ---------- 4.5 生产摘要（episode.get） ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":70,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.get","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['script_version'] == 3, d
assert d['board_version'] >= 3, d
assert d['assembly_version'] == 3, d
assert d['canon_revision'] == 3, d
assert d['tasks'] >= 3, d
print('PASS: episode.get 汇总（剧本 v%d / 分镜 v%d / 成片 v%d / Canon r%d）'
      % (d['script_version'], d['board_version'], d['assembly_version'],
         d['canon_revision']))" || bad "episode.get 汇总不对"

# ---------- 4.6 成本账本 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":71,"method":"tools/call","params":{"name":"call","arguments":{"operation":"budget.report","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['episodes'] == 3, d
assert d['renders'] >= 3, d
assert d['gpu_ms'] > 0, d
assert d['renders_per_episode'] > 0, d
print('PASS: budget.report（%d 集 / %d 次渲染 / %d ms GPU / 每集 %.2f 次）'
      % (d['episodes'], d['renders'], d['gpu_ms'],
         d['renders_per_episode'] / 100.0))" || bad "成本账本不对"

# ---------- 5. 落盘检查 ----------
n=$(ls "$DATA/projects/$PID/assemblies"/v*.json 2>/dev/null | wc -l)
[ "$n" -eq 3 ] && ok "三份合成 manifest 都在" || bad "manifest 数量是 $n"
python3 - "$DATA/projects/$PID/assemblies" <<'PY'
import glob
import json
import sys

files = sorted(glob.glob(sys.argv[1] + '/v*.json'))
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


for f in files:
    d = json.load(open(f))
    frames = d['frames']
    check(d['fps'] == 25, 'manifest 写 25 fps')
    check((frames - 5) % 17 == 0, '帧数满足 17k+5（%d）' % frames)
    check(frames * 40 >= d['duration_ms'], '帧覆盖住总时长')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

n=$(ls "$DATA/projects/$PID/scripts"/v*.json 2>/dev/null | wc -l)
[ "$n" -eq 3 ] && ok "三个剧本版本都在" || bad "剧本版本数量是 $n"
n=$(ls "$DATA/projects/$PID/assets"/episode_*.mp4 2>/dev/null | wc -l)
[ "$n" -eq 3 ] && ok "三个成片文件都在" || bad "成片数量是 $n"

seen=0
for f in "$DATA/projects/$PID/assets"/episode_*.mp4; do
    [ -f "$f" ] || continue
    nm=$(basename "$f")
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":90,"method":"tools/call","params":{"name":"call","arguments":{"operation":"asset.get","input":{"project_id":"$PID","name":"$nm"}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['asset']['mime'] == 'video/mp4', d
assert d['path'] == 'projects/$PID/assets/$nm', d
" || bad "asset.get 查不到 $nm"
    seen=$((seen + 1))
done
[ "$seen" -eq 3 ] && ok "三集成片都能通过 asset.get 共享路径访问" \
    || bad "只有 $seen 个成片可通过 asset.get 访问"

python3 - "$DATA/projects/$PID/assets" <<'PY'
import glob
import json
import sys

files = sorted(glob.glob(sys.argv[1] + '/audit_v*.json'))
assert files, '审计报告没进资产目录'
d = json.load(open(files[0]))
assert 'ok' in d and 'violations' in d, d
print('PASS: 审计报告进资产（%d 份，audit_v*.json）' % len(files))
PY
[ $? -eq 0 ] || fails=$((fails + 1))


# 百集成本报告：拿这票真实账目（集数/GPU 毫秒/重做率/不变量红数）外推
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":90,"method":"tools/call","params":{"name":"call","arguments":{"operation":"production.cost","input":{"project_id":"$PID","target_episodes":100}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['target_episodes'] == 100, d
m, p = d['measured'], d['projection']
assert d['episodes_measured'] > 0, d
assert d['per_episode']['gpu_ms'] > 0, d
assert p['gpu_minutes'] >= 0 and p['human_minutes'] > 0, d
# 外推必须严格按每集口径放大：gpu_ms ≈ 每集 × 100
assert abs(p['gpu_ms'] - d['per_episode']['gpu_ms'] * 100) <= 100, d
assert 0 <= d['per_episode']['redo_rate_pct'] <= 100, d
assert d['invariants_red'] == 0, d
print('PASS: 百集成本报告（每集 %d ms GPU ⇒ 100 集 %.1f GPU 分钟 / %d 人工分钟 / 重做率 %d%%）'
      % (d['per_episode']['gpu_ms'], p['gpu_minutes'], p['human_minutes'],
         d['per_episode']['redo_rate_pct']))"     || bad "百集成本报告口径不对"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P11 第一段（端到端一条龙）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
