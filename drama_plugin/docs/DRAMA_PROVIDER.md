# Provider 与平台说明

## 当前实现范围

本版本可运行的 Provider 是离线 `mock` LLM 和本机无认证的
OpenAI 兼容 LLM。视频侧只有确定性的 `mock.video`，不连接 ComfyUI、
云视频 API 或真实 FFmpeg 产线。

所有示例都以数据根目录为 `/var/lib/drama`。CLI 没有 `--config` 参数，
但 LLM 适配层会在每次 LLM 操作时读取：

```text
/var/lib/drama/llm.json
```

不存在 `llm.json` 时使用 `mock`，不联网，也不需要额外配置。

## LLM 配置

默认的离线模板可以省略文件；显式写出时内容如下：

```json
{"provider":"mock"}
```

本机无认证 OpenAI 兼容网关的模板如下。`base_url` 在当前实现中是
主机名或 IP，不要写 `http://` 前缀；`path` 是 HTTP 路径。

```json
{
  "provider": "openai",
  "base_url": "127.0.0.1",
  "port": 8080,
  "tls": 0,
  "path": "/v1/chat/completions",
  "model": "local-model",
  "timeout_ms": 3000,
  "max_retries": 1
}
```

字段行为：

- `provider`：`mock` 或 `openai`；其他值返回不支持错误。
- `base_url`、`port`、`path`：OpenAI 兼容 HTTP(S) 端点。
- `tls`：非零时启用 TLS；证书校验由标准库 HTTPS 栈执行。
- `model`：放入请求体的模型名；mock 不使用它。
- `timeout_ms`：连接和读取超时，默认 `3000`。
- `max_retries`：网络类失败的重试次数，默认 `1`。
- `api_key`：可选；非空时每个请求带 `Authorization: Bearer <key>`。密钥只
  在配置文件里（权限 0600），不要写进 Project Bible、任务记录或日志。

请求是 `POST`，正文使用 `model`、零温度和一条 user message；响应要求
`choices[0].message.content` 是可解析并通过剧本结构校验的 JSON。

当前不读取 `OPENAI_API_KEY` / `HTTP_PROXY` 等环境变量，也没有代理字段；
认证只来自 `llm.json` 的 `api_key`。连接公网 Provider 时务必用 `tls: 1`，
否则 Bearer 头会明文过网。P5 回归会用一个本机 HTTP 服务抓
`Authorization`，断言 `api_key` 确实变成了 `Bearer` 头。

P5 回归覆盖默认 mock、本机 OpenAI 兼容请求、`api_key` 头、500、畸形响
应、非 JSON 模型输出和超时：

```sh
sh drama_plugin/p5_selftest.sh
```

## 视频能力表

`provider.capabilities` 当前返回固定的 mock 能力表：

```json
{
  "provider": "mock.video",
  "capability_version": "mock-video-cap-1",
  "max_shots": 64,
  "max_shot_ms": 30000,
  "forbidden_actions": ["跳切", "爆炸"],
  "supports": ["anchor", "hard_cut"],
  "media": {
    "ffmpeg": true,
    "ffmpeg_path": "/usr/bin/ffmpeg",
    "ffprobe": true,
    "ffprobe_path": "/usr/bin/ffprobe"
    ,"http_provider": false
  }
}
```

`capability_version` 必须随实现或模型能力变化而更新。`media` 是宿主
媒体工具探测结果：只检查 `/usr/bin`、`/usr/local/bin`、`/bin` 三个
目录（不读宿主 `PATH`），找不到时布尔为 `false`、路径为空串；本阶段
只报可用性，不执行 FFmpeg 也不记录版本。当前 mock 渲染
只写确定性的 256 字节占位文件，不能作为可播放成片；动作禁用词在渲染
前拦截。占位文件按分镜版本分目录：
`projects/<id>/assets/v<board_version>/shot_<seq>.mp4`，所以不同集同号
镜头不会互相覆盖；`media.assemble` 只在该集分镜自己的目录里拼接。每渲染
一镜会同时写一条 `assets.jsonl` 资产账本（名字、mime、大小、SHA-256），
任务重置后重跑按名字查重，不会重复登记。P8 回归验证能力表版本、未批准剧本拦截、Worker、失败任务和
单 Worker 锁：

```sh
sh drama_plugin/p8_selftest.sh
```

真实本机视频队列、云视频 API、重试上限和 FFmpeg 适配器仍未实现，不能
依据这张 mock 能力表安排真实生产。

## Provider 接口（图像 / 音频 / 媒体 / 产线）

四类 Provider 共用一套生命周期：`submit` → `poll` → `fetch`，失败走同一张
错误映射表；每类都要在能力表里自报 `capability_version`，版本一变就得
重跑对应回归。`http_provider:false` 是显式占位：本版没有云 API 版，
不要把它当成可用能力。

### ImageProvider（尚未实现）

- `submit(shot, ref_images[])` → `{prompt_id}`；
- `ref_images` 的顺序就是 `<Picture n>` 的绑定顺序，**顺序不同即新任务**；
- `poll(prompt_id)` → `queued|running|done|failed{reason}`；
- `fetch(prompt_id)` → `{file, width, height, sha256}`；
- 能力表：`max_refs`、`supported_sizes`、`seedable`。

### AudioProvider（首版不做配音替换）

只保留方法名与错误码，调用即回 `PROVIDER_UNSUPPORTED`；首版字幕按镜头
时长均分（`media.subtitle`），不做 TTS，也不做音色绑定。

### MediaProvider（本机 FFmpeg，已实现）

由 `provider.encode` / `mux` / `mix` / `loudnorm` / `probe` 兑现，参数取自
剧本的 `format` 块；只接受项目内相对路径，不做远程上传。

### PipelineProvider（子进程方式接既有产线，已实现为 `pipeline.run`）

`pipeline.run`（`src/pipeline_ops.uya`）的入参：`pipeline_root`（绝对路径）、
`episode`（相对目录，不许含 `..`）、`entry`（九个白名单入口）、`shot`、
`dry`、`force`、`timeout_s`（默认 1800，上限 7200）。落地细节：

- 命令形如 `cd <root>/<episode>/scripts && [FORCE=1] timeout N python3 <脚本> [参数] > <日志> 2>&1`；
- 日志落在 `<episode>/.pipeline_<entry>.log`，只回尾部 600 字节（`lseek` 到末尾读）；
- 退出码原样回（`system()` 的 `(st >> 8) & 255`；超时是 `timeout` 的 124）；
- `generate` 会顺带回 `shots/shotNN/{shotNN.mp4,last.png,done.json}` 的存在性
  与字节数（走 `sys_stat`），其它入口只回退出码与日志；
- 白名单九个入口见上表；不认识的入口、越界路径、非绝对 `pipeline_root`
  一律 `SCHEMA_INVALID`。

- `submit(job_json)`：`execve` 产线脚本（绝对路径 + 白名单 env），`stdin`
  给 job JSON，`stdout` 只允许单行 JSON；
- 产物必须落到项目 `assets/` 下并回相对路径，不允许把宿主绝对路径透出去；
- 超时（默认 900 s）→ `TIMEOUT`；非 0 退出码 → `UPSTREAM_ERROR`，
  消息里带 `stderr` 末尾；
- `cancel(prompt_id)` 必须真的给子进程发信号，不能只停掉 `poll`。

### 既有产线勘定（B 档接口边界）

实地勘定的既有产线在 `~/ersunfu/micro-drama/顶楼误闯/第001集/`（一集一目录，
同系列的口径写在 `../系列规范.md`）。下面这张表是"我们只管调度、它只管生成
与合成"的接口清单；`PipelineProvider` 就按这张表接。

| 入口（`scripts/` 下） | 干什么 | 占 GPU | 产物 |
|---|---|---|---|
| `shots.py` | **本集唯一真相**：9 镜定义（提示词/台词/字幕/片尾卡/接戏） | — | 被其它脚本 import |
| `lint_shots.py` | 静态体检，秒级，不碰 GPU | 否 | stdout 摘要 + 非 0 退出码 |
| `run_shots.py [--dry] [n]` | 逐镜生成 → 轮询 → 取回 mp4 → 抽末帧 | 是 | `shots/shot<NN>/{shot<NN>.mp4,last.png,done.json}` |
| `check_join.py [strip n]` | 接戏：切点两侧数值差 + VLM 判定 | 否 | `qc/join.json` |
| `qc.py asr` | 台词是否说对（ASR，可与出片并行） | 否 | `qc/asr.json` |
| `qc.py vision n` | 竖屏/黑边/画面文字/角色与光线 | 否 | `qc/qc.json` |
| `qc.py continuity` | 相邻同场景镜是否同一空间（`CONT_PAIRS`） | 否 | 追加进 `qc/qc.json` |
| `cards.py` | 字幕/角标/片尾卡 | 否 | `cards/*.png`（含 `end_card.png`） |
| `build_film.py [--dry]` | 剪辑 + 叠卡 + 调色 + 响度归一 → 成片 | 否 | `成片/<集名>.mp4` |
| `qc.py final` | 成片终检（探针 + 逐窗 ASR） | 否 | `qc/final_qc.json` |
| `contact.py` / `queue_all.py` | 联系表 / 多集批量排队 | 否 | 联系表 png / 队列 |

勘定到的硬约束（改模板前先看这张表，都是产线侧的事实，不是我们的约定）：

| 约束 | 取值 | 出处 |
|---|---|---|
| 画布 | 448×800（32 的倍数），成片 440×800 | `run_shots.py --dry` 校验 / 成片探针 |
| 帧率 | 24 fps | `qc/final_qc.json` 的探针 |
| 片段帧数 | 必须落在 `17k+5`（k=3…25）网格上，即 `gen_seconds ≈ (17k+5)/24` | `lint_shots.py` 的 `GRID` |
| 单镜源素材 | 3–9 s（`target_seconds ≤ gen_seconds`） | `lint_shots.py` |
| 镜数 | 8–11（惯例 9–10），镜号必须连续 1..N | `lint_shots.py` |
| 参考图 | 角色定妆图 448×800；`<Picture n>` 的顺序 = `refs` 顺序 | `lint_shots.py` |
| 提示词必备句 | "vertical"、"no on-screen text/no readable"、"no black bars/no letterbox"、画里有几个人/几只猫、"reference pictures are polished cg" 或 "…studio casting photographs" | `lint_shots.py` |
| 台词 | 逐字来自 `剧本.txt`；`<d>[Chinese]…</d>` 条数 = `expect` 条数 | `lint_shots.py` |
| 场景枚举 | 只能取调色表里的键（`meeting`/`corridor`/`city`/`home`…） | `lint_shots.py` 的 `SCENES` |
| 接戏对 | `CONT_PAIRS` 必须是相邻镜 | `lint_shots.py` |
| 片尾卡 | 必须有 `END_CARD`，单列时长（本项目实测 4.2 s） | `shots.py` / `build_film.py` |
| 响度 | 成片整体 ≈ −16 LUFS | `build_film.py` |
| 实测成本 | 单镜 6–15 分钟（3060 12G，H3 int8）；一集 9 镜 1.5–2.5 h GPU | `README.md` / `build.log` |

接口边界（B 档）：

- **Uya 侧只做**：剧本/分镜版本、Canon 与 Bible（冻结文本 + hash）、任务与
  预算、审计与终检判据、资产账本、成本外推。它不碰 GPU、不生成像素。
- **产线侧只做**：从 `shots.py` 出发的生成、质检、叠卡、合成与压制；
  它不决定"第几集、用哪版剧本、有没有预算"。
- 两侧只通过三样东西握手：**job JSON**（镜号/提示词/参考图顺序/画布/
  `gen_seconds`/种子）、**退出码**（0 成功，非 0 连 `stderr` 末尾一起进
  检查点）、**产物清单**（`shots/shotNN/*`、`cards/*`、`成片/*`、`qc/*.json`
  的相对路径 + sha256）。这三样正是 `queue/<task_id>.json`、
  `provider.result` 与 `asset.list` 记的东西，所以换成子进程接法不用改状态机。

### 产能口径（`pipeline.capacity`）

拿真产线的 `build.log` 直接算，不再手抄数字：

- 逐行扫 `NN 已提交` 数提交次数、`NN 完成，用时 X.Y 分钟` 取每次用时；
- `shots` = 提交行里最大的镜号；`mean_shot_ms` = 完成用时均值；
- `redo_rate_milli` = 提交次数 / 镜数（千分比，3.56× 记 3560）；
- `episode_gpu_ms` = 本期实际总用时（含重做），`ideal_episode_gpu_ms` =
  均值 × 镜数（无重做）；
- 外推到 `target_episodes`（默认 100）给 `projection.{gpu_hours_milli,
  ideal_gpu_hours_milli, baseline_gpu_hours_milli(292000), error_pct_milli}`；
- 日志最多读尾部 256 KB（大日志用 `lseek`），空日志回 `measured=false`
  的全零报告，日志不存在回 `IO_ERROR`。

### 视觉判据（`qa.appearance`，本机 VLM）

外观/服装这条是"模型辅助"，两条判据分开算，取最严：

- **像素门**（确定性）：`baseline` 与 `image` 缩到 64×64 灰度算 PSNR，
  `psnr_mdb` 低于 `min_psnr_db`（默认 15 dB）就不过；两张图一致按 `inf`
  记 999999。真机标定：定妆图 vs 首镜末帧 7546 mdb、镜1末帧 vs 镜2末帧
  10344 mdb ⇒ 跨场景绝对值天然低，所以这道门只管"同一机位同一人"的漂移。
- **模型判**：`use_model` 时把图 base64 发本机 VLM（`<data>/llm.json` 指向
  vision 模型，走 OpenAI 形状 `/v1/chat/completions`，`content` 里放
  `{"type":"image_url"}` data URL），提示词要求第一行只回 `OK`/`DRIFT`；
  回话里出现 `DRIFT` 就判不过，原话进 `note`。
- 返回 `{image, character_id, psnr_mdb, min_psnr_mdb, psnr_ok, model_used,
  model_rc, model_verdict, note, ok}`；`model_rc` 83=没配模型（mock）、
  82=模型侧非 200、72=连接/接收失败。
- 真机实证：448×800 真帧 + 冻结文本「苏晚：短寸头，深蓝卫衣」⇒ 模型回
  `DRIFT`＋「图中人物是长马尾 + 黑色西装外套配白衬衫」，`ok=false`。
- 注意：`httpc` 的请求缓冲原来是 8 KB（栈上），装不下几百 KB 的图，已改成
  1 MB 堆缓冲；响应缓冲同样给到 1 MB。

### 真机验收（`real_gpu_check.sh`，可选）

`bash drama_plugin/real_gpu_check.sh` 对既有产线跑不占 GPU 的入口（`lint`、
`generate --dry`）并复算产能；`REAL_SHOT=3 bash ...` 再真生成一镜（6–15 分钟，
需要 ComfyUI 在 `H3_HOST`）。这脚本不进 CI（`p*_selftest.sh` 那个循环），
因为它要真 GPU 与真产线目录。

真机实测（2026-11-07，RTX 3060 12G + MiniMax H3 int8）：

| 镜号 | 帧数 | 用时 | 产物 |
|---|---|---|---|
| 镜1 | 158 | 13.0 min | `shot01.mp4` 889 KB / `last.png` 407 KB |
| 镜2 | 73 | 5.7 min | `shot02.mp4` 303 KB / `last.png` 419 KB |
| 镜3 | 107 | 8.0 min | `shot03.mp4` 452 KB / `last.png` 503 KB |
| 镜4 | 192 | 17.7 min | `shot04.mp4` 见目录 |
| 镜5 | — | 20.0 min | — |
| 镜6 | — | 11.3 min | — |
| 镜7 | — | 14.7 min | — |
| 镜8 | — | 11.0 min | — |
| 镜9 | — | 20.0 min | — |

**整集真跑（2026-11-08，全程经 `pipeline.run` 调用既有产线）**：9 镜全部真生成，
本机合计 **≈ 121 min（2.0 h）**（5.7–20.0 min/镜）；随后 `cards` + `build`
出真成片 `第001集_明早八点别迟到.mp4`（**9,018,106 B / 440×800 / 59.67 s**），
Uya 的 `media.probe` 复探一致。`final` 入口失败在环境上（产线 `qc.py final`
要 `/tmp/asrvenv/bin/python` 这个 ASR venv，本机没有），`pipeline.run` 如实
把非 0 退出码与 `stderr` 尾部回给了调用方。

### 规模压力（`real_stress.sh`，可选）

`EPISODES=N bash drama_plugin/real_stress.sh`：把样板集复制成 N 集，逐集走
`pipeline.run`（`lint` → 可选 `generate` → `cards` → `build`）再用
`media.probe` 复探成片，最后汇总"集数 / 合计 MB / 片长区间 / 墙钟"。
`REUSE=1`（默认）复用样板集已生成的真镜头，只跑不占 GPU 的那几段；`REUSE=0`
才真生成（6–20 分钟/镜）。

实测（2026-11-08，RTX 3060 12G）：

| 口径 | 结果 |
|---|---|
| 1 集真采样（9 镜全真跑） | ≈121 min，真成片 9.02 MB / 440×800 / 59.67 s |
| 100 集真产线压力（`REUSE=1`） | 100 部真 mp4 / 860.0 MB / 墙钟 3800 s / 0 失败 |
| 100 集全真采样的 GPU 预算 | ≈200 GPU h（一次过）／867 GPU h（含重做） |

这轮压力顺带压出一个真问题：`pipeline.run` 的日志尾部原来按字节截断，
会切在多字节字符（中文）中间，调用方 `json.loads` 直接失败（百集里第 100 集
必现）。现在 `read_tail` 会跳过开头的 UTF-8 续接字节，`p16` 有专门用例。

### 错误映射（四类共用）

| 情况 | 错误码 |
|---|---|
| 提交参数不合法 | `SCHEMA_INVALID` |
| 队列/服务不可达 | `NETWORK_ERROR` |
| 任务失败 | `UPSTREAM_ERROR` |
| 响应不是约定 JSON | `BAD_RESPONSE` |
| 超出预算 | `BUDGET_EXCEEDED` |
| 能力表里没有的能力 | `PROVIDER_UNSUPPORTED` |

## 平台与依赖边界

当前发布目标是 **GNU/Linux x86-64**。本仓随附的 Uya 编译器是 x86-64
静态 ELF；本项目生成的 `drama` 是 x86-64、glibc 动态链接 ELF。运行已构建
的二进制不需要 Uya 或 Python，但需要兼容的 Linux x86-64 用户态和文件系统。

从源码构建需要：

- Uya 0.11.0 编译器与匹配的 `uya/stdlib`；
- POSIX `sh`、临时目录、文件重命名和 TCP 网络能力；
- `UYA` 与 `UYA_ROOT` 可用于选择外部的匹配工具链。

完整源码自测还使用 `bash`、`python3`、`timeout`、`mktemp`、`tar`、
`sha256sum` 和 `md5sum`。这些是测试和打包依赖，不是已构建二进制的
运行时依赖。

本版本没有 macOS、Windows、ARM 或其他架构的构建与运行验收证据，
不宣称这些平台受支持。跨平台发布前必须重新构建、运行 `build_selftest.sh`
和完整阶段自测，并单独记录工具链、系统 ABI 与 Provider 结果。
