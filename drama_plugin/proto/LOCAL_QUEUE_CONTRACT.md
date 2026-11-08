# 本地生成队列契约（实测）

- 采集时间：本机队列在跑真实任务时现场采集（不是查文档抄的）
- 版本：`comfyui_version 0.33.0`，`/system_stats` 可查
- 用途：DESIGN §10.3 `LocalQueueProvider` 的接口依据；P8 的 Provider 契约

---

## 1. 端点（都在 `http://127.0.0.1:8188`）

| 方法 | 路径 | 作用 | 实测 |
|---|---|---|---|
| GET | `/system_stats` | 版本、内存、设备 | 200，JSON |
| GET | `/prompt` | **队列深度**：`{"exec_info":{"queue_remaining":N}}` | 200 |
| POST | `/prompt` | 提交：`{prompt, client_id}` → `{prompt_id, number, node_errors}` | 未提交（避免占用 GPU） |
| GET | `/queue` | `{queue_running:[…], queue_pending:[…]}` | 200 |
| DELETE | `/queue` | 取消排队项：`{delete:[prompt_id…]}` | 未实测 |
| POST | `/interrupt` | 停掉**正在执行**的任务 | 未实测 |
| GET | `/history?max_items=N` | 最近若干条完成的作业 | 200 |
| GET | `/history/<prompt_id>` | 单条；**不存在的 id 返回 `{}`（不是 404）** | 200 |
| GET | `/view?filename=&subfolder=&type=output` | 取产物（mp4/图） | 200，`video/mp4`，669534 字节 |
| GET | `/object_info` | 节点与参数枚举（做工作流校验用） | 200 |

## 2. 真实形状（现场样本）

`/queue` 的每一项是**五元组**：

```json
[17, "931ce1b0-…-e881bbf1e5c4", {工作流}, {"client_id": "h3-cat-drama",
  "create_time": 1793696859827}, [输出节点…]]
```

- `[0]` 序号 `number`；`[1]` `prompt_id`；`[2]` 工作流 dict；
- `[3]` `extra_data`（**`client_id` 由调用方给**，`create_time` 是毫秒）；
- `[4]` `outputs_to_execute`。

`/history/<id>` 的条目：

```json
{"<prompt_id>": {
  "prompt": [number, prompt_id, 工作流, extra_data, outputs],
  "outputs": {"38": {"images": [{"filename": "shot04_00002_.mp4",
                                 "subfolder": "tlwc_e001",
                                 "type": "output"}],
                      "animated": [true]}},
  "status": {"status_str": "success", "completed": true,
             "messages": [["execution_start", {"prompt_id": "…",
                                               "timestamp": …}], …]},
  "meta": {…}
}}
```

## 3. 五个必须知道的坑

1. **视频藏在 `images[]` 里**：mp4 产物出现在 `outputs.<node>.images[]`，
   靠 `animated: [true]` 区分于静态图。只找 `videos` 键会一个都拿不到。
2. **`client_id` 是唯一的关联手段**：提交时给的 `client_id` 会留在
   `extra_data` 里；历史按 `prompt_id` 索引，所以"提交后崩溃、不知道
   `prompt_id`"时只能扫最近历史按 `client_id` 找回来。**这就是幂等键的落点**
   （对应 DESIGN §4.5 的 `(operation, input_hash)` 落到 provider 侧）。
3. **未知 id 返回 `{}` 而不是 404**：轮询必须把"空 dict"当作"还没完成/不存在"，
   别当成功。
4. **单卡单槽**：`queue_running` 长度实测为 1，`queue_pending` 排队。
   并发上限固定 1（DESIGN §0.3 的产能基线就是这么来的）。
5. **取消分两种**：排队中的用 `DELETE /queue`，执行中的用 `POST /interrupt`；
   只停止轮询不叫取消（会白烧 GPU 分钟）。

## 4. 映射到 Provider 接口

| Provider 操作 | 落到队列 |
|---|---|
| `submit(shot)` | `POST /prompt`，`client_id = <project>/<episode>/<shot>/<input_hash 前 8>` |
| `poll(task_id)` | `GET /history/<prompt_id>`；`status.completed` 为真才算完成 |
| `fetch(task_id)` | `GET /view?filename=&subfolder=&type=output`（按 `outputs` 里的字段） |
| `cancel(task_id)` | 排队中 `DELETE /queue`；执行中 `POST /interrupt` |
| `depth()` | `GET /prompt` 的 `queue_remaining`（派发前先看，别灌爆队列） |
| 崩溃恢复 | 扫 `GET /history?max_items=N`，按 `client_id` 找回来，不盲目重发 |

## 5. 产能（与 DESIGN §0.3 对账）

- 真实构建日志：单镜 5.7–22.3 min，平均 12.5 min；单集 9 镜 14 次生成
  （重做率 1.56×），生成合计 175 min，整集墙钟 3.7 h。
- 队列单槽 ⇒ 百集约 292 GPU 小时、单卡 3–4 周，与 §0.3 一致。

## 6. 仍未实测

- `POST /prompt` 的真实返回与 `node_errors` 形状（要真提交，会占 GPU）；
- 队列满、队列被重启清空时的行为；
- `DELETE /queue` 与 `/interrupt` 的实际生效语义（是否真的停 GPU）。
