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

请求是 `POST`，正文使用 `model`、零温度和一条 user message；响应要求
`choices[0].message.content` 是可解析并通过剧本结构校验的 JSON。

当前请求不读取环境变量，也不发送 `Authorization` 或 API Key Header。
因此只能连接用户自管的无认证本机网关；公网认证 Provider 暂不可用。
不要把密钥写进 `llm.json`、Project Bible、任务记录或日志。

P5 回归覆盖默认 mock、本机 OpenAI 兼容请求、500、畸形响应、非 JSON
模型输出和超时：

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
  "supports": ["anchor", "hard_cut"]
}
```

`capability_version` 必须随实现或模型能力变化而更新。当前 mock 渲染
只写确定性的 256 字节占位文件，不能作为可播放成片；动作禁用词在渲染
前拦截。P8 回归验证能力表版本、未批准剧本拦截、Worker、失败任务和
单 Worker 锁：

```sh
sh drama_plugin/p8_selftest.sh
```

真实本机视频队列、云视频 API、重试上限和 FFmpeg 适配器仍未实现，不能
依据这张 mock 能力表安排真实生产。

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
