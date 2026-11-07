#!/bin/sh
# drama_plugin/p10_selftest.sh — P10 第一段（成片合成，mock 拼接）
#
# 覆盖 DRAMA_TODO §12 的一部分：
#   * 分镜 → 成片：按镜号顺序拼接镜头文件，产出 manifest（镜头数/时长/size/hash）；
#   * 确定性：同一份分镜同一批镜头 ⇒ 成片字节一致；
#   * 镜头文件缺失 ⇒ ASSEMBLY_MISSING_SHOT，不产出半成品；补回镜头后重跑恢复；
#   * `shot.retry` 只重渲一镜并恢复文件；
#   * 合成不改 Canon，成片登记进资产账本（video/mp4），asset.get 可按名查回；

#   * `media.probe` 用 ffprobe 报宽高/时长，越界路径与缺失文件各有错误码；
#   * `media.encode` 按 format.encode 参数转码，产物可被 probe 读回；
#   * `media.subtitle` 按分镜时间轴生成 SRT，`media.mux` 混成 mov_text 字幕轨；
#   * `media.mix` 把音频轨混入成片，`media.loudnorm` 两遍归一。
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
    shots = []
    for dpath, _, files in os.walk(os.path.join(base, 'assets')):
        shots += [os.path.join(dpath, f) for f in files
                  if f.startswith('shot_')]
    total = sum(os.path.getsize(f) for f in shots)
    check(real == total, '成片字节数 == 各镜头字节数之和')
for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"asset.list","input":{"project_id":"$PID"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
hit=[x for x in d['assets'] if x['name']=='episode_1.mp4']
assert len(hit)==1, d
assert hit[0]['mime']=='video/mp4', hit
print('PASS: 成片已登记为 Asset（video/mp4）')" \
    || bad "成片没有登记成 Asset"

out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"asset.get","input":{"project_id":"$PID","name":"episode_1.mp4"}}}}
JSON
)")
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['asset']['mime'] == 'video/mp4', d
assert d['asset']['size'] > 0, d
assert d['path'] == 'projects/$PID/assets/episode_1.mp4', d
print('PASS: asset.get 返回成片元数据与共享路径')" \
    || bad "asset.get 查不到成片"

out=$(ask '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"asset.get","input":{"project_id":"'"$PID"'","name":"nope.mp4"}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'NOT_FOUND', d
print('PASS: asset.get 查不到 ⇒ NOT_FOUND')" \
    || bad "asset.get 缺失资产没被拦住"

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

# ---------- 3.5 单镜头重试 ----------
SHOT2="$DATA/projects/$PID/assets/v1/shot_2.mp4"
printf 'corrupt' > "$SHOT2"
out=$(ask '{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"call","arguments":{"operation":"shot.retry","input":{"project_id":"'"$PID"'","board_version":1,"sequence":2}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('shot_no') == 2, d
assert d.get('state') == 'done', d
print('PASS: shot.retry 只重渲第 2 镜')" \
    || bad "shot.retry 没成功"
S2=$(wc -c < "$SHOT2" | tr -d ' ')
[ "$S2" = "256" ] && ok "重试后镜头文件恢复为 256 B" \
    || bad "重试后镜头大小是 $S2"

out=$(ask '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"call","arguments":{"operation":"budget.limit","input":{"project_id":"'"$PID"'","max_renders":1}}}}')
out=$(ask '{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"call","arguments":{"operation":"shot.retry","input":{"project_id":"'"$PID"'","board_version":1,"sequence":2}}}}')
printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'BUDGET_EXCEEDED', d
print('PASS: 重试计入预算，超限即熔断')" \
    || bad "重试绕过了预算"

# ---------- 4. 镜头文件缺失 ----------
VICTIM=$(python3 -c "
import os
base = '$DATA/' + 'projects/$PID/assets'
for dpath, _, files in os.walk(base):
    for f in sorted(files):
        if f == 'shot_2.mp4':
            print(os.path.join(dpath, f))
            raise SystemExit
")
if [ -n "$VICTIM" ]; then cp "$VICTIM" "$TMP/victim.bak"; fi
rm -f "$VICTIM"
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

# ---------- 5. 补回镜头后从合成步骤恢复 ----------
if [ -n "$VICTIM" ] && [ -f "$TMP/victim.bak" ]; then
    cp "$TMP/victim.bak" "$VICTIM"
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.assemble","input":{"project_id":"$PID"}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('assembly_version') == 3, d
assert d.get('size', 0) > 0, d
print('PASS: 补回镜头后从合成步骤恢复（v3，失败不占版本）')" \
        || bad "合成失败后没能恢复"
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"call","arguments":{"operation":"asset.get","input":{"project_id":"$PID","name":"episode_3.mp4"}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['asset']['mime'] == 'video/mp4', d
print('PASS: 恢复后的成片也登记进资产账本')" \
        || bad "恢复后的成片没登记"
fi

# ---------- 5.4 字幕生成（按分镜时间轴） ----------
out=$(ask '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.subtitle","input":{"project_id":"'"$PID"'","board_version":1}}}}')
SUB=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('lines', 0) > 0, d
assert d.get('path', '').startswith('subtitles/v'), d
print(d['path'])")
if [ -n "$SUB" ] && [ -f "$DATA/projects/$PID/$SUB" ]; then
    grep -q -- '-->' "$DATA/projects/$PID/$SUB" \
        && ok "字幕文件含 SRT 时间轴（$SUB）" || bad "字幕没有时间轴"
    grep -q '谁把冰箱门开着' "$DATA/projects/$PID/$SUB" \
        && ok "字幕含台词文本" || bad "字幕缺台词"
else
    bad "字幕文件没生成"
fi

# ---------- 5.5 成片终检：文件截断 ⇒ ASSEMBLY_CORRUPT ----------
FILM="$DATA/projects/$PID/assets/episode_3.mp4"
if [ -f "$FILM" ]; then
    cp "$FILM" "$TMP/film.bak"
    : > "$FILM"
    out=$(ask '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.run","input":{"project_id":"'"$PID"'","script_version":1}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
codes={i['code'] for i in d.get('report',{}).get('issues',[])}
assert 'ASSEMBLY_CORRUPT' in codes, d
print('PASS: 成片被截断 ⇒ QA 报 ASSEMBLY_CORRUPT')" \
        || bad "成片截断没被 QA 发现"
    cp "$TMP/film.bak" "$FILM"
else
    bad "找不到 episode_3.mp4"
fi

# ---------- 成片终检：解码 + format 绑定 + 字幕对轴 ----------
code_of() { printf '%s' "$1" | field | python3 -c "
import json,sys
print(json.load(sys.stdin).get('code', 'OK'))"; }

if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    PV=$(ask '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"终检"}}}}' | field | python3 -c "
import json,sys
print(json.load(sys.stdin)['project_id'])")
    ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PV","bible":{"characters":[{"id":"dad"}],"format":{"canvas":"440x800","codec":"h264"}},"locks":{"dad":"短寸头"}}}}}
JSON
)" > /dev/null
    mkdir -p "$DATA/projects/$PV/assemblies" "$DATA/projects/$PV/subtitles"
    ffmpeg -v error -f lavfi -i testsrc=duration=2:size=440x800:rate=25 \
        -pix_fmt yuv420p "$DATA/projects/$PV/assemblies/ep.mp4" -y \
        >/dev/null 2>&1
    REL="projects/$PV/assemblies/ep.mp4"
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"$REL","expect_duration_ms":2000}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
names={c['name']: c['ok'] for c in d['checks']}
assert names.get('decode') is True, d
assert names.get('resolution') is True, d
assert names.get('codec') is True, d
assert names.get('duration') is True, d
assert d['ok'] is True, d
print('PASS: 成片终检通过（解码/分辨率/编码/时长都对上 format）')" \
        || bad "成片终检没通过"

    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"$REL","expect_duration_ms":9000}}}}
JSON
)")
    [ "$(code_of "$out")" = "FINAL_VERIFY_FAILED" ] \
        && ok "时长对不上 ⇒ FINAL_VERIFY_FAILED" \
        || bad "时长不符没被拒（$(code_of "$out")）"

    head -c 3000 "$DATA/projects/$PV/assemblies/ep.mp4" \
        > "$DATA/projects/$PV/assemblies/broken.mp4"
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"projects/$PV/assemblies/broken.mp4"}}}}
JSON
)")
    [ "$(code_of "$out")" = "IO_ERROR" ] \
        && ok "截断成片解不开 ⇒ IO_ERROR（不会当成好片放行）" \
        || bad "坏片没被拒（$(code_of "$out")）"

    printf '1\n00:00:00,000 --> 00:00:00,500\n你好\n' \
        > "$DATA/projects/$PV/subtitles/v1.srt"
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"$REL","board_version":1}}}}
JSON
)")
    [ "$(code_of "$out")" = "FINAL_VERIFY_FAILED" ] \
        && ok "字幕末条没贴住成片时长 ⇒ FINAL_VERIFY_FAILED" \
        || bad "字幕对轴不齐没被拒（$(code_of "$out")）"

    printf '1\n00:00:00,000 --> 00:00:01,980\n你好\n' \
        > "$DATA/projects/$PV/subtitles/v1.srt"
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"$REL","board_version":1}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
names={c['name']: c['ok'] for c in d['checks']}
assert names.get('subtitle_sync') is True, d
print('PASS: 字幕末条与成片时长对齐（±1s）')" || bad "字幕对轴没通过"    # 黑边 / 长静音段 / 片尾卡：三条新判据各来一个反例
    ffmpeg -v error -f lavfi -i "testsrc=size=440x760:duration=2:rate=25" \
        -vf pad=440:800:0:20 -pix_fmt yuv420p \
        "$DATA/projects/$PV/assemblies/bars.mp4" -y >/dev/null 2>&1
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"projects/$PV/assemblies/bars.mp4","expect_duration_ms":2000}}}}
JSON
)")
    [ "$(code_of "$out")" = "FINAL_VERIFY_FAILED" ] \
        && ok "上下留黑边 ⇒ FINAL_VERIFY_FAILED" \
        || bad "黑边没被拒（$(code_of "$out")）"

    ffmpeg -v error -f lavfi -i "testsrc=size=440x800:duration=2:rate=25" \
        -f lavfi -i "anullsrc=r=44100:cl=mono" -shortest \
        -pix_fmt yuv420p "$DATA/projects/$PV/assemblies/mute.mp4" -y \
        >/dev/null 2>&1
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"projects/$PV/assemblies/mute.mp4","expect_duration_ms":2000}}}}
JSON
)")
    [ "$(code_of "$out")" = "FINAL_VERIFY_FAILED" ] \
        && ok "整段静音 ⇒ FINAL_VERIFY_FAILED" \
        || bad "长静音段没被拒（$(code_of "$out")）"

    ffmpeg -v error -f lavfi -i "testsrc=size=440x800:duration=2:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=2" -shortest \
        -pix_fmt yuv420p "$DATA/projects/$PV/assemblies/tone.mp4" -y \
        >/dev/null 2>&1
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"projects/$PV/assemblies/tone.mp4","expect_duration_ms":2000}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
names={c['name']: c['ok'] for c in d['checks']}
assert names.get('no_letterbox') is True, d
assert names.get('no_long_silence') is True, d
print('PASS: 画面贴满 + 有声音 ⇒ 黑边/静音两条判据都过')" \
        || bad "正常片被误判成有黑边/静音"

    mkdir -p "$DATA/projects/$PV/boards"
    python3 - "$DATA/projects/$PV/boards/v2.json" \
        "$DATA/projects/$PV/boards/v3.json" <<'PY'
import json
import sys

base = {"format_version": 1, "source_script_version": 1, "shot_count": 2}
tail_card = {"shot_id": "s2", "sequence": 2, "scene": "片尾",
             "cut_type": "card"}
tail_cut = {"shot_id": "s2", "sequence": 2, "scene": "片尾",
            "cut_type": "hard_cut"}
head = {"shot_id": "s1", "sequence": 1, "scene": "客厅"}
for path, ver, tail in ((sys.argv[1], 2, tail_card),
                        (sys.argv[2], 3, tail_cut)):
    b = dict(base)
    b["version"] = ver
    b["shots"] = [head, tail]
    open(path, "w").write(json.dumps(b, ensure_ascii=False))
PY
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"$REL","board_version":3}}}}
JSON
)")
    [ "$(code_of "$out")" = "FINAL_VERIFY_FAILED" ] \
        && ok "最后一镜不是片尾卡 ⇒ FINAL_VERIFY_FAILED" \
        || bad "片尾卡缺失没被拒（$(code_of "$out")）"
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"final.verify","input":{"project_id":"$PV","path":"$REL","board_version":2}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
names={c['name']: c['ok'] for c in d['checks']}
assert names.get('end_card') is True, d
print('PASS: 最后一镜是 card ⇒ 片尾卡判据过')" \
        || bad "片尾卡没通过"

    # 锚帧接戏差：上一镜末帧 vs 这一镜首帧
    mkdir -p "$DATA/projects/$PV/boards" "$DATA/projects/$PV/assets/v1"
    python3 - "$DATA/projects/$PV/boards/v1.json" <<'PY'
import json
import sys

shots = [{"sequence": i, "scene": "living_room", "cut_type": "anchor"}
         for i in (1, 2, 3)]
board = {"format_version": 1, "version": 1, "source_script_version": 1,
         "shot_count": 3, "shots": shots}
open(sys.argv[1], "w").write(json.dumps(board, ensure_ascii=False))
PY
    for n in 1 2 3; do
        ffmpeg -v error -f lavfi \
            -i "color=c=blue:duration=1:size=160x160:rate=10" \
            -pix_fmt yuv420p "$DATA/projects/$PV/assets/v1/shot_$n.mp4" -y \
            >/dev/null 2>&1
    done
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"shot.anchor","input":{"project_id":"$PV","board_version":1}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['checked'] == 2 and d['passed'] == 2, d
assert d['ok'] is True, d
print('PASS: 相邻两镜首末帧一致 ⇒ 锚帧接戏检查通过（%d 处）' % d['checked'])" \
        || bad "锚帧接戏检查没通过"

    ffmpeg -v error -f lavfi -i "color=c=red:duration=1:size=160x160:rate=10" \
        -pix_fmt yuv420p "$DATA/projects/$PV/assets/v1/shot_3.mp4" -y \
        >/dev/null 2>&1
    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"shot.anchor","input":{"project_id":"$PV","board_version":1}}}}
JSON
)")
    [ "$(code_of "$out")" = "ANCHOR_JUMP" ] \
        && ok "上一镜末帧与这一镜首帧差太多 ⇒ ANCHOR_JUMP" \
        || bad "接戏差没被拒（$(code_of "$out")）"

    out=$(ask "$(cat <<JSON
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"shot.anchor","input":{"project_id":"$PV","board_version":1,"threshold_db":5}}}}
JSON
)")
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['ok'] is True, d
assert d['threshold_db'] == 5, d
print('PASS: 阈值可调（5 dB 下设成通过，判据不写死）')" \
        || bad "阈值参数没生效"

fi

# ---------- 媒体输入探测（ffprobe） ----------
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    mkdir -p "$DATA/probe"
    ffmpeg -v error -f lavfi -i testsrc=duration=1:size=320x240:rate=10 \
        -pix_fmt yuv420p -c:v mpeg4 "$DATA/probe/clip.mp4" -y \
        >/dev/null 2>&1
    out=$(ask '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.probe","input":{"path":"probe/clip.mp4"}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('width') == 320, d
assert d.get('height') == 240, d
assert 900 <= d.get('duration_ms', 0) <= 1100, d
assert d.get('tool') == 'ffprobe', d
assert d.get('version', '').startswith('ffprobe version'), d
assert d.get('ffmpeg_version', '').startswith('ffmpeg version'), d
assert '-select_streams v:0' in d.get('args', ''), d
print('PASS: media.probe 报出宽高/时长/版本/参数（320x240，约 1s）')" \
        || bad "media.probe 结果不对"

    out=$(ask '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.probe","input":{"path":"probe/clip.mp4","expect_width":320,"expect_height":240,"expect_duration_ms":1000}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('width') == 320, d
print('PASS: 期望宽高/时长一致时探测通过')" \
        || bad "期望值一致却报错"

    out=$(ask '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.probe","input":{"path":"probe/clip.mp4","expect_width":1920}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'MEDIA_MISMATCH', d
print('PASS: 分辨率不符 ⇒ MEDIA_MISMATCH')" \
        || bad "分辨率不符没被拦住"

    out=$(ask '{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.encode","input":{"path":"probe/clip.mp4","output":"enc1.mp4"}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('output') == 'encodes/enc1.mp4', d
assert d.get('size', 0) > 0, d
print('PASS: media.encode 产出 %s（%d B）' % (d['output'], d['size']))" \
        || bad "media.encode 没产出"

    out=$(ask '{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.probe","input":{"path":"encodes/enc1.mp4"}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('width') == 320, d
assert d.get('height') == 240, d
assert 900 <= d.get('duration_ms', 0) <= 1100, d
print('PASS: 转码产物可被 media.probe 读回')" \
        || bad "转码产物不可读"

    out=$(ask '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.mux","input":{"video":"encodes/enc1.mp4","subtitle":"projects/'"$PID"'/subtitles/v1.srt","output":"mux1.mp4"}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('output') == 'encodes/mux1.mp4', d
assert d.get('size', 0) > 0, d
print('PASS: media.mux 产出 %s（%d B）' % (d['output'], d['size']))" \
        || bad "media.mux 没产出"
    SUB_CODEC=$(ffprobe -v error -select_streams s -show_entries stream=codec_name \
        -of csv=p=0 "$DATA/encodes/mux1.mp4" 2>/dev/null | head -1)
    [ "$SUB_CODEC" = "mov_text" ] && ok "成片含 mov_text 字幕轨" \
        || bad "字幕轨是 $SUB_CODEC"

    ffmpeg -v error -f lavfi -i sine=frequency=440:duration=1 \
        -c:a pcm_s16le "$DATA/probe/tone.wav" -y >/dev/null 2>&1
    out=$(ask '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.mix","input":{"video":"encodes/enc1.mp4","audio":"probe/tone.wav","output":"mix1.mp4"}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('output') == 'encodes/mix1.mp4', d
assert d.get('size', 0) > 0, d
print('PASS: media.mix 产出 %s（%d B）' % (d['output'], d['size']))" \
        || bad "media.mix 没产出"
    AUD_CODEC=$(ffprobe -v error -select_streams a -show_entries stream=codec_name \
        -of csv=p=0 "$DATA/encodes/mix1.mp4" 2>/dev/null | head -1)
    [ "$AUD_CODEC" = "aac" ] && ok "混入音轨是 aac" || bad "音轨是 $AUD_CODEC"

    out=$(ask '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.loudnorm","input":{"path":"encodes/mix1.mp4","output":"loud1.mp4"}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('output') == 'encodes/loud1.mp4', d
assert d.get('size', 0) > 0, d
print('PASS: media.loudnorm 产出 %s（%d B）' % (d['output'], d['size']))" \
        || bad "media.loudnorm 没产出"
    LOUD_CODEC=$(ffprobe -v error -select_streams a -show_entries stream=codec_name \
        -of csv=p=0 "$DATA/encodes/loud1.mp4" 2>/dev/null | head -1)
    [ "$LOUD_CODEC" = "aac" ] && ok "响度归一产物保留 aac 音轨" \
        || bad "归一产物音轨是 $LOUD_CODEC"

    ffmpeg -hide_banner -nostats -i "$DATA/encodes/loud1.mp4" \
        -af loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json -f null - \
        2> "$TMP/loud.meas" >/dev/null
    python3 - "$TMP/loud.meas" <<'PY'
import re, sys
s = open(sys.argv[1], errors='replace').read()
m = re.search(r'"input_i"\s*:\s*"(-?[0-9.]+)"', s)
assert m, s[-300:]
i = float(m.group(1))
assert -17.5 <= i <= -14.5, i
print('PASS: 归一后整体响度 I=%.2f LUFS（目标 -16）' % i)
PY
    [ $? -eq 0 ] || fails=$((fails + 1))

    out=$(ask '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.probe","input":{"path":"../etc/passwd"}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'SCHEMA_INVALID', d
print('PASS: 越出数据根 ⇒ SCHEMA_INVALID')" \
        || bad "越界路径没被拦住"

    out=$(ask '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"call","arguments":{"operation":"media.probe","input":{"path":"probe/nope.mp4"}}}}')
    printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('code') == 'IO_ERROR', d
print('PASS: 文件不存在 ⇒ IO_ERROR')" \
        || bad "缺失文件没被拦住"
else
    echo "SKIP: 没有 ffmpeg/ffprobe，跳过 media.probe"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P10 第一段（成片合成）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
