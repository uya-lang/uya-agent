#!/bin/sh
# drama_plugin/p2_selftest.sh — P2（Operation Registry / Schema / Dispatch）
#
# 验收判据（DRAMA_TODO §4 验收）：
#   1) list 能发现登记的操作，并带 version/mutates/async/permission/cost；
#   2) describe 返回完整契约（properties / required / enum / errors / example）；
#   3) call 能执行；写操作回 task_id，读操作回 done；
#   4) 非法字段、缺字段、类型错误分别被拒（码要分开）；
#   5) 未登记操作不可执行；
#   6) 幂等：同 (operation, input_hash) 复用 task_id；同 request_id 换
#      payload 报 REQUEST_REUSED；
#   7) describe 与 call 同源：describe 里给出的 enum 就是 call 的判定依据。
#
# 用法：sh drama_plugin/p2_selftest.sh

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

# ---------- 1. 造请求 ----------
cat > "$TMP/in.jsonl" <<'JSONL'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list","arguments":{}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"describe","arguments":{"operation":"episode.produce"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"p_00000000","episode_id":"ep-1","stage":"video"},"request_id":"r-1"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"p_00000000","episode_id":"ep-1","stage":"video"},"request_id":"r-1"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"p_00000000","episode_id":"ep-2"},"request_id":"r-1"}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.get","input":{}}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.get","input":{"project_id":7}}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"call","arguments":{"operation":"project.get","input":{"project_id":"p_00000000","nope":1}}}}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"call","arguments":{"operation":"episode.produce","input":{"project_id":"p_00000000","episode_id":"e","stage":"x"}}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"call","arguments":{"operation":"nope.op","input":{}}}}
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"call","arguments":{"operation":"continuity.inspect","input":{"project_id":"p_00000000"}}}}
JSONL

timeout 120 "$TMP/drama" mcp serve --data-dir "$TMP/data" \
    < "$TMP/in.jsonl" > "$TMP/out.jsonl" 2> "$TMP/err.txt" || true

# ---------- 2. 断言 ----------
python3 - "$TMP/out.jsonl" "$TMP/err.txt" <<'PY'
import json
import sys

resps = {}
fails = []
ok = []

for line in open(sys.argv[1], 'rb').read().split(b'\n'):
    if not line:
        continue
    o = json.loads(line)
    resps[o.get('id')] = o

err = open(sys.argv[2], 'rb').read()


def body(rid):
    r = resps.get(rid, {}).get('result')
    if r is None:
        return None, None
    return json.loads(r['content'][0]['text']), r.get('isError')


def check(cond, msg):
    (ok if cond else fails).append(msg)


# 1) list
t, e = body(2)
ops = {o['name']: o for o in (t or {}).get('data', {}).get('operations', [])}
check(e is False, 'list 的 isError=false')
check(set(ops) >= {'project.create', 'episode.produce',
                   'continuity.inspect'}, 'list 能发现三个操作')
check(all('version' in v and 'mutates' in v and 'permission' in v
          and 'cost' in v for v in ops.values()),
      'list 带 version/mutates/permission/cost')

# 2) describe
t, e = body(3)
d = (t or {}).get('data', {})
sch = d.get('input_schema', {})
props = sch.get('properties', {})
check(e is False, 'describe 的 isError=false')
check(d.get('version') == '1', 'describe 报版本')
check(d.get('permission') == 'write', 'describe 报权限')
check(d.get('cost') == 'gpu', 'describe 报成本档位')
check(d.get('idempotency_key') == 'operation+input_hash',
      'describe 报幂等键口径')
check(sch.get('additionalProperties') is False,
      'describe 声明 additionalProperties=false')
check(sch.get('required') == ['project_id', 'episode_id'],
      'describe 报 required')
check(props.get('episode_id', {}).get('type') == 'string',
      'describe 报字段类型')
check(props.get('stage', {}).get('enum') == ['script', 'video',
                                            'storyboard', 'render'],
      'describe 报 enum')
check(len(d.get('errors') or []) >= 3, 'describe 报错误码清单')
check('example' in d, 'describe 带最小示例')
stage_enum = props.get('stage', {}).get('enum') or []

# 3) call 执行
t, e = body(4)
dall = (t or {}).get('data') or {}
dd = dall.get('result') or {}
check(e is False, 'call 的 isError=false')
check(dd.get('status') == 'queued', '异步写操作回 queued')
check(bool(dd.get('task_id')), '写操作回 task_id')
check(dall.get('idempotent_replay') is False, '首次调用不是重放')
check(bool((t or {}).get('request_id')), '回显 request_id')
check(bool((t or {}).get('input_hash')), '回 input_hash')

# 6) 幂等
t, e = body(5)
dall2 = (t or {}).get('data') or {}
dd2 = dall2.get('result') or dall2
check(dd2.get('task_id') == dd.get('task_id'), '同键复用 task_id')
check(dall2.get('idempotent_replay') is True, '同键标记 idempotent_replay')

t, e = body(6)
code = ((t or {}).get('error') or {}).get('code')
check(e is False, 'REQUEST_REUSED 仍是业务失败')
check(code == 'REQUEST_REUSED', '同 rid 换 payload 报 REQUEST_REUSED')

# 4) 三类校验失败
t, e = body(7)
er = (t or {}).get('error') or {}
check(e is False, '缺字段仍是业务失败')
check(er.get('code') == 'SCHEMA_INVALID' and er.get('field') == 'project_id',
      '缺 required 字段被拒并指出字段')

t, e = body(8)
er = (t or {}).get('error') or {}
check(er.get('code') == 'TYPE_MISMATCH' and er.get('field') == 'project_id',
      '类型错误单独报 TYPE_MISMATCH')

t, e = body(9)
er = (t or {}).get('error') or {}
check(er.get('code') == 'SCHEMA_INVALID' and er.get('field') == 'nope',
      '未声明字段被拒（additionalProperties=false）')

t, e = body(12)
ddr = (t or {}).get('data', {}).get('result') or {}
check(ddr.get('ok') is True and ddr.get('revision') == 0,
      '读操作回结果（空项目 = 零账本）')
check('task_id' not in ddr, '读操作不发 task_id')

# 7) describe 与 call 同源：describe 的 enum 外值必被拒
t, e = body(10)
er = (t or {}).get('error') or {}
check(er.get('code') == 'SCHEMA_INVALID' and er.get('field') == 'stage',
      'enum 外的值被拒')
check('x' not in stage_enum, 'describe 的 enum 与 call 判定同源')

# 5) 未登记操作
t, e = body(11)
er = (t or {}).get('error') or {}
check(er.get('code') == 'OPERATION_NOT_FOUND', '未登记操作不可执行')

check(err.strip() == b'', 'stderr 干净（日志不污染协议）')

for m in ok:
    print('PASS: ' + m)
for m in fails:
    print('FAIL: ' + m)
sys.exit(1 if fails else 0)
PY
rc=$?

echo "----"
if [ "$rc" -eq 0 ] && [ "$fails" -eq 0 ]; then
    echo "PASS: P2（Registry / Schema / Dispatch）"
    exit 0
fi
echo "FAIL: P2 有未通过项"
exit 1
