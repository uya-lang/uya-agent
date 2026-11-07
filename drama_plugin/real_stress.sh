#!/usr/bin/env bash
# 真实产线压力（可选，需真产线目录）：把 N 集逐集过一遍
#   复制一集 → lint → [真生成] → cards → build → media.probe
# 全部经 `pipeline.run` / `media.probe`，跑的是真产线脚本与真 mp4。
#
#   EPISODES=2 bash drama_plugin/real_stress.sh          # 复用已有镜头（不占 GPU）
#   EPISODES=1 REUSE=0 bash drama_plugin/real_stress.sh  # 真生成（6–20 分钟/镜）
#
# 环境：
#   EP_SRC  样板集目录（默认 ~/ersunfu/micro-drama/顶楼误闯/第001集）
#   EPISODES 集数（默认 2）
#   REUSE   1 = 复用样板集已生成的 shots/（默认 1）
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
EP_SRC=${EP_SRC:-$HOME/ersunfu/micro-drama/顶楼误闯/第001集}
EPISODES=${EPISODES:-2}
REUSE=${REUSE:-1}
BIN="$HERE/../build/drama"
WORK=$(mktemp -d /tmp/realstress.XXXXXX)
DATA="$WORK/data"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

[ -d "$EP_SRC" ] || { echo "FAIL: 找不到样板集 $EP_SRC"; exit 1; }
echo "== 样板集：$EP_SRC（$EPISODES 集，REUSE=$REUSE）"
if ! bash "$HERE/build.sh" > "$WORK/build.log" 2>&1; then
    tail -20 "$WORK/build.log"
    echo "FAIL: 构建失败"
    exit 1
fi
ok "构建通过"

call() {
    op="$1"
    input="$2"
    printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"%s","input":%s}}}\n' \
        "$op" "$input" > "$DATA/req.jsonl"
    "$BIN" mcp serve --data-dir "$DATA" < "$DATA/req.jsonl" 2>/dev/null \
        | tail -1 | python3 -c '
import json
import sys

d = json.loads(sys.stdin.read().strip())
print(d["result"]["content"][0]["text"])'
}

mkdir -p "$DATA/projects/p_stress/assets"
T0=$(date +%s)
i=1
while [ "$i" -le "$EPISODES" ]; do
    ep="ep$i"
    cp -a "$EP_SRC" "$WORK/$ep"
    rm -rf "$WORK/$ep/成片" "$WORK/$ep/cards"
    mkdir -p "$WORK/$ep/成片"
    if [ "$REUSE" != "1" ]; then
        rm -rf "$WORK/$ep/shots"
        mkdir -p "$WORK/$ep/shots"
    fi
    # lint
    call pipeline.run "{\"pipeline_root\":\"$WORK\",\"episode\":\"$ep\",\"entry\":\"lint\"}" \
        | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["ok"] is True, d' || bad "$ep lint 没过"
    # 真生成（可选）
    if [ "$REUSE" != "1" ]; then
        call pipeline.run "{\"pipeline_root\":\"$WORK\",\"episode\":\"$ep\",\"entry\":\"generate\",\"timeout_s\":7200}" \
            | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["ok"] is True, d
print("     %s 生成完毕，用时 %d s" % ("'"$ep"'", d["seconds"]))' \
            || bad "$ep 生成没过"
    fi
    # 卡片 + 成片
    call pipeline.run "{\"pipeline_root\":\"$WORK\",\"episode\":\"$ep\",\"entry\":\"cards\"}" \
        | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["ok"] is True, d' || bad "$ep cards 没过"
    call pipeline.run "{\"pipeline_root\":\"$WORK\",\"episode\":\"$ep\",\"entry\":\"build\"}" \
        | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["ok"] is True, d' || bad "$ep build 没过"
    FILM=$(ls "$WORK/$ep"/成片/*.mp4 2>/dev/null | head -1)
    if [ -z "${FILM:-}" ]; then
        bad "$ep 没出成片"
    else
        cp "$FILM" "$DATA/projects/p_stress/assets/$ep.mp4"
        call media.probe "{\"path\":\"projects/p_stress/assets/$ep.mp4\"}" \
            | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["width"] > 0 and d["duration_ms"] > 30000, d
print("     '"$ep"' 成片 %dx%d / %d ms" % (d["width"], d["height"],
                                            d["duration_ms"]))' \
            || bad "$ep 成片探针不过"
        ok "$ep 出片并复探通过（$(basename "$FILM")）"
    fi
    i=$((i + 1))
done
T1=$(date +%s)

# 汇总：集数 / 时长 / 总量 / 墙钟
python3 - "$DATA/projects/p_stress/assets" "$EPISODES" "$((T1 - T0))" <<'PY'
import glob
import os
import subprocess
import sys

d, n, wall = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
films = sorted(glob.glob(os.path.join(d, "*.mp4")))
assert len(films) == n, (len(films), n)
total = sum(os.path.getsize(f) for f in films)


def dur(p):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                          "format=duration", "-of", "csv=p=0", p],
                         capture_output=True, text=True).stdout.strip()
    return float(out)


durs = [dur(f) for f in films]
assert all(55 <= x <= 65 for x in durs), durs
print("PASS: %d 集全部出片：合计 %.1f MB / 片长 %.2f–%.2f s / 墙钟 %d s"
      % (n, total / 1048576.0, min(durs), max(durs), wall))
PY
[ $? -eq 0 ] || bad "汇总口径不对"

echo "----"
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: 真产线压力（$EPISODES 集：lint → [生成] → cards → build → probe）"
    exit 0
fi
echo "FAIL: $FAILS 项"
exit 1
