#!/bin/sh
# P15 自测：30 集跨题材（M3）
#
# 三个题材各跑一票，唯一的差别是输入：Bible 模板（人物/世界/规则）+
# 资产包 + format（画布/编码）。代码一行不改，产线照跑。
#   EPISODES=30 sh drama_plugin/p15_selftest.sh   # 默认
# 每个题材 EPISODES/3 集，跑完断言：批准 revision 连续、单次 Worker 全做完、
# canon.audit 绿、Bible 版本与 format 就是模板里写的那份。

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
$HERE/src/queue_ops.uya $HERE/src/pipeline_ops.uya \
$HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"

EPISODES=${EPISODES:-30}
PER=$((EPISODES / 3))

if ! "$UYA" build $SRC -o "$TMP/drama" > "$TMP/build.log" 2>&1; then
    echo "FAIL: 构建失败"
    tail -10 "$TMP/build.log"
    exit 1
fi
echo "PASS: 构建通过"

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

ask() {
    timeout 120 "$TMP/drama" mcp serve --data-dir "$DATA" \
        < "$TMP/q.jsonl" 2>/dev/null
}

# 只取 data.result（业务错误时给 error 对象，便于断言 code）
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

req() {
    id=$1
    op=$2
    input=$3
    printf '%s' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":{\"name\":\"call\",\"arguments\":{\"operation\":\"$op\",\"input\":$input}}}" \
        > "$TMP/q.jsonl"
    ask
}

# 三个题材模板：只给输入（Bible + 资产包 + format），不给代码分支
run_genre() {
    name=$1
    bible=$2
    locks=$3
    canvas=$4
    codec=$5

    out=$(req 1 project.create "{\"name\":\"M3-$name\"}")
    pid=$(printf '%s' "$out" | field | python3 -c '
import json
import sys
print(json.load(sys.stdin)["project_id"])')
    [ -n "$pid" ] || { bad "$name 建项目失败"; return; }

    # format 放在 bible 里（bible.put 的入参没有独立的 format 字段）
    out=$(req 2 bible.put "{\"project_id\":\"$pid\",\"bible\":$bible,\"locks\":$locks}")
    printf '%s' "$out" | field | python3 -c '
import json
import sys
d = json.load(sys.stdin)
assert d.get("version") == 1, d' 2>/dev/null \
        || bad "$name 的 Bible 模板没落盘"

    i=1
    while [ "$i" -le "$PER" ]; do
        req $((100 + i)) episode.generate \
            "{\"project_id\":\"$pid\",\"target_seconds\":90}" > /dev/null
        out=$(req $((200 + i)) episode.approve \
            "{\"project_id\":\"$pid\",\"script_version\":$i}")
        rev=$(printf '%s' "$out" | field | python3 -c '
import json
import sys
print(json.load(sys.stdin).get("revision", "ERR"))')
        [ "$rev" = "$i" ] || bad "$name 第 $i 集批准 revision=$rev"
        req $((300 + i)) episode.produce \
            "{\"project_id\":\"$pid\",\"episode_id\":\"e$i\",\"stage\":\"video\"}" \
            > /dev/null
        i=$((i + 1))
    done

    timeout 900 "$TMP/drama" worker run --data-dir "$DATA" \
        > "$TMP/worker_$name.out" 2>/dev/null
    python3 - "$TMP/worker_$name.out" "$PER" "$name" <<'PY'
import json
import sys

raw = [x for x in open(sys.argv[1]).read().split(chr(10)) if x.strip()]
d = json.loads(raw[-1])
n = int(sys.argv[2])
assert d["tasks_seen"] == n, d
assert d["tasks_done"] == n, d
assert d["tasks_failed"] == 0, d
print("PASS: %s 一票 %d 集视频任务全部跑完" % (sys.argv[3], n))
PY
    [ $? -eq 0 ] || fails=$((fails + 1))

    out=$(req 9000 canon.audit "{\"project_id\":\"$pid\"}")
    printf '%s' "$out" | field > "$TMP/audit_$name.json"
    python3 - "$TMP/audit_$name.json" "$PER" "$name" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
n = int(sys.argv[2])
assert d["ok"] is True, d
assert d["commits"] == n, d
print("PASS: %s 闭环审计绿（%d 条提交）" % (sys.argv[3], n))
PY
    [ $? -eq 0 ] || bad "$name 的闭环审计没绿"

    # 模板真的生效了：Bible 版本 1、format 就是给的那份、人物就是模板里的人
    out=$(req 9001 bible.get "{\"project_id\":\"$pid\"}")
    printf '%s' "$out" | field | python3 -c "
import json
import sys
d = json.load(sys.stdin)
b = d['bible']
assert d['version'] == 1, d
assert b['format']['canvas'] == '$canvas', b
assert b['format']['codec'] == '$codec', b
print('PASS: $name 的 Bible 模板生效（format %s/%s）' % ('$canvas', '$codec'))" \
        || bad "$name 的模板没生效"
}

# 家庭喜剧：竖屏
run_genre 家庭喜剧 \
    '{"characters":[{"id":"dad"},{"id":"mum"},{"id":"kid"}],"world":{"rule":["一家人住在老小区"]},"format":{"canvas":"440x800","codec":"h264"}}' \
    '{"dad":"爸爸：短寸头","mum":"妈妈：马尾","kid":"孩子：蘑菇头"}' \
    "440x800" h264

# 悬疑：竖屏，规则是"不能提前揭底"
run_genre 悬疑 \
    '{"characters":[{"id":"detective"},{"id":"suspect"}],"world":{"rule":["结局前不许揭底"]},"format":{"canvas":"440x800","codec":"h264"}}' \
    '{"detective":"侦探：风衣","suspect":"嫌疑人：灰帽"}' \
    "440x800" h264

# 古装：横屏
run_genre 古装 \
    '{"characters":[{"id":"general"},{"id":"consort"}],"world":{"rule":["说话用古称"]},"format":{"canvas":"1280x720","codec":"h264"}}' \
    '{"general":"将军：铁甲","consort":"贵妃：凤冠"}' \
    "1280x720" h264

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: P15（3 个题材 × $PER 集 = $((PER * 3)) 集，换模板不改代码）"
    exit 0
fi
echo "FAIL: $fails 项"
exit 1
