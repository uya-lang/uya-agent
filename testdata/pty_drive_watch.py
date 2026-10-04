#!/usr/bin/env python3
"""PTY 驱动（P42 验收用，不属于产品）：验收 `/watch` 的实时性。

现场：真终端里的 uya-agent 派出一个子代理 → 子代理先思考、再跑 `sleep N` 的 bash →
期间敲 `/watch sub-1` → 必须能在**子代理结束之前**看到 `[step …]` / `▸ bash …` 上屏。

这就是「实时」的判据：不是「最后能看到」，而是「还在跑的时候就已经看到」。
（对照旧行为：面板上那列「已收输出行数」对普通 subagent 恒为 0 —— 管道只承载终态答复。）

用例：
    python3 testdata/pty_drive_watch.py --port PORT --workspace DIR [--sleep 8]

输出一行 VERDICT: PASS/FAIL 并给出各判据 + 最后一屏；PTY_DUMP=1 时总是打屏。
"""
import argparse
import os
import pty
import re
import select
import signal
import struct
import sys
import time

BIN = os.environ.get("UYA_BIN", "./build/uya-agent")

CSI_RE = re.compile(rb"\x1b\[([0-9;?]*)([A-Za-z])")
OSC_RE = re.compile(rb"\x1b\]([^\x07\x1b]*)(\x07|\x1b\\)")


class Screen:
    """极简终端解释器：够判断我们要找的字符串出现（与 pty_drive.py 同一路子）。"""

    def __init__(self, cols=110, rows=30):
        self.cols, self.rows = cols, rows
        self.buf = [[" "] * cols for _ in range(rows)]
        self.row = self.col = 0

    def feed(self, data):
        i, n = 0, len(data)
        while i < n:
            b = data[i]
            if b == 0x1B:
                m = CSI_RE.match(data, i)
                if m:
                    self.csi(m.group(1).decode("ascii", "replace"), m.group(2).decode("ascii"))
                    i = m.end()
                    continue
                m = OSC_RE.match(data, i)
                if m:
                    i = m.end()
                    continue
                i += 1
                continue
            if b == 0x0A:
                self.row = min(self.rows - 1, self.row + 1)
                i += 1
                continue
            if b == 0x0D:
                self.col = 0
                i += 1
                continue
            ln = 1
            if b >= 0xF0:
                ln = 4
            elif b >= 0xE0:
                ln = 3
            elif b >= 0xC0:
                ln = 2
            try:
                ch = data[i:i + ln].decode("utf-8")
            except UnicodeDecodeError:
                ch, ln = "?", 1
            if self.col < self.cols:
                self.buf[self.row][self.col] = ch
            self.col = min(self.cols - 1, self.col + 1)
            i += ln

    def csi(self, params, final):
        if params.startswith("?"):
            return
        if final in ("H", "f"):
            parts = [p for p in params.split(";") if p.isdigit()]
            r = int(parts[0]) if parts else 1
            c = int(parts[1]) if len(parts) > 1 else 1
            self.row = max(0, min(self.rows - 1, r - 1))
            self.col = max(0, min(self.cols - 1, c - 1))
        elif final == "J":
            self.buf = [[" "] * self.cols for _ in range(self.rows)]
            self.row = self.col = 0
        elif final == "K":
            for c in range(self.col, self.cols):
                self.buf[self.row][c] = " "

    def text(self):
        return "\n".join("".join(r).rstrip() for r in self.buf)


def pump(fd, scr, seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            scr.feed(data)


def drive(port, workspace, sleep_secs, mode="direct", extra=None):
    os.makedirs(workspace, exist_ok=True)
    extra = extra or []
    env = dict(os.environ)
    env["UYA_AGENT_API_KEY"] = "dummy"
    env.pop("DEEPSEEK_API_KEY", None)
    env.pop("OPENAI_API_KEY", None)
    argv = [BIN, "--no-dsh-config", "--base-url", "http://127.0.0.1:%d/v1" % port,
            "--api=chat", "--model", "watch-mock", "--workspace", workspace,
            "--agent-home", os.path.join(workspace, ".home"), "--tls-verify=none"] + extra
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
        os._exit(127)
    import fcntl
    import termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 110, 0, 0))

    scr = Screen()
    verdict = {"mode": mode}
    cr = b"\r"
    try:
        pump(fd, scr, 1.2)
        verdict["frame_ok"] = "Ask anything" in scr.text()
        os.write(fd, "派一个会跑慢工具的子代理\r".encode("utf-8"))
        # 等子代理真的开跑（agents 面板上出现 sub-1）
        t0 = time.time()
        while time.time() - t0 < 15:
            pump(fd, scr, 0.3)
            if "sub-1 [subagent]" in scr.text():
                break
        verdict["agent_seen"] = "sub-1 [subagent]" in scr.text()

        if mode == "direct":
            # P42 那条路：敲 /watch sub-1。TUI 输入纪律：以 / 开头先弹命令面板；这条不在
            # 表内，回车把整行还回输入行（+ notice），**再**回车才真的派发。
            os.write(fd, "/watch sub-1".encode("utf-8"))
            pump(fd, scr, 0.5)
            os.write(fd, cr)
            pump(fd, scr, 0.5)
            os.write(fd, cr)
            pump(fd, scr, 0.8)
        elif mode == "pick":
            # P46：裸 /watch → 面板里选中 /watch → 现役清单浮层。
            # 游标默认落在**第一个代理行**上（第 0 行是表头），所以**一次回车**就该开始跟随。
            os.write(fd, "/watch".encode("utf-8"))
            pump(fd, scr, 0.6)
            os.write(fd, cr)
            pump(fd, scr, 0.9)
            if "跟随子代理（" not in scr.text():
                os.write(fd, cr)          # 面板那条路要第二次回车时兜一下
                pump(fd, scr, 0.9)
            verdict["list_opened"] = "跟随子代理（" in scr.text()
            verdict["list_hint"] = "回车跟随" in scr.text()
            verdict["list_row"] = "sub-1 [running]" in scr.text()
            t_pick = time.time()
            os.write(fd, cr)
            pump(fd, scr, 1.2)
            verdict["pick_secs"] = round(time.time() - t_pick, 1)
            # 游标要是落在表头上，得到的会是这句 notice（P46 之前的样子）
            verdict["header_notice"] = "没认出子代理编号" in scr.text()
        else:  # running
            # P46：父代理那一轮**还在飞**（假网关把 parent-final 按住）时敲 /watch sub-1。
            # 面板拦一道（+ 提示「再按一次回车」），第二次回车派发 —— 必须**当场**开浮层，
            # 而不是等父代理的回合结束。
            os.write(fd, "/watch sub-1".encode("utf-8"))
            pump(fd, scr, 0.5)
            os.write(fd, cr)
            pump(fd, scr, 0.4)
            verdict["hint_seen"] = "再按一次回车" in scr.text()
            t_pick = time.time()
            os.write(fd, cr)
            pump(fd, scr, 1.2)
            verdict["pick_secs"] = round(time.time() - t_pick, 1)

        verdict["watch_opened"] = "跟随 sub-1" in scr.text()
        verdict["parent_done_seen"] = "PARENT-DONE-OK" in scr.text()
        verdict["frame_after_open"] = scr.text()

        # 关键判据：在子代理**还在跑**的时候就出现这些事件
        need = ("[step", "▸ bash")
        first_seen = {}
        ended_seen = False
        tw = time.time()
        while time.time() - tw < sleep_secs + 14:
            pump(fd, scr, 0.3)
            txt = scr.text()
            for k in need:
                if k not in first_seen and k in txt:
                    first_seen[k] = round(time.time() - tw, 1)
            if "已结束" in txt:
                ended_seen = True
                # 已结束之后再多收一会儿，让最后几条事件都画出来
                if len(first_seen) == len(need):
                    pump(fd, scr, 1.0)
                    break
        verdict["first_seen"] = first_seen
        verdict["ended_seen"] = ended_seen
        verdict["tool_done_seen"] = "CHILD_TOOL_DONE" in scr.text()
        # 结束行出现时，说明这次跟随走完了整个生命周期
        verdict["final_frame"] = scr.text()
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
    return verdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--sleep", type=int, default=8, help="子代理那条慢命令睡多久")
    ap.add_argument("--mode", default="direct", choices=("direct", "pick", "running"),
                    help="direct=P42 的 /watch sub-1；pick=P46 清单里选中即跟随；"
                         "running=P46 父代理回合还在飞时敲 /watch sub-1")
    ap.add_argument("--parent-hold", type=int, default=0,
                    help="running 模式：假网关把父代理收尾按住多少秒（必须 > 开浮层耗时）")
    args = ap.parse_args()

    v = drive(args.port, args.workspace, args.sleep, args.mode)
    failures = []

    def check(cond, msg):
        if not cond:
            failures.append(msg)

    check(v.get("frame_ok"), "首帧没画出来（'Ask anything' 不在屏上）")
    check(v.get("agent_seen"), "agents 面板上没出现 sub-1（子代理没派出去？）")
    if args.mode == "pick":
        check(v.get("list_opened"), "裸 /watch 没开出「跟随子代理」清单浮层")
        check(v.get("list_hint"), "清单标题里没写「回车跟随」（用户不知道回车能干什么）")
        check(v.get("list_row"), "清单里没有 sub-1 那一行")
        check(not v.get("header_notice"), "回车落在了表头那一行（默认游标没到第一个代理行）")
        check(v.get("watch_opened"), "清单里选中 sub-1 之后没看到跟随浮层")
    elif args.mode == "running":
        check(v.get("hint_seen"), "面板拦下 /watch sub-1 后没有提示「再按一次回车」")
        check(v.get("watch_opened"), "父代理还在跑时敲 /watch sub-1 没有开出跟随浮层")
        check(not v.get("parent_done_seen"),
              "跟随浮层是在父代理回合结束之后才开的（运行中派发那条路没生效）")
        check((v.get("pick_secs") or 99) < max(1, args.parent_hold - 2),
              "开浮层耗时不小于假网关按住的时长（父代理可能已经收尾，判据不作数）")
    else:
        check(v.get("watch_opened"), "敲 /watch sub-1 之后没看到跟随浮层")
    fs = v.get("first_seen", {})
    # 实时性：这两条都必须在子代理结束之前就出现
    check("[step" in fs, "浮层里没出现 [step …]（事件没被渲染出来？）")
    check("▸ bash" in fs, "浮层里没出现 ▸ bash（工具调用没被渲染出来？）")
    check(v.get("ended_seen"), "子代理结束后没有补上 [已结束 …]")
    check(v.get("tool_done_seen"), "没看到工具的真实输出（CHILD_TOOL_DONE）")

    print("---- 判据 ----")
    for k in ("mode", "frame_ok", "agent_seen", "list_opened", "list_hint", "header_notice",
              "hint_seen", "parent_done_seen", "pick_secs", "watch_opened", "ended_seen",
              "tool_done_seen"):
        if k in v:
            print("%-16s: %s" % (k, v.get(k)))
    print("%-16s: %s" % ("first_seen", fs))
    if os.environ.get("PTY_DUMP") or failures:
        print("\n---- 最后一屏 ----")
        print(v.get("final_frame", ""))
    if failures:
        print("\n---- 失败 ----")
        for f in failures:
            print("FAIL:", f)
        print("\nVERDICT: FAIL")
        return 1
    print("\nVERDICT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
