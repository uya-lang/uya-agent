#!/usr/bin/env python3
"""wire_schema_check.py — 拿 **DSH 自己的 zod schema** 校验形状适配层的译文。

为什么要一个外部 oracle：`selftest[wire-adapt]` 的断言都是**子串**判据，而
「JSON 结构坏掉」可以完全绕过它们 —— 实测抓到过两种：
  ① `…"time":1{"role":…`（漏了收尾引号与 `"data":`）
  ② `"data":{{"role":…`（多一个花括号）
两次都是**子串全中、schema 判红**。所以「形状对不对」这条判据必须由 DSH 自己来判 ——
这正是「不改 DSH 的 webui」的前提：我们适配出的东西必须是它认得的。

用法：
  make wire-schema            # 默认：跑 binary 的 wire dump，逐条校验
  UYA_DSH_ROOT=/path make wire-schema

退出码：0 = 全部通过；1 = 有译文不合法（或 dump 拿不到）。
"""

import json
import os
import pathlib
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "build", "uya-agent")

# DSH 的安装位置（与 session/dshcfg.uya 的「常见 npm 全局路径」同一套口径）
CANDIDATES = [
    os.environ.get("UYA_DSH_ROOT", ""),
    os.path.expanduser("~/.npm-global/lib/node_modules/@deepseek-ai/dsh"),
    "/usr/lib/node_modules/@deepseek-ai/dsh",
    "/usr/local/lib/node_modules/@deepseek-ai/dsh",
]


def find_schema():
    """找到 DSH 的 sessions.schema.js（含 sessionEventSchema 的那份）。

    Returns:
        (schema_path, dsh_root) 或 (None, None)。
    """
    for root in CANDIDATES:
        if not root:
            continue
        p = os.path.join(
            root, "node_modules", "@deepseek-ai", "dsh-host-apiproxy",
            "lib", "types", "api", "sessions.schema.js")
        if os.path.exists(p):
            return p, root
    return None, None


def dump_lines():
    """跑二进制的 wire dump，返回译文行（只留 JSON 行）。

    Returns:
        行列表。空列表 = dump 失败（调用方判红）。
    """
    env = dict(os.environ)
    env["UYA_SELFTEST_WIRE_DUMP"] = "1"
    try:
        r = subprocess.run([OUT, "--selftest"], capture_output=True, env=env,
                           timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        print("wire-schema: 跑 binary 失败：%s" % e)
        return []
    text = (r.stderr or b"").decode("utf-8", "replace")
    text += (r.stdout or b"").decode("utf-8", "replace")
    return [l for l in text.split("\n") if l.startswith("{")]


# 用 node 把「JSON 解析 + schema 校验」放在 DSH 自己的运行时里做：
# 这样校验的就是 DSH 真用的那份 schema（不是我们抄的一份）。
NODE_PROG = r"""
const mod = await import(process.argv[1]);
const schema = mod.sessionEventSchema;
const lines = JSON.parse(process.argv[2]);
let bad = 0;
for (const l of lines) {
  let obj;
  try { obj = JSON.parse(l); }
  catch (e) { console.log('JSON-FAIL\t' + l.slice(0, 100)); bad++; continue; }
  const r = schema.safeParse(obj);
  if (r.success) { console.log('OK\t' + obj.type); }
  else {
    console.log('SCHEMA-FAIL\t' + (obj && obj.type) + '\t' +
      JSON.stringify(r.error.issues[0]).slice(0, 200));
    bad++;
  }
}
process.exit(bad === 0 ? 0 : 1);
"""


def main():
    """入口：dump → 用 DSH 的 schema 逐条校验 → 汇总。"""
    schema, root = find_schema()
    if schema is None:
        print("wire-schema: 跳过 —— 本机没装 DSH（找不到 sessions.schema.js）。"
              "装了的话用 UYA_DSH_ROOT=… 指路。")
        return 0
    lines = dump_lines()
    if not lines:
        print("wire-schema: 失败 —— binary 没有吐出任何译文"
              "（UYA_SELFTEST_WIRE_DUMP=1 的那条路坏了？）")
        return 1

    # type: module —— DSH 的包是 ESM，用 --input-type=module 跑内联程序。
    # `-e` 的内联程序让 argv[0] 就是第一个真参数（没有脚本名占位），所以不传 `--`。
    r = subprocess.run(
        ["node", "--input-type=module", "-e", NODE_PROG,
         schema, json.dumps(lines)],
        capture_output=True)
    out = (r.stdout or b"").decode("utf-8", "replace")
    for line in out.strip().split("\n"):
        if not line:
            continue
        parts = line.split("\t")
        if parts[0] == "OK":
            print("  ok   %s" % parts[1])
        else:
            print("  FAIL %s" % "\t".join(parts[1:]))
    n_ok = sum(1 for l in out.split("\n") if l.startswith("OK\t"))
    if r.returncode != 0:
        print("wire-schema: 失败 —— %d/%d 条译文不合 DSH 的 schema（%s）"
              % (len(lines) - n_ok, len(lines), os.path.basename(schema)))
        return 1
    print("wire-schema: 通过 —— %d 条译文全部合 DSH 的 sessionEventSchema"
          "（%s）" % (n_ok, root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
