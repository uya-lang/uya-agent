#!/usr/bin/env python3
"""断言会话日志**每一行**都是合法 JSON（活会话那一腿的第五个判据）。

为什么单列一条：会话日志是**宿主的事件源**（`dwhc_tick` 逐行喂 `dwire_line`），
而混进一行非 JSON 时 `dwire_line` 只是「跳过它」—— 页面**照样能渲染**（消息一条
不少），所以其余几条腿全是绿的。实测就是这么发现的：子进程的 `/model` 回执
（「模型已切换」那一整块）直接写进了日志，因为它走 `err_fd()` = fd 2，
而当时 fd 2 指向的正是会话日志。

判据取「每一行都能 `json.loads`」而不是找某个特征串：与 `web-snapshot` 轮那条
「结构坏掉要由外部 oracle 判」同一条道理（子串断言对结构坏掉是瞎的）。

用法：python3 testdata/dsh_web_log_check.py <AGENT_HOME>
退出码：0 = 找到日志且每行都是合法 JSON；1 = 有非 JSON 行（打印前几行）；2 = 找不到日志。
"""
import glob
import json
import os
import sys


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("用法：dsh_web_log_check.py <AGENT_HOME>\n")
        return 2
    home = sys.argv[1]
    paths = glob.glob(os.path.join(home, "sessions", "*", "*", "session.jsonl"))
    if not paths:
        sys.stderr.write("找不到会话日志（%s/sessions/*/*/session.jsonl）\n" % home)
        return 2
    bad = []
    total = 0
    for p in paths:
        with open(p, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                s = line.strip()
                if not s:
                    continue
                total += 1
                try:
                    json.loads(s)
                except ValueError:
                    bad.append("%s:%d: %s" % (p, n, s[:120]))
    print("会话日志 %d 行，其中非 JSON %d 行" % (total, len(bad)))
    if bad:
        for b in bad[:5]:
            sys.stderr.write("  " + b + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
