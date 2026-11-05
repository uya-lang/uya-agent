#!/bin/sh
# drama_plugin/p13c_selftest.sh — P13 M4 mock video pressure
#
# 默认跑 100 集：每集生成、批准、排队并由独立 Worker 完成 mock 视频任务。
# 逐集启动 Worker 是为了让每个任务绑定当时已批准的剧本版本；这不是
# 真实 GPU 产能测试。末尾抽样十条 commit 做历史重放字段检查，并测试
# Canon 删除后的恢复与 Worker 幂等重跑。
#
# 用法：sh drama_plugin/p13c_selftest.sh
# 可用 EPISODES=10 做较短的开发回归。

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

SRC="$HERE/src/main.uya $HERE/src/bytes.uya \
$HERE/src/json_min.uya $HERE/src/json_out.uya \
$HERE/src/registry.uya $HERE/src/schema.uya \
$HERE/src/dispatch.uya $HERE/src/store.uya \
$HERE/src/project.uya $HERE/src/digest.uya \
$HERE/src/asset.uya $HERE/src/bible.uya \
$HERE/src/canon.uya $HERE/src/httpc.uya \
$HERE/src/llm.uya $HERE/src/story.uya \
$HERE/src/context.uya $HERE/src/task.uya \
$HERE/src/board.uya $HERE/src/provider.uya \
$HERE/src/qa.uya $HERE/src/audit.uya \
$HERE/src/assemble.uya $HERE/src/index.uya \
$HERE/src/series.uya $HERE/src/ops.uya \
$HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"
EPISODES=${EPISODES:-100}
case "$EPISODES" in
    ''|*[!0-9]*) echo "FAIL: EPISODES must be an integer"; exit 1 ;;
esac
[ "$EPISODES" -ge 10 ] || {
    echo "FAIL: EPISODES must be at least 10"
    exit 1
}

if ! "$UYA" build $SRC -o "$TMP/drama" > "$TMP/build.log" 2>&1; then
    echo "FAIL: 构建失败"
    tail -10 "$TMP/build.log"
    exit 1
fi
echo "PASS: 构建通过"

ask() {
    python3 - "$TMP/q.jsonl" > "$TMP/request.jsonl" <<'PY'
import json
import sys
obj = json.load(open(sys.argv[1]))
print(json.dumps(obj, ensure_ascii=False, separators=(',', ':')))
PY
    timeout 120 "$TMP/drama" mcp serve --data-dir "$DATA" \
        < "$TMP/request.jsonl" 2>/dev/null
}

field() {
    python3 -c '
import json
import sys
raw = [x for x in sys.stdin.read().split(chr(10)) if x.strip()]
o = json.loads(raw[0])
t = json.loads(o["result"]["content"][0]["text"])
r = t.get("data", {}).get("result")
print(json.dumps(r if r is not None else t.get("error"),
                 ensure_ascii=False))
'
}

cat > "$TMP/q.jsonl" <<'JSON'
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "project.create", "input": {"name": "M4视频压力"}
  }}
}
JSON
out=$(ask)
PID=$(printf '%s' "$out" | field | python3 -c '
import json
import sys
print(json.load(sys.stdin)["project_id"])
')
echo "PASS: 项目创建 id=$PID"

# 每集立即执行 Worker，避免当前任务记录未保存 screenplay version。
i=1
while [ "$i" -le "$EPISODES" ]; do
    cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": $((1000 + i)),
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "episode.generate",
    "input": {"project_id": "$PID", "target_seconds": 90}
  }}
}
JSON
    ask > /dev/null

    cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": $((2000 + i)),
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "episode.approve",
    "input": {"project_id": "$PID", "script_version": $i}
  }}
}
JSON
    out=$(ask)
    rev=$(printf '%s' "$out" | field | python3 -c '
import json
import sys
print(json.load(sys.stdin).get("revision", "ERR"))
')
    [ "$rev" = "$i" ] || {
        echo "FAIL: 第 $i 集批准 revision=$rev"
        exit 1
    }

    cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": $((3000 + i)),
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "episode.produce",
    "input": {"project_id": "$PID", "episode_id": "e$i",
               "stage": "video"}
  }}
}
JSON
    out=$(ask)
    tid=$(printf '%s' "$out" | field | python3 -c '
import json
import sys
print(json.load(sys.stdin)["task_id"])
')

    [ -n "$tid" ] || {
        echo "FAIL: 第 $i 集没有建出任务"
        exit 1
    }
    i=$((i + 1))
done

echo "PASS: $EPISODES 集已排队（每集一个视频任务）"

# 一次 Worker 扫描消费全部任务：任务里固定的剧本版本必须各自对上，
# 不能都渲染"当前最新一集"。
timeout 900 "$TMP/drama" worker run --data-dir "$DATA" \
    > "$TMP/worker.out" 2>/dev/null
python3 - "$TMP/worker.out" "$EPISODES" <<'PY'
import json
import sys
raw = [x for x in open(sys.argv[1]).read().split(chr(10)) if x.strip()]
d = json.loads(raw[-1])
n = int(sys.argv[2])
assert d["tasks_seen"] == n, d
assert d["tasks_done"] == n, d
assert d["tasks_failed"] == 0, d
print("PASS: 单次 Worker 跑完 %d 个视频任务" % n)
PY

cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": 4001,
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "task.list", "input": {"project_id": "$PID"}
  }}
}
JSON
out=$(ask)
printf '%s' "$out" | field > "$TMP/tasks.json"
python3 - "$TMP/tasks.json" "$EPISODES" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
assert len(d["tasks"]) == n, len(d["tasks"])
assert all(x.get("state") == "done" for x in d["tasks"]), d
print("PASS: task.list 包含 %d 条 done 记录" % n)
PY

cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": 4002,
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "budget.report", "input": {"project_id": "$PID"}
  }}
}
JSON
out=$(ask)
printf '%s' "$out" | field > "$TMP/budget.json"
python3 - "$TMP/budget.json" "$EPISODES" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
assert d["episodes"] == n, d
assert d["renders"] == n * 3, d
assert d["gpu_ms"] > 0, d
print("PASS: 成本账本 %d 集 / %d 次渲染" %
      (d["episodes"], d["renders"]))
PY

cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": 4006,
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "asset.list", "input": {"project_id": "$PID"}
  }}
}
JSON
out=$(ask)
printf '%s' "$out" | field > "$TMP/assets.json"
python3 - "$TMP/assets.json" "$EPISODES" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
assert len(d["assets"]) == n * 3, len(d["assets"])
assert all(x["size"] == 256 for x in d["assets"]), d["assets"][:2]
print("PASS: asset.list 返回 %d 条（每条 256 B）" % len(d["assets"]))
PY

cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": 4003,
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "canon.audit", "input": {"project_id": "$PID"}
  }}
}
JSON
out=$(ask)
printf '%s' "$out" | field > "$TMP/audit.json"
python3 - "$TMP/audit.json" "$EPISODES" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
assert d["ok"] is True, d
assert d["revision"] == n, d
assert d["commits"] == n, d
assert d["replay_ok"] is True, d
assert not d["violations"], d
print("PASS: 全历史审计 %d 条提交无违规" % n)
PY

python3 - "$DATA/projects/$PID" "$EPISODES" <<'PY'
import json
import pathlib
import sys
project = pathlib.Path(sys.argv[1])
n = int(sys.argv[2])
if n <= 10:
    samples = list(range(1, n + 1))
else:
    samples = sorted({i * (n - 1) // 9 + 1 for i in range(10)})
assert len(samples) == 10, samples
for rev in samples:
    path = project / "commits" / (str(rev) + ".json")
    record = json.loads(path.read_text())
    assert record["revision"] == rev, record
    assert record["state"]["revision"] == rev, record
print("PASS: 抽样重放 10 条提交：" + ",".join(map(str, samples)))
boards = list((project / "boards").glob("v*.json"))
assert len(boards) == n, len(boards)
tasks = list((project / "tasks").glob("t_*.json"))
assert len(tasks) == n, len(tasks)
print("PASS: 分镜版本和任务文件各 %d 个" % n)
dirs = sorted(p.name for p in (project / "assets").glob("v*") if p.is_dir())
assert len(dirs) == n, len(dirs)
shots = list((project / "assets").glob("v*/shot_*.mp4"))
assert len(shots) == n * 3, len(shots)
print("PASS: 镜头文件按分镜版本分 %d 个目录，共 %d 个文件" %
      (len(dirs), len(shots)))
index = project / "assets.jsonl"
lines = [x for x in index.read_text().splitlines() if x.strip()]
assert len(lines) == n * 3, len(lines)
names = {json.loads(x)["name"] for x in lines}
assert len(names) == n * 3, len(names)
assert "v%d/shot_1.mp4" % (n // 2) in names, sorted(names)[:3]
print("PASS: 资产账本 %d 条，路径带分镜版本" % len(lines))
PY

rm "$DATA/projects/$PID/canon.json"
cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": 4004,
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "canon.recover", "input": {"project_id": "$PID"}
  }}
}
JSON
out=$(ask)
printf '%s' "$out" | field > "$TMP/recover.json"
python3 - "$TMP/recover.json" "$EPISODES" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
assert d["revision"] == n, d
assert d["recovered"] is True, d
print("PASS: 删除 Canon 后恢复到 revision %d" % n)
PY

MID=$((EPISODES / 2))
cat > "$TMP/q.jsonl" <<JSON
{
  "jsonrpc": "2.0",
  "id": 4005,
  "method": "tools/call",
  "params": {"name": "call", "arguments": {
    "operation": "media.assemble",
    "input": {"project_id": "$PID", "board_version": $MID}
  }}
}
JSON
out=$(ask)
printf '%s' "$out" | field > "$TMP/asm.json"
python3 - "$TMP/asm.json" "$DATA/projects/$PID" "$MID" <<'PY'
import json
import os
import sys
d = json.load(open(sys.argv[1]))
base = sys.argv[2]
bv = int(sys.argv[3])
assert d["board_version"] == bv, d
shot_dir = os.path.join(base, "assets", "v%d" % bv)
files = sorted(f for f in os.listdir(shot_dir) if f.startswith("shot_"))
assert len(files) == d["shots"], (len(files), d["shots"])
total = sum(os.path.getsize(os.path.join(shot_dir, f)) for f in files)
assert total == d["size"], (total, d["size"])
assert os.path.isfile(os.path.join(base, "assets", d["output"]))
print("PASS: 第 %d 集按自己的镜头目录合成（%d 镜 / %d B）" %
      (bv, d["shots"], d["size"]))
PY

# 恢复后再次启动 Worker，不应重复执行已完成任务。
timeout 120 "$TMP/drama" worker run --data-dir "$DATA" \
    > "$TMP/worker-again.out" 2>/dev/null
python3 - "$TMP/worker-again.out" <<'PY'
import json
import sys
raw = [x for x in open(sys.argv[1]).read().split(chr(10)) if x.strip()]
d = json.loads(raw[-1])
assert d["tasks_seen"] == 0, d
print("PASS: Worker 恢复后幂等重跑无重复任务")
PY

echo "----"
echo "PASS: P13 M4 mock 视频压力与抽样恢复（${EPISODES} 集）"
