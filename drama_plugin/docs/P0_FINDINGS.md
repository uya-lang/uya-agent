# P0 调研结论

> 口径：只写「跑过测试」或「读过源码」的结论。没验证的一律进 §7「不可用 /
> 替代方案」。测试脚本都是 `drama_plugin/p*_selftest.sh`，共 22 个。

## 1. 运行时与工程

| 项 | 结论 | 证据 |
| --- | --- | --- |
| Uya 模块 / 构建 | 已验证：28 个单模块 `.uya` 编成一个可执行 | `bash drama_plugin/build.sh` → `build/drama`（1.08 MB） |
| 运行时依赖 | 已验证：只用 `libc.so.6`，不引第三方库 | `ldd build/drama` 两行 |
| selftest 规范 | 已验证：p 脚本全走「起真进程 + JSON-RPC」黑盒 | 22 个 `p*_selftest.sh` |
| 首版目标平台 | 决定：Linux x86_64；系统调用只用 `libc.syscall` 子集（read/write/open/fsync/rename/mkdir/getrandom/clock_gettime） | `src/plat.uya` |
| 仓库落点 | 决定：**暂留本仓 `drama_plugin/`**（独立仓库只影响打包，不影响代码）；迁移时整目录拖走即可 | §19 |
| 宿主插件契约 | 已验证：宿主 fork+execve，只给白名单 env，不套沙箱；`cwd` 由配置给 | `src/plugin/mcprun.uya` |

## 2. MCP Server 原型（已验证）

- 传输：stdio 的**单行紧凑 JSON-RPC 2.0**，一请求一行，不美化、不换行。
- 方法：`tools/list`、`tools/call`、`ping`；错误统一 `{code,message,field,retryable}`。
- 证据：`p1`（协议 / CLI 三模式）、`p2`（Registry / Schema / 未知操作）。

## 3. HTTP 请求原型（已验证）

- 自己写 HTTP/1.1 客户端，**不引 libcurl**：`src/http.uya`（DNS/TCP/请求拼装/
  分块读/超时）。
- 证据：`p5`（LLM 传输层 + Adapter 骨架），mock 服务端跑真实套接字。

## 4. 文件事务原型（已验证）

- 写：`tmp + fsync + rename`（`store.write_atomic`），父目录 `mkdir_p` 自动建。
- 锁：`O_CREAT|O_EXCL` + 陈旧锁探活（`{pid,host,acquired_at,purpose}`），
  抢不到回 `LOCKED`。
- 证据：`p3`（基础存储）、`p4`（提交 / 锁 / 恢复 / 重放）。

## 5. Worker 中断 / 重启（已验证）

- 任务落盘 `state=pending|running|done|failed`，进程重启后按 `cursor` 续跑。
- 证据：`p5d`（持久任务 / 断点续跑）、`p8`（失败重试 / 预算熔断）、
  `p13c`（10 集 mock 压力 + 抽样恢复）。

## 6. 产线适配接口草图（已验证）

- 边界：**Uya 只做状态与调度**，生成/合成在产线；接口是
  `media.*` + 能力表 `provider.capabilities`，见 `DRAMA_PROVIDER.md`。
- 证据：`p8`（能力表 / 视频任务 / Worker）、`p10`（编码 / 字幕 / 混音 /
  成片合成 / 单镜重试）、`p12`（资产完整性）。

## 7. 不可用 / 替代方案

| 能力 | 状态 | 替代 |
| --- | --- | --- |
| 真实视频 Provider | 不可用（无凭据） | mock 镜头 + 本地拼接（`media.assemble`），`p13c` 压到 10 集 |
| ASR 对齐 | 引擎不可用；判定已实现（`qa.align`，转录文本由外部给） | 字幕按镜头时间轴生成（`media.subtitle`）；相似度阈值 85% |
| 画布 32 倍数 / `17k+5` 帧 | manifest 记 25 fps 与 `17k+5` 帧（`assemble`）；不做真实编码 | `media.encode` 只透传参数并回 `MEDIA_MISMATCH` |
| TLS 经代理（CONNECT） | 未做 | 走代理只支持明文 HTTP，TLS+代理直接回 `PROXY_TLS_UNSUPPORTED`（p5f） |
