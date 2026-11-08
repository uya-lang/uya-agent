#!/usr/bin/env bash
# P18：qa.appearance —— 人物外观/服装检查（模型辅助）+ 外观锚帧比对（PSNR 门）。
# 用 ffmpeg 造的图验证像素门；用一个假的本机 VLM（python http.server）验证
# 模型侧的口径（OK / DRIFT / 超时 / 没配置）。真机有 VLM 时再跑一遍真的。
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
TMP=$(mktemp -d /tmp/p18.XXXXXX)
trap 'rm -rf "$TMP"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT
DATA="$TMP/data"
PROJ="p_abcd1234"
ASSETS="$DATA/projects/$PROJ/assets"
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

d = json.loads(sys.stdin.read().strip())
print(d["result"]["content"][0]["text"])'
}

# app <json-input>
app() {
    printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"qa.appearance","input":%s}}}\n' \
        "$1" > "$TMP/req.jsonl"
    "$BIN" mcp serve --data-dir "$DATA" < "$TMP/req.jsonl" 2>/dev/null \
        | tail -1 | field
}

mkdir -p "$ASSETS"
IMG="projects/$PROJ/assets"
# 三张 448×800 的图：base（纯色渐变）/ same（同一张）/ other（另一种）
ffmpeg -v error -y -f lavfi -i "color=c=0x223344:s=448x800" -frames:v 1 \
    "$ASSETS/base.png" 2>/dev/null
cp "$ASSETS/base.png" "$ASSETS/same.png"
ffmpeg -v error -y -f lavfi -i "color=c=0xddccbb:s=448x800" -frames:v 1 \
    "$ASSETS/other.png" 2>/dev/null
[ -s "$ASSETS/base.png" ] || { echo "FAIL: 造图失败"; exit 1; }
ok "测试图就位（448×800：base / same / other）"

# 1) 同一张图：PSNR 无穷大，过门
app "{\"project_id\":\"$PROJ\",\"image\":\"$IMG/same.png\",\"baseline\":\"$IMG/base.png\",\"min_psnr_db\":15}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["psnr_mdb"] >= 999999, d
assert d["psnr_ok"] is True and d["ok"] is True, d
print("PASS: 同一张图 PSNR 视为无穷大，过门（%d）" % d["psnr_mdb"])' \
    || bad "同一张图的 PSNR 口径不对"

# 2) 两张不同颜色的图：PSNR 很低，卡门
app "{\"project_id\":\"$PROJ\",\"image\":\"$IMG/other.png\",\"baseline\":\"$IMG/base.png\",\"min_psnr_db\":15}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert 0 < d["psnr_mdb"] < 15000, d
assert d["psnr_ok"] is False and d["ok"] is False, d
print("PASS: 外观差太多的锚帧被卡（PSNR %d mdb < 15000）" % d["psnr_mdb"])' \
    || bad "PSNR 门没卡住"

# 3) 阈值可调：把门槛降到 5 dB，同一对图就过了
app "{\"project_id\":\"$PROJ\",\"image\":\"$IMG/other.png\",\"baseline\":\"$IMG/base.png\",\"min_psnr_db\":3}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["min_psnr_mdb"] == 3000, d
assert d["psnr_ok"] is True and d["ok"] is True, d
print("PASS: min_psnr_db 可调（门槛降到 3 dB 时放行，实到 %d）"
      % d["psnr_mdb"])' \
    || bad "min_psnr_db 没生效"

# 4) 没配置 VLM：mock 模式，模型侧跳过但不报错
app "{\"project_id\":\"$PROJ\",\"image\":\"$IMG/same.png\",\"use_model\":true,\"frozen\":\"深蓝卫衣\"}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["model_used"] is False, d
assert d["model_rc"] == 83, d
assert d["model_verdict"] == "", d
print("PASS: 没配 VLM 时模型侧跳过（model_rc=83，不误报）")' \
    || bad "mock 模式口径不对"

# 假的本机 VLM：回什么都由 FAKE 控制
cat > "$TMP/fake_vlm.py" <<'PY'
import json
import os
import sys
from http.server import BaseHTTPRequestHandler
from http.server import HTTPServer

ANSWER = os.environ.get("FAKE_ANSWER", "OK\n对得上")


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        d = json.loads(body)
        c = d["messages"][0]["content"][0]["text"]
        assert "冻结文本" in c, c
        assert "data:image/png;base64," in json.dumps(d), "图没带上"
        out = json.dumps({"id": "x", "object": "chat.completion", "choices": [
            {"index": 0, "message": {"role": "assistant",
                                     "content": ANSWER}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

start_vlm() {
    answer="$1"
    FAKE_ANSWER="$answer" python3 "$TMP/fake_vlm.py" "$PORT" \
        > "$TMP/vlm.log" 2>&1 &
    SRV_PID=$!
    i=0
    while [ $i -lt 40 ]; do
        if python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $PORT))
except OSError:
    sys.exit(1)
sys.exit(0)" 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    return 1
}

PORT=$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
printf '{"provider":"openai","base_url":"127.0.0.1","port":%s,"path":"/v1/chat/completions","model":"fake-vl","tls":0,"timeout_ms":5000}\n' \
    "$PORT" > "$DATA/llm.json"

start_vlm "OK
外观和服装都对得上" || { echo "FAIL: 假 VLM 起不来"; exit 1; }
app "{\"project_id\":\"$PROJ\",\"character_id\":\"su_wan\",\"image\":\"$IMG/same.png\",\"use_model\":true,\"frozen\":\"深蓝卫衣\"}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["model_used"] is True, d
assert d["model_verdict"] == "OK", d
assert d["ok"] is True, d
assert d["note"].startswith("OK"), d
print("PASS: 模型回 OK 时判过（note 带模型原话）")' \
    || bad "模型 OK 分支不对"
kill "$SRV_PID" 2>/dev/null
unset SRV_PID

start_vlm "DRIFT
外套颜色不对" || { echo "FAIL: 假 VLM 起不来"; exit 1; }
app "{\"project_id\":\"$PROJ\",\"character_id\":\"su_wan\",\"image\":\"$IMG/same.png\",\"use_model\":true,\"frozen\":\"深蓝卫衣\"}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["model_used"] is True, d
assert d["model_verdict"] == "DRIFT", d
assert d["ok"] is False, d
print("PASS: 模型回 DRIFT 时判不过（即使 PSNR 过门）")' \
    || bad "模型 DRIFT 分支不对"

# 模型说 DRIFT 但同时给了 baseline 且 PSNR 也过门 ⇒ 仍然不过（模型优先把问题指出来）
app "{\"project_id\":\"$PROJ\",\"image\":\"$IMG/same.png\",\"baseline\":\"$IMG/base.png\",\"use_model\":true,\"frozen\":\"深蓝卫衣\"}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)["data"]["result"]
assert d["psnr_ok"] is True and d["model_verdict"] == "DRIFT", d
assert d["ok"] is False, d
print("PASS: 两条判据取最严（PSNR 过 + 模型 DRIFT ⇒ 不过）")' \
    || bad "两条判据没取最严"
kill "$SRV_PID" 2>/dev/null
unset SRV_PID

# 入参校验
app "{\"image\":\"$IMG/same.png\"}" | python3 -c '
import json
import sys

d = json.load(sys.stdin)
assert d["success"] is False and d["error"]["code"] == "SCHEMA_INVALID", d
print("PASS: 缺 project_id 被拒（SCHEMA_INVALID）")' \
    || bad "缺 project_id 没被拒"

app "{\"project_id\":\"$PROJ\",\"image\":\"$IMG/nope.png\",\"baseline\":\"$IMG/base.png\"}" \
    | python3 -c '
import json
import sys

d = json.load(sys.stdin)
assert d["success"] is False and d["error"]["code"] == "IO_ERROR", d
print("PASS: 图不存在时报 IO_ERROR")' \
    || bad "图不存在时没报错"

# 真机 VLM（本机有就再跑一遍真模型）
if timeout 5 curl -s -o /dev/null http://127.0.0.1:11435/api/tags 2>/dev/null; then
    MODEL=$(timeout 8 curl -s http://127.0.0.1:11435/api/tags | python3 -c '
import json
import sys

d = json.load(sys.stdin)
for m in d["models"]:
    if "vl" in m["name"] or "vision" in m["name"] or "mimo" in m["name"]:
        print(m["name"])
        break' 2>/dev/null)
    if [ -n "$MODEL" ]; then
        printf '{"provider":"openai","base_url":"127.0.0.1","port":11435,"path":"/v1/chat/completions","model":"%s","tls":0,"timeout_ms":120000}\n' \
            "$MODEL" > "$DATA/llm.json"
        app "{\"project_id\":\"$PROJ\",\"image\":\"$IMG/base.png\",\"use_model\":true,\"frozen\":\"苏晚：短寸头，深蓝卫衣\"}" \
            > "$TMP/real_vlm.json"
        python3 - "$TMP/real_vlm.json" "$MODEL" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))["data"]["result"]
if d["model_rc"] in (82, 72):
    # 本机模型临时不可用（正在换模型 / 显存不够）不算失败，但要如实说话
    print("SKIP: 真 VLM 这次没答上（model_rc=%d）" % d["model_rc"])
    raise SystemExit(0)
assert d["model_used"] is True, d
assert d["model_rc"] == 0, d
assert d["model_verdict"] in ("OK", "DRIFT"), d
print("PASS: 真 VLM（%s）答上了：%s" % (sys.argv[2], d["model_verdict"]))
print("      原话：%s" % d["note"].replace(chr(10), " ")[:80])
PY
        [ $? -eq 0 ] || bad "真 VLM 那条没过"
    else
        ok "本机没有 vision 模型，跳过真模型用例"
    fi
else
    ok "本机没有 ollama，跳过真模型用例"
fi

echo "----"
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: P18（qa.appearance：PSNR 门 / 阈值可调 / 模型 OK+DRIFT / 入参校验）"
    exit 0
fi
echo "FAIL: $FAILS 项"
exit 1
