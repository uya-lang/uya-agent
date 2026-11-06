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

### PipelineProvider（子进程方式接既有产线）

- `submit(job_json)`：`execve` 产线脚本（绝对路径 + 白名单 env），`stdin`
  给 job JSON，`stdout` 只允许单行 JSON；
- 产物必须落到项目 `assets/` 下并回相对路径，不允许把宿主绝对路径透出去；
- 超时（默认 900 s）→ `TIMEOUT`；非 0 退出码 → `UPSTREAM_ERROR`，
  消息里带 `stderr` 末尾；
- `cancel(prompt_id)` 必须真的给子进程发信号，不能只停掉 `poll`。

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
