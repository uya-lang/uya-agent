#!/bin/sh
# testdata/dsh_web_check.sh — 产品侧 `--dsh-web` 的端到端验收（一条命令自证）。
#
# 验的是**产品二进制**（不是 python 探针）：它起 `--dsh-web`，再用 headless chromium
# + CDP 驱动到「DSH 的界面里渲染出本仓会话的消息」，断言两条只可能来自本仓日志的文本。
#
# 本机没装 DSH 或没有 chromium 时**跳过**（退出 0）—— 别的机器上也该能跑。
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/build/uya-agent
[ -x "$bin" ] || { echo "dsh-web-check: 先 make build"; exit 1; }

# 把**调用者的** `UYA_AGENT_*` 环境变量清掉再起产品。
#
# 为什么必须清：这台机器（以及任何 agent 会话）常常已经导出了
# `UYA_AGENT_BASE_URL` / `UYA_AGENT_MODEL` / `UYA_AGENT_API` / `UYA_AGENT_API_KEY`
# —— 而它们的优先级**高于 DSH 设置**（配置链是 DSH 设置 → env → CLI）。
# 它们漏进来时：本腿的模型目录夹具被 `--model` 那种 env 顶掉（实测：假网关收到
# `model=DeepSeek-V4.1-Flash path=/v1/responses`，而夹具里是 `model-a` 与
# `openai-completions`），于是「切模型」这一腿恒红 —— 而那是**环境**的错，不是产品的。
# 判据要验的是产品自己的来源链，所以把外部注入的那几条摘掉。
unset UYA_AGENT_BASE_URL UYA_AGENT_MODEL UYA_AGENT_API UYA_AGENT_API_KEY \
    UYA_AGENT_CONTEXT_WINDOW UYA_AGENT_REASONING_EFFORT UYA_AGENT_NO_DSH_CONFIG \
    UYA_AGENT_DSH_WEB_EVENTS UYA_AGENT_FORCE_SESSION_ID UYA_AGENT_STDIN_FRAMES

command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 \
    || { echo "dsh-web-check: 跳过 —— 本机没有 chromium"; exit 0; }
ls "$HOME/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html" >/dev/null 2>&1 \
    || { echo "dsh-web-check: 跳过 —— 本机没装 DSH 的 webui"; exit 0; }

# 真会话日志只有前两腿要（它们验「一份会话能渲染出来」）。**第三~五腿不要它**
# —— 那几腿自己起假网关造会话（活会话）。所以「没有日志」不再整条跳过：
# 那样会让这个目标在最需要它的机器上（干净 checkout）什么都不验。
log=$(find "$root/build" -name session.jsonl -size +500c 2>/dev/null | head -1)
if [ -z "$log" ]; then
    echo "dsh-web-check: 提示 —— 找不到真会话日志，前两腿（历史渲染）跳过；"
    echo "                 跑一次 make selftest 生成后再来可以覆盖它们"
fi

ev=$root/build/dshweb_check_events.ndjson
mkdir -p "$root/build"
# 前两腿（历史渲染 + 零事件源）需要一份真日志当事件源；没有就跳过这两腿，
# 但**继续**跑后面的活会话腿（它们自己造事件）。
if [ -n "$log" ]; then

UYA_SELFTEST_WIRE_FILE="$log" "$bin" --selftest 2>"$ev" >/dev/null
[ -s "$ev" ] || { echo "dsh-web-check: 失败 —— 适配层没翻出事件"; exit 1; }

port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
UYA_AGENT_DSH_WEB_EVENTS="$ev" "$bin" --no-dsh-config --dsh-web "127.0.0.1:$port" \
    >"$root/build/dshweb_check_host.log" 2>&1 &
host=$!
trap 'kill $host 2>/dev/null || true' EXIT

# 等宿主**真的**开始服务（而不是盲等固定秒数）：`--dsh-web` 起来时要读 14 个 bundle
# 算 rev，机器忙的时候 2 秒不够 —— 而它的症状是「页面空着」，看起来像数据没送到。
i=0
while [ $i -lt 40 ]; do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$port/"; then
        break
    fi
    sleep 0.5
    i=$((i+1))
done
curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$port/" \
    || { echo "dsh-web-check: 失败 —— --dsh-web 没起来（看 build/dshweb_check_host.log）"; exit 1; }

# 从译文里挑第一条用户消息的正文当断言（它只可能来自那份日志）
needle=$(python3 - "$ev" <<'PY'
import json,sys
for line in open(sys.argv[1],encoding='utf-8'):
    line=line.strip()
    if not line.startswith('{'): continue
    e=json.loads(line)
    if e.get('type')=='user/message':
        for b in e['data'].get('content',[]):
            if b.get('type')=='text' and b.get('text'):
                print(b['text']); raise SystemExit
PY
)
[ -n "$needle" ] || { echo "dsh-web-check: 失败 —— 日志里没有可断言的用户消息"; exit 1; }

# 起一个有 CDP 的 headless chromium（**用 localhost**：本机 DevTools 只绑 IPv6 回环）
prof=$(mktemp -d)
cdpport=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
chromium --headless --no-sandbox --disable-gpu --remote-debugging-port="$cdpport" \
    --user-data-dir="$prof" about:blank >/dev/null 2>&1 &
chrome=$!
cleanup() {
    kill $host $chrome 2>/dev/null || true
    wait $chrome 2>/dev/null || true
    rm -rf "$prof" 2>/dev/null || true
}
trap cleanup EXIT
ws=""
i=0
while [ $i -lt 40 ]; do
    sleep 0.5
    ws=$(curl -s --max-time 2 "http://localhost:$cdpport/json/list" 2>/dev/null \
        | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d[0]['webSocketDebuggerUrl'] if d else '')
except Exception:
    print('')" 2>/dev/null || true)
    [ -n "$ws" ] && break
    i=$((i+1))
done
[ -n "$ws" ] || { echo "dsh-web-check: 失败 —— chromium 的 CDP 没起来"; exit 1; }

# `set -e` 下不能让断言直接终止：失败时还要把浏览器控制台捞出来
#（「页面只是空」这类故障的唯一线索都在那儿 —— 本仓在 P80 上两次靠它定位）。
rc=0
WIRE_PROBE_URL="http://127.0.0.1:$port/" node "$root/testdata/wire_probe_drive.mjs" \
    "$ws" "" "$needle" || rc=$?
if [ $rc -ne 0 ]; then
    echo "--- 浏览器控制台 ---"
    WIRE_PROBE_URL="http://127.0.0.1:$port/" node "$root/testdata/wire_probe_console.mjs" "$ws" 2>&1 | head -25 || true
    exit $rc
fi
echo "dsh-web-check: 通过 —— 产品二进制 --dsh-web 把本仓会话渲染进了 DSH 的 webui"

# ── 第二腿：**零事件源**（用户零参数跑 `--dsh-web` 的形态）───────────────
#
# 为什么必须单跑这一腿：上面那条只覆盖「有译文」的路，而用户报的现场恰恰是
# **没有**译文的那一路 —— 快照 `records[]` 多一个逗号（`},,{`）时客户端拒帧、
# `close(4002)`，页面红字「加载会话历史失败」+ 每 3 秒重连一次，而上面那条
# （有译文、seed 与译文之间正好需要那个逗号）**照样绿**。
# 判据在 `dsh_web_zero_drive.mjs`：合成器活着 + 红字不在 + 不重连。
zero_port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
"$bin" --no-dsh-config --dsh-web "127.0.0.1:$zero_port" \
    >"$root/build/dshweb_check_zero.log" 2>&1 &
zhost=$!
trap 'kill $host $zhost 2>/dev/null || true' EXIT
i=0
while [ $i -lt 40 ]; do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$zero_port/"; then
        break
    fi
    sleep 0.5
    i=$((i+1))
done
curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$zero_port/" \
    || { echo "dsh-web-check: 失败 —— 零事件源的 --dsh-web 没起来（看 build/dshweb_check_zero.log）"; exit 1; }

zero_rc=0
WIRE_PROBE_URL="http://127.0.0.1:$zero_port/" \
    node "$root/testdata/dsh_web_zero_drive.mjs" "$ws" || zero_rc=$?
kill $zhost 2>/dev/null || true
if [ $zero_rc -ne 0 ]; then
    echo "dsh-web-check: 失败 —— 零事件源那一路（用户零参数跑的形态）"
    exit $zero_rc
fi
echo "dsh-web-check: 通过 —— 零事件源也能起（无红字、不重连）"
else
    echo "dsh-web-check: 前两腿跳过（没有真会话日志）"
fi

# ── 第三腿：**活会话**（用户零参数跑 `--dsh-web` 之后真的打字）─────────────
#
# 上面两条都只覆盖「页面能起来、历史画得出来」。用户报的另外两条是
# **「模型选择器空的」**与**「打不了字」** —— 它们在这一腿上才看得见：
#   * 一、二两腿起宿主时都**没有**活会话（一腿给了译文、二腿零事件源但也没起
#     子进程的判断被快照那一条盖住了），所以「输入框发出去有没有人接」从来没被
#     验过；
#   * 判据必须走**真键盘**（`Input.insertText` + 回车）：直接 curl `session/prompt`
#     只验宿主自己，验不到「页面上的输入框把什么发出去了」。
#
# 这一腿起一个假网关（`mock_gateway_route.py` 的 A 口），并把**模型名**当暗号：
# `PROV-A-ANSWER` 只可能来自它 ⇒ 对话区里出现它，就说明
# 「打字 → composer 提交 → 宿主 → 子进程 → LLM → 日志 → tail → 推送 → 渲染」
# 整条链都通了。本机没装 DSH / 没 chromium 时已经在上面的跳过分支里退出了。
chat_port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
gwlog="$root/build/dshweb_check_gw.log"
gwalog="$root/build/dshweb_check_gw_b.log"
# **两个**假网关，各扮演一个提供方：
#   * A 口（`mock_gateway_route.py`）—— 第一问走它，答 `PROV-A-ANSWER`；
#   * B 口（`mock_gateway_answer.py`）—— 切过去之后走它，答 `PROV-B-ANSWER`。
# 为什么 A 口用 route 那个「先要一条慢 bash」的：它的答复文本按提供方不同，
# 于是「这一轮是谁答的」在页面/日志里就是可读的事实（它就是为这类判据造的）。
# 为什么 B 口要另造一个「当场答一句」的：切换之后的判据只需要「谁答的」，
# 而 route 那个会**再要一条慢 bash** ⇒ 每条腿多等 10 秒、且要读两轮才看得到答复。
python3 "$root/testdata/mock_gateway_route.py" 0 >"$gwlog" 2>&1 &
gwp=$!
python3 "$root/testdata/mock_gateway_answer.py" 0 "PROV-B-ANSWER" >"$gwalog" 2>&1 &
gwap=$!
trap 'kill $host 2>/dev/null || true; kill ${zhost:-0} 2>/dev/null || true; kill $gwp 2>/dev/null || true; kill $gwap 2>/dev/null || true' EXIT
i=0
gw_a=""
gw_b=""
while [ $i -lt 40 ]; do
    gw_a=$(awk '/^PORT-A/{print $2}' "$gwlog" 2>/dev/null)
    gw_b=$(awk '/^PORT/{print $2}' "$gwalog" 2>/dev/null)
    [ -n "$gw_a" ] && [ -n "$gw_b" ] && break
    sleep 0.25
    i=$((i+1))
done
if [ -z "$gw_a" ] || [ -z "$gw_b" ]; then
    echo "dsh-web-check: 失败 —— 假网关没起来"; cat "$gwlog"; cat "$gwalog"; exit 1
fi
echo "dsh-web-check: 假网关 PORT-A=$gw_a PORT-B=$gw_b"

# 活会话的落点：独立的 HOME/agent-home/workspace（**不能**用仓库根 —— 会话日志会
# 写进去，而这一腿要断言「日志里只有 JSONL」）。
live_ws="$root/build/dshweb_check_live"
rm -rf "$live_ws"; mkdir -p "$live_ws/ws" "$live_ws/home"
python3 "$root/testdata/dsh_web_live_home.py" "$live_ws/dsh" "$gw_a" "$gw_b" \
    || { echo "dsh-web-check: 失败 —— 造不出模型目录夹具"; exit 1; }

live_port=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
# ⚠ **不给 `--no-dsh-config`**：这一腿要的正是「模型目录来自 `--dsh-home` 这一份
# settings.yaml」（`--dsh-home` 与 `--no-dsh-config` 是互斥的两条路 —— 前者说
# 「去这里读」，后者说「什么都别读」）。给了它，夹具里那两个提供方一个都进不了
# 目录，切模型那一腿就恒红，而症状是「请求仍打出厂默认的那个模型」（实测）。
# 也不给 `UYA_AGENT_BASE_URL`：路线要从夹具里来，否则 env 会盖过它。
(
    cd "$live_ws/ws" || exit 1
    UYA_AGENT_API_KEY=k \
        "$bin" --dsh-home "$live_ws/dsh" \
        --agent-home "$live_ws/home" --dsh-web "127.0.0.1:$live_port" \
        --workspace "$live_ws/ws" >"$root/build/dshweb_check_live.log" 2>&1
) &
lhost=$!
trap 'kill $host 2>/dev/null || true; kill ${zhost:-0} 2>/dev/null || true; kill $gwp 2>/dev/null || true; kill $lhost 2>/dev/null || true' EXIT
i=0
while [ $i -lt 60 ]; do
    if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$live_port/"; then
        break
    fi
    sleep 0.5
    i=$((i+1))
done
curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$live_port/" \
    || { echo "dsh-web-check: 失败 —— 活会话的 --dsh-web 没起来（看 build/dshweb_check_live.log）"; cat "$root/build/dshweb_check_live.log"; exit 1; }

chat_rc=0
WIRE_PROBE_URL="http://127.0.0.1:$live_port/" \
    node "$root/testdata/dsh_web_chat_drive.mjs" "$ws" "PROV-A-QUESTION" \
    "PROV-A-ANSWER" || chat_rc=$?
if [ $chat_rc -ne 0 ]; then
    echo "--- 活会话宿主日志 ---"
    cat "$root/build/dshweb_check_live.log"
    echo "--- 假网关说了什么（两个口都看）---"
    grep -E "^GW-" "$gwlog" "$gwalog" | tail -8 || true
    echo "dsh-web-check: 失败 —— 打字那一腿"
    exit $chat_rc
fi
echo "dsh-web-check: 通过 —— 在页面里打字，答复渲染进了对话区"

# ── 第四腿：**模型选择**（选了另一个提供方 ⇒ 请求真的打到那一家）───────────
#
# 为什么判据是「假网关收到的 model / 端口」而不是「页面上显示的名字」：
# 显示名是宿主自己画的，**页面显示对了、请求没变**正是这一族最典型的假绿
# （`dshmodel.uya` 不变量③：选择要落执行核与投影两处，只落一处就是那种假象）。
# 所以走 A 口问一次（PROV-A-ANSWER），切到 B 家的模型，再问一次 ——
# 第二次的答复必须是 `PROV-B-ANSWER`。
#
# 输入用 `Input.insertText` 而不是真键盘找触发器：DSH 的选择器是一个菜单浮层
# （`dsh-client-ui-model-selection`），点开它要点好几层、且 class 名是构建期哈希
# （钉死就假红）。这里直接打 composer 的 slash 命令路径**不存在** —— 所以这一腿
# 走宿主的 API（`session/selectModel`），页面那一侧由第三腿的 `modelCatalog` 渲染
# 保证（选择器读的就是同一个目录）。两条合起来覆盖「目录对 + 选择生效」。
model_rc=0
WIRE_PROBE_URL="http://127.0.0.1:$live_port/" \
    node "$root/testdata/dsh_web_model_drive.mjs" "$ws" \
    "http://127.0.0.1:$live_port" "$gwalog" || model_rc=$?
if [ $model_rc -ne 0 ]; then
    echo "--- 活会话宿主日志 ---"
    cat "$root/build/dshweb_check_live.log"
    echo "--- 假网关说了什么（两个口都看）---"
    grep -E "^GW-" "$gwlog" "$gwalog" | tail -10 || true
    echo "dsh-web-check: 失败 —— 模型选择那一腿"
    exit $model_rc
fi
echo "dsh-web-check: 通过 —— 切模型之后请求真的打到了另一家"

# ── 第五腿：**会话日志必须是逐行 JSONL**（活会话的诊断不许混进去）──────────
#
# 为什么单列这一条：会话日志是**宿主的事件源**（`dwhc_tick` 逐行喂 `dwire_line`），
# 混进一行非 JSON 时 `dwire_line` 只是「跳过它」——**页面照样能渲染**，所以上面
# 三条腿全都是绿的（实测：子进程的 `/model` 回执与 `warning:` 直接写进了日志）。
# 判据是每行都能被 `json.loads` 解出来（与 `web-snapshot` 轮那条「结构坏掉要由
# 外部 oracle 判」同一条道理）。
log_rc=0
python3 "$root/testdata/dsh_web_log_check.py" "$live_ws/home" || log_rc=$?
if [ $log_rc -ne 0 ]; then
    echo "dsh-web-check: 失败 —— 会话日志里有非 JSONL 的行"
    exit $log_rc
fi
echo "dsh-web-check: 通过 —— 会话日志每一行都是合法 JSON（诊断没有混进去）"
