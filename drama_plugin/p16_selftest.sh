#!/usr/bin/env bash
# P16：PipelineProvider（pipeline.run）——把既有产线当 VideoProvider 用。
# 用一个假的产线目录（自己的 scripts/*.py）验证：白名单入口、退出码、
# 日志尾部、产物清单、超时、路径越界拒绝。不碰 GPU。
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
TMP=$(mktemp -d /tmp/p16.XXXXXX)
trap '[ "${KEEP:-0}" = "1" ] || rm -rf "$TMP"' EXIT
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

# ask <id> <operation> <input-json>
ask() {
    printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"call","arguments":{"operation":"%s","input":%s}}}\n' \
        "$1" "$2" "$3" >> "$TMP/req.jsonl"
    echo "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"call\",\"arguments\":{\"operation\":\"$2\",\"input\":$3}}}"
}
field() {
    python3 -c '
import json
import sys

line = sys.stdin.read().strip()
d = json.loads(line)
print(d["result"]["content"][0]["text"])'
}

mkdir -p "$DATA"
PID=$(python3 - <<'PY'
import json
print(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                  "params": {"name": "call", "arguments": {
                      "operation": "project.create",
                      "input": {"name": "p16"}}}}))
PY
)
out=$(printf '%s\n' "$PID" | "$BIN" mcp serve --data-dir "$DATA" 2>/dev/null \
    | tail -1)
PROJ=$(printf '%s' "$out" | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['data']['result']['project_id'])")
[ -n "$PROJ" ] || { echo "FAIL: 建项目失败"; exit 1; }

# 假产线：<root>/<episode>/scripts/*.py
mkline() {
    root="$1"
    ep="$2"
    mkdir -p "$root/$ep/scripts"
    cat > "$root/$ep/scripts/lint_shots.py" <<'PY'
print("lint ok: 9 镜 源素材 56.4s")
PY
    cat > "$root/$ep/scripts/run_shots.py" <<'PY'
import os
import sys

n = 1
dry = "--dry" in sys.argv
for a in sys.argv[1:]:
    if a.isdigit():
        n = int(a)
if os.environ.get("FORCE") == "1":
    print("force=1")
if dry:
    print("dry: 计划 %d 镜" % n)
    sys.exit(0)
d = "../shots/shot%02d" % n
os.makedirs(d, exist_ok=True)
p = "%s/shot%02d.mp4" % (d, n)
open(p, "wb").write(b"x" * 2048)
open("%s/last.png" % d, "wb").write(b"p" * 128)
open("%s/done.json" % d, "w").write('{"index": %d}' % n)
print("done shot%d -> %s" % (n, p))
PY
    cat > "$root/$ep/scripts/qc.py" <<'PY'
import sys

print("qc " + " ".join(sys.argv[1:]))
PY
    cat > "$root/$ep/scripts/cards.py" <<'PY'
print("cards ok")
PY
    cat > "$root/$ep/scripts/build_film.py" <<'PY'
import sys

print("build " + ("dry" if "--dry" in sys.argv else "done"))
PY
    cat > "$root/$ep/scripts/check_join.py" <<'PY'
print("join ok")
PY
    cat > "$root/$ep/scripts/slow.py" <<'PY'
import time

time.sleep(30)
PY
}

ROOT="$TMP/plroot"
mkline "$ROOT" "ep1"
ok "假产线就位（$ROOT/ep1/scripts）"

# 跑一次请求批：把多条请求一次性喂给 serve
serve_batch() {
    "$BIN" mcp serve --data-dir "$DATA" < "$TMP/batch.jsonl" 2>/dev/null \
        | while IFS= read -r line; do printf '%s\n' "$line"; done
}
: > "$TMP/batch.jsonl"
python3 - "$TMP/batch.jsonl" "$ROOT" "$PROJ" <<'PY'
import json
import sys

path, root, proj = sys.argv[1], sys.argv[2], sys.argv[3]
reqs = [
    {"id": 10, "entry": "lint"},
    {"id": 11, "entry": "generate", "dry": 1},
    {"id": 12, "entry": "generate", "shot": 2},
    {"id": 13, "entry": "asr", "shot": 3},
    {"id": 14, "entry": "nope"},
    {"id": 15, "entry": "lint", "episode": "../ep1"},
    {"id": 16, "entry": "lint", "root": "rel/root"},
]
with open(path, "w") as f:
    for r in reqs:
        inp = {"pipeline_root": r.get("root", root),
               "episode": r.get("episode", "ep1"),
               "entry": r["entry"]}
        if "shot" in r:
            inp["shot"] = r["shot"]
        if "dry" in r:
            inp["dry"] = True
        f.write(json.dumps({"jsonrpc": "2.0", "id": r["id"],
                            "method": "tools/call", "params": {
                                "name": "call", "arguments": {
                                    "operation": "pipeline.run",
                                    "input": inp}}}) + "\n")
PY

serve_batch > "$TMP/out.jsonl"
python3 - "$TMP/out.jsonl" "$TMP" <<'PY'
import json
import sys

rows = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    rows[d["id"]] = d


def body(i):
    d = rows[i]
    txt = d["result"]["content"][0]["text"]
    return json.loads(txt)


res = []

b = body(10)
r = b.get("data", {}).get("result", {})
assert r.get("ok") is True and r.get("exit_code") == 0, b
assert "lint ok" in r["log_tail"], r
assert r["log_path"].endswith(".pipeline_lint.log"), r
res.append("lint 入口：退出码 0 + 日志尾部带产线输出")

b = body(11)
r = b["data"]["result"]
assert r["exit_code"] == 0 and "dry" in r["log_tail"], b
assert r["products"] == [], r
res.append("generate --dry：只出计划，不产文件")

b = body(12)
r = b["data"]["result"]
assert r["ok"] is True, b
paths = [p["path"] for p in r["products"]]
assert paths == ["shots/shot02/shot02.mp4", "shots/shot02/last.png",
                 "shots/shot02/done.json"], paths
by = {p["path"]: p["bytes"] for p in r["products"]}
assert by["shots/shot02/shot02.mp4"] == 2048, by
assert by["shots/shot02/last.png"] == 128, by
res.append("generate 2：产物清单三条 + 字节数对（2048/128/done.json）")

b = body(13)
r = b["data"]["result"]
assert r["exit_code"] == 0 and "qc asr 3" in r["log_tail"], b
assert r["products"] == [], r
res.append("qc_asr 3：参数透传到产线（日志尾部是 qc asr 3）")

b = body(14)
assert b["success"] is False, b
assert b["error"]["code"] == "SCHEMA_INVALID", b
res.append("不在白名单的入口被拒（SCHEMA_INVALID）")

for i in (15, 16):
    b = body(i)
    assert b["success"] is False, b
    assert b["error"]["code"] == "SCHEMA_INVALID", b
res.append("episode 带 .. 或 root 不是绝对路径都被拒")

for x in res:
    print("PASS: " + x)
PY
[ $? -eq 0 ] || bad "pipeline.run 的入口/产物/参数断言有不过的"
ok "pipeline.run 主路径"

# FORCE=1 透传
printf '%s\n' "$(ask 20 pipeline.run \
    "{\"pipeline_root\":\"$ROOT\",\"episode\":\"ep1\",\"entry\":\"generate\",\"shot\":1,\"force\":true}")" \
    > "$TMP/b.jsonl"
"$BIN" mcp serve --data-dir "$DATA" < "$TMP/b.jsonl" 2>/dev/null | tail -1 \
    | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d['data']['result']
assert 'force=1' in r['log_tail'], r
assert r['exit_code'] == 0, r
print('PASS: force=1 透传到产线（重拍同一镜）')" \
    || bad "force 没透传"

# 超时：slow.py 不是白名单入口，所以拿 run_shots 造一个慢入口后替换
cp "$ROOT/ep1/scripts/slow.py" "$ROOT/ep1/scripts/cards.py"
printf '%s\n' "$(ask 21 pipeline.run \
    "{\"pipeline_root\":\"$ROOT\",\"episode\":\"ep1\",\"entry\":\"cards\",\"timeout_s\":1}")" \
    > "$TMP/b2.jsonl"
"$BIN" mcp serve --data-dir "$DATA" < "$TMP/b2.jsonl" 2>/dev/null | tail -1 \
    | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d['data']['result']
assert r['exit_code'] == 124, r
assert r['ok'] is False, r
print('PASS: 超时被 timeout 掐断（退出码 124）')" \
    || bad "超时没生效"

# 日志尾部截断不能切在 UTF-8 多字节字符中间（切了调用方 JSON 就解析不了）
cat > "$ROOT/ep1/scripts/cards.py" <<'PY'
import sys

for i in range(200):
    print("第%03d镜：字幕「你还想面试？」已插入" % i)
sys.exit(0)
PY
printf '%s\n' "$(ask 24 pipeline.run \
    "{\"pipeline_root\":\"$ROOT\",\"episode\":\"ep1\",\"entry\":\"cards\"}")" \
    > "$TMP/b5.jsonl"
"$BIN" mcp serve --data-dir "$DATA" < "$TMP/b5.jsonl" 2>/dev/null | tail -1 \
    | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d['data']['result']
t=r['log_tail']
assert r['exit_code'] == 0, r
assert 0 < len(t.encode()) <= 600, len(t)
assert '镜' in t, t[:40]
print('PASS: 日志尾部按 UTF-8 边界截断（%d 字节，能解码）' % len(t.encode()))" \
    || bad "日志尾部切在多字节字符中间"

# 产线真的挂了（非 0 退出码）要如实回给调用方
cat > "$ROOT/ep1/scripts/cards.py" <<'PY'
import sys

print("boom: 显存不足", file=sys.stderr)
sys.exit(3)
PY
printf '%s\n' "$(ask 22 pipeline.run \
    "{\"pipeline_root\":\"$ROOT\",\"episode\":\"ep1\",\"entry\":\"cards\"}")" \
    > "$TMP/b3.jsonl"
"$BIN" mcp serve --data-dir "$DATA" < "$TMP/b3.jsonl" 2>/dev/null | tail -1 \
    | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d['data']['result']
assert r['exit_code'] == 3, r
assert r['ok'] is False, r
assert '显存不足' in r['log_tail'], r
print('PASS: 产线非 0 退出码如实回传（3 + stderr 尾部）')" \
    || bad "非 0 退出码没回传"

# 不存在的产线目录
printf '%s\n' "$(ask 23 pipeline.run \
    "{\"pipeline_root\":\"$ROOT\",\"episode\":\"nope\",\"entry\":\"lint\"}")" \
    > "$TMP/b4.jsonl"
"$BIN" mcp serve --data-dir "$DATA" < "$TMP/b4.jsonl" 2>/dev/null | tail -1 \
    | field | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d['data']['result']
assert r['ok'] is False and r['exit_code'] != 0, r
print('PASS: 产线目录不存在时失败可见（退出码 %d）' % r['exit_code'])" \
    || bad "目录不存在时的失败不可见"

echo "----"
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: P16（PipelineProvider：白名单入口 / 退出码 / 日志尾部 / 产物清单 / 超时）"
    exit 0
fi
echo "FAIL: $FAILS 项"
exit 1
