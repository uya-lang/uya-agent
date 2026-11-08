#!/usr/bin/env bash
# P17：pipeline.capacity —— 从真实产线日志算产能，再和 DESIGN §0.3 基线比。
# 用合成日志（数字手算得出）验证解析口径：提交数 / 完成数 / 镜数 / 每镜均值 /
# 重做率 / 一集总工时 / 百集外推 / 与基线的误差。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/src/store.uya $HERE/src/bytes.uya $HERE/src/json.uya \
$HERE/src/ops.uya $HERE/src/canon.uya $HERE/src/story.uya \
$HERE/src/registry.uya $HERE/src/dispatch.uya $HERE/src/media.uya \
$HERE/src/media_ops.uya $HERE/src/bible.uya $HERE/src/qa.uya \
$HERE/src/audit.uya $HERE/src/task.uya $HERE/src/worker.uya \
$HERE/src/llm.uya $HERE/src/provider.uya $HERE/src/server.uya \
$HERE/src/index.uya $HERE/src/verify_ops.uya $HERE/src/queue_ops.uya \
$HERE/src/pipeline_ops.uya $HERE/src/vision_ops.uya"
UYA=${UYA:-$HERE/../uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$HERE/../uya/stdlib}
TMP=$(mktemp -d /tmp/p17.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"
FAILS=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

echo "== 构建"
if ! bash "$HERE/build.sh" > "$TMP/build.log" 2>&1; then
    tail -20 "$TMP/build.log"
    echo "FAIL: 构建失败"
    exit 1
fi
BIN="$HERE/../build/drama"
[ -x "$BIN" ] || { echo "FAIL: 没有 $BIN"; exit 1; }
ok "构建通过"

field() {
    python3 -c '
import json
import sys

line = sys.stdin.read().strip()
d = json.loads(line)
print(d["result"]["content"][0]["text"])'
}

cap() {
    root="$1"
    ep="$2"
    printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"pipeline.capacity","input":{"pipeline_root":"%s","episode":"%s"}}}}\n' \
        "$root" "$ep" > "$TMP/req.jsonl"
    "$BIN" mcp serve --data-dir "$DATA" < "$TMP/req.jsonl" 2>/dev/null \
        | tail -1 | field
}

mkdir -p "$DATA"

# 合成日志：3 镜、5 次提交、4 次完成，用时 10.5 / 12.25 / 8 / 20 分钟
ROOT="$TMP/pl"
mkdir -p "$ROOT/ep1"
cat > "$ROOT/ep1/build.log" <<'LOG'
[10:00:00] shot1 已提交 prompt_id=a 帧数=158  448x800
[10:10:30] shot1 完成，用时 10.5 分钟 → shot01.mp4
[11:00:00] shot2 已提交 prompt_id=b 帧数=73  448x800
[11:12:15] shot2 完成，用时 12.25 分钟 → shot02.mp4
[12:00:00] shot3 已提交 prompt_id=c 帧数=107  448x800
[12:08:00] shot3 完成，用时 8 分钟 → shot03.mp4
[13:00:00] shot3 已提交 prompt_id=d 帧数=107  448x800
[13:20:00] shot3 完成，用时 20 分钟 → shot03.mp4
[14:00:00] shot2 已提交 prompt_id=e 帧数=73  448x800
LOG
ok "合成日志就位（3 镜 / 5 提交 / 4 完成 / 合计 50.75 分钟）"

cap "$ROOT" "ep1" | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["runs"] == 5, d
assert d["finished"] == 4, d
assert d["shots"] == 3, d
# 50.75 分钟 = 3045000 ms，均值 761250 ms
assert d["episode_gpu_ms"] == 3045000, d
assert d["mean_shot_ms"] == 761250, d
# 5 / 3 = 1.666x
assert d["redo_rate_milli"] == 1666, d
# 一次过口径：761250 * 3 = 2283750
assert d["ideal_episode_gpu_ms"] == 2283750, d
print("PASS: 解析口径对（5 提交 / 4 完成 / 3 镜 / 合计 50.75 min / 重做 1.666x）")' \
    || bad "提交数/完成数/镜数/工时口径不对"

cap "$ROOT" "ep1" | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
p = d["projection"]
assert p["baseline_gpu_hours_milli"] == 292000, p
# 3045000 ms/集 × 100 集 / 3600 = 84583 毫小时（含重做）
assert p["gpu_hours_milli"] == 84583, p
# 2283750 × 100 / 3600 = 63437 毫小时（无重做）
assert p["ideal_gpu_hours_milli"] == 63437, p
# |84583 - 292000| / 292000 = 710‰
assert p["error_pct_milli"] == 710, p
print("PASS: 百集外推对（含重做 84.6 GPU h / 无重做 63.4 GPU h / 偏差 71%%）")' \
    || bad "百集外推口径不对"

# 小数分钟要按 60 进制进位：12.25 分钟 = 735 s，不是 12250 ms 那种读法
cap "$ROOT" "ep1" | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
# 单条 12.25 min 必须落在日志里（总时长已经包含它，这里用均值反推）
assert d["mean_shot_ms"] % 1000 == 250, d
print("PASS: 小数分钟按真分钟解析（均值尾数 .25 s）")' \
    || bad "小数分钟解析不对"

# 空日志 / 没有提交行
mkdir -p "$ROOT/empty"
: > "$ROOT/empty/build.log"
cap "$ROOT" "empty" | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["measured"] is False, d
assert d["runs"] == 0 and d["finished"] == 0 and d["shots"] == 0, d
print("PASS: 空日志不瞎报（measured=false，各项为 0）")' \
    || bad "空日志口径不对"

# 日志不存在
printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"pipeline.capacity","input":{"pipeline_root":"%s","episode":"nope"}}}}\n' \
    "$ROOT" > "$TMP/req.jsonl"
"$BIN" mcp serve --data-dir "$DATA" < "$TMP/req.jsonl" 2>/dev/null | tail -1 \
    | field | python3 -c '
import json
import sys

d = json.load(sys.stdin)
assert d["success"] is False, d
assert d["error"]["code"] == "IO_ERROR", d
print("PASS: 日志不存在时报 IO_ERROR")' \
    || bad "日志不存在时没报错"

# 真日志（本机有就跑一遍，验证大日志也能解析）
REAL="/home/winger/ersunfu/micro-drama/顶楼误闯/第001集/build.log"
if [ -f "$REAL" ]; then
    cap "/home/winger/ersunfu/micro-drama/顶楼误闯" "第001集" | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["measured"] is True, d
assert d["shots"] == 9, d
assert d["finished"] >= 9, d
assert d["runs"] >= d["finished"], d
assert d["mean_shot_ms"] > 300000, d
print("PASS: 真产线日志（%d KB）解析出 %d 提交 / %d 完成 / %d 镜 / 每镜 %.1f 分钟"
      % (d["bytes"] // 1024, d["runs"], d["finished"], d["shots"],
         d["mean_shot_ms"] / 60000.0))' \
        || bad "真产线日志解析不对"
else
    ok "本机没有真产线日志，跳过（合成用例已覆盖）"
fi

echo "----"
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: P17（pipeline.capacity：提交/完成/镜数/均值/重做率/百集外推）"
    exit 0
fi
echo "FAIL: $FAILS 项"
exit 1
