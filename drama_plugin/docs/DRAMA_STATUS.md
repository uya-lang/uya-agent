# DRAMA 实现状态（v1.0 / 1.13 落地版）

这份文件只回答三个问题：**哪些阶段已经有代码**、**代码在哪**、**怎么复核**。
设计与取舍看 `DRAMA_DESIGN.md`，任务清单看 `DRAMA_TODO.md`。

## 1. 复核入口（16 个脚本，全部可重跑）

| 脚本 | 覆盖 | 断言数 |
|---|---|---|
| `p1_selftest.sh` | CLI 三模式 + stdio MCP 协议 + 宿主连接 | 9 |
| `p2_selftest.sh` | Registry / Schema / Dispatch / 幂等 | 36 |
| `p3_selftest.sh` | Project + 基础存储（原子写、重启、路径穿越） | 24 |
| `p3b_selftest.sh` | Bible 版本 + 冻结文本 hash + Asset | 22 |
| `p4_selftest.sh` | Canon 提交 / 四轴不变量 / 锁 / 崩溃恢复 | 18 |
| `p5_selftest.sh` | LLM 传输层 + Adapter（本机上游） | 11 |
| `p5b_selftest.sh` | 剧本生成 / 审核 / 批准入 Canon | 12 |
| `p5c_selftest.sh` | 上下文组装（来源 ID / 预算裁剪） | 12 |
| `p5d_selftest.sh` | 持久任务 / 断点续跑 | 10 |
| `p6_selftest.sh` | 连续三集 + 重放复现（M1 最小版） | 9 |
| `p7_selftest.sh` | 分镜生成 / 版本 / 时长口径 | 19 |
| `p8_selftest.sh` | Provider 能力表 / 视频任务 / Worker | 14 |
| `p9_selftest.sh` | 确定性 QA / 生产状态 / 重试 | 9 |
| `p12_selftest.sh` | 闭环审计（四本账 / 不变量 / 重放） | 13 |
| `p12b_selftest.sh` | 反例库六条（DESIGN §13.5） | 9 |
| `p10_selftest.sh` | 成片合成（mock 拼接 + manifest） | 11 |

跑全部：

```sh
for f in drama_plugin/p*_selftest.sh; do sh "$f" || echo "FAILED $f"; done
```

外加仓库门槛：`make lint-size`（文件 ≤2000 行 / 函数 ≤100 行 / 行宽 ≤80 码点）。

## 2. 代码地图（`drama_plugin/src/`，25 个文件，约 8900 行）

| 模块 | 职责 | 行数 |
|---|---|---|
| `main.uya` | CLI：version / health / mcp serve / worker run | 139 |
| `server.uya` | MCP 三工具（list/describe/call）+ 协议错误 | 816 |
| `ops.uya` | 24 个业务操作的分派与实现 | 858 |
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
| `audit.uya` | 闭环审计：账本 / 不变量 / 重放完整性 | 375 |
| `assemble.uya` | 成片合成（mock 拼接）+ manifest | 246 |

## 3. 阶段落地情况

| 阶段 | 状态 | 说明 |
|---|---|---|
| P0 | 完成 | 技术核验、HTTPS 证书校验修好、工具链同步到 `uya/` |
| P1 | 完成 | CLI + 三工具 stdio server |
| P2 | 完成 | Registry / Schema / Dispatch 闭环 |
| P3 | 大部分 | Project / 存储 / Bible 版本 / Asset；缺子模型字段约束、迁移器、审计轮转 |
| P4 | 第一段 | Canon 提交 + 四轴不变量 + 锁 + 恢复；缺事件显式 ID、候选状态差异比较 |
| P5 | 大部分 | 传输层 / Adapter / 剧本 / 上下文 / 任务；缺 SSE、代理、Prompt 版本、日志脱敏 |
| P6 | M1 最小版 | 三集闭环 + 重放复现；真实模型与视频 Mock 未接 |
| P7 | 第一段 | 确定性分镜；缺参考图顺序、状态迁移、固定资产引用 |
| P8 | 第一段 | 能力表 + mock VideoProvider + Worker；缺真实本机队列 Adapter、单 Worker 锁 |
| P9 | 第一段 | 确定性 QA + 生产状态 + 重试；缺 ASR/锚帧/成片终检/跨集审计 |
| P10 | 第一段 | mock 拼接 + manifest；缺 FFmpeg 探测/转码/响度/字幕 |
| P11 | 未开始 | 端到端发布 |
| P12 | 大部分 | 四本账 + 重放 + 六条反例全绿；缺九条完整谓词、增量检查、错误定位 |
| P13 | 未开始 | 规模与产能 |

## 4. 已知限制（别当成承诺）

- **没有 fsync**：原子 rename 保证"不留半个文件"，掉电仍可能丢最后一次提交。
- **mock 优先**：剧本、分镜、视频三条链路都能跑，但模型与渲染都是确定性的
  替身；真实 Provider 是替换点，不是已完成项。
- **单进程假设**：Canon 有 O_EXCL 锁 + pid 探活，但幂等槽、任务索引都在内存/追加
  日志里，多进程并发写同一项目未验证。
- **上下文是全量 + 预算裁剪**，没有向量检索；长期梗只做了 promise 账。
- **反例回归不全**：证书错误的负例、越权资产读取的符号链接逃逸都还没脚本化。
