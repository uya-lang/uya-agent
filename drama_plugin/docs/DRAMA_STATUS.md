# DRAMA 实现状态（v1.0 / 1.13 落地版）

这份文件只回答三个问题：**哪些阶段已经有代码**、**代码在哪**、**怎么复核**。
设计与取舍看 `DRAMA_DESIGN.md`，任务清单看 `DRAMA_TODO.md`。

> 自测：22 个 `p*_selftest.sh` 全绿（2026-02 本轮实测，p11 已修）。

## 1. 复核入口（22 个自测脚本 + 打包脚本，全部可重跑）

最近一次全套（`EPISODES=10`）：22 个自测脚本全绿。

| 脚本 | 覆盖 | 断言数 |
|---|---|---|
| `p1_selftest.sh` | CLI 三模式 + stdio MCP 协议 + 宿主连接 | 9 |
| `p2_selftest.sh` | Registry / Schema / Dispatch / 幂等 | 36 |
| `p3_selftest.sh` | Project + 基础存储（原子写、重启、路径穿越、configure） | 25 |
| `p3b_selftest.sh` | Bible 版本 + 冻结文本 hash + Asset | 22 |
| `p4_selftest.sh` | Canon 提交 / 四轴不变量 / 锁 / 崩溃恢复 | 18 |
| `p5_selftest.sh` | LLM 传输层 / 调用摘要 / 格式修复（本机上游） | 16 |
| `p5b_selftest.sh` | 剧本生成 / 审核 / 批准入 Canon | 12 |
| `p5c_selftest.sh` | 上下文组装（来源 ID / 预算裁剪） | 12 |
| `p5d_selftest.sh` | 持久任务 / 断点续跑 | 10 |
| `p6_selftest.sh` | 连续三集 + 重放复现（M1 最小版） | 9 |
| `p7_selftest.sh` | 分镜生成 / 版本 / 时长口径 | 19 |
| `p8_selftest.sh` | Provider 能力表 / 视频任务 / Worker / 单 Worker 锁 / 每集 manifest | 17 |
| `p9_selftest.sh` | 确定性 QA / 生产状态 / 重试 / 取消 / 熔断 | 14 |
| `p12_selftest.sh` | 闭环审计 + 九条不变量 + 重复全历史篡改检测 | 16 |
| `p12b_selftest.sh` | 反例库 + 规则/回收率/错误定位 | 14 |
| `p10_selftest.sh` | 成片合成 / media.probe / 资产登记 / 失败恢复 | 22 |
| `p11_selftest.sh` | 端到端一条龙（三集 → 成片 → 审计 → 成本账本 → 资产共享） | 23 |
| `p13_selftest.sh` | 10 集规模测算（控制面耗时/审计/状态体积） | 11 |
| `p13b_selftest.sh` | 派生索引与全量重建 | 12 |
| `p13c_selftest.sh` | 百集 mock 视频压力 / 资产账本 / 操作审计 / 索引计时 | 23 |
| `p15_selftest.sh` | 30 集跨题材（3 个 Bible 模板 × 每题材 EPISODES/3 集，换模板不改代码） | 12 |
| `p16_selftest.sh` | PipelineProvider：白名单入口 / 退出码 / 日志尾部 / 产物清单 / 超时 | 12 |
| `p17_selftest.sh` | 真产线产能：提交/完成/镜数/每镜均值/重做率/百集外推 | 8 |
| `p18_selftest.sh` | 人物外观/服装：PSNR 锚帧门 / VLM OK+DRIFT / 阈值可调 | 12 |
| `real_gpu_check.sh`（不是自测，需真 GPU） | 真产线入口：lint / dry / [REAL_SHOT] / capacity | 4–5 |
| `real_stress.sh`（不是自测，需真产线） | N 集过真产线：lint → [生成] → cards → build → probe | 按集数 |
| `build_selftest.sh` | 独立构建入口：任意 cwd / 输出路径 / 启动 | 4 |
| `pack.sh`（不是自测） | 打交付包：bin/docs/src/selftest + tar.gz + sha256 | — |
| `p5e_selftest.sh` | 百集大纲与批准（系列层） | 12 |

跑全部：

```sh
for f in drama_plugin/p*_selftest.sh; do sh "$f" || echo "FAILED $f"; done
```

外加仓库门槛：`make lint-size`（文件 ≤2000 行 / 函数 ≤100 行 / 行宽 ≤80 码点）。

## 2. 代码地图（`drama_plugin/src/`，28 个文件，约 9900 行）

| 模块 | 职责 | 行数 |
|---|---|---|
| `main.uya` | CLI：version / health / mcp serve / worker run | 139 |
| `server.uya` | MCP 三工具（list/describe/call）+ 协议错误 | 816 |
| `ops.uya` | 业务操作的分派与实现 | 1844 |
| `media_ops.uya` | 媒资四件套 / 单镜头重试 / 资产 / 生产报告 | 320 |
| `registry.uya` | 操作目录 + 字段规格（describe 与 call 同源） | 359 |
| `schema.uya` | Input Schema 校验（required/type/enum/额外字段） | 198 |
| `dispatch.uya` | 幂等槽 + request_id + task_id 生成 | 161 |
| `json_min.uya` | 最小 JSON 读（键/数组项定位） | 356 |
| `json_out.uya` | 定长缓冲上的 JSON 写 | 97 |
| `bytes.uya` | 字节串比较/写 fd/fnv64 | 146 |
| `store.uya` | 路径拼接、逐级 mkdir、原子写、读回、format_version 守卫 | 228 |
| `project.uya` | 项目 ID 规则与 create/get/list | 216 |
| `bible.uya` | Bible 版本化 + 冻结文本 SHA-256 | 316 |
| `asset.uya` | 资产登记（size/mime/sha256）与列表 | 203 |
| `canon.uya` | 权威状态 + 事件 + 不变量 + 提交记录 + 锁 + 恢复 | 1125 |
| `digest.uya` | SHA-256 → 十六进制（单点实现） | 41 |
| `context.uya` | 生成前上下文（来源 ID / 预算裁剪 / 摘要） | 279 |
| `llm.uya` | Provider 适配（mock / openai 兼容）与结构化校验 | 306 |
| `httpc.uya` | HTTP/HTTPS POST（超时、状态码、错误分类） | 307 |
| `story.uya` | 剧本模型、确定性时长、版本存储、批准幂等 | 369 |
| `task.uya` | 持久任务（script / video 步骤）+ Worker 扫描 | 567 |
| `board.uya` | 剧本 → 确定性分镜 + 版本存储 | 499 |
| `provider.uya` | 版本化能力表 + mock VideoProvider | 136 |
| `qa.uya` | 剧本/分镜确定性体检 + 不可变报告 | 362 |
| `audit.uya` | 闭环审计：账本 / 不变量 / 全历史重放 / 回收率 | 614 |
| `assemble.uya` | 成片合成（mock 拼接）+ manifest | 246 |
| `index.uya` | 派生索引（episodes）+ 全量重建 | 255 |
| `series.uya` | 百集大纲生成、批准与拦截 | 312 |

## 3. 阶段落地情况

| 阶段 | 状态 | 说明 |
|---|---|---|
| P0 | 完成 | 技术核验、HTTPS 证书校验修好、工具链同步到 `uya/`（v0.11.0） |
| P1 | 完成 | CLI 三模式 + 三工具 stdio server |
| P2 | 完成 | Registry / Schema / Dispatch / 幂等闭环 |
| P3 | 大部分 | Project / 存储 / Bible 版本 / Asset（含 `asset.get` 单条查询）/ configure / 操作审计日志（8 MiB × 5 轮转）；缺子模型字段约束、迁移器 |
| P4 | 大部分 | Canon 提交 + 四轴不变量 + 锁 + 崩溃恢复；缺事件显式 ID、候选状态差异比较 |
| P5 | 大部分 | 传输层 / Adapter / 调用摘要 / 格式修复 / 剧本 / 上下文 / 任务 / 百集大纲 / 配置文件 API Key；缺 SSE、代理 |
| P6 | M1 最小版 | 三集闭环 + 重放复现；真实模型与视频 Mock 未接 |
| P7 | 第一段 | 确定性分镜；缺参考图顺序、状态迁移、固定资产引用 |
| P8 | 第二段 | 能力表 + mock VideoProvider + Worker + 单 Worker 锁 + 在线状态；缺真实队列 Adapter、重试上限 |
| P9 | 第一段 | 确定性 QA + 成片完整性终检 + 生产状态 + 重试 + 取消；缺 ASR/锚帧/画质终检/跨集审计；已有 `shot.retry` 单镜重做 |
| P10 | 第一段 | mock 拼接 + manifest + 成片登记 Asset；能力表探测 FFmpeg/ffprobe + `media.probe` 宽高/时长/版本/参数/期望值校验，失败可恢复；缺转码/响度/字幕 |
| P11 | 第二段 | 端到端一条龙 + 成片资产共享路径 + 交付包/Worker/权限/限制/Provider/平台说明；缺升级迁移与服务管理流程 |
| P12 | 大部分 | 四账 / 全量审计 / 九不变量 / 定位 / 反例库；缺增量 |
| P13 | 第三段 | 10 集测算 + 百集控制面压力 + 百集 mock 视频压力 + 成本/资产/派生索引账本 + 日终报告 `production.report` + 每集 `manifest.json`（含 format 规格）；缺真实视频管线与真实产能报告 |

## 4. 已知限制（别当成承诺）

- **没有 fsync**：原子 rename 保证"不留半个文件"，掉电仍可能丢最后一次提交。
- **mock 优先**：剧本、分镜、视频三条链路都能跑，但模型与渲染都是确定性的
  替身；真实 Provider 是替换点，不是已完成项。
- **单进程假设**：Canon 有 O_EXCL 锁 + pid 探活，但幂等槽、任务索引都在内存/追加
  日志里，多进程并发写同一项目未验证。
- **上下文是全量 + 预算裁剪**，没有向量检索；长期梗只做了 promise 账。
- **反例回归不全**：证书错误的负例、越权资产读取的符号链接逃逸都还没脚本化。
- **没有真实外部依赖的验证**：模型、视频队列、FFmpeg 全是 mock/替身，
  接真实产线前不能拿它跑真片。
- **规模只到 10 集**：百集压力、索引分片、单日配额都没跑过。

## 5. 合并回 main 后补的四个缺陷（2026-11-08 实测修复）

原先在 session 分支上，`sh` 调用下有两个自测红；修完 27 个脚本（含
`build_selftest.sh`）在 `sh` 下全绿，`p13c` 默认 `EPISODES=100` 也全绿。

| 现象 | 根因 | 修法 |
|---|---|---|
| 第 11 集之后 `episode.approve` 报 `IO_ERROR/unknown failure` | `fmt_version_ok_p` 把 `take` 和 512 字节缓冲区取成同一个数，`copy_to` 要留 1 字节结尾 ⇒ **凡 ≥512 字节的状态文件都判成"格式不认识"**（canon.json 每集长 ~37 字节，第 11 集正好越过 512） | 缓冲区改 520，`take` 仍 512 |
| 同一个错误只写 `unknown failure`，看不出是哪一步 | `canon_commit` 的 50/52/55/56 没进错误码表，全落兜底分支 | 新增 `do_commit_error`：`invalid project_id` / `canon state unreadable` / `commit record write failed` / `commit index unreadable` |
| 默认 100 集跑到第 33 集红 | 承诺槽沿用 `MAX_OBJ=32`，百集每集一条钩子必然撑爆，且爆掉时报成 `PROMISE_UNKNOWN`（像是"承诺不存在"） | 承诺单独 `PROMISE_MAX=160`；槽满改报 `CAPACITY_EXCEEDED`（rc 57） |
| 100 集过了数量关，仍因 `COMEDY_REPEAT` 判红 | mock 剧本写死同一个笑点 setup，20 集窗口里同一个 setup 出现 100 次 | mock 按 prompt 的 FNV-1a 在 12 条 setup 里挑，仍然是"同输入同输出" |
| `p6_selftest.sh` 在 `sh`（dash）下 Syntax error | 脚本是 `#!/bin/sh`，却用了只有 bash 认的 `<( )` 进程替换 | 改成临时文件 + `diff` |
| `p13c` 偶发 `JSONDecodeError`（空回） | `serve` 被打断 / 管道半截，`real_stress.sh` 早就加了重试，`p13c` 没加 | `ask_once` + 一次重试，口径与 `real_stress.sh` 一致 |
