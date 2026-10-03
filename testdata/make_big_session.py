#!/usr/bin/env python3
# testdata/make_big_session.py — 造一份「大日志」会话 fixture（P35 的段错误回归用）
#
# 用法：python3 testdata/make_big_session.py <home>
#
# 为什么要造这么大的：`sess_read_meta` 逐行取行时把切片第二个参数写成了**绝对行尾偏移**
# （`data.ptr[pos: nl]`），而 uya 的 `p[a: b]` 是「偏移 + 长度」—— 每行的 view.len 约等于
# 真实行长 + pos，`sess_has_cstr` 于是会一直往后读过本行。小日志时只是**静默越过本行**
# 做匹配（最后一条 session/workspace 可能被错过），大日志（data 缓冲经 realloc 走 mmap）
# 读到映射尾就 SIGSEGV。1 MiB 时越界窗口还能侥幸落在同一个 mapping 里，3 MiB 稳定崩 ——
# 所以这里取 ~3 MiB，让 `make e2e-resume-big` 真能抓到退出码 139。
#
# 写出来的形状：
#   header（cwd = /selftest/meta-big/cwd）
#   session/workspace → /selftest/meta-big/early
#   ~3 MiB 的 step/end 填充行（payload 是 'x' 重复，**不含** session/workspace 字面量）
#   session/workspace → /selftest/meta-big/final（最后一条，权威）
#   一条**没有换行结尾**的残行（reader 必须按「崩在写一半」丢弃它）
import json
import os
import sys

SID = "session-b19b19b1-2222-4333-8444-555566667777"
CWD = "/selftest/meta-big/cwd"
WS_EARLY = "/selftest/meta-big/early"
WS_FINAL = "/selftest/meta-big/final"
TARGET = 3 * 1024 * 1024
DIRNAME = "--selftest-meta-big--"


def J(o):
    return json.dumps(o, separators=(",", ":"))


def main():
    home = sys.argv[1]
    d = os.path.join(home, "sessions", DIRNAME, SID)
    os.makedirs(d, exist_ok=True)
    log = os.path.join(d, "session.jsonl")
    head = [
        J({"type": "session", "version": 0, "id": SID, "createdAt": 1, "cwd": CWD,
           "delegationDepth": 0, "agentPreset": "standard", "model": "selftest-model",
           "provider": "uya-agent"}),
        J({"type": "session/workspace", "seq": 0, "time": 1,
           "data": {"workspace": WS_EARLY, "previous": CWD, "source": "human"}}),
    ]
    filler = "x" * 1000
    n = sum(len(x) + 1 for x in head)
    i = 1
    with open(log, "w") as f:
        f.write("\n".join(head) + "\n")
        while n < TARGET:
            line = J({"type": "step/end", "seq": i, "time": 2, "data": {"payload": filler}})
            f.write(line + "\n")
            n += len(line) + 1
            i += 1
        f.write(J({"type": "session/workspace", "seq": 9999, "time": 3,
                   "data": {"workspace": WS_FINAL, "previous": WS_EARLY,
                            "source": "tool"}}) + "\n")
        # 残行：没有换行结尾 —— 对齐「崩在写一半」的那条记录，reader 必须丢弃
        f.write('{"type":"session/workspace","data":{"workspace":"/selftest/meta-big/TRUNC')
    idx = J({"id": SID, "cwd": CWD, "lastActiveAt": 9, "title": "big",
             "model": "selftest-model", "delegationDepth": 0, "turns": 0, "events": 0,
             "path": log})
    with open(os.path.join(home, "index.jsonl"), "w") as f:
        f.write(idx + "\n")
    print("fixture bytes %d" % os.path.getsize(log))


if __name__ == "__main__":
    main()
