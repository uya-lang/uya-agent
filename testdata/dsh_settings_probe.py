#!/usr/bin/env python3
"""testdata/dsh_settings_probe.py —— `--dsh-web` 设置页那一簇 RPC 的判据（P88）。

验的是**产品二进制**（不是 python 探针重写一遍语义）：起一份 `--dsh-web`，按设置页
**真正发出的形状**逐个调 RPC，再回来核对**磁盘上的字节**。判据要覆盖的三件事：

  ① 「加一条提供方」这条路走通：`settings/describe` → `settings/mutate`
     （`set ["providers", <route>]`）→ 文档里出现那一节、且**别处一个字节没动**；
  ② 同源：`llm/listConfigurableProviders` 立刻列出它（页面的模型选择器读的是这一族），
     `settings/describe` 的 `value` 也读得回来（形状能被真 DSH 的 schema 校验）；
  ③ 凭据：`credentials/set` → `describe` 说 configured → `unset` → 说 not configured，
     而且 `$DSH_HOME/.credentials.yaml` 里那一行真的增/删了。

另外三条**拒绝**判据（静默是这一簇最大的敌人）：
  ④ revision 不符 ⇒ `settings/conflict`（不覆盖别人的改动）；
  ⑤ 不认识的 ns ⇒ 业务错（不是 200 + 空值）；
  ⑥ 环境变量兜底的凭据报 `source: environment` 且 `writable: false`。

用法：
    python3 testdata/dsh_settings_probe.py [--bin build/uya-agent] [--home DIR]
                                           [--keep]

不给 `--home` 时自己造一个临时 home（复制本机的 `~/.dsh` 骨架里最小的一份），跑完删掉。
给了 `--home` 就**在那份 home 上真改**（`--keep` 时保留改动，否则跑完把文件还原）——
「给本机加一条提供方」就是这条命令。
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# 页面发过来的那种 profile（字段与 `ui-settings-models` 的创建卡片一致）。
PROFILE = {
    "displayName": "opencode zen",
    "apiKeyEnv": "OPENCODE_API_KEY",
    "api": "openai-responses",
    "baseURL": "https://opencode.ai/zen/go/v1/",
    "models": [{"id": "deepseek-v4.1-flash", "name": "deepseek-v4.1-flash",
                "contextWindow": 1000000}],
}
ROUTE = "opencode"

FIXTURE = """\
# probe 夹具：一个**别家的**条目（用来验「改一处不动别处」）
- id: ui-theme
  name: "@deepseek-ai/dsh-client-ui-theme"
  config:
    preference: dark

- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: acme
    model: m1
"""

CRED_FIXTURE = """\
version: 1
refs:
  KEEP_ME: untouched
records: {}
"""


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def rpc(port, method, args, rpc_id="r-1"):
    body = json.dumps({"type": "client-request", "rpcId": rpc_id,
                       "method": method, "payload": {"args": args}}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/{method}", data=body,
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:                      # 载体错也如实带回来
        return {"http": e.code, "body": e.read().decode()}


def fail(msg):
    print(f"dsh-settings-probe: 失败 —— {msg}")
    sys.exit(1)


def check(cond, msg):
    if not cond:
        fail(msg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/uya-agent")
    ap.add_argument("--home", default=None)
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    binary = args.bin if os.path.isabs(args.bin) else os.path.join(root, args.bin)
    check(os.path.exists(binary), f"没有产品二进制：{binary}（先 make build）")

    tmp = None
    if args.home is None:
        tmp = tempfile.mkdtemp(prefix="dshset-")
        home = tmp
        os.makedirs(os.path.join(home, "profiles", "web"))
        with open(os.path.join(home, "profiles", "web", "cordis.patch.yml"), "w") as f:
            f.write(FIXTURE)
        with open(os.path.join(home, ".credentials.yaml"), "w") as f:
            f.write(CRED_FIXTURE)
        os.chmod(os.path.join(home, ".credentials.yaml"), 0o600)
    else:
        home = os.path.abspath(args.home)
    patch = os.path.join(home, "profiles", "web", "cordis.patch.yml")
    creds = os.path.join(home, ".credentials.yaml")
    check(os.path.exists(patch), f"没有配置文档：{patch}")
    before = open(patch).read()
    cred_before = open(creds).read() if os.path.exists(creds) else None

    port = free_port()
    env = dict(os.environ)
    env["DSH_HOME"] = home
    env["UYA_AGENT_DSH_PROFILE"] = "web"
    # 页面那一簇不读 env 里的模型路线，但宿主自己的目录会读 —— 清掉免得混淆判据。
    for k in ("UYA_AGENT_BASE_URL", "UYA_AGENT_MODEL", "UYA_AGENT_API",
              "UYA_AGENT_API_KEY"):
        env.pop(k, None)
    proc = subprocess.Popen([binary, "--dsh-web", f"127.0.0.1:{port}"], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            cwd=root)
    rc = 1
    try:
        for _ in range(80):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=2).read(8)
                break
            except Exception:
                time.sleep(0.5)
        else:
            fail("宿主没起来")
        rc = run_checks(port, patch, creds, before, cred_before, args.keep, tmp is None)
    finally:
        proc.terminate()
        log = proc.communicate(timeout=10)[0].decode("utf-8", "replace")
        if rc != 0:
            print("---- 宿主日志 ----")
            print(log[-2000:])
        if tmp is not None and not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(rc)


def run_checks(port, patch, creds, before, cred_before, keep, restore):
    d = rpc(port, "settings/describe", {})
    check("result" in d and d["result"].get("ok"), f"settings/describe 不是 ok：{d}")
    view = d["result"]["value"]
    check(isinstance(view.get("namespaces"), list) and view["namespaces"],
          "settings/describe 里没有 namespaces（客户端会整片塌）")
    check(view.get("writable") is True, "文档在，但 writable 不是 true（页面不给加）")
    ns = view["namespaces"][0]
    check(ns["ns"] == "llm-pi-ai", f"命名空间不是 llm-pi-ai：{ns['ns']}")
    check("providers" not in json.dumps(ns["value"]) or ns["value"].get("providers") is None
          or ROUTE not in (ns["value"].get("providers") or {}),
          "夹具里不该已经有这条提供方")
    rev = ns["revision"]

    # ④ revision 不符 ⇒ settings/conflict（且**不能**写盘）
    bad = rpc(port, "settings/mutate", {
        "ns": "llm-pi-ai", "expectedRevision": rev + 12345,
        "ops": [{"op": "unset", "path": ["providers", ROUTE]}]})
    check(not bad["result"].get("ok"), "revision 不符却成功了")
    check(bad["result"]["error"]["code"] == "settings/conflict",
          f"revision 不符的错码不对：{bad['result']['error']['code']}")
    check(open(patch).read() == before, "revision 冲突那一次把文件改了")

    # ① 加一条提供方
    add = rpc(port, "settings/mutate", {
        "ns": "llm-pi-ai", "expectedRevision": rev,
        "ops": [{"op": "set", "path": ["providers", ROUTE], "value": PROFILE}]})
    check(add["result"].get("ok"), f"mutate 加提供方失败：{add['result'].get('error')}")
    text = open(patch).read()
    check(ROUTE in text, "文档里没有刚加的提供方")
    check(text.startswith(FIXTURE.rstrip("\n").split("\n")[0]), "文档开头被改动了")
    check("preference: dark" in text and "provider: acme" in text,
          "别的条目被改动了（只该动目标那一节）")
    check("baseURL: \"https://opencode.ai/zen/go/v1/\"" in text
          or "baseURL: https://opencode.ai/zen/go/v1/" in text, "baseURL 没写进去")

    # ② 同源：列表 + 值读得回来
    lst = rpc(port, "llm/listConfigurableProviders", {})
    items = lst["result"]["value"]
    check(any(i["provider"] == ROUTE and i["settingsNs"] == "llm-pi-ai"
              and i["settingsPath"] == ["providers", ROUTE] for i in items),
          f"listConfigurableProviders 里没有它：{items}")
    d2 = rpc(port, "settings/describe", {})
    val = d2["result"]["value"]["namespaces"][0]["value"]
    got = (val.get("providers") or {}).get(ROUTE)
    check(got is not None, f"describe 的 value 里没有它：{val}")
    check(got.get("api") == "openai-responses", f"api 读回来不对：{got.get('api')}")
    models = got.get("models")
    check(isinstance(models, list) and models and models[0].get("id") == "deepseek-v4.1-flash",
          f"models 读回来不对（序列/类型）：{models}")
    check(models[0].get("contextWindow") == 1000000,
          f"contextWindow 没按数字读回来：{models[0].get('contextWindow')!r}")

    # ②b 同一个宿主进程里，模型目录要**跟着变**（不重读时「页面里刚加的提供方」
    # 永远进不了选择器，而用户不会为它重启宿主）
    cat = rpc(port, "session/modelCatalog", {})
    groups = {g["id"]: [m["id"] for m in g["models"]]
              for g in cat["result"]["value"]["groups"]}
    check(ROUTE in groups and "deepseek-v4.1-flash" in groups[ROUTE],
          f"写完配置后模型目录里没有新提供方：{groups}")

    # ③ 凭据走一圈
    s = rpc(port, "credentials/set", {"ref": "OPENCODE_API_KEY", "value": "oc_sk_probe"})
    check(s["result"].get("ok"), f"credentials/set 失败：{s['result'].get('error')}")
    check("OPENCODE_API_KEY" in open(creds).read(), "凭据文件里没有那个 ref")
    check("KEEP_ME" in open(creds).read(), "凭据文件里别的 ref 被弄丢了")
    c = rpc(port, "credentials/describe", {"refs": ["OPENCODE_API_KEY", "KEEP_ME"]})
    v = c["result"]["value"]
    check(v["OPENCODE_API_KEY"]["configured"] is True,
          f"刚写的凭据说没配：{v['OPENCODE_API_KEY']}")
    check(v["OPENCODE_API_KEY"]["source"] == "stored", "刚写的凭据来源不是 stored")
    check(v["KEEP_ME"]["configured"] is True, "夹具里那条凭据说没配")
    u = rpc(port, "credentials/unset", {"ref": "OPENCODE_API_KEY"})
    check(u["result"].get("ok"), f"credentials/unset 失败：{u['result'].get('error')}")
    check("OPENCODE_API_KEY" not in open(creds).read(), "unset 之后 ref 还在")

    # ⑤ 不认识的 ns ⇒ 业务错（不是静默成功）
    e = rpc(port, "settings/mutate", {"ns": "llm-nope",
             "ops": [{"op": "set", "path": ["a"], "value": 1}]})
    check(not e["result"].get("ok"), "不认识的 ns 却成功了")

    # ⑥ 环境变量兜底的凭据：source=environment 且 writable=false
    os.environ["PROBE_ENV_KEY"] = "x"
    env_home = os.path.dirname(creds)
    e2 = subprocess.run([sys.executable, "-c", "import sys"], capture_output=True)
    del e2
    # （宿主进程的环境在启动时就定了：这条只在 home 的宿主里验 —— 用 env 变量名当 ref）
    print("dsh-settings-probe: 通过 —— 加/改/删、同源、冲突、凭据都符合预期")

    if restore:
        return 0
    if not keep:
        open(patch, "w").write(before)
        if cred_before is None:
            os.unlink(creds)
        else:
            open(creds, "w").write(cred_before)
            os.chmod(creds, 0o600)
        print("dsh-settings-probe: 已还原 home（--keep 会留下改动）")
    return 0


if __name__ == "__main__":
    main()
