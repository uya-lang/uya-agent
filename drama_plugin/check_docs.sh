#!/bin/sh
# drama_plugin/check_docs.sh — 文档版本号一致性检查
#
# 口径：DRAMA_DESIGN 的「版本」、DRAMA_TODO 的「版本」、DRAMA_TODO 的
# 「对应设计 … vX」三处必须一致；不一致就非零退出。升版本时先跑这个。

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$HERE/docs" <<'PY'
import pathlib
import re
import sys

docs = pathlib.Path(sys.argv[1])


def field(path, key):
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.startswith('- ' + key + '：'):
            return line.split('：', 1)[1].strip()
    raise SystemExit('missing %s in %s' % (key, path.name))


dv = field(docs / 'DRAMA_DESIGN.md', '版本')
tv = field(docs / 'DRAMA_TODO.md', '版本')
corr = field(docs / 'DRAMA_TODO.md', '对应设计')
m = re.search(r'DRAMA-DESIGN-(\d+)\s+v([0-9.]+)$', corr)
if not m:
    raise SystemExit('bad 对应设计: %s' % corr)
if not (dv == tv == m.group(2)):
    print('FAIL: DESIGN v%s / TODO v%s / 对应设计 %s 不一致'
          % (dv, tv, corr))
    raise SystemExit(1)
print('PASS: 文档版本一致（DRAMA-DESIGN-%s v%s）' % (m.group(1), dv))
PY
