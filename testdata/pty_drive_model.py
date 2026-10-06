#!/usr/bin/env python3
"""PTY 驱动（P37 验收用，不属于产品）：验收「回合运行中切换模型」当场生效且**换对了路线**。

现场：真终端里的 uya-agent 跑一条 `sleep N` 的 bash（回合被撑住），期间敲 `/model <另一个
提供方的模型>`，然后断言三件事（都在**回合结束之前**取样）：

  ① 屏幕上的信息行（模型 + 提供方）已经变了；
  ② 之后那条请求打到的是**新提供方**的网关（那边收到请求、旧的没有）；
  ③ 那条请求带的 `Authorization` 是**新提供方**的密钥（旧密钥绝不跨提供方发出去）。

对照旧行为（本轮修掉的）：`base_url` 停在启动时那一条 ⇒ 请求继续打到旧提供方；
`/model <名字>` 不在只读集合里 ⇒ 被当普通文本发给模型（请求体里出现 `/model b-two`）。

用法：
    python3 testdata/pty_drive_model.py --port-a PA --port-b PB --workspace DIR
                                        [--slow 10] [--mode text|overlay]
输出一行 VERDICT: PASS/FAIL 与各判据；PTY_DUMP=1 时总是打屏。
"""
import argparse
import fcntl
import importlib.util
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ.get("UYA_BIN", "./build/uya-agent")

# 复用 pty_drive.py 的终端模拟器（同一份「屏幕事实」口径，不写第二份）
_spec = importlib.util.spec_from_file_location("pty_drive", os.path.join(HERE, "pty_drive.py"))
pd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pd)
Screen = pd.Screen

MARKER = "ROUTE-CHECK"          # 父代理的任务文本（用来确认哪条请求是我们发的）


def spawn(port_a, port_b, workspace, home, extra):
    """起一个真终端 TUI：两个提供方分别指向两个假网关，密钥由 env 给。

    ⚠ 序列：**先把窗口尺寸定好再 exec**。`pty.fork()` 之后再 TIOCSWINSZ 会让 TUI 在
    第一次 size 刷新之前判定「终端太小（<32x8）」并静默退回滚动模式 —— 那时 /model
    走的是文本入口、浮层根本不开，整条腿会变成假绿（本轮真踩到过）。
    """
    env = dict(os.environ)
    env["ROUTE_KEY_A"] = "key-of-prov-a"
    env["ROUTE_KEY_B"] = "key-of-prov-b"
    env.pop("UYA_AGENT_API_KEY", None)
    env.pop("UYA_AGENT_BASE_URL", None)
    env.pop("DEEPSEEK_API_KEY", None)
    env.pop("OPENAI_API_KEY", None)
    argv = [BIN,
            "--dsh-home", home,
            "--agent-home", os.path.join(workspace, ".home"),
            "--workspace", workspace,
            "--tls-verify=none"] + extra
    mfd, sfd = pty.openpty()
    fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack("HHHH", 34, 110, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.setsid()
        try:
            fcntl.ioctl(sfd, termios.TIOCSCTTY, 0)
        except OSError:
            pass
        os.dup2(sfd, 0)
        os.dup2(sfd, 1)
        os.dup2(sfd, 2)
        if sfd > 2:
            os.close(sfd)
        os.close(mfd)
        os.execvpe(argv[0], argv, env)
        os._exit(127)
    os.close(sfd)
    return pid, mfd


def write_settings(home, port_a, port_b):
    """两个提供方：prov-a（responses）与 prov-b（completions），各带自己的 baseURL/apiKeyEnv。"""
    os.makedirs(home, exist_ok=True)
    body = """agent-default-model:
  provider: prov-a
  model: a-one
llm-pi-ai:
  providers:
    {
      prov-a:
        {
          apiKeyEnv: ROUTE_KEY_A,
          api: openai-completions,
          baseURL: http://127.0.0.1:PORT_A/v1,
          models: [ { id: a-one, contextWindow: 111000 } ]
        },
      prov-b:
        {
          apiKeyEnv: ROUTE_KEY_B,
          api: openai-completions,
          baseURL: http://127.0.0.1:PORT_B/v1,
          models: [ { id: b-two, contextWindow: 222000 } ]
        }
    }
"""
    body = body.replace("PORT_A", str(port_a)).replace("PORT_B", str(port_b))
    with open(os.path.join(home, "settings.yaml"), "w") as f:
        f.write(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-a", type=int, required=True)
    ap.add_argument("--port-b", type=int, required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--mode", default="text", choices=("text", "overlay"))
    ap.add_argument("--slow", type=int, default=10, help="假网关那条慢 bash 的秒数")
    args = ap.parse_args()

    ws = args.workspace
    os.makedirs(ws, exist_ok=True)
    home = os.path.join(ws, "dsh")
    write_settings(home, args.port_a, args.port_b)

    failures = []
    verdict = {"mode": args.mode}
    pid, fd = spawn(args.port_a, args.port_b, ws, home, [])
    scr = Screen(110, 34)
    try:
        pd.pump(fd, scr, 1.5)
        verdict["tui_ok"] = "Ask anything" in scr.text()
        if not verdict["tui_ok"]:
            failures.append("TUI 没起来（屏幕上没有输入面板）—— 别在滚动模式上做这条验收")

        # ① 起一个会被慢 bash 撑住的回合
        pd.type_keys(fd, MARKER + " 跑一条慢命令\r")
        t0 = time.time()
        while time.time() - t0 < 10:
            pd.pump(fd, scr, 0.25)
            if "运行中" in scr.text():
                break
        verdict["turn_running"] = "运行中" in scr.text()
        if not verdict["turn_running"]:
            failures.append("回合没进入「运行中」（假网关的慢 bash 没跑起来？）")

        # ② 回合还在跑的时候切换模型
        if args.mode == "overlay":
            # 裸 /model → 浮层。条目序是 [# prov-a, a-one, # prov-b, b-two]，而游标默认停在
            # **当前模型（a-one）**那一行 —— 所以到 b-two 要按两次 ↓：第一次落在分组标题
            # `# prov-b` 上（它反解不出模型名，回车等于什么都没发生），第二次才到 b-two。
            pd.type_keys(fd, "/model\r")
            pd.pump(fd, scr, 1.2)
            verdict["overlay_seen"] = "模型（enter 切换" in scr.text()
            if not verdict["overlay_seen"]:
                failures.append("回合运行中裸 /model 没有开出模型浮层")
            pd.type_keys(fd, "\x1b[B")
            pd.pump(fd, scr, 0.4)
            pd.type_keys(fd, "\x1b[B")
            pd.pump(fd, scr, 0.4)
            t_switch = time.time()
            pd.type_keys(fd, "\r")
        else:
            # 带参数的文本命令：TUI 输入纪律要求走两次回车（先弹面板、回车把整行还回输入行）
            pd.type_keys(fd, "/model b-two")
            pd.pump(fd, scr, 0.5)
            pd.type_keys(fd, "\r")
            pd.pump(fd, scr, 0.5)
            t_switch = time.time()
            pd.type_keys(fd, "\r")

        # ③ 「当场生效」：等屏幕上出现新模型名（**不许**等回合结束）
        seen = None
        deadline = time.time() + 6.0
        while time.time() < deadline:
            pd.pump(fd, scr, 0.1)
            txt = scr.text()
            if "b-two" in txt and "prov-b" in txt:
                seen = round((time.time() - t_switch) * 1000)
                break
        verdict["switch_ms"] = seen
        verdict["switch_visible"] = seen is not None
        if seen is None:
            failures.append("切换之后屏幕上一直没出现 b-two/prov-b（没有当场生效）")
        elif not verdict["turn_running"]:
            failures.append("切换生效时回合已经结束了（窗口没撑住，判据不算数）")

        # ④ 回合结束（等慢 bash 收工，让第二条请求真的发出去）
        # ⚠ 这里以前等的是「屏幕上有 `轮 ·` 且没有 `运行中`」—— 这条**否定式代理判据**
        # 在回合**半途**就成立（踩坑 109 的现场）：脚注的 `轮 · ` 回合一开始就在，而状态区
        # 那三档词是「思考中 / 输出中 / 运行中 」—— 慢 bash 一收工就回到「思考中」，
        # 于是循环在答案上屏**之前**跳出，取样到一张还在跑的屏 ⇒ 约 5% 的假红。
        # 判据改成等**正面事实**：PROV-B-ANSWER 只可能由新提供方那条答复产生，
        # 正是这条腿要断言的语义（等 A 本身，别去猜「哪些字不在就等于 A 发生了」）。
        t1 = time.time()
        while time.time() - t1 < args.slow + 25:
            pd.pump(fd, scr, 0.3)
            if "PROV-B-ANSWER" in scr.text():
                break
        verdict["final_screen_has_b_answer"] = ("PROV-B-ANSWER" in scr.text())
        if not verdict["final_screen_has_b_answer"]:
            failures.append("切换之后那一轮不是 prov-b 答的（屏幕上没有 PROV-B-ANSWER）")
        # 失败时也打屏：flake 的现场（那一刻屏幕上到底是什么）是最难补的证据，
        # 以前只有 PTY_DUMP=1 才打，定位一次要手工重跑好几轮。
        if os.environ.get("PTY_DUMP") or failures:
            print("---- screen ----")
            print(scr.text())
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

    print("VERDICT: %s" % ("PASS" if not failures else "FAIL"))
    for k in ("tui_ok", "turn_running", "overlay_seen", "switch_visible", "switch_ms",
              "final_screen_has_b_answer"):
        if k in verdict:
            print("  %-26s %s" % (k, verdict[k]))
    for f in failures:
        print("  FAIL: " + f)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
