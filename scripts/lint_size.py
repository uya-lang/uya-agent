#!/usr/bin/env python3
"""scripts/lint_size.py — AGENTS.md 三条硬指标的检查器。

用法：
    python3 scripts/lint_size.py --all          # 看存量（退出码恒 0）
    python3 scripts/lint_size.py --changed      # 只查本次 git 改动新增的行（评审门槛）
    python3 scripts/lint_size.py FILE...        # 只查给定文件（同样只报存量）

三条指标（见 AGENTS.md）：
    1. 文件 <= 2000 行
    2. 函数 <= 100 行
    3. 行宽 <= 80 字符

口径（必须写死，否则「80 列」在中文注释里会有两种读法）：
    * **行宽按 Unicode 码点计**（`len(line)`，与 UTF-8-aware 的
      `awk 'length($0)>80'` 同口径）。**不按终端显示列**（CJK 算 2 列）——
      本仓注释以中文为主，按显示列算等于只给 40 个汉字，注释会被压缩到读不懂。
    * 报告里附带显示列数（CJK 算 2 列），**不作为判据**。

`--changed` 的口径是 **git diff 新增的行**（`git diff -U0` 里 '+' 开头那些），
所以「改一行老代码」不会因为那个函数本来就超长而报警 —— 这正是 AGENTS.md
「历史存量不追」那条的机器实现。未跟踪的新文件按「整份都是新增」算。
"""

import os
import re
import subprocess
import sys
import unicodedata

FILE_MAX_LINES = 2000
FUNC_MAX_LINES = 100
LINE_MAX_CHARS = 80

# `fn` 声明的头部（含 `export fn` / 带缩进的嵌套 fn / `extern "libc" fn`）
FN_RE = re.compile(r'^\s*(?:export\s+)?(?:extern\s+"[^"]*"\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)')


def disp_cols(s):
    """显示列数：东亚宽/全角按 2 列，组合字符 0 列，制表符按 8 列停靠。
    只用于报告里附带显示，**不作为判据**（判据是码点数，见文件头口径）。"""
    n = 0
    for ch in s:
        if ch == '\t':
            n += 8 - (n % 8)
        elif unicodedata.combining(ch):
            continue
        elif unicodedata.east_asian_width(ch) in ('W', 'F'):
            n += 2
        else:
            n += 1
    return n


def read_lines(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        return fh.read().split('\n')


def scan_functions(lines):
    """返回 [(name, start_idx, end_idx)]（0 基闭区间）。

    只认「花括号配平」的收尾：Uya 的函数体一定有 `{`，所以从 `fn` 那一行开始数
    `{` / `}` 的净值，回到 <= 0 且这一行里出现过 `{` 就算结束。
    单行声明（`fn f() void { … }` 或错误码体 `fn f() !i32 { return 1; }`）因此也算得上。
    """
    out = []
    i = 0
    n = len(lines)
    while i < n:
        m = FN_RE.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        depth = 0
        seen_brace = False
        j = i
        # 头部可能跨行（参数列表按 80 列折行），所以一直数到配平为止
        while j < n:
            depth += lines[j].count('{') - lines[j].count('}')
            if '{' in lines[j]:
                seen_brace = True
            if seen_brace and depth <= 0:
                break
            j += 1
        if not seen_brace:
            i += 1
            continue
        out.append((name, i, min(j, n - 1)))
        i = j + 1
    return out


def added_lines_for(path, changed_map):
    """返回该文件「本次新增」的行号集合（1 基）。changed_map 为 None 表示不筛。"""
    if changed_map is None:
        return None
    return changed_map.get(path)


def check_file(path, changed_map):
    """返回 (violations, stats)。violations 是 [(kind, line_no, detail)]。"""
    try:
        lines = read_lines(path)
    except OSError as exc:
        return [('io', 0, str(exc))], {}
    # 末尾换行会split出一个空串，不计入行数
    if lines and lines[-1] == '':
        lines = lines[:-1]
    added = added_lines_for(path, changed_map)
    viol = []

    # ① 文件长度：只有「整份都算新增」的新文件才判（改动老文件不判，见 AGENTS.md）
    if len(lines) > FILE_MAX_LINES and (added is None or len(added) >= len(lines) - 2):
        viol.append(('file-len', len(lines),
                     '%d 行 > %d' % (len(lines), FILE_MAX_LINES)))

    # ② 函数长度：函数的**收尾行**属于新增时才判（否则是存量）
    for name, s, e in scan_functions(lines):
        length = e - s + 1
        if length <= FUNC_MAX_LINES:
            continue
        if added is not None and (e + 1) not in added:
            continue
        # 函数上方写了「行宽豁免/不拆」说明的放行（AGENTS.md 的例外条款）
        head = '\n'.join(lines[max(0, s - 6):s])
        if '不拆' in head or 'lint-size:ignore' in head:
            continue
        viol.append(('func-len', s + 1, '%s 起 %d 行 > %d' % (name, length, FUNC_MAX_LINES)))

    # ③ 行宽：只看新增行
    for idx, raw in enumerate(lines):
        lineno = idx + 1
        if added is not None and lineno not in added:
            continue
        nchar = len(raw)
        if nchar <= LINE_MAX_CHARS:
            continue
        # 豁免：本行或**上方 5 行内**有显式声明（长 URL / MIME 字面量这类不可断的
        # 内容，一处声明覆盖一整块连续的字面量；见 AGENTS.md 的例外条款）。
        lo = max(0, idx - 5)
        near = '\n'.join(lines[lo:idx + 1])
        if '行宽豁免' in near or 'lint-size:ignore' in near:
            continue
        viol.append(('line-width', lineno,
                     '%d 字符（显示 %d 列）> %d'
                     % (nchar, disp_cols(raw), LINE_MAX_CHARS)))
    return viol, {'lines': len(lines)}


def git_changed_map(root):
    """git 本次改动新增的行 → {相对路径: set(行号)}。

    用 `git diff -U0 HEAD` + 未跟踪文件（`git ls-files --others`）。工作区干净时
    再退一步看 `HEAD~1..HEAD`，这样「刚提交完再跑一次」也能看到本次改动。
    """
    changed = {}

    def parse(diff_text):
        cur = None
        for line in diff_text.split('\n'):
            if line.startswith('+++ b/'):
                cur = line[6:]
                changed.setdefault(cur, set())
            elif line.startswith('@@') and cur is not None:
                m = re.search(r'\+(\d+)(?:,(\d+))?', line)
                if not m:
                    continue
                start = int(m.group(1))
                count = int(m.group(2)) if m.group(2) is not None else 1
                for k in range(count):
                    changed[cur].add(start + k)

    for args in (['git', 'diff', '-U0', 'HEAD'],
                 ['git', 'diff', '-U0', 'HEAD~1', 'HEAD']):
        try:
            res = subprocess.run(args, cwd=root, capture_output=True, text=True)
        except OSError:
            return None
        if res.returncode == 0 and res.stdout.strip():
            parse(res.stdout)
            break
    # 未跟踪的新文件：整份都算新增（用一个大集合表示"全部"）
    try:
        res = subprocess.run(['git', 'ls-files', '--others', '--exclude-standard'],
                             cwd=root, capture_output=True, text=True)
        if res.returncode == 0:
            for rel in res.stdout.split():
                if rel.endswith('.uya'):
                    changed[rel] = None      # None = 全部行都算新增
    except OSError:
        pass
    if not changed:
        return None
    # None 展开：读文件行数后补全
    for rel in list(changed):
        if changed[rel] is None:
            try:
                n = len(read_lines(os.path.join(root, rel)))
            except OSError:
                n = 0
            changed[rel] = set(range(1, n + 2))
    return changed


def collect_targets(root, argv):
    if argv:
        return list(argv)
    out = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, 'src')):
        dirnames[:] = [d for d in dirnames if d not in ('build', '.git')]
        for fn in sorted(filenames):
            if fn.endswith('.uya'):
                out.append(os.path.relpath(os.path.join(dirpath, fn), root))
    return sorted(out)


def main():
    argv = sys.argv[1:]
    mode = 'changed' if '--changed' in argv else ('all' if '--all' in argv else 'changed')
    files = [a for a in argv if not a.startswith('--')]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    changed_map = git_changed_map(root) if (mode == 'changed' and not files) else None
    if mode == 'changed' and changed_map is None and not files:
        print('lint-size: 没有 git 改动可比（工作区干净且 HEAD 无父提交）'
              '—— 按全量存量检查，退出码 0')
        mode = 'all'

    targets = collect_targets(root, files)
    if changed_map is not None:
        # 只查这次真动过的 .uya 文件
        targets = [t for t in targets if t in changed_map]
        if not targets:
            print('lint-size: 通过（本次没有改动 .uya 文件）')
            return 0

    total_viol = 0
    for rel in targets:
        path = rel if os.path.isabs(rel) else os.path.join(root, rel)
        viol, _ = check_file(path, changed_map)
        if not viol:
            continue
        print('%s:' % rel)
        for kind, lineno, detail in viol:
            total_viol += 1
            label = {'file-len': '文件过长', 'func-len': '函数过长',
                     'line-width': '行宽超限', 'io': '读不了'}[kind]
            print('  %s:%d: %s（%s）' % (rel, lineno, label, detail))

    if total_viol == 0:
        scope = '本次改动' if changed_map is not None else '全部文件'
        print('lint-size: 通过（%s 的 %d 个文件满足 AGENTS.md 三条指标）'
              % (scope, len(targets)))
        return 0
    print('lint-size: %d 处违规（AGENTS.md 三条指标）' % total_viol)
    # --all 是"看存量"，不当场红
    return 0 if mode == 'all' else 1


if __name__ == '__main__':
    sys.exit(main())
