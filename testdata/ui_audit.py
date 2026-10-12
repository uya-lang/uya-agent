#!/usr/bin/env python3
"""ui-audit —— 界面后端接缝的机器判据（CODING.md §1.4 / DESIGN.md §11.9 的可执行版本）。

来历：这套接缝存在的全部意义是「**换后端不动执行核**」。但这条承诺**没有任何功能断言
看得见** —— 端口装好了、后端也实现了，然后有人在 `agent/` 里又写一句
`if tui_active()`，或者更糟：写一句 `&g_tui as &UiBackend`（**能编译、能链接、运行期
SIGSEGV**）。`make build` / `make check` / `make selftest` 对这两件事都是绿的（编译期
看不见「谁调了谁」，段错误只在跑到那条路径时才炸）。与 §4 踩坑 94 同族：**「全绿」只覆盖
被断言过的东西**，所以没有断言的结构约束必须自己有一条。

只读检查，不改任何文件。退出码：0 = 通过；1 = 有违规。

用法：
    python3 testdata/ui_audit.py            # 全部判据
    python3 testdata/ui_audit.py --list     # 连通过项也打印

判据（六条，逐条对应 CODING.md §1.4 与 DESIGN.md §11.9）：

  A. **接口转换陷阱**（最要命的一条）：全仓任何地方不许出现
     `&<表达式> as &<接口名>`。`&具体struct as &接口` 能编译、能链接，但 codegen 不构造
     `{vtable, data}` 对 ⇒ **运行期 SIGSEGV**。接口值只能由「具体 struct → 接口变量」
     的赋值构造（`var r: I = g_reg[i];`）。
  B. **执行层不许直呼后端私有符号**：`agent/ tools/ net/ media/ diff/ vcs/ pm/ plugin/`
     里不许出现 `betui_` / `bescroll_` / `beevents_` / `benull_`。要输出就走 `ui_*` 端口。
  C. **端口层不许认识执行核**：`src/ui/**` 里不许出现 `Config` / `agent_` / `g_sess` /
     `g_turn`。端口层一旦依赖执行核，后端就换不动、也没法独立自测。
  D. **后端必须实现接口**：`src/ui/be_*.uya` 里每个 `export struct` 都要 `: UiBackend`。
     漏实现方法是编译期错误，但「根本忘了写 `: UiBackend`」不会报错（那只是个普通
     struct），所以这条要机器看。
  E. **注册表槽位必须填满**：`src/ui/ui_reg.uya` 的 `g_reg` 数组字面量元素个数必须等于
     `UI_BE_MAX`。空槽的 vtable 是 null，`ui_use` 切过去即崩。
  F. **`tui_active()` / `tui_overlay_kind()` 的欠账计数**（**进展量，不是硬门槛**）：
     P80 的目标是把它们从执行核里清零。清零之前这里只报数、不判失败 —— 它们今天还有
     19 + 10 处，硬红了等于让整条审计在过渡期永远红，那样的审计会被关掉。
     清零之后把本项改成硬判据。
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 执行层：它只该认 ui_* 端口，不该认识任何具体后端
EXEC_DIRS = ('agent', 'tools', 'net', 'media', 'diff', 'vcs', 'pm', 'plugin')
# 后端私有前缀（只有 src/ui/ 内部能用）
BACKEND_PREFIXES = ('betui_', 'bescroll_', 'beevents_', 'benull_')
# 端口层不许出现的执行核符号
EXEC_SYMBOLS = ('Config', 'agent_', 'g_sess', 'g_turn', 'History')


def uya_files(root):
    """列出 root 下所有 .uya 文件（相对仓库根的路径）。"""
    out = []
    for dirpath, _dirnames, filenames in os.walk(os.path.join(REPO, root)):
        for fn in filenames:
            if fn.endswith('.uya'):
                out.append(os.path.relpath(os.path.join(dirpath, fn), REPO))
    return sorted(out)


def read_lines(rel):
    """读文件的行；失败返回空列表（审计不该因为一个读不到的文件崩掉）。"""
    try:
        with open(os.path.join(REPO, rel), 'r', encoding='utf-8', errors='replace') as f:
            return f.readlines()
    except OSError:
        return []


def strip_comment(line):
    """去掉 `//` 之后的注释部分（字符串字面量里的 `//` 不处理 —— 本仓没有这种写法，
    真出现了也只是漏报，不会误报）。"""
    at = line.find('//')
    return line if at < 0 else line[:at]


# ---- A：接口转换陷阱 ----
# 判据必须**只认接口名**：`null as &HandshakeCtx` 这类普通指针转换是本仓到处都有的正常
# 写法，误报一大片的话这条审计会被关掉。所以接口名从源码里现扫 `interface X` 得来
# （新增接口自动进入判据，不用改脚本）。
IFACE_DECL = re.compile(r'^\s*(?:export\s+)?interface\s+([A-Za-z0-9_]+)')


def interface_names():
    """扫全仓 `interface X` 声明，返回接口名集合。"""
    names = set()
    for rel in uya_files('src'):
        for line in read_lines(rel):
            m = IFACE_DECL.match(strip_comment(line))
            if m:
                names.add(m.group(1))
    return names


def check_cast_trap(ifaces):
    """A：`&x as &Interface` —— 能编译、能链接，**运行期 SIGSEGV**。

    安全写法是「具体 struct → 接口变量」的赋值（`var r: I = g_reg[i];`），
    或传 `&接口变量`；`&具体struct as &接口` 不构造 {vtable, data} 对。
    """
    if not ifaces:
        return []
    pat = re.compile(r'as\s+&\s*(%s)\b' % '|'.join(sorted(ifaces)))
    bad = []
    for rel in uya_files('src'):
        for i, line in enumerate(read_lines(rel), 1):
            code = strip_comment(line)
            if pat.search(code):
                bad.append('%s:%d: %s' % (rel, i, line.strip()))
    return bad


# ---- B：执行层不许直呼后端私有符号 ----
def check_backend_leak():
    """B：执行层出现 betui_/bescroll_/beevents_/benull_ = 绕过了端口。"""
    bad = []
    for d in EXEC_DIRS:
        for rel in uya_files('src/' + d):
            for i, line in enumerate(read_lines(rel), 1):
                code = strip_comment(line)
                for p in BACKEND_PREFIXES:
                    if p in code:
                        bad.append('%s:%d: %s' % (rel, i, line.strip()))
                        break
    return bad


# ---- C：端口层不许认识执行核 ----
def check_port_purity():
    """C：src/ui/ 里出现执行核符号 = 端口层反向依赖了执行核。"""
    bad = []
    for rel in uya_files('src/ui'):
        for i, line in enumerate(read_lines(rel), 1):
            code = strip_comment(line)
            for s in EXEC_SYMBOLS:
                if s in code:
                    bad.append('%s:%d: %s' % (rel, i, line.strip()))
                    break
    return bad


# ---- D：后端必须实现接口 ----
STRUCT_DECL = re.compile(r'^\s*export\s+struct\s+([A-Za-z0-9_]+)\s*(:\s*([A-Za-z0-9_]+))?')


def check_backend_impl():
    """D：src/ui/be_*.uya 里每个 export struct 都要 `: UiBackend`。"""
    bad = []
    for rel in uya_files('src/ui'):
        base = os.path.basename(rel)
        if not base.startswith('be_'):
            continue
        for i, line in enumerate(read_lines(rel), 1):
            m = STRUCT_DECL.match(strip_comment(line))
            if m and m.group(3) != 'UiBackend':
                bad.append('%s:%d: struct %s 没有实现 UiBackend' % (rel, i, m.group(1)))
    return bad


# ---- E：注册表槽位填满 ----
REG_DECL = re.compile(r'var\s+g_reg\s*:\s*\[UiBackend\s*:\s*UI_BE_MAX\]\s*=\s*\[([^\]]*)\]')


def check_registry_full():
    """E：g_reg 的字面量元素个数必须 == UI_BE_MAX（空槽 = null vtable = 切过去即崩）。"""
    bad = []
    src = ''.join(read_lines('src/ui/ui_reg.uya'))
    m = REG_DECL.search(src)
    if not m:
        return ['src/ui/ui_reg.uya: 找不到 g_reg 的数组字面量（判据 E 需要它保持这个形状）']
    n = len([x for x in m.group(1).split(',') if x.strip()])
    maxm = re.search(r'UI_BE_MAX\s*:\s*usize\s*=\s*(\d+)', ''.join(read_lines('src/ui/ui_port.uya')))
    if not maxm:
        return ['src/ui/ui_port.uya: 找不到 UI_BE_MAX']
    want = int(maxm.group(1))
    if n != want:
        bad.append('src/ui/ui_reg.uya: g_reg 填了 %d 个槽，UI_BE_MAX = %d（空槽的 vtable 是 null）'
                   % (n, want))
    return bad


# ---- F：欠账计数（进展量，不判失败）----
def count_debt():
    """F：执行层里 tui_active() / tui_overlay_kind() 的出现次数（P80 的目标是 0）。"""
    out = []
    for d in EXEC_DIRS:
        for rel in uya_files('src/' + d):
            text = ''.join(strip_comment(l) for l in read_lines(rel))
            a = text.count('tui_active()')
            b = text.count('tui_overlay_kind()')
            if a or b:
                out.append((rel, a, b))
    return out


def main():
    show_all = '--list' in sys.argv
    ifaces = interface_names()
    sections = [
        ('A 接口转换陷阱（`&x as &I` → 运行期段错误）', check_cast_trap(ifaces)),
        ('B 执行层直呼后端私有符号', check_backend_leak()),
        ('C 端口层依赖执行核', check_port_purity()),
        ('D 后端没有实现 UiBackend', check_backend_impl()),
        ('E 注册表槽位没填满', check_registry_full()),
    ]
    failed = 0
    for title, bad in sections:
        if bad:
            failed = 1
            print('ui-audit: [红] %s —— %d 处' % (title, len(bad)))
            for line in bad[:20]:
                print('    ' + line)
            if len(bad) > 20:
                print('    …（还有 %d 处）' % (len(bad) - 20))
        elif show_all:
            print('ui-audit: [绿] %s' % title)

    debt = count_debt()
    total = sum(a + b for _r, a, b in debt)
    if debt:
        print('ui-audit: [欠账] 执行核里 tui_active() / tui_overlay_kind() 共 %d 处'
              '（P80 目标 0；清零后本项改硬判据）' % total)
        if show_all:
            for rel, a, b in debt:
                print('    %s: tui_active=%d tui_overlay_kind=%d' % (rel, a, b))
    else:
        print('ui-audit: [绿] 执行核里 tui_active() / tui_overlay_kind() 已清零')

    if failed:
        print('ui-audit: 失败')
        return 1
    print('ui-audit: 通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
