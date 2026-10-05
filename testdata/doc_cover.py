#!/usr/bin/env python3
"""doc-cover —— 文档覆盖审计（CODING.md §2 / §3 的可执行版本）。

来历：文件头 5 行与函数前置注释是本仓「改一处只读一小块」的全部依据 —— 它们是**本地索引**，
不是装饰。但这两件事**没有任何测试看得见**：漏一行头注释、少一句函数注释，`make build`、
`make selftest`、`link-audit`、`codegen-audit`、`doc-audit` 全绿（与踩坑 94 的冲突标记同族：
「全绿」只覆盖被断言过的东西）。所以文档这类没有功能断言的产物必须单独有一条审计。

只读检查，不改任何文件。退出码：0 = 通过；1 = 有缺口。

用法：
    python3 testdata/doc_cover.py            # 扫 src/ 下所有 .uya
    python3 testdata/doc_cover.py --list     # 连通过项也打印

判据（两条，都是 CODING.md 里写死的）：
  1. **文件头四行**：`本文件：` / `不变量：` / `依赖：` / `命名：` 必须在**文件头注释块**里
     （`//` 开头、且在第一段连续注释之内）；第 1 行必须是 `// src/<域>/<文件>.uya — …`
     —— 重组过目录之后，留旧路径的文件头等于索引指向一个不存在的文件。
  2. **函数前置注释**：每个 `fn` / `export fn` 声明的**紧邻上方**必须有 `//` 注释行
     （中间不空行）。Uya 只有 `//`，没有 `///` 与 `/* */`。

例外（写着为了不误报）：
  * `src/tools.uya` 是 P50 起不在构建里的死文件，不在审计范围（见 Makefile 的 SRC 注释）。
  * 只审计 `Makefile` 的 `SRC` 列出的文件 —— 没进构建的文件没有读者。
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEADER_FIELDS = ('本文件：', '不变量：', '依赖：', '命名：')
# 文件头注释块的行数上限：超过这个还不齐，就不是「头」了
HEADER_SCAN_LINES = 40


def src_files():
    """从 Makefile 的 SRC 变量取文件清单（唯一真值，别手抄）。"""
    out = subprocess.run(['make', '-s', 'print-src'], cwd=REPO,
                         capture_output=True, text=True, check=True).stdout
    return [p for p in out.split() if p.endswith('.uya')]


def check_header(path, lines):
    """返回缺口描述列表（空 = 通过）。"""
    problems = []
    # 第 1 行必须是新路径
    want_prefix = '// ' + path + ' — '
    first = lines[0] if lines else ''
    if not first.startswith(want_prefix):
        problems.append('第 1 行不是 `// %s — …`（重组目录后留了旧路径？）实际：%s'
                        % (path, first[:70]))
    # 四字段必须在头注释块里
    head = []
    for ln in lines[:HEADER_SCAN_LINES]:
        if ln.startswith('//'):
            head.append(ln)
        elif head:
            break            # 注释块结束
    headtext = '\n'.join(head)
    for f in HEADER_FIELDS:
        if f not in headtext:
            problems.append('文件头缺 `%s`' % f)
    return problems


FN_RE = re.compile(r'^(export )?fn\s')


def check_functions(lines):
    """返回缺注释的函数行号列表。

    判据：紧邻上方是 `//`，**或**上方隔一个空行再是 `//`。后者在仓里是少数派
    （实测 12 处 vs 紧贴 1900+ 处），但注释确实在，不该判红 —— 审计的红必须指向
    「真的没有」，否则它会先把自己的可信度耗掉（与踩坑 86「判据要读事实」同族）。
    推荐写法仍是紧贴（CODING.md §3）。
    """
    missing = []
    for i, ln in enumerate(lines):
        if not FN_RE.match(ln):
            continue
        j = i - 1
        if j >= 0 and lines[j].startswith('//'):
            continue                      # 紧贴
        if (j - 1 >= 0 and not lines[j].strip() and lines[j - 1].startswith('//')):
            continue                      # 隔一个空行
        missing.append(i + 1)
    return missing


def main():
    show_all = '--list' in sys.argv
    files = src_files()
    n_ok = 0
    n_fn = 0        # 全部函数声明
    n_bad = 0       # 缺注释的函数
    report = []
    for path in files:
        full = os.path.join(REPO, path)
        if not os.path.exists(full):
            report.append((path, ['文件不存在（Makefile 的 SRC 与磁盘不一致）']))
            continue
        lines = open(full, encoding='utf-8').read().split('\n')
        problems = check_header(path, lines)
        total = sum(1 for ln in lines if FN_RE.match(ln))
        miss = check_functions(lines)
        n_fn += total
        n_bad += len(miss)
        if miss:
            problems.append('%d/%d 个函数缺前置注释（行号：%s）'
                            % (len(miss), total,
                               ', '.join(str(x) for x in miss[:12])
                               + (' …' if len(miss) > 12 else '')))
        if problems:
            report.append((path, problems))
        else:
            n_ok += 1
            if show_all:
                report.append((path, ['ok']))

    print('doc-cover: 扫了 %d 个构建文件 / %d 个函数声明；缺注释 %d 个'
          % (len(files), n_fn, n_bad))
    if not report:
        print('doc-cover: 通过（文件头四行齐、每个函数都有前置注释）')
        return 0
    for path, problems in report:
        for p in problems:
            print('  %-38s %s' % (path, p))
    print('doc-cover: %d/%d 个文件通过 —— 缺口见上（规范见 CODING.md §2 / §3）'
          % (n_ok, len(files)))
    return 1


if __name__ == '__main__':
    sys.exit(main())
