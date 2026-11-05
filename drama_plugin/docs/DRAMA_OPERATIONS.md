# 部署、权限与运行限制

## 进程布局

Drama Server 和 Worker 是两个独立进程，必须在同一台机器上使用同一个
绝对数据根目录。MCP Host 通过 stdio 启动 Server；Worker 由用户或服务
管理器单独启动。Worker 每次只扫描一遍未完成任务后退出，不是常驻队列。

```sh
DATA=/var/lib/drama
/opt/drama/bin/drama mcp serve --data-dir "$DATA"
/opt/drama/bin/drama worker run --data-dir "$DATA"

# 或者把数据根写进 /etc/drama/config.json：{"data_dir":"/var/lib/drama"}
/opt/drama/bin/drama mcp serve --config /etc/drama/config.json
/opt/drama/bin/drama worker run --config /etc/drama/config.json
```

`--data-dir` 与 `--config` 同时给时以 `--data-dir` 为准。

Server 与 Worker 不要使用不同的数据目录。备份、权限和清理策略必须覆盖
整个数据根；详见发布包 README 的备份恢复章节。

## Host 权限与无人值守

MCP Host 的权限模式决定每次工具调用是否需要宿主批准：

| 宿主模式 | `call` 行为 |
|---|---|
| `read-only` | 每次调用需要用户批准 |
| `workspace-write` | 每次调用需要用户批准 |
| `danger-full-access` | 直接放行 |
| 无交互回答渠道 | 需要批准时 fail closed |

这项批准发生在 MCP Host，不是 Drama 内部 Registry 的替代品。Registry
仍会区分 `read`/`write` 与 `none`/`low`/`gpu` 成本，写操作还要经过
Drama 自身的状态、幂等、预算和审计逻辑。

一次生产流程会包含多次 `call`。交互部署应在发起高成本的 `episode.produce`
或 `task.run` 前向用户说明 GPU 时间并取得确认；不要假设宿主会把一组调用
自动合并。无人值守场景不要让 Agent、cron 或子代理循环调用 MCP，因为没有
批准渠道时会拒绝；应由 Worker 扫描已经落盘的任务。

## Worker、重试与预算

- 同一数据根只允许一个 Worker；`locks/worker.lock` 使用原子创建，记录
  PID。持有者仍存活时新 Worker 返回 `busy`；持有者已退出时可清理陈旧锁。
- Worker 只执行记录文件中不是 `done` 或 `cancelled` 的任务；成功和失败
  都更新任务记录，失败原因不会留在 `queued` 状态无限重试。
- 视频任务要求剧本已批准，动作必须通过当前 Provider 能力表；未批准、动作
  不支持和预算超限都会在产出前失败，不改变 Canon。
- `budget.limit` 设置项目级最大渲染次数和 GPU 分钟；Worker 在执行整集前
  估算镜头数与时长，超限记录 `budget_exceeded`。`budget.report` 汇总已
  记录的任务、渲染数和 GPU 毫秒。

## 数据安全与已知限制

- 写入使用临时文件、权限 `0600` 和同文件系统 `rename`，不会留下半个目标
  文件；标准库没有 `fsync`，掉电仍可能丢失最后一次提交。
- `canon.audit` 每次从 Canon 与 commits 全量重放并返回账本和违规项。
- 每个带 `project_id` 的 `call` 会在 `projects/<id>/audit/operations.jsonl`
  追加一行（`ts` / `op` / `ok`）；写前判断大小，达到 8 MiB 就把当前文件
  rename 成 `.1`，旧的 `.1`–`.4` 逐级后移，只保留 5 份（DESIGN §8.6）。
  审计是可观测性数据：写失败只记 stderr，不影响业务结果；没有 `project_id`
  的操作（如 `project.create`）不记项目日志。
- 当前视频 Provider 是确定性的 mock，占位文件不是可播放成片；真实视频队列、
  FFmpeg、ASR、字幕、响度和外部 API 尚未接入。
- 项目格式迁移器尚未实现。升级或更换版本前必须停止写入、备份整个数据根，
  在新目录验证 `health` 和 `project.list`，不要直接用新版本打开旧项目。
- `llm.json` 支持可选 `api_key`（请求带 `Authorization: Bearer`），但仍
  没有代理字段；密钥落在 0600 配置文件里，数据根和备份要按敏感数据保护。
  连公网 Provider 时把 `tls` 置 1，避免密钥明文过网。

## 证据入口

```sh
sh drama_plugin/p4_selftest.sh
sh drama_plugin/p8_selftest.sh
sh drama_plugin/p9_selftest.sh
sh drama_plugin/p12_selftest.sh
sh drama_plugin/p13_selftest.sh
EPISODES=100 sh drama_plugin/p13_selftest.sh
EPISODES=100 sh drama_plugin/p13c_selftest.sh
```

这些脚本覆盖 Canon 恢复、Worker 锁与任务、预算熔断、全历史审计和篡改
检测；`p13_selftest.sh` 的 `EPISODES=100` 只验证控制面提交与重放，
`p13c_selftest.sh` 另外跑 100 集 mock 视频任务（先全部排队、再一次
Worker 扫描消费，抽 10 条提交重放、抽一集按自己的镜头目录合成、删
Canon 恢复、幂等重跑）。两者都不证明真实 GPU 产能、真实外部 Provider
或跨平台运行已经完成。
