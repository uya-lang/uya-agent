#!/bin/sh
# drama_plugin/p3_selftest.sh — P3（Project + 基础存储）
#
# 本轮覆盖 DRAMA_TODO §5 的这几条（其余条目仍在 TODO 里挂着）：
#   * 项目 ID 规则、project.create / get / list；
#   * 数据根目录显式配置（--data-dir），项目目录创建；
#   * 原子写（tmp → rename，不留 .tmp）、JSON 带 format_version；
#   * 路径边界：ID 只允许 [0-9a-f_]，`../` 与绝对路径进不来。
#
# 验收判据（TODO §5 验收）：
#   1) 创建两个项目并互不干扰；
#   2) 关闭重启后项目仍存在；
#   3) 非授权路径无法读取。
#
# 用法：sh drama_plugin/p3_selftest.sh

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
UYA=${UYA:-$ROOT/uya/bin/uya}
export UYA_ROOT=${UYA_ROOT:-$ROOT/uya/stdlib}

SRC="$HERE/src/main.uya $HERE/src/bytes.uya $HERE/src/json_min.uya \
$HERE/src/json_out.uya $HERE/src/registry.uya $HERE/src/schema.uya \
$HERE/src/dispatch.uya $HERE/src/store.uya $HERE/src/project.uya \
$HERE/src/digest.uya $HERE/src/asset.uya $HERE/src/bible.uya \
$HERE/src/ops.uya $HERE/src/server.uya"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"

fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# ---------- 0. 构建 ----------
if ! "$UYA" build $SRC -o "$TMP/drama" > "$TMP/build.log" 2>&1; then
    echo "FAIL: 构建失败"
    tail -10 "$TMP/build.log"
    exit 1
fi
ok "构建通过"

# ---------- 1. 第一次进程：建两个项目 ----------
cat > "$TMP/in1.jsonl" <<'JSONL'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"顶楼误闯","episode_count":100}}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"第二部","episode_count":30}}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.create","input":{"name":"顶楼误闯","episode_count":100}}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.get","input":{"project_id":"../../etc/passwd"}}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.get","input":{"project_id":"p_deadbeef"}}}}
JSONL

timeout 120 "$TMP/drama" mcp serve --data-dir "$DATA" \
    < "$TMP/in1.jsonl" > "$TMP/out1.jsonl" 2> "$TMP/err1.txt" || true

# ---------- 2. 第二个进程：验证持久化 ----------
cat > "$TMP/in2.jsonl" <<'JSONL'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.list","input":{}}}}
JSONL

timeout 120 "$TMP/drama" mcp serve --data-dir "$DATA" \
    < "$TMP/in2.jsonl" > "$TMP/out2.jsonl" 2> "$TMP/err2.txt" || true

# ---------- 3. 断言 ----------
python3 - "$TMP/out1.jsonl" "$TMP/out2.jsonl" "$DATA" \
    "$TMP/err1.txt" "$TMP/err2.txt" <<'PY'
import json
import os
import sys

out1, out2, data = sys.argv[1], sys.argv[2], sys.argv[3]
err = (open(sys.argv[4], 'rb').read() + open(sys.argv[5], 'rb').read())
fails, ok = [], []


def check(cond, msg):
    (ok if cond else fails).append(msg)


def load(path):
    resps = {}
    for line in open(path, 'rb').read().split(b'\n'):
        if not line:
            continue
        o = json.loads(line)
        resps[o.get('id')] = o
    return resps


def body(resps, rid):
    r = resps.get(rid, {}).get('result')
    if r is None:
        return None, None
    return json.loads(r['content'][0]['text']), r.get('isError')


r1 = load(out1)
t, e = body(r1, 1)
a = ((t or {}).get('data') or {}).get('result') or {}
check(e is False and bool(a.get('project_id')), '项目 A 创建成功并回 ID')

t, e = body(r1, 2)
b = ((t or {}).get('data') or {}).get('result') or {}
check(bool(b.get('project_id')), '项目 B 创建成功')
check(a.get('project_id') != b.get('project_id'), '两个项目 ID 不同')

t, e = body(r1, 3)
er = (t or {}).get('error') or {}
check(er.get('code') == 'ALREADY_EXISTS', '同名项目再建报 ALREADY_EXISTS')

t, e = body(r1, 4)
er = (t or {}).get('error') or {}
check(er.get('code') == 'SCHEMA_INVALID', '路径穿越的 project_id 被拒')

t, e = body(r1, 5)
er = (t or {}).get('error') or {}
check(er.get('code') == 'NOT_FOUND', '不存在的项目报 NOT_FOUND')

# 落盘检查
pj = os.path.join(data, 'projects')
check(os.path.isdir(pj), '数据根下建出 projects/')
ids = sorted(d for d in os.listdir(pj) if d.startswith('p_'))
check(len(ids) == 2, '两个项目各占一个目录')
check(not any(n.endswith('.tmp') for n in os.listdir(pj)), '索引不留 .tmp')

for pid in ids:
    f = os.path.join(pj, pid, 'project.json')
    check(os.path.isfile(f), '项目目录里有 project.json')
    if os.path.isfile(f):
        rec = json.load(open(f))
        check(rec.get('format_version') == 1, 'project.json 带 format_version')
        check(rec.get('id') == pid, 'project.json 的 id 与目录名一致')

names = {}
for pid in ids:
    rec = json.load(open(os.path.join(pj, pid, 'project.json')))
    names[rec['name']] = rec
check(set(names) == {'顶楼误闯', '第二部'}, '两个项目各自保留自己的名字')
check(names.get('顶楼误闯', {}).get('episode_count') == 100,
      '项目 A 的集数没被 B 覆盖')
check(names.get('第二部', {}).get('episode_count') == 30,
      '项目 B 的集数没被 A 覆盖')

# 重启后
r2 = load(out2)
t, e = body(r2, 1)
lst = (((t or {}).get('data') or {}).get('result') or {}).get('projects') or []
check(len(lst) == 2, '重启后 list 仍能看到两个项目')
check({p['name'] for p in lst} == {'顶楼误闯', '第二部'}, '重启后名字仍正确')

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
    echo "PASS: P3（Project + 基础存储）"
    exit 0
fi
echo "FAIL: P3 有未通过项"
exit 1
