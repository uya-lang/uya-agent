#!/usr/bin/env bash
# 真机验收（可选，进不了 CI）：把既有产线当 VideoProvider，跑一遍真产线入口。
#
#   bash drama_plugin/real_gpu_check.sh            # 只跑不占 GPU 的入口（lint/dry）
#   REAL_SHOT=1 bash drama_plugin/real_gpu_check.sh # 再真生成一镜（6–15 分钟）
#
# 环境：
#   EP_DIR   既有产线的一集（默认 ~/ersunfu/micro-drama/顶楼误闯/第001集）
#   H3_HOST  ComfyUI 地址（默认 http://127.0.0.1:8188）
#   REAL_SHOT 要真生成的镜号（不给就只跑 lint/dry）
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
EP_DIR=${EP_DIR:-$HOME/ersunfu/micro-drama/顶楼误闯/第001集}
H3_HOST=${H3_HOST:-http://127.0.0.1:8188}
BIN="$HERE/../build/drama"
DATA=$(mktemp -d /tmp/realgpu.XXXXXX)
trap 'rm -rf "$DATA"' EXIT
FAILS=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

[ -d "$EP_DIR" ] || { echo "FAIL: 找不到产线目录 $EP_DIR"; exit 1; }
EP_NAME=$(basename "$EP_DIR")
EP_ROOT=$(dirname "$EP_DIR")
echo "== 产线：$EP_ROOT / $EP_NAME"

echo "== 构建"
if ! bash "$HERE/build.sh" > "$DATA/build.log" 2>&1; then
    tail -20 "$DATA/build.log"
    echo "FAIL: 构建失败"
    exit 1
fi
ok "构建通过（$BIN）"

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

# 1) 静态体检：不占 GPU，1 秒内回
call pipeline.run "{\"pipeline_root\":\"$EP_ROOT\",\"episode\":\"$EP_NAME\",\"entry\":\"lint\"}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["ok"] is True and d["exit_code"] == 0, d
assert "镜" in d["log_tail"], d
print("PASS: 真产线静态体检过（%s）" % d["log_tail"].strip().splitlines()[0])' \
    || { bad "lint 没过"; exit 1; }

# 2) 只看计划：校验画布与帧数网格，不提交 GPU 任务
call pipeline.run "{\"pipeline_root\":\"$EP_ROOT\",\"episode\":\"$EP_NAME\",\"entry\":\"generate\",\"dry\":true}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["ok"] is True and d["exit_code"] == 0, d
assert d["products"] == [], d
assert d["log_tail"].strip(), d
print("PASS: run_shots --dry 过（不产文件，计划在日志里）")' \
    || bad "dry 没过"

# 3) 真生成一镜（可选）
if [ -n "${REAL_SHOT:-}" ]; then
    echo "== 真生成镜 $REAL_SHOT（6–15 分钟，ComfyUI 在 $H3_HOST）"
    if ! timeout 5 curl -s -o /dev/null "$H3_HOST/system_stats"; then
        bad "ComfyUI 不在 $H3_HOST，跳过真生成"
    else
        call pipeline.run "{\"pipeline_root\":\"$EP_ROOT\",\"episode\":\"$EP_NAME\",\"entry\":\"generate\",\"shot\":$REAL_SHOT,\"timeout_s\":2400}" \
            > "$DATA/shot.json"
        python3 - "$DATA/shot.json" "$REAL_SHOT" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))["data"]["result"]
assert d["ok"] is True, d
by = {p["path"].split("/")[-1]: p["bytes"] for p in d["products"]}
n = int(sys.argv[2])
mp4 = "shot%02d.mp4" % n
assert mp4 in by and by[mp4] > 50000, by
assert "last.png" in by and by["last.png"] > 1000, by
assert "done.json" in by, by
print("PASS: 真生成镜 %d 完成：%s %.0f KB / last.png %.0f KB / 用时 %d s"
      % (n, mp4, by[mp4] / 1024.0, by["last.png"] / 1024.0, d["seconds"]))
print("      日志尾部：%s" % d["log_tail"].strip().splitlines()[-1])
PY
        [ $? -eq 0 ] || bad "真生成那镜没过"
    fi
else
    ok "没给 REAL_SHOT，跳过真生成（省 GPU）"
fi

# 4) 产能口径：同一条日志算出来的数字要能复现
call pipeline.capacity "{\"pipeline_root\":\"$EP_ROOT\",\"episode\":\"$EP_NAME\"}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["measured"] is True, d
assert d["shots"] >= 1, d
print("PASS: 产能口径可算：%d 提交 / %d 完成 / %d 镜 / 每镜 %.1f 分钟 / "
      "重做 %.2fx / 百集 %.0f GPU h"
      % (d["runs"], d["finished"], d["shots"], d["mean_shot_ms"] / 60000.0,
         d["redo_rate_milli"] / 1000.0,
         d["projection"]["gpu_hours_milli"] / 1000.0))' \
    || bad "产能口径算不出来"

echo "----"
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: 真机验收（lint / dry / [REAL_SHOT] / capacity）"
    exit 0
fi
echo "FAIL: $FAILS 项"
exit 1
