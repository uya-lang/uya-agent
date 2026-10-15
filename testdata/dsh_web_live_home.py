#!/usr/bin/env python3
"""造「活会话」那一腿要用的 DSH 模型目录夹具（`--dsh-home` 指向它）。

为什么要夹具而不是用真机的 `~/.dsh/settings.yaml`：那一份是用户的、会变，而且
本机**根本没有**（这台机器的 `~/.dsh` 里只有 credentials）。判据要的是「两个提供方
各有一个模型」，好让「切过去之后请求真的打到另一家」成为一个可断言的事实。

用法：python3 testdata/dsh_web_live_home.py <DIR> <PORT_A> <PORT_B>
  `DIR` 会被建成一份 DSH home（`settings.yaml` 在里面）；两个端口是假网关的
  A / B 口（`mock_gateway_route.py` 打印的那两个）。

与 `mock_gateway_*.py` 同一路子：本地验收用的夹具，不进产品、不进 SRC。
"""
import os
import sys

BODY = """\
agent-default-model:
  provider: prov-a
  model: model-a
llm-pi-ai:
  providers:
    {
      prov-a:
        {
          api: openai-completions,
          baseURL: http://127.0.0.1:%(a)s/v1,
          models:
            [
              { id: model-a, contextWindow: 111000, reasoningEfforts: { off: none, high: high } }
            ]
        },
      prov-b:
        {
          api: openai-completions,
          baseURL: http://127.0.0.1:%(b)s/v1,
          models:
            [
              { id: model-b, contextWindow: 222000 }
            ]
        }
    }
"""

# `agent-default-model` 那一段定「会话开局用谁」——**必须有**：不给的话子进程会用
# 出厂默认（`deepseek-chat`）去打 A 口，而 A 口会把任意模型名照单全收 ⇒ 断言看不出
# 「到底切没切过去」（实测就是这么漏掉的：两条请求都写着 `DeepSeek-V4.1-Flash`）。


def main():
    if len(sys.argv) < 4:
        sys.stderr.write("用法：dsh_web_live_home.py <DIR> <PORT_A> <PORT_B>\n")
        return 2
    d, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "settings.yaml")
    with open(p, "w", encoding="utf-8") as f:
        f.write(BODY % {"a": a, "b": b})
    print(p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
