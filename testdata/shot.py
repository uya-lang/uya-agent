#!/usr/bin/env python3
"""testdata/shot.py —— 把真 TUI 的一屏拍成 SVG / PNG（文档截图用，不属于产品）。

为什么要走**真 PTY** 而不是 `--tui-demo`：那条路输出的是**纯文本**，一个 SGR
都没有（实测 `--color=always` 也没差别），截出来是黑白线框。README 首屏那张图
必须和用户真看到的一样，所以这里 fork 一个真 TUI、给它 100x30 的窗口、按脚本敲
一句话，再把子进程吐出来的**字节流**（含 SGR）喂给一个够用的终端解释器。

为什么不用 asciinema / vhs / 现成截图工具：本仓的判据是「离线、零外部依赖」——
`make shot` 必须在一台只有 python3 + rsvg-convert 的机器上跑出同一张图。所以
终端解释器是这里的一个小状态机（只解 uya-agent 自己会发的那些序列：光标定位、
清屏/清行、SGR、备用屏幕、OSC 标题），与 `src/web/ttyemu.uya` 是同一种白名单思路。

配色：故意只认 uya-agent 实际用的 256 色档位（245 灰、255 白、33 蓝、214 橙、
42 绿…），其余一律落到默认前景 —— 图里出现一个不该有的颜色就说明这份白名单
过期了，比静默截错图好。

用法（网关自己起、自己收，只依赖 python3）：
    make shot                       # 出 docs/tui-demo.svg + .png
    python3 testdata/shot.py --out /tmp/x --prompt "..."

产物：`<out>.svg`（进仓，README 引用）+ `<out>.png`（rsvg-convert 在才生成）。

**哪一处不逐字节可复现**：脚注里的 `cpu N%` 是**真采样**（读进程树的 CPU 时间），
两次跑出来必然不同；`ctx` / `内存` / `LLM 0s` 那些是确定的。所以判据定成
「**除 cpu 采样外**逐行相同」（`make shot` 连跑两次，`diff` 只剩那一行）。
不要为了好看把 cpu 写死 —— 那张图就会开始撒谎。
"""
import argparse
import fcntl
import os
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import termios
import time
import unicodedata
from xml.sax.saxutils import escape

# ── 终端解释器 ────────────────────────────────────────────────────────────
CSI_RE = re.compile(rb'\x1b\[([0-9;?]*)([A-Za-z])')
OSC_RE = re.compile(rb'\x1b\][^\x07\x1b]*(\x07|\x1b\\)')

# SGR 里我们**认**的几条：`(粗体?, 暗?, 256 色号)`。认不出就沿用上一个。
SGR_RE = re.compile(rb'^([0-9;]*)$')


class Screen:
    """够用的屏幕模型：只有字符与「前景色/是否暗/是否粗」这三样样式。"""

    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.cells = [[(' ', None) for _ in range(cols)] for _ in range(rows)]
        self.x = self.y = 0
        self.attr = None

    def put(self, ch, attr):
        """写一个字。**东亚宽字符占两格**（终端就是这么排的，不这么算后面全错位）。"""
        wide = unicodedata.east_asian_width(ch) in ('W', 'F')
        if 0 <= self.y < self.rows and 0 <= self.x < self.cols:
            self.cells[self.y][self.x] = (ch, attr)
        if 0 <= self.y < self.rows and wide and self.x + 1 < self.cols:
            self.cells[self.y][self.x + 1] = ('', attr)
        self.x += 2 if wide else 1

    def erase_line(self):
        for x in range(self.x, self.cols):
            self.cells[self.y][x] = (' ', self.attr)

    def erase_screen(self):
        self.cells = [[(' ', None) for _ in range(self.cols)]
                      for _ in range(self.rows)]

    def move(self, row, col):
        self.y, self.x = max(0, row), max(0, col)


def parse_sgr(params):
    """把 `1;38;5;255` 这种解成 (bold, dim, color256)。不认识的参数忽略。"""
    bold = dim = False
    color = None
    nums = [int(p) for p in params.split(b';') if p]
    i = 0
    while i < len(nums):
        n = nums[i]
        if n == 0:
            bold = dim = False
            color = None
        elif n == 1:
            bold = True
        elif n == 2:
            dim = True
        elif n == 22:
            bold = dim = False
        elif n == 39:
            color = None
        elif n == 38 and i + 2 < len(nums) and nums[i + 1] == 5:
            color = nums[i + 2]
            i += 2
        i += 1
    return (bold, dim, color)


def feed(screen, buf):
    """把 pty 字节流灌进屏幕模型。解码按 UTF-8，坏字节记成 `?`。"""
    i, n = 0, len(buf)
    while i < n:
        b = buf[i]
        if b == 0x1b:
            m = CSI_RE.match(buf, i)
            if m:
                params, final = m.group(1), m.group(2)
                if final == b'H':
                    if params:
                        parts = params.split(b';')
                        row = int(parts[0] or 1) - 1
                        col = int(parts[-1] or 1) - 1 if len(parts) > 1 else 0
                        screen.move(row, col)
                    else:
                        screen.move(0, 0)
                elif final == b'J':
                    screen.erase_screen()
                elif final == b'K':
                    screen.erase_line()
                elif final == b'm':
                    if SGR_RE.match(params):
                        screen.attr = parse_sgr(params)
                i = m.end()
                continue
            m = OSC_RE.match(buf, i)
            if m:
                i = m.end()
                continue
            i += 2
            continue
        if b == 0x0a:
            screen.y += 1
            i += 1
            continue
        if b == 0x0d:
            screen.x = 0
            i += 1
            continue
        # UTF-8：按首字节判长度，解不出来就吃掉一个字节记 `?`
        ln = 1
        if b >= 0xf0:
            ln = 4
        elif b >= 0xe0:
            ln = 3
        elif b >= 0xc0:
            ln = 2
        try:
            ch = buf[i:i + ln].decode('utf-8')
        except UnicodeDecodeError:
            ch, ln = '?', 1
        screen.put(ch, screen.attr)
        i += ln
    return screen


# ── SVG 输出 ──────────────────────────────────────────────────────────────
# 配色表：键是 256 色号或 None（默认前景）。值必须在暗底上读得清 ——
# 这张图会出现在 GitHub 的浅色页面里，所以整幅自带深色背景。
PALETTE = {
    None: '#d8dee9',
    255: '#ffffff',
    254: '#e6e6e6',
    252: '#d0d0d0',
    250: '#bcbcbc',
    248: '#a8a8a8',
    245: '#8a8a8a',
    244: '#808080',
    242: '#6c6c6c',
    240: '#585858',
    238: '#444444',
    33: '#3b9dff',
    39: '#3b9dff',
    42: '#4ec9a0',
    214: '#ffaf5f',
    203: '#ff6b6b',
    196: '#ff4d4d',
    141: '#b48ead',
    177: '#c792ea',
}
BG = '#14161b'
FONT_SIZE = 13
LINE_H = 20
CELL_W = 7.8
PAD = 18


def color_of(attr):
    """→ (fill, opacity, weight)。暗色用透明度表示，粗体用 weight 表示。"""
    if attr is None:
        return PALETTE[None], '1', 'normal'
    bold, dim, color = attr
    fill = PALETTE.get(color, PALETTE[None])
    opacity = '0.55' if dim and not bold else '1'
    weight = 'bold' if bold and not dim else 'normal'
    return fill, opacity, weight


def to_svg(screen, title):
    """把屏幕模型写成一份自包含 SVG（不引外部字体文件，只给 font-family 链）。"""
    cols, rows = screen.cols, screen.rows
    width = int(cols * CELL_W + PAD * 2)
    height = int(rows * LINE_H + PAD * 2 + 26)
    out = []
    out.append('<?xml version="1.0" encoding="UTF-8"?>')
    out.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
               'viewBox="0 0 %d %d" font-family="ui-monospace, '
               'SFMono-Regular, Menlo, Consolas, &quot;Source Han Mono SC&quot;, '
               '&quot;Noto Sans Mono CJK SC&quot;, monospace">'
               % (width, height, width, height))
    out.append('<rect width="100%%" height="100%%" rx="10" fill="%s"/>' % BG)
    # 标题条：一行小字，让图里的人知道这是哪个程序
    out.append('<circle cx="%d" cy="%d" r="5" fill="#ff5f57"/>' % (PAD, PAD - 4))
    out.append('<circle cx="%d" cy="%d" r="5" fill="#febc2e"/>'
               % (PAD + 16, PAD - 4))
    out.append('<circle cx="%d" cy="%d" r="5" fill="#28c840"/>'
               % (PAD + 32, PAD - 4))
    out.append('<text x="%d" y="%d" fill="#8a8a8a" font-size="12">%s</text>'
               % (PAD + 52, PAD, escape(title)))
    top = PAD + 20
    for y in range(rows):
        row = screen.cells[y]
        # 把连续同样式的格子并成一段 <text>，否则每格一个元素、文件会大十倍
        runs = []
        cur, cur_attr, start = [], None, 0
        for x, (ch, attr) in enumerate(row):
            key = attr
            if key != cur_attr:
                if cur:
                    runs.append((start, ''.join(cur), cur_attr))
                cur, cur_attr, start = [ch], key, x
            else:
                cur.append(ch)
        if cur:
            runs.append((start, ''.join(cur), cur_attr))
        for start, text, attr in runs:
            text = text.rstrip()
            if not text:
                continue
            fill, opacity, weight = color_of(attr)
            # 用 `&#160;`（不换行空格）扛住前导空格：HTML/SVG 里连续空格会被
            # 折叠，`xml:space="preserve"` 在浏览器实现里并不可靠（实测首行
            # 缩进被吃掉，整屏看着像右移了）。NBSP 在任何渲染器里都不会折叠。
            text = escape(text).replace(' ', '&#160;')
            out.append(
                '<text x="%.1f" y="%d" fill="%s" opacity="%s" '
                'font-weight="%s" font-size="%d">%s</text>'
                % (PAD + start * CELL_W, top + y * LINE_H, fill, opacity,
                   weight, FONT_SIZE, text))
    out.append('</svg>')
    return '\n'.join(out) + '\n'


# ── 驱动 ──────────────────────────────────────────────────────────────────
def capture(binary, port, workspace, prompt, cols, rows, settle_s, extra):
    """fork 一个真 TUI，喂 prompt 之后把整段字节流收回来。"""
    home = os.path.join(workspace, '..', 'shot-agent-home')
    shutil.rmtree(home, ignore_errors=True)
    args = [binary, '--no-dsh-config', '--no-stream', '--api=chat',
            '--base-url', 'http://127.0.0.1:%s/v1' % port,
            '--api-key', 'shot', '--model', 'mock-model',
            '--workspace', workspace, '--agent-home', home,
            '--tls-verify=none', '--no-save', '--no-title-auto'] + extra
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.environ.pop('UYA_AGENT_MODEL', None)
        os.environ.pop('UYA_AGENT_BASE_URL', None)
        os.execv(args[0], args)
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', rows, cols, 0, 0))
    buf = bytearray()

    def drain(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            buf.extend(chunk)
        return True

    drain(settle_s)
    os.write(fd, (prompt + '\r').encode('utf-8'))
    drain(settle_s * 3)
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return bytes(buf)


def start_gateway():
    """起脚本化假网关，返回 (proc, port)。收工由调用方 kill。

    自己起而不是让用户先起一条：截图命令必须**一条就出图** —— 否则 README 里
    那句「改图请跑 make shot」就变成「先读三段说明再跑三条命令」，没人会照做，
    图很快就会与真界面对不上（这一屏的价值全在「它真的长这样」）。
    """
    proc = subprocess.Popen(
        [sys.executable,
         os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      'mock_gateway_demo.py'), '0'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    line = proc.stdout.readline().decode('utf-8', 'replace')
    for tok in line.split():
        if tok.isdigit():
            return proc, int(tok)
    proc.kill()
    raise SystemExit('shot: 起不来假网关（输出 %r）' % line[:200])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=0,
                    help='用已在跑的网关端口；0 = 自己起一个（默认）')
    ap.add_argument('--bin', default='build/uya-agent')
    ap.add_argument('--out', default='docs/tui-demo',
                    help='输出前缀；会写 <out>.svg 与 <out>.png')
    ap.add_argument('--prompt', default='把 hello.uya 的问候语改成 Hello, uya!')
    ap.add_argument('--title', default='uya-agent')
    ap.add_argument('--cols', type=int, default=100)
    ap.add_argument('--rows', type=int, default=30)
    ap.add_argument('--tool-lines', type=int, default=3,
                    help='工具正文首尾各留几行（0 = 只留一行标题）')
    ap.add_argument('--settle', type=float, default=2.0)
    args = ap.parse_args()

    workspace = os.path.join('/tmp', 'hello-uya')
    shutil.rmtree(workspace, ignore_errors=True)
    os.makedirs(workspace)
    with open(os.path.join(workspace, 'hello.uya'), 'w',
              encoding='utf-8') as fh:
        fh.write('export fn main() i32 {\n'
                 '    @println("Hello, DSH!");\n'
                 '    return 0;\n'
                 '}\n')

    gw = None
    port = args.port
    if port == 0:
        gw, port = start_gateway()
    try:
        extra = ['--tool-lines', str(args.tool_lines)]
        raw = capture(args.bin, port, workspace, args.prompt,
                      args.cols, args.rows, args.settle, extra)
    finally:
        if gw is not None:
            gw.kill()
            gw.wait()
    screen = feed(Screen(args.cols, args.rows), raw)
    svg = to_svg(screen, args.title)
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out + '.svg', 'w', encoding='utf-8') as fh:
        fh.write(svg)
    print('shot: %s.svg（%d 字节）' % (args.out, len(svg)))
    rsvg = shutil.which('rsvg-convert')
    if not rsvg:
        print('shot: 没有 rsvg-convert，跳过 PNG（SVG 已写好）')
        return 0
    png = args.out + '.png'
    subprocess.run([rsvg, '-z', '2', args.out + '.svg', '-o', png], check=True)
    print('shot: %s（%d 字节）' % (png, os.path.getsize(png)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
