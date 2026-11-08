#!/bin/sh
# drama_plugin/p7_selftest.sh — P7 第一段（分镜生成 / 版本 / 时长口径）
#
# 覆盖 DRAMA_TODO §9 的一部分：
#   * 剧本 → 分镜是确定性的：同一份剧本重复 build 复用同一版本；
#   * 每个镜头有 shot_id / sequence / scene / framing / camera / audio / action / cut_type /
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

# ---------- 2b. ASR 对齐：转录文本按台词逐镜比对 ----------
python3 - "$DATA/projects/$PID/boards/v1.json" \
    "$DATA/projects/$PID/asr.txt" <<'PY'
import json
import sys

board = json.load(open(sys.argv[1]))
board = board.get('board', board)
lines = [s['line'] for s in board['shots'] if s.get('line')]
open(sys.argv[2], 'w').write('\n'.join(lines) + '\n')
PY
[ $? -eq 0 ] || fails=$((fails + 1))

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.align","input":{"project_id":"$PID","transcript":"asr.txt"}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/align1.json"
python3 - "$TMP/align1.json" "$DATA/projects/$PID/boards/v1.json" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
b = b.get('board', b)
lines = [s['line'] for s in b['shots'] if s.get('line')]
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


check(d.get('ok') is True, '转录与台词一致 ⇒ ok')
check(d.get('checked') == len(lines), '逐镜比对条数 == 对白镜头数')
check(d.get('min_pct') == 100, '完全一致 ⇒ min_pct=100')
check(all(s['source'].get('events') for s in b['shots']),
      '镜头都追到剧本事件（source.events 非空）')
check(all(e >= 0 for s in b['shots'] for e in s['source']['events']),
      '事件下标合法')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

python3 - "$DATA/projects/$PID/asr.txt" <<'PY'
import sys

lines = open(sys.argv[1]).read().split('\n')
lines[0] = '这句和台词完全不一样'
open(sys.argv[1], 'w').write('\n'.join(lines))
PY
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.align","input":{"project_id":"$PID","transcript":"asr.txt"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['ok'] is False, d
assert any(m['shot'] == 2 for m in d['mismatches']), d
assert d['min_pct'] < 85, d
print('PASS: 台词被改 ⇒ 第 2 镜不达标（%d%%）' % d['min_pct'])" \
    || bad "改台词后没报不达标"

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
check(all(isinstance(s.get('camera'), dict) and
           s['camera'].get('move') == 'static' for s in shots),
      '每镜有 camera.move=static')
check(all(s.get('audio', {}).get('has_dialogue') == bool(s.get('line'))
          for s in shots), 'audio.has_dialogue 与台词一致')
check(shots[0]['cut_type'] == 'anchor', '首镜是 anchor')
check(all(s['cut_type'] == 'hard_cut' for s in shots[1:]),
      '其余镜头是 hard_cut')
check(shots[0]['timeline_in'] == 0, '首镜从 0 开始')
gaps = [s for a, s in zip(shots, shots[1:])
        if s['timeline_in'] != a['timeline_out']]
check(not gaps, 'timeline 首尾相接（没有空档/重叠）')
check(all(s['scene'] for s in shots), '每个镜头都有场景 ID')
src = [s.get('source', {}) for s in shots]
check(all(x.get('script_version') == 1 for x in src),
      '每个镜头都记了来源剧本版本（可回溯）')
check(all(x.get('shot') == s['sequence'] for x, s in zip(src, shots)),
      'source.shot 与该镜 sequence 一致')
check([s['beat'] for s in shots] == sorted(s['beat'] for s in shots)
      and shots[0]['beat'] == 1 and shots[-1]['beat'] >= 2,
      '镜头按剧本段落（beat）单调递增，可追到第几段')
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

# ---------- 镜头状态进出 / 迁移 / 引用固定资产版本 ----------
PSS=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":70,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"状态进出"}}}}
JSON
)" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":71,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PSS","bible":{"characters":[{"id":"dad"},{"id":"kid"}]},"locks":{"dad":"短寸头，深灰夹克","kid":"马尾，校服"}}}}}
JSON
)" > /dev/null
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":72,"method":"tools/call","params":{"name":"call","arguments":{"operation":"canon.commit","input":{"project_id":"$PSS","base_revision":0,"events":[{"type":"scene.define","scene":"living_room"},{"type":"scene.define","scene":"kitchen"},{"type":"character.place","character":"dad","scene":"living_room"},{"type":"character.place","character":"kid","scene":"kitchen"}]}}}}
JSON
)" > /dev/null
mkdir -p "$DATA/projects/$PSS/boards"
python3 - "$DATA/projects/$PSS/boards/v1.json" <<'PY'
import json
import sys

shots = [
    {"shot_id": "s1", "sequence": 1, "scene": "living_room",
     "cut_type": "anchor", "who": "dad"},
    {"shot_id": "s2", "sequence": 2, "scene": "kitchen",
     "cut_type": "hard_cut"},
    {"shot_id": "s3", "sequence": 3, "scene": "kitchen",
     "cut_type": "hard_cut", "who": "kid"},
]
board = {"format_version": 1, "version": 1, "source_script_version": 1,
         "shot_count": 3, "shots": shots}
open(sys.argv[1], "w").write(json.dumps(board, ensure_ascii=False))
PY
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":73,"method":"tools/call","params":{"name":"call","arguments":{"operation":"shot.state","input":{"project_id":"$PSS","board_version":1}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
s1, s2 = d['shots'][0], d['shots'][1]
assert s1['state_out']['characters'] == ['dad'], s1
assert s2['state_out']['characters'] == ['kid'], s2
assert s2['transition']['added_characters'] == ['kid'], s2
assert s2['transition']['removed_characters'] == ['dad'], s2
assert s2['state_in']['characters'] == ['dad'], s2
assert d['continuity_breaks'] == 0, d
print('PASS: 镜头状态进出与迁移（dad 出、kid 进）都对上了')" \
    || bad "镜头状态进出不对"

printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
ref = d['shots'][0]['references']['characters'][0]
assert ref['id'] == 'dad', ref
assert len(ref['frozen_hash']) == 12, ref
assert ref['asset_version'] == d['bible_version'], ref
s2 = d['shots'][1]['references']['characters'][0]
assert s2['frozen_hash'] != ref['frozen_hash'], (ref, s2)
print('PASS: 引用固定资产版本（Bible v%d + 冻结文本 hash 前 12 位，逐人不同）'
      % d['bible_version'])" || bad "固定资产引用不对"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":75,"method":"tools/call","params":{"name":"call","arguments":{"operation":"provider.refs","input":{"project_id":"$PSS","board_version":1,"shot":2}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['shot'] == 2, d
assert d['ref_count'] == 1, d
r = d['refs'][0]
assert r['order'] == 0, r
assert r['role'] == 'character', r
assert r['id'] == 'kid', r
assert r['slot'] == 'first_frame', r
assert r['frame_index'] == 0, r
assert len(r['frozen_hash']) == 12, r
print('PASS: 参考素材参数转换（顺序 + 首帧槽位 + 冻结 hash）')" \
    || bad "参考素材参数转换不对"

python3 - "$DATA/projects/$PSS/boards/v1.json" <<'PY'
import json
import sys

p = sys.argv[1]
b = json.load(open(p))
b['shots'][1]['who'] = 'mom'    # 厨房里没有 mom
json.dump(b, open(p, 'w'), ensure_ascii=False)
PY
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":74,"method":"tools/call","params":{"name":"call","arguments":{"operation":"shot.state","input":{"project_id":"$PSS","board_version":1}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'CONTINUITY_BREAK', d
print('PASS: 说话人不在这一镜的场景里 ⇒ CONTINUITY_BREAK')" \
    || bad "说话人不在场没被拒"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P7 第一段（分镜生成 / 版本 / 时长口径）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
