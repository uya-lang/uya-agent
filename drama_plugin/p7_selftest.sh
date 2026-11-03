#!/bin/sh
# drama_plugin/p7_selftest.sh — P7 第一段（分镜生成 / 版本 / 时长口径）
#
# 覆盖 DRAMA_TODO §9 的一部分：
#   * 剧本 → 分镜是确定性的：同一份剧本重复 build 复用同一版本；
#   * 每个镜头有 shot_id / sequence / scene / framing / action / cut_type /
#     timeline_in / timeline_out / duration_ms；
#   * 首镜 anchor、其余 hard_cut；timeline 首尾相接；
#   * Σ镜头时长 == 剧本时长（同一套确定性口径）；
#   * 台词逐字保留；剧本换版本 ⇒ 分镜出新版本，旧版不覆盖；
#   * 动作越出能力表（禁用词）⇒ ACTION_UNSUPPORTED，而不是生成后才发现。
#
# 用法：sh drama_plugin/p7_selftest.sh

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
$HERE/src/audit.uya $HERE/src/assemble.uya $HERE/src/ops.uya \
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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"分镜测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# ---------- 1. 生成剧本 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID","target_seconds":60}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/gen.json"
SCREEN_MS=$(python3 -c "
import json
print(json.load(open('$TMP/gen.json'))['duration_ms'])")
ok "剧本生成，时长 $SCREEN_MS ms"

# ---------- 2. 分镜 build（第一次） ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"storyboard.build","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/board1.json"
python3 - "$TMP/board1.json" "$SCREEN_MS" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
screen = int(sys.argv[2])
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


check(d.get('board_version') == 1, '首次 build 得到 board v1')
check(d.get('reused') is False, '首次 build 不是复用')
check(d.get('shot_count', 0) > 0, '镜头数 > 0')
check(d.get('total_ms') == screen,
      'Σ镜头时长 == 剧本时长（%d ms）' % screen)
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 3. 再 build：复现 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"storyboard.build","input":{"project_id":"$PID","script_version":1}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['board_version'] == 1 and d['reused'] is True, d
print('PASS: 同一份剧本再 build 复用 v1（分镜是确定性的）')" \
    || bad "重复 build 没复用"

# ---------- 4. 分镜内容与接戏 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"storyboard.get","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/board.json"
python3 - "$TMP/board.json" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
b = d['board']
shots = b['shots']
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


need = ['shot_id', 'sequence', 'scene', 'framing', 'cut_type',
        'timeline_in', 'timeline_out', 'duration_ms']
check(all(all(k in s for k in need) for s in shots), '每个镜头字段齐全')
check(shots[0]['cut_type'] == 'anchor', '首镜是 anchor')
check(all(s['cut_type'] == 'hard_cut' for s in shots[1:]),
      '其余镜头是 hard_cut')
check(shots[0]['timeline_in'] == 0, '首镜从 0 开始')
gaps = [s for a, s in zip(shots, shots[1:])
        if s['timeline_in'] != a['timeline_out']]
check(not gaps, 'timeline 首尾相接（没有空档/重叠）')
check(all(s['scene'] for s in shots), '每个镜头都有场景 ID')
dlg = [s for s in shots if 'line' in s]
check(bool(dlg), '对白镜头保留了台词')
check(all(s.get('who') for s in dlg), '对白镜头有人物 ID')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 5. 剧本换版本 ⇒ 分镜出新版本 ----------
mkdir -p "$DATA/projects/$PID/scripts"
printf '%s' '{"format_version":1,"version":2,"content_hash":"x","screenplay":{"title":"v2","hook":"h","scenes":[{"no":1,"action":"爸爸走进厨房。","dialogue":[]}]}}' \
    > "$DATA/projects/$PID/scripts/v2.json"
printf '%s' '{"version":2}' > "$DATA/projects/$PID/scripts/current.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"storyboard.build","input":{"project_id":"$PID","script_version":2}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['board_version'] == 2 and d['reused'] is False, d
print('PASS: 剧本换版本 ⇒ 分镜出新版本 v2（旧版不覆盖）')" \
    || bad "剧本换版本没出新分镜"

# ---------- 6. 动作越出能力表 ----------
printf '%s' '{"format_version":1,"version":3,"content_hash":"y","screenplay":{"title":"v3","hook":"h","scenes":[{"no":1,"action":"冰箱爆炸了","dialogue":[]}]}}' \
    > "$DATA/projects/$PID/scripts/v3.json"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"storyboard.build","input":{"project_id":"$PID","script_version":3}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'ACTION_UNSUPPORTED', d
print('PASS: 越出能力表的动作在体检阶段被拒（ACTION_UNSUPPORTED）')" \
    || bad "动作体检没拦住"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P7 第一段（分镜生成 / 版本 / 时长口径）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
