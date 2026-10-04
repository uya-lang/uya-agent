#!/usr/bin/env python3
"""P46 自动起标题的真终端驱动（验收用，不属于产品）。

为什么需要它：自动起标题**只服务交互界面**（管道/CI 上标题通道本来就是空操作，
为一个看不见的东西多发一次请求没有道理）—— 所以行式 REPL 那一路它根本不会跑，
只能拿真 PTY 验「它真的发了请求、真的落了 provider 事件」。

两个方向（都用同一个假网关，靠请求计数与日志事件区分）：
  ① HOME_A：默认（自动起标题开）—— 打一条任务，等回合 + 静默期 + 起标题请求都收场；
  ② HOME_B：--no-title-auto —— 同样的任务，不该发第二个请求、也不该有 provider 事件。

环境变量（Makefile 传进来）：UYA_BIN / PORT / HOME_A / HOME_B。
退出码 0 = 两个方向都按预期跑完；非 0 = 起不来或没退出（由 Makefile 的 set -e 拦下）。
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

BIN = os.environ["UYA_BIN"]
PORT = os.environ["PORT"]
HOME_A = os.environ["HOME_A"]
HOME_B = os.environ["HOME_B"]

# 自动起标题要等两段静默（arm 窗口 + 键盘窗口，各 900ms）才发，
# 所以「回合跑完」之后还得再给它留够时间，再读一个来回。
SETTLE_SEC = 14.0
TASK = "写一个 hello"


def run(home, extra):
    env = dict(os.environ)
    env["UYA_AGENT_API_KEY"] = "dummy"
    env.pop("DEEPSEEK_API_KEY", None)
    env.pop("OPENAI_API_KEY", None)
    argv = [
        BIN, "--no-dsh-config",
        "--base-url", "http://127.0.0.1:%s/v1" % PORT,
        "--api=chat", "--model", "m",
        "--agent-home", home, "--tls-verify=none",
    ] + extra
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
        os._exit(127)
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        buf = bytearray()

        def pump(sec):
            end = time.time() + sec
            while time.time() < end:
                r, _, _ = select.select([fd], [], [], 0.05)
                if r:
                    try:
                        d = os.read(fd, 65536)
                    except OSError:
                        return False
                    if not d:
                        return False
                    buf.extend(d)
            return True

        pump(1.5)
        os.write(fd, (TASK + "\r").encode())
        pump(SETTLE_SEC)
        os.write(fd, b"\x04")          # 空行上的 ctrl+d = 退出
        pump(1.5)
        return buf
    finally:
        try:
            os.kill(pid, 9)
        except Exception:  # noqa: BLE001
            pass
        try:
            os.waitpid(pid, 0)
        except Exception:  # noqa: BLE001
            pass


def main():
    a = run(HOME_A, [])
    if "SELFTEST_OK" not in bytes(a).decode("utf-8", "replace"):
        sys.stderr.write("FAIL: 自动起标题那一轮连回合都没跑完（mock 的最终答案没出现）\n")
        return 1
    b = run(HOME_B, ["--no-title-auto"])
    if "SELFTEST_OK" not in bytes(b).decode("utf-8", "replace"):
        sys.stderr.write("FAIL: --no-title-auto 那一轮连回合都没跑完\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
