# Drama 骨架（P1）

这是 `DRAMA_TODO-001 v1.3` 的 P1 骨架：**能构建、能起进程、能被宿主连上**。
业务逻辑（Canon、任务、Provider）都还没有——那是 P2 之后的事。

## 文件

| 文件 | 职责 |
|---|---|
| `main.uya` | CLI：`version` / `health` / `mcp serve` / `worker run` |
| `server.uya` | stdio 主循环与三个工具（list / describe / call） |
| `registry.uya` | 操作目录（P1 是三条 mock；P2 换成动态 Registry） |
| `json_min.uya` | 一行 JSON 的最小读取（找键、取字符串、取 id、比方法名） |
| `json_out.uya` | 定长缓冲上的 JSON 写手（含转义） |
| `bytes.uya` | 字节工具：长度/比较/写满/十进制/FNV-1a |

## 构建与验收

```bash
UYA_ROOT=<repo>/uya/stdlib <repo>/uya/bin/uya build \
    drama_plugin/src/main.uya drama_plugin/src/bytes.uya \
    drama_plugin/src/json_min.uya drama_plugin/src/json_out.uya \
    drama_plugin/src/registry.uya drama_plugin/src/server.uya \
    -o /tmp/drama

sh drama_plugin/p1_selftest.sh     # 构建 + CLI + 协议 + 宿主连接
```

`p1_selftest.sh` 的判据（全部可判定）：

1. 六个源文件能编成一个可执行；
2. `version` 打印 `drama 0.1.0`；
3. `health` 是**单行** JSON，且 `data_dir` 跟着 `--data-dir` 走；
4. `worker run` 骨架能起、能读到 data_dir；
5. 未知命令退出码 2，诊断只在 stderr；
6. stdio 协议：8 条响应（通知不回、超 1 MiB 整行丢弃）、3 个工具、
   `isError` 语义、`-32601`、非 ASCII 透传、stderr 干净；
7. 宿主 `uya-agent --list-plugins` 认出 3 个工具。

## 已知边界（P1 故意不做）

- **没有配置文件**：只有 `--data-dir`；`config.json` 与 `format_version` 走 P3。
- **没有持久化**：`health` 只回显路径，不落盘、不加锁。
- **三条操作是 mock**：`call` 不产生副作用，`input_hash` 用整行算（P2 换成
  `(operation, input)` 归一化后再算）。
- **没有 Worker 任务循环**：`worker run` 只打印骨架信息。
- **错误码不完整**：目前只有 `SCHEMA_INVALID` / `OPERATION_NOT_FOUND`，
  DESIGN §6.11 的九条不变量错误码在 P12 落地。

## 实现时踩到的两个 codegen 坑（写在这里省下一次踩）

1. **不要把全局数组切成 slice**：`&g_data_dir[0: N]` 会被推断成
   `uya_slice_int32_t`，生成 `struct ... has no member named 'ptr'`。
   逐字节拷或用指针+容量代替。
2. **`--strict-overflow` 连取十进制位都不放过**：`(x - (x/10)*10) + 48`
   必须改成饱和运算（`-|` `*|` `+|`），否则编译失败。
