#!/bin/sh
# drama_plugin/p3b_selftest.sh — P3 第二段（Bible 版本 + Asset Store）
#
# 覆盖 DRAMA_TODO §5 的：
#   * Bible 版本可追溯：内容不变不产生新版本，冻结文本改动必须产生新版；
#   * 冻结文本逐字校验：每个锁都有 SHA-256，历史里能逐版比对；
#   * 资产元数据可查询：name / mime / size / sha256；
#   * 非授权路径无法读取：`../` 形式的资产名直接拒。
#
# 用法：sh drama_plugin/p3b_selftest.sh

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
$HERE/src/ops.uya $HERE/src/server.uya"

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

# 第一个进程：建项目 → 写三版 Bible → 登记资产
cat > "$TMP/in1.jsonl" <<'JSONL'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"bible-proj"}}}}
JSONL
timeout 120 "$TMP/drama" mcp serve --data-dir "$DATA" \
    < "$TMP/in1.jsonl" > "$TMP/out1.jsonl" 2> "$TMP/err1.txt" || true

PID=$(python3 - "$TMP/out1.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1], 'rb').read().split(b'\n'):
    if not line:
        continue
    o = json.loads(line)
    t = json.loads(o['result']['content'][0]['text'])
    print(t['data']['result']['project_id'])
    break
PY
)
if [ -z "$PID" ]; then
    echo "FAIL: 没拿到 project_id"
    exit 1
fi
ok "项目创建，id=$PID"

mkdir -p "$DATA/projects/$PID/assets"
printf 'fake-png-bytes' > "$DATA/projects/$PID/assets/cover.png"

cat > "$TMP/in2.jsonl" <<JSONL
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PID","bible":{"characters":[{"id":"c1","name":"林岚"}]},"locks":{"c1":"长发，深蓝风衣"}}}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PID","bible":{"characters":[{"id":"c1","name":"林岚"}]},"locks":{"c1":"长发，深蓝风衣"}}}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.put","input":{"project_id":"$PID","bible":{"characters":[{"id":"c1","name":"林岚"}]},"locks":{"c1":"短发，深蓝风衣"}}}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.history","input":{"project_id":"$PID"}}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"bible.get","input":{"project_id":"$PID","version":1}}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"asset.register","input":{"project_id":"$PID","name":"cover.png","mime":"image/png"}}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"asset.register","input":{"project_id":"$PID","name":"../escape.png","mime":"image/png"}}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"asset.list","input":{"project_id":"$PID"}}}}
JSONL

timeout 120 "$TMP/drama" mcp serve --data-dir "$DATA" \
    < "$TMP/in2.jsonl" > "$TMP/out2.jsonl" 2> "$TMP/err2.txt" || true

python3 - "$TMP/out2.jsonl" "$DATA" "$PID" "$TMP/err2.txt" <<'PY'
import hashlib
import json
import os
import sys

out2, data, pid = sys.argv[1], sys.argv[2], sys.argv[3]
err = open(sys.argv[4], 'rb').read()
fails, ok = [], []


def check(cond, msg):
    (ok if cond else fails).append(msg)


resps = {}
for line in open(out2, 'rb').read().split(b'\n'):
    if not line:
        continue
    o = json.loads(line)
    resps[o.get('id')] = json.loads(o['result']['content'][0]['text'])


def data_of(rid):
    return (resps.get(rid) or {}).get('data', {}).get('result') or {}


v1 = data_of(1)
check(v1.get('version') == 1 and v1.get('created') is True,
      '第一版 Bible 写入成功')
v2 = data_of(2)
check(v2.get('version') == 1 and v2.get('created') is False,
      '内容没变不产生新版本')
v3 = data_of(3)
check(v3.get('version') == 2 and v3.get('created') is True,
      '冻结文本改动产生新版本')
check(v1.get('content_hash') != v3.get('content_hash'),
      '两个版本的 content_hash 不同')

hist = (data_of(4).get('versions') or [])
check(len(hist) == 2, '历史里有两版')
check(hist[0].get('version') == 1 and hist[1].get('version') == 2,
      '历史按版本号递增')
check(len(hist[0].get('content_hash') or '') == 64,
      '历史里的 hash 是 64 位十六进制')

snap = data_of(5)
check(snap.get('version') == 1, 'bible.get 能按版本号取旧版')
locks = snap.get('locks') or {}
check(len(locks.get('c1') or '') == 64, '快照里每个锁都有 SHA-256')
expect = hashlib.sha256('长发，深蓝风衣'.encode()).hexdigest()
check(locks.get('c1') == expect, '锁的 hash 与逐字文本一致（可核对）')

reg = data_of(6)
check(reg.get('registered') is True, '资产登记成功')
bad = (resps.get(7) or {}).get('error') or {}
check(bad.get('code') == 'SCHEMA_INVALID', '`../` 形式的资产名被拒')
assets = (data_of(8).get('assets') or [])
check(len(assets) == 1, '资产列表只有一条')
a = assets[0] if assets else {}
check(a.get('name') == 'cover.png', '资产名正确')
check(a.get('mime') == 'image/png', '资产 mime 正确')
check(a.get('size') == 14, '资产大小正确')
want = hashlib.sha256(b'fake-png-bytes').hexdigest()
check(a.get('sha256') == want, '资产 SHA-256 与文件一致')

files = sorted(os.listdir(os.path.join(data, 'projects', pid, 'bible')))
check(files == ['current.json', 'v1.json', 'v2.json'],
      'bible 目录里只有 current + 两个版本')
check(err.strip() == b'', 'stderr 干净')

for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
rc=$?

echo "----"
if [ "$rc" -eq 0 ] && [ "$fails" -eq 0 ]; then
    echo "PASS: P3 第二段（Bible 版本 + Asset）"
    exit 0
fi
echo "FAIL: P3 第二段有未通过项"
exit 1
