#!/usr/bin/env python3
"""PTY 驱动（P30/P31 验收用，不属于产品）：把真终端下的 uya-agent 跑起来，按脚本敲键并回读屏幕。

用法：
    python3 testdata/pty_drive.py --port PORT --workspace DIR -- [--steps N] [--gap-ms N] 场景名

场景：
    status-single-step   单步长流式运行中敲 /status，打印「浮层出现」与「回合是否已结束」
    status-header-wait   （P31）请求已发出、**响应头还没回来**时敲 /status：这一段客户端
                         卡在 hc_open 的读头循环里，必须是「当场出浮层」而不是等头到
    status-idle          （P31）空闲敲 /status：派发之后要当场出帧，不再等下一次 200ms 轮询
    status-during-bash   （P31）bash 工具跑着的时候敲 /status
    status-during-compact（P31）压缩（摘要请求）在飞的时候敲 /status
    new-mid-turn         运行中敲 /new，打印回执与是否中断了当前回合
    interrupt-then-task  esc 中断一个回合，再跑一个任务（验证中断标志没有粘住）
    baseline             （对照）不做任何输入，只看回显的脚注

只依赖 Python 标准库；解释器把 pty 的输出按「屏幕重建」的方式解析（备用屏幕 + 光标定位）。
"""
import argparse
import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

BIN = os.environ.get("UYA_BIN", "./build/uya-agent")

OVERLAY_TITLE = "状态（esc 关闭）"

CSI_RE = re.compile(rb"\x1b\[([0-9;?]*)([A-Za-z])")
OSC_RE = re.compile(rb"\x1b\]([^\x07\x1b]*)(\x07|\x1b\\)")


class Screen:
    """极简终端解释器：只关心我们要断言的字符（备用屏幕不下沉，直接铺当前屏幕）。"""

    def __init__(self, cols=100, rows=30):
        self.cols = cols
        self.rows = rows
        self.buf = [[" "] * cols for _ in range(rows)]
        self.row = 0
        self.col = 0
        self.titles = []
        self.alt = False
        self.raw = bytearray()

    def feed(self, data):
        self.raw += data
        i = 0
        n = len(data)
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
                    self.titles.append(m.group(1).decode("utf-8", "replace"))
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
            # UTF-8：解一个码点（宽度按 1 算，够我们判断字符串出现）
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
                ch = "?"
                ln = 1
            if self.col < self.cols:
                self.buf[self.row][self.col] = ch
            self.col = min(self.cols - 1, self.col + 1)
            i += ln

    def csi(self, params, final):
        if params.startswith("?"):
            if final == "h" and params == "?1049":
                self.alt = True
            elif final == "l" and params == "?1049":
                self.alt = False
            return
        if final == "H" or final == "f":
            parts = [p for p in params.split(";") if p.isdigit()]
            r = int(parts[0]) if parts else 1
            c = int(parts[1]) if len(parts) > 1 else 1
            self.row = max(0, min(self.rows - 1, r - 1))
            self.col = max(0, min(self.cols - 1, c - 1))
        elif final == "J":
            for r in range(self.rows):
                self.buf[r] = [" "] * self.cols
            self.row = 0
            self.col = 0
        elif final == "K":
            for c in range(self.col, self.cols):
                self.buf[self.row][c] = " "

    def text(self):
        return "\n".join("".join(r).rstrip() for r in self.buf)

    def has(self, s):
        return s in self.text()


def spawn(port, workspace, extra):
    env = dict(os.environ)
    env["UYA_AGENT_API_KEY"] = "dummy"
    env.pop("DEEPSEEK_API_KEY", None)
    env.pop("OPENAI_API_KEY", None)
    argv = [BIN, "--no-dsh-config", "--base-url", "http://127.0.0.1:%d/v1" % port,
            "--api=chat", "--model", "p30-mock", "--workspace", workspace,
            "--agent-home", os.path.join(workspace, ".home"), "--tls-verify=none"] + extra
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
        os._exit(127)
    # 窗口大小
    import fcntl
    import struct
    import termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    return pid, fd


def pump(fd, screen, seconds, deadline_note=None):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            screen.feed(data)
    return True


def type_keys(fd, text):
    os.write(fd, text.encode("utf-8"))


def wait_overlay(fd, screen, t0, max_ms=3000):
    """按键已经敲下去（t0）之后，等浮层标题上屏；返回毫秒，没等到返回 None。"""
    rounds = int(max_ms / 50)
    for _ in range(rounds):
        pump(fd, screen, 0.05)
        if screen.has(OVERLAY_TITLE):
            return round((time.time() - t0) * 1000)
    return None


def run_scenario(port, workspace, scenario, extra=None, gap_ms=None, steps=None,
                 head_delay_ms=0, tool_cmd=None):
    """起一个假网关 + 一个真终端 TUI 子进程，跑一个场景，返回 verdict 字典。"""
    env_bin = BIN
    argv = [sys.executable, "testdata/mock_gateway_sse.py", "0",
            str(steps if steps is not None else 1), str(gap_ms if gap_ms is not None else 3000),
            str(head_delay_ms), tool_cmd or ""]
    gw = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          cwd=os.path.dirname(os.path.abspath(__file__)) + "/..")
    try:
        line = gw.stdout.readline().decode()
        gw_port = int(line.split()[1])
    except Exception:  # noqa: BLE001
        gw.kill()
        raise SystemExit("mock gateway 起不来")
    try:
        return _drive(gw_port, workspace, scenario, extra)
    finally:
        gw.kill()
        gw.wait()


def check(cond, msg, failures):
    if not cond:
        failures.append(msg)
    return cond


def suite():
    """P30 + P31 的验收（退出码非 0 = 有断言没过）。"""
    failures = []
    base = os.path.join("build", "p30_suite")
    v1 = run_scenario(0, base + "_status", "status-single-step")
    check(v1.get("overlay_seen"), "/status 浮层没出现", failures)
    lat = v1.get("overlay_latency_ms")
    check(lat is not None and lat <= 800, "/status 浮层太慢：%s ms（上限 800）" % (lat,), failures)
    check(v1.get("turn_still_running"), "/status 浮层是在回合结束之后才出来的", failures)
    v2 = run_scenario(0, base + "_new", "new-mid-turn")
    check(v2.get("receipt_seen"), "/new 没有立刻给出回执", failures)
    check(v2.get("interrupted"), "/new 没有中断当前回合", failures)
    v3 = run_scenario(0, base + "_intr", "interrupt-then-task")
    check(v3.get("second_turn_ok"), "esc 中断一回合之后，第二个任务没有正常跑完（粘住的中断标志？）",
          failures)
    # ---- P31：请求在飞的每一段都要能当场响应 ----
    v4 = run_scenario(0, base + "_hdr", "status-header-wait", head_delay_ms=3000)
    check(v4.get("overlay_seen"), "请求在飞（响应头还没回来）时敲 /status 浮层没出现", failures)
    lat = v4.get("overlay_latency_ms")
    check(lat is not None and lat <= 800,
          "等响应头那段 /status 浮层太慢：%s ms（上限 800；旧实现要等头回来，≈2.2s）" % (lat,), failures)
    check(v4.get("turn_still_running"), "等响应头那段的浮层是回合结束之后才出来的", failures)
    v5 = run_scenario(0, base + "_idle", "status-idle")
    check(v5.get("overlay_seen"), "空闲敲 /status 浮层没出现", failures)
    lat = v5.get("overlay_latency_ms")
    check(lat is not None and lat <= 150,
          "空闲 /status 浮层太慢：%s ms（上限 150；旧实现 243ms = 等下一次 200ms 轮询）" % (lat,), failures)
    v6 = run_scenario(0, base + "_bash", "status-during-bash", tool_cmd="sleep 8")
    check(v6.get("overlay_seen"), "bash 跑着时敲 /status 浮层没出现", failures)
    lat = v6.get("overlay_latency_ms")
    check(lat is not None and lat <= 200,
          "bash 跑着时 /status 浮层太慢：%s ms（上限 200；P31 实测 101ms）" % (lat,), failures)
    check(v6.get("turn_still_running"), "bash 跑着时的浮层是回合结束之后才出来的", failures)
    v7 = run_scenario(0, base + "_compact", "status-during-compact", tool_cmd="sleep 1",
                      extra=["--context-window", "8000"])
    check(v7.get("turn_done"), "压缩场景的前置回合没有跑完", failures)
    check(v7.get("compact_ran"), "压缩请求根本没发出去（这一轮是空跑，判据不算数）", failures)
    check(v7.get("overlay_seen"), "压缩在飞时敲 /status 浮层没出现", failures)
    lat = v7.get("overlay_latency_ms")
    check(lat is not None and lat <= 300,
          "压缩在飞时 /status 浮层太慢：%s ms（上限 300）" % (lat,), failures)
    all_v = {"status": v1, "new": v2, "interrupt": v3,
             "header_wait": v4, "idle": v5, "bash": v6, "compact": v7}
    print(json.dumps(all_v, ensure_ascii=False, indent=2))
    if failures:
        print("P30/P31 FAIL:")
        for f in failures:
            print("  - " + f)
        return 1
    print("P31 PASS（流式 %s ms · 等响应头 %s ms · 空闲 %s ms · bash %s ms · 压缩 %s ms；"
          "回合都还没结束/压缩确实发出去过）"
          % (v1.get("overlay_latency_ms"), v4.get("overlay_latency_ms"),
             v5.get("overlay_latency_ms"), v6.get("overlay_latency_ms"),
             v7.get("overlay_latency_ms")))
    return 0


def _drive(port, workspace, scenario, extra=None):
    os.makedirs(workspace, exist_ok=True)
    extra = extra or []
    screen = Screen()
    pid, fd = spawn(port, workspace, extra)
    verdict = {}
    try:
        pump(fd, screen, 0.6)
        verdict["first_frame_ok"] = screen.has("Ask anything")
        if scenario == "status-single-step":
            type_keys(fd, "跑一个长任务\r")
            pump(fd, screen, 1.2)
            t0 = time.time()
            type_keys(fd, "/status\r")
            seen_at = None
            for _ in range(60):
                pump(fd, screen, 0.05)
                if screen.has(OVERLAY_TITLE):
                    seen_at = time.time() - t0
                    break
            verdict["overlay_seen"] = seen_at is not None
            verdict["overlay_latency_ms"] = None if seen_at is None else round(seen_at * 1000)
            verdict["turn_still_running"] = not screen.has("1 轮 · 1 步")
            verdict["step_line"] = [ln.strip() for ln in screen.text().split("\n")
                                    if "轮 ·" in ln][:1]
            pump(fd, screen, 0.4)
        elif scenario == "status-header-wait":
            # P31：回合刚起步，假网关把**响应头**压住 3 s —— 客户端此刻卡在 hc_open 的
            # 读头循环里。旧实现这一段一个泵点都没有：敲 /status 要等头回来才动。
            type_keys(fd, "跑一个长任务\r")
            pump(fd, screen, 0.8)
            t0 = time.time()
            type_keys(fd, "/status\r")
            verdict["overlay_latency_ms"] = wait_overlay(fd, screen, t0)
            verdict["overlay_seen"] = verdict["overlay_latency_ms"] is not None
            # 头还没回来 → 回合当然还没结束（这一条也是「不是等回合结束才画」的判据）
            verdict["turn_still_running"] = not screen.has("SELFTEST_OK")
            verdict["answer_seen"] = screen.has("SELFTEST_OK")
            pump(fd, screen, 0.4)
        elif scenario == "status-idle":
            # P31：空闲路径的延迟全在「派发之后没人当场画帧」上（旧实现要等下一次
            # 200ms 的 tui_poll_keys）
            t0 = time.time()
            type_keys(fd, "/status\r")
            verdict["overlay_latency_ms"] = wait_overlay(fd, screen, t0)
            verdict["overlay_seen"] = verdict["overlay_latency_ms"] is not None
        elif scenario == "status-during-bash":
            # P31：bash sleep 8 跑着的时候敲 /status（工具循环里的泵点 + 派发即出帧）
            type_keys(fd, "跑一个长 bash\r")
            pump(fd, screen, 2.0)
            t0 = time.time()
            type_keys(fd, "/status\r")
            verdict["overlay_latency_ms"] = wait_overlay(fd, screen, t0)
            verdict["overlay_seen"] = verdict["overlay_latency_ms"] is not None
            verdict["turn_still_running"] = not screen.has("SELFTEST_OK")
        elif scenario == "status-during-compact":
            # P31：压缩的摘要请求在飞的时候敲 /status。旧实现里压缩请求 interactive=false，
            # 整段流式没有任何泵点（界面全冻）；主循环发起的请求还没登记泵点上下文。
            type_keys(fd, "跑一个带工具的任务\r")
            pump(fd, screen, 5.0)          # 等回合跑完（bash sleep 1 + 第二步的答案）
            verdict["turn_done"] = screen.has("SELFTEST_OK")
            type_keys(fd, "/compact\r")
            pump(fd, screen, 0.4)
            t0 = time.time()
            type_keys(fd, "/status\r")
            verdict["overlay_latency_ms"] = wait_overlay(fd, screen, t0)
            verdict["overlay_seen"] = verdict["overlay_latency_ms"] is not None
            # 浮层盖着转录，[compact] 那行在它下面 —— 先 esc 关掉再等这一轮收场
            type_keys(fd, "\x1b")
            pump(fd, screen, 4.0)
            verdict["compact_ran"] = screen.has("[compact]")
        elif scenario == "new-mid-turn":
            type_keys(fd, "跑一个长任务\r")
            pump(fd, screen, 1.2)
            type_keys(fd, "/new\r")
            pump(fd, screen, 1.5)
            verdict["receipt_seen"] = screen.has("已排队") or screen.has("已收到")
            verdict["interrupted"] = screen.has("interrupted")
            pump(fd, screen, 4.0)
            verdict["final_ok"] = screen.has("SELFTEST_OK")
        elif scenario == "interrupt-then-task":
            type_keys(fd, "第一个长任务\r")
            pump(fd, screen, 1.0)
            os.write(fd, b"\x1b")
            pump(fd, screen, 0.6)
            type_keys(fd, "第二个任务\r")
            pump(fd, screen, 4.0)
            verdict["second_turn_ok"] = screen.has("SELFTEST_OK")
        else:
            type_keys(fd, "随便跑一个任务\r")
            pump(fd, screen, 5.0)
            verdict["final_ok"] = screen.has("SELFTEST_OK")
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
    verdict["titles"] = screen.titles[:4]
    if os.environ.get("PTY_DUMP"):
        print("---- screen ----")
        print(screen.text())
    return verdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int)
    ap.add_argument("--workspace")
    ap.add_argument("--extra", default="")
    ap.add_argument("--suite", action="store_true")
    ap.add_argument("scenario", nargs="?")
    args = ap.parse_args()
    if args.suite:
        return sys.exit(suite())
    if not args.port or not args.workspace or not args.scenario:
        ap.error("--port/--workspace/场景名 必填（或用 --suite）")

    extra = args.extra.split() if args.extra else []
    verdict = _drive(args.port, args.workspace, args.scenario, extra)
    print(json.dumps(verdict, ensure_ascii=False, indent=2))
    if os.environ.get("PTY_DUMP"):
        print("（PTY_DUMP 只对 --suite 之外的场景打印屏幕；这里只看 verdict）")


if __name__ == "__main__":
    main()
