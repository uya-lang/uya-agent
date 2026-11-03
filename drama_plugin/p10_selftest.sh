#!/bin/sh
# drama_plugin/p10_selftest.sh — P10 第一段（成片合成，mock 拼接）
#
# 覆盖 DRAMA_TODO §12 的一部分：
#   * 分镜 → 成片：按镜号顺序拼接镜头文件，产出 manifest（镜头数/时长/size/hash）；
#   * 确定性：同一份分镜同一批镜头 ⇒ 成片字节一致；
#   * 镜头文件缺失 ⇒ ASSEMBLY_MISSING_SHOT，不产出半成品；
#   * 合成不改 Canon。
#
# 用法：sh drama_plugin/p10_selftest.sh

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

out=$(ask '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"成片测试"}}}}')
PID=$(printf '%s' "$out" | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
[ -n "$PID" ] && ok "项目创建 id=$PID" || { bad "项目没建起来"; exit 1; }

# 剧本 → 分镜 → 镜头文件（走 worker 的 video 任务最省事）
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.generate","input":{"project_id":"$PID"}}}}
JSON
)" > /dev/null
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.approve","input":{"project_id":"$PID","script_version":1}}}}
JSON
)" > /dev/null
ask "$(cat <<JSON
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"$PID","episode_id":"e1","stage":"video"}}}}
JSON
)" > /dev/null
timeout 120 "$TMP/drama" worker run --data-dir "$DATA" > /dev/null 2>&1 || true

CANON_BEFORE=$(md5sum "$DATA/projects/$PID/canon.json" | cut -d' ' -f1)

# ---------- 1. 合成 ----------
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.assemble","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field > "$TMP/asm1.json"
python3 - "$TMP/asm1.json" "$DATA/projects/$PID" <<'PY'
import json
import os
import sys

d = json.load(open(sys.argv[1]))
base = sys.argv[2]
ok, fails = [], []


def check(c, m):
    (ok if c else fails).append(m)


check(d['assembly_version'] == 1, '首次合成得到 assembly v1')
check(d['shots'] > 0, 'manifest 里有镜头数')
check(d['duration_ms'] > 0, 'manifest 里有总时长')
out_path = os.path.join(base, 'assets', d['output'])
check(os.path.isfile(out_path), '成片文件写出来了')
if os.path.isfile(out_path):
    real = os.path.getsize(out_path)
    check(real == d['size'], '成片大小与 manifest 一致（%d B）' % real)
    shots = [f for f in os.listdir(os.path.join(base, 'assets'))
             if f.startswith('shot_')]
    total = sum(os.path.getsize(os.path.join(base, 'assets', f))
                for f in shots)
    check(real == total, '成片字节数 == 各镜头字节数之和')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# ---------- 2. 合成不改 Canon ----------
CANON_AFTER=$(md5sum "$DATA/projects/$PID/canon.json" | cut -d' ' -f1)
[ "$CANON_BEFORE" = "$CANON_AFTER" ] && ok "合成没有改动 Canon" \
    || bad "合成改了 Canon"

# ---------- 3. 确定性：再合成一次，内容 hash 一致 ----------
H1=$(python3 -c "
import json;print(json.load(open('$TMP/asm1.json'))['sha256'])")
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.assemble","input":{"project_id":"$PID"}}}}
JSON
)")
H2=$(printf '%s' "$out" | field | python3 -c "
import json,sys;print(json.load(sys.stdin)['sha256'])")
[ "$H1" = "$H2" ] && ok "同样输入再合成，成片 hash 一致（确定性）" \
    || bad "第二次合成的 hash 变了"

# ---------- 4. 镜头文件缺失 ----------
rm -f "$DATA/projects/$PID/assets/shot_2.mp4"
out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.assemble","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'ASSEMBLY_MISSING_SHOT', d
print('PASS: 镜头文件缺失 ⇒ ASSEMBLY_MISSING_SHOT')" \
    || bad "缺镜头没被拦住"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P10 第一段（成片合成）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
