# OpenBench 4 任务对比装置（uya-agent vs dsh）

**这不是产品的一部分**，而是 P78 那次「与 DSH 头对头」的**测量装置**。
结论与踩坑记在 [DESIGN.md §19.1](../../DESIGN.md)；这里只放**怎么复现**。

## 它回答什么问题

**同一个模型、同一批任务，harness 差多少？**
模型固定为 `aigw-local/DeepSeek-V4.1-Flash`（推理强度 `max`），
任务固定为 OpenBench 的 4 个核心任务：`taskflow` `make-ci-green` `add-feature` `webcore`。

用的是第三方基准 **OpenBench**（`minghinmatthewlam/openbench`），专为「换 harness、
不换模型」设计 —— **不是 DSH 官网的 bench**（官网没有任何 bench 页）。

## 装置组成

| 路径 | 是什么 |
|---|---|
| `template_dsh/settings.yaml` | dsh 的隔离 home 模板（`maxTokens: 256000`，**配对口径**）。凭据由 runner 从 `~/.dsh/.credentials.yaml` 拷入，**不入库** |
| `uyaagent.py` | OpenBench adapter：按 `obench/ADAPTER_SPEC.md` 暴露 `run()` |
| `dsh.py` | 同上，跑 `dsh --profile headless`（`OPENBENCH_DSH_PATCH` 可挂覆盖层） |
| `opencode.patch.yml` | 走 opencode zen 时的 dsh 覆盖层（见上「换一条路线跑」） |

## 怎么复现

```bash
cd /home/winger/uya-agent
git clone --depth 1 https://github.com/minghinmatthewlam/openbench /tmp/obrepo   # 168 MB，不 vendor 进本仓

T=/home/winger/uya-agent/testdata/openbench_adapters
H=/tmp/ob_bench                      # 工作目录：隔离 home 与结果都放这
mkdir -p $H/home_dsh
cp $T/template_dsh/settings.yaml $H/home_dsh/
cp ~/.dsh/.credentials.yaml $H/home_dsh/ && chmod 600 $H/home_dsh/.credentials.yaml
export OPENBENCH_DSH_HOME_TEMPLATE=$H/home_dsh          # dsh 臂的隔离 home 模板
export OPENBENCH_UYAAGENT_BIN=/home/winger/uya-agent/build/uya-agent

cd /tmp/obrepo
# 1. 负控（零成本，必红：未改动的仓库应当拿基线分）
python3 -m obench.cli legacy run \
  --task taskflow,make-ci-green,add-feature,webcore --harness null \
  --model DeepSeek-V4.1-Flash --trials 1 --results-path $H/ctrl_neg.jsonl

# 2. 正控（oracle 覆盖后必须全 1.0000）
for t in taskflow make-ci-green add-feature webcore; do
  cp -r tasks/$t $H/pos_$t
  cp -r $H/pos_$t/solution/. $H/pos_$t/workspace/
  (cd $H/pos_$t/workspace && TASK_DIR=$H/pos_$t bash $H/pos_$t/checker.sh | tail -1)
done

# 3. 真跑（两侧输出上限都是 256000）
python3 -m obench.cli legacy run \
  --task taskflow,make-ci-green,add-feature,webcore \
  --harness uyaagent,dsh --model DeepSeek-V4.1-Flash --trials 1 --force \
  --timeout 1800 --checker-timeout 120 \
  --adapters-dir $T --results-path $H/results.jsonl
```

token/成本/延迟的第二份证据从网关账本取（`request_logs` 给
`client`/`call_kind`/`workspace`，`usage_records` 给 `dimensions_json`/`cost_micros`），
两侧 adapter 上报的数与账本**逐数相等**才算数。

### 五、opencode 不提供 Responses API，两臂都不能钉 `openai-responses`

`POST .../v1/responses` 回 **503 `Endpoint is unavailable`**，
`/chat/completions` 回 200。实测（2026-10-22）：

| 配置 | 结果 |
|---|---|
| 钉 `--api=responses` | HTTP 400（`reasoning_content` 未回传），第 2–8 步退出 |
| 不钉（让本仓自己协商） | 协商到 chat/completions，任务正常跑完 |

**两个独立的坑叠在一起**，别只修一个：

1. **钉死协议会关掉协商**：`api_may_negotiate` 只在「未显式声明协议」时才回退，
   而 503 也不在回退集合（404/405/501）里 —— 声明即权威 + 503 不可回退 = 必挂。
2. **本仓不回传 `reasoning_content`**：`Msg` 只有 `text` / `extra` 两个槽，
   思考内容只进会话日志（`assistant/reasoning`，供显示），从不进历史，
   两条协议路径都没有这个字段。opencode 的 thinking 模式**强制要求**回传上一轮的
   `reasoning_content`，所以真跑起来仍然会在第 N 步撞同一个 400。

⇒ 装置侧已改成不钉协议（`OPENBENCH_UYAAGENT_API` 可按需覆盖）；
**第 2 条是本仓的真缺陷，未修**，详见本文件末尾「已知未修」。

## 三个坑（都是实测踩出来的，不是推测）

### 一、两侧的**输出上限**必须配对，否则比的是配置不是 harness

pi-ai 目录给 `DeepSeek-V4.1-Flash` 的默认 `maxTokens` 是 **32768**；
而本仓 `--max-tokens` 的默认是 **256000**。没配对时 dsh 在 `webcore` 上
**每一步都正常、到第 16 步撞顶**（会话日志：`outputTokens: 32768` +
`finish reason: max-tokens`）—— 它想把整个实现写在一次推理里，撞顶后
**一个字节都没落盘**（`workspace_changed=false`），得分停在基线 0.30。
**这不是能力差距，是两侧预算不等。** 把 `maxTokens` 提到 256000 后，
同一个任务 **78 步跑完、score 1.0000**。
⇒ 本目录的 `template_dsh/` 已经写成 256000；**任何跨 harness 的输出上限都必须
显式配对并写进报告**，否则结论会反过来。

### 二、dsh 的隔离 home 只能拷**文件**，不能拷目录

dsh 首次启动会在 `$DSH_HOME` 下建 `profiles/`（里面是一整片指向安装目录的符号链接）
和 `sessions/`。把一个**已经启动过**的 home 整个 `copytree` 成新 home，dsh 会撞上
`.../profiles/node_modules/@deepseek-ai/dsh exists and is not a symlink; remove it so
dsh can manage the installation fallback` 并直接退出。所以 `dsh.py` 的 `_stage_home()`
只拷文件、跳过目录，让 dsh 自己建。

### 三、操作者真实的 `~/.dsh/settings.yaml` 会让 dsh **整个 provider 注册失败**

症状：`NO_ADAPTER: no adapter registered for provider "aigw-local"`。
逐项二分定位到根因：**任何模型条目只要带 `compat: { supportsReasoningEffort: ... }`**
（`true` / `false` **都算**）就触发 —— 现场那个 `hy4-preview` 正带着它。
去掉该键即恢复；同一份文件**本仓（uya-agent）读得动**。
⇒ 所以 dsh 臂**必须**用隔离 home，不能用操作者那份（这也意味着本装置不会碰你的活配置）。

## 诚实边界（别把这些当成结论）

* **n=1**（webcore 另补了重复轮），**不是统计显著**；报的是方向性差异。
* **本仓没有传输层重试，dsh 有** —— 这是那次唯一一条**该改本仓**的结论。
  dsh 的 `dsh-base` 挂了 `dsh-llm-retry`，默认对
  `TRANSPORT`/`TIMEOUT`/`SERVER`/`RATE_LIMIT`/`EMPTY_RESPONSE` **重试 5 次**
  （退避 500 ms–10 s、10% 抖动）；本仓 `agent_step_stream` 收到
  `err_kind == 3`（网络/TLS）**直接 `return AGENT_NET`（退出码 2），一层重试都没有**。
  实测：配对窗口内 dsh 100 次请求 **0 失败**，本仓 163 次请求 **2 失败**；
  `webcore` 上本仓累计被上游掐断 **4 次**，而唯一跑通的补测轮拿了**满分 1.0**
  —— 丢的全是本来能解出来的题。所以「本仓 webcore 0.30」**不是能力差**。
* `webcore` 在真机上**反复**撞到网关 `upstream_error`（延迟 108–261 s 后失败）：
  这是**共享基础设施故障**，不是 harness 缺陷。网关历史里
  `unknown`/`dsh`/`uya-agent` 三方都出现过该错误。
* dsh 的会话日志**不写 `reasoningTokens`**（该版本实测：`usage` 块只有
  `inputTokens` / `outputTokens` / `cacheReadTokens`），而网关账本里确实有 reasoning
  计数。所以两侧的 `reasoning` 列**不可比**，`dsh.py` 照实报 0 而不是编一个数。
* 两侧 `tokens` 的 `in` 字段语义已与网关账本**逐数对上**（`input_cache_miss`），
  不是推测；但两边的**上下文管理策略不同**：本仓平均 prompt **56 k token（峰值 213 k）**，
  dsh **18.6 k（峰值 53 k）** —— 3× 差距，既解释了本仓更高的单请求成本，
  也解释了它更容易撞上上游的长请求不稳定。

## 复现这套装置踩到的坑（2026-10-22 重跑时补）

这四条都是「装置在骗你」那一族：**结果行看起来完全正常，数字却是假的**。

### 一、`_binary()` 先查 PATH 再查 `OPENBENCH_UYAAGENT_BIN` —— 测了别的二进制

`shutil.which("uya-agent")` 会命中操作者装过的 `~/.local/bin/uya-agent`。
实测那台机器上它是一份 **0.1.0 (p83-clip-any)** 的旧构建，不认新 flag，
于是每个单元格都在**参数解析阶段**退出：

| 现场 | 读起来像 |
|---|---|
| `error: exit 3` | 协议/配置错 |
| `output_tail` **空字符串** | 「没输出」 |
| `workspace_changed: false`、得分停在基线 | **「模型没做出来」** |

判据：`results.jsonl` 每行的 `cmd[0]` 必须是你要测的那份产物。
已修：显式路径优先（`uyaagent.py` 的 `_binary()`）。

### 二、dsh 0.2.0-rc.2 换了会话日志文件名与结构 —— token/轮数全变 None

| 项 | 旧构建 | 0.2.0-rc.2 |
|---|---|---|
| 文件名 | `session.jsonl.zstd` | `session.v4.jsonl.zstd` |
| usage 记录 | `assistant/chunk` | `assistant/message` |
| usage 位置 | `data.chunk.usage` | `data.usage` |
| 镜像位置 | — | `data.stream[].chunk.usage` |

adapter 原来只匹配 `session.jsonl*`，**新名字一个都匹配不到** ⇒
`_parse_session_usage` 返回 None ⇒ 12 格全是 `turns=None / tokens=None`，
而 `score` 照样是 1.0（判分不经过 adapter），所以**表面看不出来**。
已修：`_record_usage` 同时读两种布局；v4 有 `data.usage` 就用它，
避免把 `stream[]` 里那几份镜像**重复累加**（一次模型调用 = 一个 step = 一份 usage）。
四条判据见 `dsh.py` 的 docstring 与自测夹具（旧布局 / 新布局 / 无 `data.usage` 回退 / 无关记录）。

### 三、两个 runner 并发写同一份 `results.jsonl` —— 结果互相污染

为了省时间并行跑了「主轮」和「dsh 单独臂」，两边写的是**不同的**文件，
但同时在打同一个上游。实测差异肉眼可见：

| | taskflow 三格 | webcore |
|---|---|---|
| 串行主轮 | 1.0 / 1.0 / 1.0（65/121/71 s） | 1.0 / 1.0 / 1.0 |
| 并发那一轮 | 1.0 / **0.28** / 1.0（348/14/75 s） | 1.0 / 1.0 / 1.0 |

并发那轮的两格失败是 **10–14 s 就 `exit 1`**、`output_tail` 为空 ——
不是模型答错，是启动阶段被挤掉。**跨 harness 比效率时必须串行**，
否则你量的是自己的调度。

### 四、`output_tail: None` 与空字符串是两种不同的病

`None` 是 adapter 根本没拿到输出（子进程没起来 / 被 kill）；
`''` 是拿到了但一个字节都没有（旧二进制参数解析失败那一族）。
两者都指向「装置有问题」而不是「模型不行」，
所以**看到基线分 + 空输出，先查装置**。

## 已修：不回传 `reasoning_content`（本轮修的）

**症状**：在要求回传思考内容的路线（opencode thinking 模式）上，第一次工具调用之后
必然 `HTTP 400 The reasoning_content in the thinking mode must be passed back`。
真机现场：webcore 跑到第 2–8 步退出，`workspace_changed=false`、得分停在基线 ——
**读起来像「模型做不出来」，其实是协议走不通**。

**根因**：`struct Msg` 只有 `text` / `extra` 两个数据槽（`extra` 已被 tool_calls
原文或 tool_call_id 占用），思考内容只进会话日志供显示，从不进历史；
两条构请求路径也都没有写这个字段。aigw 那条路线会替没回传的历史补空串，
所以藏了很久；opencode 直连不补。

**修法**：`Msg` 加 `reasoning` / `reasoning_len`；新增 `hist_push_msg_reasoning`
（旧 `hist_push*` 全部转调，62 个调用点不用改）；chat 路径写 `reasoning_content`，
responses 路径发独立的 `{"type":"reasoning",...}` item 且排在 `function_call` 之前。

**判据**：`mock_reasoning_echo_ok(rx, expect)` —— 带 tool_calls 的 assistant
必须带非空 `reasoning_content`；`expect` 由调用方给（不能靠「请求里有没有
reasoning」自我判断，那是循环论证）。
A 臂 147 ok / 0 个 verdict 250；B 臂（摘掉修复）红在
`selftest[unlimited-steps] verdict 250`；真机 webcore **score=1.0、60 轮、1124 s**。

**教训（值得单独记）**：第一版判据写成「无条件要求每个 tool_calls 消息都有
reasoning」，但 `mock_bigcall_body` 本来就不回思考，当场假红；第二版改成
「靠请求里有没有 reasoning 自我判断」，负控下永远绿（自我放行）。
两个方向都错，最后靠「由调用方显式告诉判据这一轮该不该有」才对。
**判据的适用条件不能从被测对象本身推出来。**
