# Drama Plugin 技术设计文档

- 文档编号：DRAMA-DESIGN-001
- 版本：1.3
- 状态：修订设计稿；P0 十条中 6 条已核验（见 §18），4 条待实测
- 实现语言：Uya
- 对外协议：MCP stdio（宿主仅实现 stdio）
- 主要宿主：uya-agent
- 业务目标：自动生成连续短剧，**验收终局为 100 集**（M1–M4，见 §17）
- 连续性目标：故事/人物/环境/逻辑四轴**机器可判定**的闭环（见 §6.11、§7.5）

---

## 0. 1.3 版本修订摘要

本版本把验收目标从「连续三集」改写为「百集闭环」，依据是：用户明确要求
百集，且要求故事、人物、环境、逻辑全部完整连续闭环。以下为新增决策：

1. **多一层系列模型**：`Series → Season/Arc → EpisodeOutline → Episode
   → Shot`；100 集大纲先批准，再逐集细化（见 §6.9）。
2. **连续性变成四本账**：承诺/道具/知识/空间，都是提交产物，随 Canon
   revision 版本化（见 §6.10）。
3. **四轴不变量写成可判定谓词**，共 9 条，每条带错误码与定位（见 §6.11）。
4. **提交门**：`episode.approve` 内部强制跑不变量与账本更新，任一步失败
   整体不生效；只允许「承诺延期」一种显式豁免（见 §7.5）。
5. **任意点可复现**：从 Commit Record 重放到任意集任意镜的输入状态，
   抽样 10 集验证（见 §13.4）。
6. **容量与索引**：百集约 4500–6000 个文件，必须走派生索引，禁止扫全树
   （见 §8.7）。
7. **预算与熔断**：GPU 分钟/token/生成次数进账本，超限停止派发（见 §9.6）。
8. **闭环审计与反例库**：每 10 集审计一次；六类踩过的坑做成回归 fixture
   （见 §13.4、§13.5）。
9. **路线改为四个台阶**：M1 三集闭环、M2 十集无人值守、M3 三十集跨题材、
   M4 百集（见 §17）。

### 0.1 1.2 版本修订摘要（历史，保留）

本版本依据《DRAMA_REVIEW.md》修订，以下为新增/变更的明确决策：

1. **宿主互操作硬约束写死**：stdio 帧 = 一行一条紧凑 JSON（单条 ≤1 MiB）、
   宿主仅实现 stdio、`toolCallTimeoutMs` 默认 60000 ms、业务失败与基础设施
   失败的 `isError` 语义分开、MCP 工具名不带点（见 §4）。
2. **首版视频 Provider = 本机本地队列**（ComfyUI，`prompt_id` 即幂等键、
   GPU 单卡串行），云 API 留作后续 `HttpProvider`（见 §10.3、§18）。
3. **复用既有产线（B 档）**：Uya 负责 Canon / Task / MCP / Registry / 审批；
   已跑通的 Python 产线（shots / qc / build_film）降级为 Provider 子进程
   适配，不做一次性重写（见 §1.2、§15）。
4. **数据模型吸收真实资产包字段**：连续性锁（冻结描述文本）、一致性锚点、
   状态变体、正/反向提示词、潜空间缓存、适用镜头清单（见 §6.2、§6.3）。
5. **分镜补接戏机制**：`anchor_prev`（上一镜末帧当本镜第 0 帧）、硬切 +
   开场接戏句、参考图顺序、台词逐字、到 0.01 s 的成片时间轴、片尾卡
   （见 §6.7、§7）。
6. **成片规格与时长核算是显式契约**：画布/成片/帧率/正片+片尾卡/编码/响度，
   Σ镜头时长 = 正片时长（误差 ≤0.05 s）（见 §5.3、§16.3）。
7. **存储与事务降级到可验证的边界**：stdlib 无 `fsync`，提交只保证
   「rename 原子性 + 崩溃后重建」，掉电可能丢最后一次提交；锁要能识别陈旧锁；
   幂等记录、锁文件、`format_version` 进布局；说明为什么不用数据库（见 §8）。
8. **QA 口径对齐真实产线**：台词由视频模型直出、不做配音替换；ASR 对齐、
   锚帧接戏差、成片终检为确定性检查（见 §13.2）。

### 0.2 1.1 版本修订摘要（历史，保留）

1.1 版本根据架构评审修订，以下内容为本版本的明确决策：

1. Drama Plugin 是独立项目、独立构建、独立发布的 Uya 程序，不放进 `uya-agent/src/`。
2. MCP Server 与 Worker 分离：MCP 进程负责控制面；独立 Worker 负责持久任务执行。二者共享项目数据目录。
3. MCP 只注册三个工具：`list`、`describe`、`call`（公开名
   `mcp__drama__list` 等）。业务操作通过内部 Operation Registry 注册，
   不逐个注册为 MCP Tool。
4. Drama Plugin 自己拥有 LLM Adapter，不依赖宿主 Agent 提供创作能力。宿主 Agent 负责用户交互、需求澄清和发起业务操作。
5. 视频、音频和图片文件不通过 MCP 传输。首版采用同机共享文件系统资产目录；远程资产传输作为后续扩展。
6. 正式剧情状态在“剧本审核通过”时提交；视频成片验收只确认视听呈现合格，不再次改变剧情事实状态。
7. 状态提交采用单项目写入锁、不可变提交记录和可重建快照。快照与 `current` 指针是派生数据，不是唯一事实来源。
8. 首版不依赖 MCP 新版任务扩展、进度通知或 Resource 能力；异步任务、恢复和查询由 Drama Plugin 自己实现。
9. 第一里程碑是跨进程重启的连续三集剧本生成，不以视频生成作为连续性引擎的前置条件。

本文件中的 Uya 结构体、函数和 CLI 命令均为接口/伪代码示意。具体语法、文件 API、原子重命名、锁和进程能力必须通过 P0 验证，不得把示意语
法直接当作已经可编译的代码。

### 0.3 百集基线（实测，不是估算）

来源：既有产线的真实构建日志（第 001 集，逐镜时间戳可查）。
这份基线决定"百集能不能做、要多久"，所以放在设计文档开头。

| 项 | 实测值 |
|---|---|
| 单集镜头数 | 9 镜（正片 55.8 s + 片尾卡 4.2 s ≈ 60 s） |
| 单镜生成耗时 | 5.7–22.3 min，平均 **12.5 min** |
| 单集生成次数 | 14 次 / 9 镜 ⇒ 重做率 **1.56×** |
| 单集墙钟 | 生成合计 175 min，含周边 **3.7 h** |
| 百集镜头数 | ≈ 900 镜 |
| 百集 GPU 时间 | ≈ 187 GPU h（无重做）→ **≈ 292 GPU h**（含重做） |
| 百集交付周期 | 单卡串行、含人工与等待 **3–4 周** |

三条推论（写进设计，不再讨论）：

1. **瓶颈是 GPU 有效工时**，不是架构：要提速只能降规格（分辨率/帧数/
   单镜时长）或加机器，不能靠"并发调度"绕过单卡串行。
2. **重做率是核心成本指标**：1.56× 已经把 GPU 时间抬高 56%，所以
   提示词/能力表前置校验（§6.8）不是锦上添花。
3. **人工注意力是第二种稀缺资源**：百集约 300 次审批点，必须抽样 +
   异常优先（§13.4、TODO P13）。

这三条是后续所有容量与预算设计的前提。

---

# 1. 项目定位与目标

## 1.1 项目定位

Drama Plugin 是一个可独立运行、可由任意兼容 MCP 的 Agent 调用的 AI 连续短剧生产引擎。

用户提出创作目标后，Drama Plugin 可以在自身内部完成：

- 项目世界观、人物、场景和道具管理；
- 连续剧情规划、剧本和对白创作；
- 剧情事实和人物知识状态检查；
- 分镜生成和参考素材管理；
- 调用视频、图片、语音模型；
- 视频镜头质量检查、失败重试和剪辑；
- 剧集状态提交、历史追溯和后续剧集续写。

## 1.2 设计目标

- **独立性：** 不依赖 `uya-agent` 内部 API；宿主只通过 MCP 通信。
- **小接口面：** MCP 永远只暴露三个稳定入口，业务操作由注册表动态发现。
- **Uya 优先：** 核心业务逻辑、状态机、存储和 Provider 适配层优先使用 Uya。
- **事实可验证：** LLM 负责创作和语义判断，Uya 负责事实状态、事件校验、事务和任务生命周期。
- **可恢复：** 进程退出、机器重启或任务失败后，可以从持久化状态恢复。
- **可替换：** LLM、视频、图片、音频和媒体处理服务通过 Provider Adapter 隔离。
- **可审计：** 每次正式状态变化、外部任务和成片均可追溯到输入、版本和事件。

### 1.2.1 Uya 与既有产线的边界（B 档，1.2 定档）

领域里已经有一条跑通的产线（Python）：分镜定义 `shots.py`（唯一来源）、
静态体检 `lint_shots.py`、出图 `run_shots.py`、质检 `qc.py`、成片
`build_film.py`。首版**不重写**它，边界如下：

| 层 | 归属 | 理由 |
|---|---|---|
| Canon / 事件 / 提交记录 / 快照 | **Uya** | 这是本项目的核心价值，既有产线没有 |
| Task / Worker / 检查点 / 恢复 | **Uya** | 同上 |
| MCP 门面 / Operation Registry / 审批 / 预算 | **Uya** | 宿主边界，必须在 Uya 侧收口 |
| 分镜生成、镜头出图、QC、剪辑合成 | **既有产线（子进程）** | 已验证可用，重写收益低、风险高 |

因此 `VideoProvider` / `MediaProvider` / `QaProvider` 的首版实现是
**子进程适配器**（把结构化 shot 描述交给产线脚本，收回产物与报告），
而不是在 Uya 里重写生成与剪辑。Uya 侧的重写只发生在「产线无法给出可验证
结果」的地方。全量 Uya 重写（A 档）不在 1.2 的范围里。


## 1.3 非目标（首版不做）

- 多租户 SaaS、计费和用户管理平台；
- 分布式任务队列和多节点调度；
- 自研基础模型或模型训练；
- 完整视频非线性编辑器；
- 复杂 Web 管理后台；
- 将所有内部函数暴露成 MCP Tool；
- 让 Agent Memory 充当剧情事实数据库；
- 通过 MCP 传输完整视频、音频或高分辨率图片二进制。

## 1.4 通用性定义（1.3 新增）

"通用短剧"在本项目里指**同一套程序能承载不同题材、不同系列**，不是
"一套参数打天下"。落地为四样可替换物：

1. **题材模板**：`genre`（都市/家庭/悬疑/古装…）= Bible 模板 +
   资产包模板 + 该题材的常见节拍；
2. **能力表**：provider 能演什么、不能演什么，随模型/工作流版本变化；
3. **`format`**：画布、成片尺寸、帧率、时长、编码、响度（§5.3）；
4. **产线脚本参数化**：脚本不许硬编码项目路径/镜号/角色名，参数一律走
   JSON 入参（§10.3）。

判定标准（M3）：换一个题材模板，**不改代码**就能从大纲跑到成片。

---

# 2. 架构决策

## 2.1 总体架构

```text
                 MCP Host（例如 uya-agent）
           用户交互 / 意图理解 / 需求确认 / 结果呈现
                            |
                      MCP stdio
                            |
                  +-------------------+
                  | Drama MCP Server  |
                  |                   |
                  | list              |
                  | describe          |
                  | call              |
                  +---------+---------+
                            |
                    Operation Registry
                            |
                    Domain Dispatcher
                            |
       +--------------------+---------------------+
       |                    |                     |
  Project/Asset        Story/Continuity      Episode/Production
       |                    |                     |
       +--------------------+---------------------+
                            |
                     Persistent Store
                Project / Event / Task / Asset
                            ^
                            |
                  +---------+---------+
                  | Drama Worker      |
                  |                   |
                  | Durable Job Loop  |
                  | Workflow Steps    |
                  | Retry / Recovery  |
                  +---------+---------+
                            |
             +--------------+----------------+
             |              |                |
         LLM Provider  Video/Image/Audio  Media Provider
                                      (FFmpeg Adapter)
```

MCP Server 和 Worker 是同一个 Drama 可执行文件的两种运行模式，但属于两个独立进程：

- MCP Server 通过 stdin/stdout 提供 MCP 服务，不负责长期后台任务循环。
- Worker 读取持久化任务队列，执行耗时任务和恢复任务。
- 两个进程共享同一个 Drama 数据根目录，并通过项目锁/任务锁协调写入。

首版部署要求 MCP Server 和 Worker 位于同一台机器，并能访问同一个数据目录。以后可以扩展远程资产存储和独立 Worker 主机，但不作
为首版前提。

## 2.2 独立仓库和宿主关系

建议使用独立仓库，例如：

```text
uya-lang/
  uya/             # Uya 语言
  uya-agent/       # 通用编程 Agent
  drama/           # 独立短剧生产引擎
```

Drama Plugin：

- 自己构建、测试和发布；
- 不链接 `uya-agent` 内部模块；
- 不要求 `uya-agent` 修改 Agent Loop；
- 通过标准 MCP 工具发现和调用；
- 可以被其他 MCP Host 使用。

`uya-agent` 只是首个宿主，不是 Drama Plugin 的运行时依赖。

## 2.3 进程与生命周期

首版提供两个运行入口：

```bash
# MCP 控制面，由 MCP Host 启动并通过 stdio 通信
drama mcp serve --config /etc/drama/config.json

# 独立任务 Worker，由用户或服务管理器启动
drama worker run --config /etc/drama/config.json
```

实际命令名称以 P0 确认的 CLI 约定为准；上面的空格/命令仅用于说明运行模式，正式实现时统一为 `drama`。

运行原则：

- MCP Server 退出不代表持久化任务消失。
- Worker 退出时，当前步骤必须处于可恢复检查点，或被标记为需要恢复。
- 本地队列任务提交后，队列继续执行；本地保存 `prompt_id`，Worker 重启后先查
  队列/历史再决定是否续上（见 §9.4）。
- 本地 FFmpeg 等步骤中断后，从最近完成的步骤恢复，不假设已完成的副作用可以无条件重复。
- 若没有运行 Worker，`call` 可以创建任务，但必须返回明确的 `worker_unavailable` 状态/错误，不得假装任务正在执行。

首版 Worker 可以单实例运行。多 Worker 并发、租约续期和分布式锁不属于首版范围。

---

# 3. 职责边界

## 3.1 MCP Host / uya-agent

负责：

- 与用户对话，收集创作要求；
- 解释 Drama 能力目录和接口说明；
- 创建项目、发起生产、查询进度；
- 将结果和错误解释给用户；
- 在调用高成本视频生成之前向用户说明成本（钱或 GPU 时间）并取得确认。
- 注意宿主权限粒度：workspace-write 下每次 `call` 都要用户批准。

不负责：

- 保存权威剧情状态；
- 实现连续性规则；
- 管理 provider task id（`prompt_id`）和本地生产步骤；
- 判断视频是否可以提交为正式资产；
- 执行 Drama 内部状态迁移。

## 3.2 Drama Plugin

负责所有短剧领域逻辑，包括 LLM 调用、剧本生成、连续性校验、分镜、任务、资产、Provider、质量验收和项目存储。

它必须能在没有 Agent Host 的情况下通过自身 CLI 和配置完成核心任务。MCP 是对外控制接口，不是业务逻辑容器。

## 3.3 LLM 与 Uya 代码边界

LLM 负责：

- 创意、主题、冲突、包袱、反转；
- 人物描述、对白和表演建议；
- 剧本和分镜草案；
- 对语义质量和多模态画面的辅助判断。

Uya 代码负责：

- 数据模型和结构校验；
- 角色/道具/场景事实状态；
- 事件前置条件、状态迁移和版本冲突；
- 任务状态机、重试和恢复；
- 文件和资产元数据；
- 权限、预算、幂等和审计。

LLM 只能提交候选数据。LLM 不得直接写正式状态文件，也不得执行任意状态表达式。

---

# 4. MCP 协议设计

## 4.1 固定工具面

MCP Server 只注册以下三个 Tool：

| 工具名（raw） | 模型侧公开名 | 作用 |
|---|---|---|
| `list` | `mcp__drama__list` | 查询业务能力目录和操作名称 |
| `describe` | `mcp__drama__describe` | 查询一个业务操作的完整契约 |
| `call` | `mcp__drama__call` | 执行已注册的业务操作 |

**工具名不带点（1.2 决策）。** 宿主把 MCP raw 名归一化成
`mcp__<serverName>__<rawName>`，并把 `[^A-Za-z0-9_-]` 一律替换成 `_`。
若 raw 名写成 `drama.list`，模型侧会变成 `mcp__drama__drama_list`
（"drama" 出现三遍），且 `drama.list` 与 `drama_list` 会归一到同一个公开名。
因此：**MCP 工具名不带点，点号只留给业务操作名**（`project.create` 这类
不经过 MCP 层，见第 5 章）。

内部操作不逐个注册为 MCP Tool。

需要区分三个层次：

- MCP `tools/list`：列出三个固定 MCP Tool，是协议层发现。
- `list` 工具：列出 Drama 内部的业务操作，是领域层发现。
- 宿主自带的 `mcp` 元工具（`{action:"list"|"reload"}`）：列的是**每个
  MCP server 的工具与失败原因**，是宿主层诊断。三者语义不同，不要互相替代。

## 4.2 首版协议兼容范围（1.2 已核验）

宿主 `uya-agent` 的实现事实（已核对源码，标注处为证据）：

- 协议版本 `2024-11-05`；只实现 **stdio** 传输（`transport: http` 字段存在但
  未实现，只会被如实报成"不支持"）。
- 只依赖 `initialize`、`notifications/initialized`、`tools/list`、
  `tools/call`；宿主另外会发自定义钩子方法，**不认的方法须回 `-32601`**，
  宿主按"放行"处理（标准 server 的常态，不是错误）。
- **stdio 帧 = 一行一条 JSON**（`\n` 分隔，容忍 `\r`）。宿主按 `\n` 切行，
  一行必须是一条**完整、紧凑**的 JSON-RPC 消息；单条上限 **1 MiB**，超限
  **整行丢弃**（不是截断后解析）。⇒ **禁止 pretty-print、禁止消息内换行、
  禁止在协议流里混日志。**
- 工具结果投影：`content[]` 里 `type=="text"` 的 `text` 逐段拼接（`\n` 连接）；
  非 text 段落落成占位行；`isError:true` ⇒ 结果文本前缀 `Error: `。
- `structuredContent` **宿主已支持**（有则优先读）。首版可选使用，
  不作为必需依赖。
- **`toolCallTimeoutMs` 默认 60000 ms**（可配 1–3,600,000）。超时的表现是
  一句 `Error: …` 工具文本，server 进程**不被杀**。
- 名字归一化与 `serverName` 约束：`serverName` 须匹配
  `^[A-Za-z0-9_-]{1,32}$`；公开名规则见 §4.1。

首版不依赖：

- MCP Tasks 扩展；
- MCP 进度通知；
- MCP Resource；
- MCP Sampling；
- MCP Roots 或其他可选扩展。

异步任务、状态查询、恢复、资产引用由 Drama 自己实现。


## 4.3 `list` 工具

用途：返回业务操作目录，保持简短，不返回全部参数文档。

输入 Schema 示例：

```json
{
  "type": "object",
  "properties": {
    "category": { "type": "string" },
    "keyword": { "type": "string" }
  },
  "additionalProperties": false
}
```

返回示例：

```json
{
  "plugin": "drama",
  "plugin_version": "1.1.0",
  "protocol_version": "1",
  "operations": [
    {
      "name": "project.create",
      "category": "project",
      "description": "创建短剧项目",
      "operation_version": "1.0"
    },
    {
      "name": "episode.produce",
      "category": "episode",
      "description": "创建剧集生产任务",
      "operation_version": "1.0"
    },
    {
      "name": "production.status",
      "category": "production",
      "description": "查询生产任务状态",
      "operation_version": "1.0"
    }
  ]
}
```

完整列表见第 5 章。可选 `category` 和 `keyword` 过滤，但不得因此注册新的 MCP Tool。

## 4.4 `describe` 工具

用途：Agent 确定要调用某个操作后，再按需查询完整接口契约。

输入：

```json
{
  "operation": "episode.produce"
}
```

返回必须包括：

- 操作名称和操作版本；
- 功能说明；
- 完整 `input_schema`；
- 完整 `output_schema`；
- 只读/写入属性；
- 是否创建异步任务；
- 权限/策略类别；
- 成本类别和可能的外部副作用；
- 幂等规则；
- 错误码；
- 最小示例。

示例：

```json
{
  "name": "episode.produce",
  "operation_version": "1.0",
  "description": "根据项目 Bible 和已提交的前序剧情状态，创建剧集生产任务",
  "input_schema": {
    "type": "object",
    "properties": {
      "project_id": { "type": "string" },
      "episode_number": { "type": "integer", "minimum": 1 },
      "target": {
        "type": "string",
        "enum": ["script", "video"]
      },
      "duration_seconds": {
        "type": "integer",
        "minimum": 10,
        "maximum": 180,
        "default": 60
      },
      "creative_brief": { "type": "string" }
    },
    "required": ["project_id", "episode_number", "target"],
    "additionalProperties": false
  },
  "output_schema": {
    "type": "object",
    "properties": {
      "task_id": { "type": "string" },
      "status": { "type": "string" },
      "episode_id": { "type": "string" }
    },
    "required": ["task_id", "status", "episode_id"]
  },
  "mutates": true,
  "async": true,
  "permission": "production.create",
  "cost_class": "depends_on_target",
  "idempotency": "request_id_required"
}
```

## 4.5 `call` 工具

用途：执行唯一的业务分发入口。

固定输入 Schema：

```json
{
  "type": "object",
  "properties": {
    "operation": { "type": "string" },
    "operation_version": { "type": "string" },
    "request_id": { "type": "string" },
    "input": { "type": "object" }
  },
  "required": ["operation", "input"],
  "additionalProperties": false
}
```

**`request_id` 改为可选（1.2 决策）。** 1.1 把它列成必填，等于要求模型临时
编 ID，会带来三种错：碰撞、复用、重试时换了新 ID 于是重复执行。1.2 的规则：

- 缺省由 Plugin 生成（建议 `req-<毫秒时间戳>-<6 位随机>`）并在结果里回显；
- **幂等键 = `(operation, input_hash)`**，不是 `request_id`；
- `request_id` 只当 tracing 用（日志、审计、Task 字段），冲突不报错；
- 调用方显式给同一个 `request_id` 且 `input_hash` 相同 ⇒ 复用既有 Task；
  给了 `request_id` 但 `input_hash` 不同 ⇒ 报 `REQUEST_REUSED`
  （不静默执行，防止"以为幂等其实改了参数"）。

调用示例：

```json
{
  "operation": "episode.produce",
  "operation_version": "1.0",
  "request_id": "req-2026-000021",
  "input": {
    "project_id": "family_comedy",
    "episode_number": 2,
    "target": "script",
    "duration_seconds": 60,
    "creative_brief": "围绕爸爸藏遥控器设计反转笑点"
  }
}
```

**SLA（硬约束）：** 宿主默认 `toolCallTimeoutMs = 60000`，超时结果是
`Error: …` 工具文本。因此 `call` **必须在 60 s 内返回**：

- 只读操作直接返回；
- 生产类操作**先落盘再返回** `{status:"queued"}`，绝不在请求里等模型或视频；
- 预计会超过约 45 s 的任何步骤一律转成持久任务；
- 部署文档给出建议配置值（不低于 60000，且不大于操作自身的超时预算）。

分发规则：

1. 查找操作注册项；
2. 检查操作版本；
3. 计算 `input_hash`，查幂等记录；
4. 校验内部动态 Input Schema；
5. 检查项目权限、预算和操作策略；
6. 执行或创建持久化任务；
7. 返回统一结果。

动态 Schema 的强校验由 Plugin 执行。宿主只能对外层 `call` 静态 Schema
做预检查，不能假设宿主理解内部操作 Schema。
**代价要认**：内部参数错误只能靠返回文本纠正，所以错误信息必须机器可读
且可照做——给字段路径、期望类型、实际值，外加一个最小正确示例。

## 4.6 返回格式与兼容性

首版采用 MCP Tool 的文本内容返回 JSON 字符串。`structuredContent` 宿主已支持，
但首版不作为必需依赖（可选增强：有 outputSchema 的操作可同时给结构化结果）。

**帧格式（硬约束）：** 返回的 JSON 必须是**单行紧凑**文本——不允许
pretty-print、不允许换行、单条消息 ≤1 MiB（宿主按 `\n` 切行，超限整行丢弃）。
文档里的示例为了可读性缩进显示，**实现输出必须是紧凑单行**。

成功结果（示例缩进仅为可读）：

```json
{
  "success": true,
  "operation": "episode.produce",
  "request_id": "req-2026-000021",
  "data": {
    "task_id": "task_01J...",
    "episode_id": "ep002",
    "status": "queued"
  }
}
```

失败结果：

```json
{
  "success": false,
  "operation": "episode.produce",
  "request_id": "req-2026-000021",
  "error": {
    "code": "CONTINUITY_CONFLICT",
    "message": "前序剧集状态与本集前置条件不一致",
    "details": {},
    "retryable": false
  }
}
```

**`isError` 的语义（1.2 决策，必须严格区分）：**

- **业务/校验失败**（`CONTINUITY_CONFLICT`、`SCHEMA_INVALID`、
  `REQUEST_REUSED`…）⇒ `isError` = **false**，文本里给
  `{"success":false,…}`；模型应当读到并自己纠正。
- **协议/基础设施失败**（未知方法、内部异常、Worker 不可用导致的任务
  失败）⇒ `isError` = **true**，宿主会加前缀 `Error: `。

把业务校验失败标成 `isError:true` 会让宿主把它当工具硬失败处理，模型的纠正
路径就断了。

**体积约束：** 返回文本上限按 1 MiB 预算；剧本/分镜这类大对象一律返回
**摘要 + 资产引用**（`asset_id` / `relative_path` / `sha256`），不把全文塞进
工具结果。

不得将异常堆栈、密钥、系统提示词或本机未授权路径返回给 Agent。

## 4.7 Operation Registry

所有业务操作在启动时注册到内部 Registry。

注册信息至少包括：

```text
name
operation_version
description
input_schema
output_schema
handler
mutates
async
permission
cost_class
idempotency_policy
side_effects
error_codes
```

Registry 内部函数建议：

```text
operation.register
operation.find
operation.list
operation.describe
operation.validate
operation.dispatch
```

上述为逻辑职责名，不代表必须对 MCP 暴露。

禁止：

- 通过字符串动态调用任意函数；
- 通过 `call` 执行 Uya 代码或 shell 命令；
- 将未经注册的操作透传给 Provider；
- 用任意表达式字符串驱动状态变更。

## 4.8 缓存与版本

- Agent 可以缓存 `list` 和 `describe` 结果。
- 缓存键使用插件版本、操作名称和操作版本。
- 插件版本变化时重新获取目录；操作版本变化时重新获取说明。
- 可选参数新增通常可兼容；删除字段、修改必需字段或改变语义属于破坏性变更。
- 插件版本与操作版本分别管理。

---

# 5. 首版业务操作目录

首版保持小而完整，不暴露 Character、Scene、Prop 的全部 CRUD。

| 操作 | 作用 | 类型 |
|---|---|---|
| `project.create` | 创建项目及初始 Bible | 写入 |
| `project.get` | 读取项目设定和版本 | 只读 |
| `project.configure` | 修改人物、场景、道具、风格等设定 | 写入 |
| `episode.produce` | 创建剧本或完整视频生产任务 | 异步写入 |
| `episode.get` | 读取剧集、剧本和生产摘要 | 只读 |
| `episode.review` | 执行剧本/成片审核并返回问题清单 | 可产生审核记录 |
| `episode.approve` | 批准剧本或成片；剧本批准可提交剧情状态 | 写入 |
| `episode.retry` | 重试指定失败步骤或镜头 | 异步写入 |
| `production.status` | 查询任务状态和进度 | 只读/轻量更新 |
| `production.cancel` | 请求取消任务 | 写入 |
| `continuity.inspect` | 查询人物、场景、道具、事件和伏笔状态 | 只读 |
| `asset.get` | 获取资产元数据和受控访问引用 | 只读 |

内部可以有更多细粒度函数，但首版不应全部暴露给 Agent。

### 5.0 上表的实现对照（1.17）

首版实现把上表**拆细**了：粒度更小、每个操作只做一件事，方便校验与重放。
完整清单（54 个）在 `DRAMA_TODO.md` §16，唯一来源是 `src/registry.uya`。

| 设计里的操作 | 实现成 |
|---|---|
| `project.create` / `project.get` | 同名，另有 `project.list` 与
  `project.configure`（改名/改集数，config_version 递增） |
| `project.configure` | `bible.put` / `bible.get` / `bible.history`（Bible 版本化）
  加 `asset.register` / `asset.list` |
| `episode.produce` | 同名（`stage=script\|video`），落盘建任务后立刻回 `queued` |
| `episode.get` | 同名（汇总剧本/分镜/成片版本 + Canon + 任务数），
  细粒度读取另有 `task.get` / `task.list` / `storyboard.get` |
| `episode.review` | 同名（QA + 九条不变量的合并审核，落 reviews/v<N>.json） |
| `episode.approve` | 同名（剧本结构复核 → 候选事件提交 Canon） |
| `episode.retry` | 同名（把失败任务重置成 queued） |
| `production.status` | 同名 |
| `production.cancel` | 同名（未完成可取消，已完成的拒绝） |
| `continuity.inspect` | 同名（返回 `canon.audit` 的四本账/不变量/全历史重放；
  本机百集实测 34 ms） |
| `asset.get` | `asset.list`（元数据）；按名单查留到接真实产线 |

另外多出四个设计里没写、实现需要的操作：`canon.commit` / `canon.recover`
（提交与恢复）、`llm.ping` / `llm.complete`（传输层自检）、
`context.inspect`（上下文组装自检）、`provider.capabilities`（能力表）、
`storyboard.build` / `media.assemble`（分镜与合成）、`task.run`（worker 单步）。

粒度拆细的代价是操作数变多；收益是每个操作都能单独校验、单独重放，
`describe` 出来的契约也更精确（`DRAMA_STATUS.md` 有测试覆盖对照）。

### 5.1 `project.create`

输入包括项目名称、简介、风格、目标时长及初始 Bible。创建时允许先创建空项目，再通过 `project.configure` 补充人物、场景和道具。

### 5.2 `project.configure`

采用版本化配置补丁。修改已被剧集引用的人物外观、角色关系或世界规则时，必须创建新版本，不得悄悄覆盖旧设定。配置变化可标记哪些未完成剧集需要重新校验。

### 5.3 `episode.produce`

核心业务入口。`target` 至少支持：

- `script`：生成剧本和剧情事件候选，不调用视频服务；
- `video`：从已批准剧本开始完成分镜、素材准备、视频生成、QA 和合成。

`video` 模式必须要求存在已批准的剧本版本，除非未来明确增加自动审批策略。第一里程碑只实现 `script`。

**`format` 规格块（1.2 新增，可选；缺省取项目 Bible 的 `format`）：**

```json
{
  "canvas": { "width": 448, "height": 800, "rule": "w%32==0 && h%32==0" },
  "delivery": { "width": 440, "height": 800, "fps": 24,
                "orientation": "portrait" },
  "duration": { "main_seconds": 56, "end_card_seconds": 4,
                "total_seconds": 60, "tolerance_seconds": 0.05 },
  "encode": { "vcodec": "libx264", "crf": 20, "pix_fmt": "yuv420p",
              "acodec": "aac", "abitrate": "128k", "asr": 32000,
              "faststart": true },
  "loudness": { "target_i": -16, "target_tp": -1.5, "passes": 2 }
}
```

三处必须由后端强制，不能只当文档：

1. 画布尺寸校验（宽高 32 的倍数；帧数满足 `17k+5`）；
2. 时长核算：Σ镜头时长 = `main_seconds`，误差 ≤ `tolerance_seconds`，
   超出即拒绝生成（确定性检查，不靠模型判断）；
3. 编码与响度参数在成片登记时回读并写进生产 manifest。

### 5.4 `episode.approve`

必须明确批准对象：

- `approval_type: "screenplay"`：批准剧本和事件计划，提交剧情 Canon；
- `approval_type: "final_cut"`：批准视频成片，标记视觉生产完成，不改变剧情 Canon。

审批必须关联确切的剧本/成片版本和审核结果 ID，防止审批后内容被替换。

### 5.5 `episode.retry`

输入必须明确目标：`task_id`、`stage` 或 `shot_id`、失败原因（可选）、重试策略。只重做所选范围及其依赖步骤，不默认重新生成整集。

---

# 6. 业务领域模型

## 6.1 Project 与 Bible

Bible 是相对稳定的世界设定，至少包含：

- 项目风格和叙事规则；
- 人物 Profile 和人物关系；
- 场景定义、布局和参考资产；
- 道具定义和标准外观；
- 叙事边界、禁忌和创作要求；
- **成片规格 `format`**（画布/成片/帧率/正片+片尾卡/编码/响度，见 §5.3）；
- **系列级冻结口径**（哪些是跨集不允许变的：空间、光、人物身份）。

Bible 具有版本号。每集生成时固定引用一个 Bible 版本，不能在后续修改中隐式改变既有剧集的依据。

**字段来源是既有资产包，不是另起一套（1.2 决策）。** 落地时的字段表直接对齐
`系列规范.md` + `场景资产/SCxx.md` + `角色资产/Sxx.md`，这样既有产线产物能与
状态库双向对照（同一份冻结文本既在状态库里，也在产线脚本里，逐字一致）。

## 6.2 人物模型

人物静态档案与动态状态分离。

`CharacterProfile`（身份级冻结，跨集不变）：

- 身份：年龄、身份/职业、叙事功能；
- 外观冻结：脸、发型、服装（按集固定的那一套）、配饰；
- 声音/语言风格、表演口径（怎么演、禁止怎么演）；
- **参考图口径**：只取身份（脸/发型/服装），**不复制**参考图的背景与棚灯；
- 关系；
- **冻结描述文本**（逐字粘贴的提示词段落，见下）；
- **禁止项/反向提示词**（漂移排除项）。

`CharacterState`（按集/按镜附加，不进冻结文本）：所在场景/位置、服装、情绪、
动作状态、持有道具、污渍/凌乱度、身体状态、已知事实。

**冻结描述文本（连续性锁）是一等字段。** 规则：定稿后逐字粘贴，不换近义词、
不调词序；状态变化一律写在 `CharacterState` 里，不许混进冻结文本——混写会让
"状态一变就把身份带偏"。

人物知识状态必须记录事实 ID 和获得事实的事件来源。不要只保存一段自由文本“人物知道什么”。

还应区分：

- 角色知道的事实；
- 观众知道的事实；
- 其他角色知道的事实。

这样才能检查误会、隐瞒、信息差和反转是否成立。

## 6.3 场景模型

场景静态布局与当前状态分离。

静态信息（身份级冻结）：

- 场景 ID / 名称、叙事功能；
- **一致性锚点 3–5 条**：可画、可认、可核对的具体视觉特征（结构/固定道具/
  材质/光照基调/色彩倾向），忌用"温馨""陈旧"这类形容词；
- **冻结描述文本**（连续性锁，逐字粘贴）；
- 参考图组（全景/中景/特写分层，不要一张图承担所有一致性）；
- **反向提示词**（漂移排除项）；
- **适用镜头清单**（已实测可用的景别/机位）。

动态信息（状态变体，**不写进连续性锁**）：时段、天光/色温、门窗状态、
可移动物体、桌面道具状态、场景受损状态。

可选：**潜空间缓存**（首段生成的原始 latent / 场景特征缓存），只对走潜空间
接力的产线有意义；不进 Canon，只作产线资产登记。

位置使用稳定 ID 或结构化区域表达，不只依赖自然语言描述。

## 6.4 道具模型

每个道具使用全项目唯一 `prop_id`。

状态至少包括：当前位置、持有人、完好状态、可见性、参考资产版本。

道具转移必须产生事件，不能由 LLM 直接覆盖当前位置。

## 6.5 剧情事件

禁止将可执行条件写成任意表达式字符串。事件条件和效果必须是结构化数据。

示意：

```json
{
  "event_id": "evt_ep002_003",
  "episode_id": "ep002",
  "sequence": 3,
  "type": "prop_transfer",
  "actor_id": "father",
  "entity_id": "remote_001",
  "preconditions": [
    {
      "entity_id": "remote_001",
      "field": "holder_id",
      "operator": "equals",
      "value": "father"
    }
  ],
  "effects": [
    {
      "entity_id": "remote_001",
      "field": "location_id",
      "value": "refrigerator"
    },
    {
      "entity_id": "remote_001",
      "field": "holder_id",
      "value": null
    }
  ],
  "cause": "father_hides_remote",
  "source_scene_id": "kitchen"
}
```

首版允许的条件操作符应是有限枚举，例如 `equals`、`not_equals`、`exists`、`one_of`。不提供任意脚本或表达式求值。

事件记录来源：剧本版本、场景/镜头 ID（如有）、创建模型/Prompt 版本和审核记录。

## 6.6 伏笔与长期梗

伏笔/长期梗不是普通人物记忆，应有独立结构：

- 唯一 ID；
- 引入集和引入事件；
- 当前状态；
- 已出现集数；
- 计划回收范围；
- 实际回收事件；
- 是否允许延期或废弃。

生成新集时只检索相关伏笔，不把整个历史剧本全部塞入上下文。

## 6.7 Episode 与版本

每集至少区分：

- 剧本版本；
- 剧情事件候选版本；
- 已批准剧情事件版本；
- 分镜版本；
- 镜头素材版本；
- 最终成片版本；
- 审核记录。

已批准对象不可原地修改。重写必须生成新版本，并重新审核。

## 6.8 分镜与接戏模型（1.2 新增）

`Storyboard`：本集镜头序列 + 时间轴；`Shot` 至少包含：

| 字段 | 含义 | 为什么必须有 |
|---|---|---|
| `shot_id` / `sequence` | 镜号与顺序 | 重试与局部重做的定位键 |
| `beat` | 落在剧本第几拍 | 拍与镜的对应关系可核对 |
| `scene_id` | 场景（资产包引用） | 冻结文本按场景取 |
| `framing` / `camera` | 景别、机位 | 参考图与机位复用靠它 |
| `action` | 画面里发生什么（只写可被模型演出来的） | 与 provider 能力表对照 |
| `line_text` | 台词**逐字** | ASR 核对与字幕定时以它为基准 |
| `timeline_in` / `timeline_out` | 成片时间轴（0.01 s） | 时长核算是确定性检查 |
| `source_duration` / `final_duration` | 源/成片时长 | 剪辑会有微差，两栏都留 |
| `ref_image_order` | 参考图顺序（`<Picture n>`） | 顺序变化会换身份绑定 |
| `anchor_prev` | 是否用上一镜末帧当本镜第 0 帧 | 同机位连续切点靠它 |
| `cut_type` | `anchor` / `hard_cut` / `card` | 接戏类型枚举，见下 |
| `transition_line` | 硬切时的"开场接戏句" | 换机位时靠文字承接空间 |
| `state_in` / `state_out` | 镜头起始/预期结束状态 | 镜头间连续性检查的输入 |
| `render_tool` / `workflow_hash` | 产线与工作流版本 | 复现与回归定位 |

**接戏机制（必须建模，不能只写"镜头要衔接"）：**

1. 同机位连续切点 ⇒ `cut_type="anchor"` + `anchor_prev=true`
   （上一镜末帧作为本镜第 0 帧，帧索引 0 引导）；
2. 换机位或省略事故 ⇒ `cut_type="hard_cut"` + `transition_line`
   （提示词第一段写死接戏句，把空间关系用文字钉住）；
3. 片尾卡/字幕板 ⇒ `cut_type="card"`（不参与接戏校验）。

**provider 能力表（1.2 新增）。** 每条 `action` 必须落在 provider 声明的
能力范围内（例如"能演走路、站定、转身、说话；不能演整身失衡、流体事件"）。
超范围的写法要拆镜或改用剪辑省略——这是既有产线踩出来的结论，必须变成
校验规则，而不是留给模型自由发挥。

## 6.9 系列层模型（1.3 新增）

百集不是"一百次单集生成"，而是"一次系列规划 + 一百次收窄"。模型必须多一层：

**`Series`（系列）**

- 系列承诺：一百集要回答的那个问题，一句话；
- 题材模板 ID、`format`、系列级冻结口径（哪些跨集不许变）；
- 节奏：每集 ≈60 s、钩子密度、每 10 集一个中高潮。

**`Season` / `Arc`（季/弧）**

- 起止集、弧内冲突、兑现点；
- 角色成长弧：起点 → 终点，中间每一步必须事件驱动（不得凭空变强）。

**`EpisodeOutline`（分集大纲，先把 100 条写完）**

- `episode_no`；
- 本集抛出的钩子（下一集要兑现的问题）；
- 本集兑现上一集的哪个钩子（引用 `promise_id`）；
- 笑点配额、场次、涉及角色/场景/道具、承诺 ID 列表。

**铁律：**

1. 大纲整体批准后才允许逐集细化；大纲未批准，`episode.produce` 拒绝执行。
2. 任何 `Screenplay` 必须能追到 `EpisodeOutline`；大纲里没有的承诺不得在
   剧本里新增——新增即在审批时写回大纲并升版本。
3. 大纲变更走版本，受影响集标记 `needs_revalidation`（复用 §7.4 机制）。

## 6.10 四本账（1.3 新增）

四本账都是**提交产物**，随 Canon revision 版本化，落在
`canon/ledgers/`（§8.1），只追加、只升版本、不可改写。

**1. `promise.jsonl` —— 承诺账**

字段：`promise_id`、`kind`（`hook` / `foreshadow` / `gag` / `rule`）、
`opened_ep`、`due_ep`、`payoff_ep`、`status`
（`open` / `paid` / `overdue` / `waived`）、`waiver_reason`。

**2. `prop.jsonl` —— 道具有账**

字段：`prop_id`、`ep`、`scene_id`、`holder`、`from_event`、`note`。
不变式：**每个道具在每个已批准集结束时恰有一个位置**。

**3. `knowledge.jsonl` —— 知识账**

字段：`character_id`、`fact_id`、`learned_ep`、`from_event`、
`certainty`（`know` / `suspect` / `misbelieve`）。
不变式：没有 `from_event` 的授予即非法；授予必须发生在该角色在场的场景。

**4. `space.jsonl` —— 环境账**

字段：`scene_id`、`connect_to`（有向连通）、`furniture_hash`、
`time_of_day`、`variant`（状态变体，取自资产包允许集合）。

账本与 Canon 的关系：账本是 Canon 的**投影**，可从事件重放重建
（重建校验见 §13.4）；落盘只是为了检查变快，不能当成唯一事实来源。

## 6.11 四轴不变量（1.3 新增，提交门判据）

不变量必须写成**可判定谓词**，实现里就是一组检查函数；每条带错误码，
报错必须能指到具体对象（哪一集、哪一镜、哪件道具）。

| 轴 | 不变量（谓词） | 错误码 |
|---|---|---|
| 故事 | `status=open` 且 `due_ep ≤ 当前集` 的承诺必须被 paid 或 waived | `PROMISE_OVERDUE` |
| 故事 | 本集头 3 s 内回应上一集到期钩子 | `HOOK_UNANSWERED` |
| 人物 | 冻结文本 hash 与资产包一致 | `CHARACTER_DRIFT` |
| 人物 | 每条知识有 `from_event`，且角色在该事件在场 | `KNOWLEDGE_LEAK` |
| 环境 | 道具位置唯一，位置变化必须有事件 | `PROP_TELEPORT` |
| 环境 | 场景陈设 hash 与资产包一致，变体在允许集合内 | `SCENE_DRIFT` |
| 逻辑 | 每个状态 diff 有 `from_event`，且事件已 approved | `ORPHAN_CHANGE` |
| 逻辑 | 时间轴单调；同角色同一时刻不得在两个场景 | `TIMELINE_CONFLICT` |
| 逻辑 | 世界规则只可扩展、不可推翻 | `RULE_VIOLATION` |

---

# 7. 剧情 Canon 与视频生产的一致性

这是首版必须遵循的核心规则。

## 7.1 两种不同的完成状态

**剧情 Canon：** 剧本和剧情事件代表这个系列中正式发生的故事事实。

**Production Result：** 视频、声音和剪辑是对已批准剧本的视听实现。

二者不能混成一个状态。

## 7.2 提交时机

- 剧本生成完成：只产生候选剧本和候选事件，不修改 Canon。
- 剧本审核通过并执行 `episode.approve(screenplay)`：校验事件后提交 Canon，形成新 revision。
- 视频生成与 QA：只检查视频是否正确呈现已批准剧本，不改变 Canon。
- 成片审核通过并执行 `episode.approve(final_cut)`：将成片标记为正式交付资产，不再次推进剧情状态。

因此，连续三集剧本可以在视频尚未生成时依次提交并继续创作；后续视频失败不会污染剧情状态。

## 7.3 视频与剧本不一致时

如果生成视频与批准剧本不一致：

1. 优先重做不合格镜头；
2. 若是剪辑或音频问题，修复对应生产步骤；
3. 若视频模型无法呈现某动作，可调整镜头表达但不能无审核地改变剧情事件；
4. 如果必须修改剧情，则创建新剧本版本，重新审核，并处理已经依赖旧版本的后续剧集。

第 3 条要有可执行的判据，不能凭感觉：改动只允许落在 `Shot` 层
（景别/机位/`action`/`cut_type`/`transition_line`），且新 `action` 必须通过
provider 能力表校验（§6.8）；只要剧本版本不变，`line_text` 与剧情事件一律不许动。

## 7.4 修改已批准剧本

修改已经批准的第 N 集可能影响 N+1 之后的剧情。必须：

- 创建新版本；
- 标记依赖旧 revision 的后续剧集为 `needs_revalidation`；
- 重新执行事件冲突检查；
- 在新版本批准后产生新的 Canon revision；
- 不删除旧提交记录。

首版不做自动复杂分支合并；发现冲突时要求重新生成或人工决策。

## 7.5 连续性闭环（1.3 新增）

「保证故事、人物、环境、逻辑完整连续闭环」必须落成三条工程定义，
缺一条都不算闭环：

1. **任意点可复现**：任取第 N 集任一镜，能从 Commit Record 重放出它当时
   的世界状态（外观、场景、道具位置、谁知道什么）。抽样验证见 §13.4。
2. **零悬空引用**：每个 setup 有 payoff、每次道具移动有事件、每个状态变化
   有两端快照。
3. **全历史回归**：新集若推翻旧事实，提交直接失败——不是事后 QA 才发现。

**提交门（必须实现成钩子，不是事后质检）：**

`episode.approve` 内部顺序固定为：

```text
结构校验 → 事件前置检查 → 四轴不变量(§6.11) → 账本更新
        → 写 Commit Record → 更新快照 → 更新索引
```

任一步失败 ⇒ 整个提交不生效，回滚到提交前 revision，返回具体对象与错误码。

**豁免只允许一种**：承诺延期（`waived` + 原因 + 新 `due_ep`），且必须在
审批界面显式确认。其他不变量**不容豁免**——否则闭环就退化成"人工记忆"。

**机器判定边界**：连续性 100% 机器判定；"好不好笑 / 好不好看"走模型辅助
加人工抽样（§13.2），不进硬门。

---

# 8. 状态存储与事务

## 8.1 首版文件布局

```text
DRAMA_ROOT/
  config/
    drama.json

  projects/
    family_comedy/
      project.json
      bible/
        bible_v001.json
      episodes/
        ep001/
          screenplay_v001.json
          events_candidate_v001.json
          storyboard_v001.json
          reviews/
          manifest.json
        ep002/
          ...
      canon/
        commits/
          000001_commit_xxx.json
          000002_commit_yyy.json
        snapshots/
          revision_000001.json
          revision_000002.json
        current.json
      locks/
        canon.lock
        worker.lock
      idempotency/
        <input_hash>.json
      tasks/
        task_xxx.json
      assets/
        characters/
        scenes/
        props/
        v<board_version>/   # 镜头文件按分镜版本隔离：shot_<seq>.mp4
        audio/
        final/
      audit/
        operations.jsonl
        operations.jsonl.1
```

数据含义：

- `commits/`：权威的不可变剧情提交记录；
- `snapshots/`：根据提交记录生成的可重建快照；
- `current.json`：当前 revision 指针/缓存，可丢弃重建；
- `locks/`：单写者锁文件（含持有者 pid 与获取时间，见 §8.4）；
- `idempotency/`：幂等记录（键 = `operation` + `input_hash`，见 §4.5）；
- `tasks/`：持久任务状态；
- `assets/`：多媒体文件；
- `audit/`：操作审计日志（**按大小轮转**，见 §8.6）。

**每一类 JSON 文件都带 `format_version` 字段**（与 `plugin_version` 分开）：
读到不认识的版本时，启动恢复按 §8.3 进入只读故障状态并报出需要的迁移，
**不允许猜测着解析**。迁移只做加法（新增字段可忽略），破坏性变更必须写
迁移器并在 P3 加测试。

### 8.1.1 为什么不用数据库（1.2 补充）

Uya 标准库的 `std.sql` 只提供 `Driver`/`Conn`/`Tx` 接口，**没有随仓的 sqlite
驱动**；宿主侧也没有可链接的嵌入式数据库。要引入数据库，就得先写（并长期
维护）一个驱动 + native 依赖，这会把"独立构建、单文件静态发布"这条约束打穿。
所以首版用「不可变提交记录 + 可重建快照」，把事务语义压到"一次原子 rename"
上；等到有第二个写者或多节点需求时再谈数据库。

## 8.2 提交记录作为事务边界

不采用“先追加 JSONL、再写快照、再写 current”的多文件步骤作为唯一提交机制，因为中途崩溃会产生不一致。

首选方案：每次 Canon 提交生成一个完整、不可变的 Commit Record。单条提交记录包含：

- commit_id；
- project_id；
- base_revision；
- new_revision；
- episode_id 和批准的 screenplay version；
- 经过验证的事件集合；
- 事件后的状态摘要或快照内容；
- 输入 Bible version；
- 创建时间和校验摘要。

提交流程：

1. 获取项目单写者锁（含陈旧锁探活，见 §8.4）；
2. 读取当前 revision；
3. 验证 `base_revision` 与当前 revision 一致；
4. 验证事件前置条件和所有状态效果；
5. 构造完整 Commit Record；
6. 写临时文件（独占创建、0600、写完 flush 后 close）；
7. 在同一文件系统中原子 rename 为正式 commit 文件；
8. 更新快照和 `current.json`（二者均可重建）；
9. 释放锁。

正式 commit 文件成功 rename 是提交的线性化点。

**持久化边界的实测结论（1.2 已核验，必须写进实现与文档）：**

- Uya 标准库**没有 `fsync`/`fdatasync`**（`osal`/`libc`/`syscall` 都没有包装）。
  因此第 6 步**做不到**"数据落到稳定存储再 rename"；
- 能保证的是：**读者永远看到完整的旧文件或完整的新文件**（rename 在同一
  文件系统内原子），以及崩溃后**不会留下半个文件**；
- **不能**保证的是：掉电/内核崩溃时最后一次提交一定还在（可能丢最后一次，
  但不会出现"改了一半"的状态）；
- 这条必须写进部署文档的"已知限制"，并在 selftest 里用"杀进程"而不是
  "断电"来验证（后者无法在本仓的测试环境里做）。

若将来引入 fsync（自写 syscall 包装），只需在 §8.2 第 6 步加一次调用，
其余流程不变。

## 8.3 崩溃恢复

启动时：

- 扫描并校验 commit 文件；
- 检查 revision 是否连续；
- 检查 commit hash/校验摘要；
- 检查每类文件的 `format_version`：不认识的版本一律停在只读故障状态并报出
  需要的迁移，禁止猜测解析；
- 发现快照或 `current.json` 落后时，从 commit 记录重建；
- 发现有孤儿临时文件（`*.tmp`）时清理，但**只清理超过一个宽限期的**，
  避免删掉另一个还活着的写者的临时文件；
- 发现损坏、revision 缺口或冲突时进入只读故障状态，不猜测并覆盖数据。

## 8.4 并发控制

首版每个项目只允许一个 Canon 写者。

已核验的实现路径（1.2）：Uya 没有 `flock` 包装，但**排他创建够用**——
`open(path, O_CREAT|O_EXCL|O_WRONLY, 0600)` 建 `<...>.lock`，成功者持锁，
释放即 `unlink`。本仓已有三处同款实现（会话落盘、DSH 设置、PM 仓库），
退避 20→200 ms、超时让位。

**陈旧锁必须处理（1.1 漏了，这是真会卡死的洞）：** 持锁进程被 kill -9 之后
锁文件还在，下一个写者会永远抢不到，项目变成永久只读。锁文件里写
`{pid, host, acquired_at, purpose}`，抢锁失败时：

1. 读锁文件，`kill(pid, 0)` 探活；进程不存在 ⇒ 记一条审计后删除并重抢；
2. 探活成功但 `acquired_at` 超过 `LOCK_STALE_MS`（建议 10 分钟，且可配）⇒
   报 `LOCK_STALE` 给人看，**不自动删**（对方可能只是慢）；
3. 锁文件读不出来/格式坏 ⇒ 报 `LOCK_UNREADABLE`，同样等人工处理。

启动时拒绝第二个 Worker：Worker 抢 `locks/worker.lock`，抢不到就退出并说明
已有实例（而不是静默变成双写者）。

## 8.5 事件日志与快照

事件可以按 Commit Record 保存；必要时额外导出 JSONL 便于检索，但 JSONL 导出不能成为唯一事实来源。

快照是性能优化。即使快照丢失，也应能从有效 Commit Record 重建 Canon。

## 8.6 审计日志的容量（1.2 新增）

`audit/operations.jsonl` 只追加，必须按大小轮转（建议 8 MiB 一份、保留 5 份），
否则长期运行会把数据盘吃满。轮转发生在写入前（先判断大小再追加），
轮转本身用 rename（`operations.jsonl` → `operations.jsonl.1`），不重写文件。
审计**可以丢**（它是可观测性数据，不是事实来源）；不能因为审计写失败就让
业务操作失败，但要记一条 stderr 诊断。

## 8.7 容量与索引（1.3 新增）

百集规模（§0.3 基线外推）：100 集 × 9 镜 = 900 镜，每镜约 5 个产物
（源片、末帧、参考图、潜空间缓存、元数据）⇒ **约 4500–6000 个文件**。

因此：

- `index/` 放**派生索引**：`episode_index.json`、`shot_index.jsonl`、
  `asset_index.jsonl`；只读查询一律走索引，**绝不扫全树**。
- 每集一个 `manifest.json`：该集镜头、资产、canon revision、成本。
- 索引是派生的：损坏可从 Commit Record + manifest 全量重建。
- 重建预算：900 镜全量重建 < 60 s；超过说明索引设计不对。
- 分片：镜头靠文件名前缀区分（`shot03_shot03.mp4`），不再为每镜开
  三层子目录。

**判据（M2 门槛之一）**：百集规模下 `list` / `continuity.inspect` 单次
< 200 ms。

---

# 9. 异步任务和 Worker

## 9.1 任务模型

所有较长生产任务使用持久化 Task，不把 MCP 请求保持数分钟。

Task 字段至少包括：

```json
{
  "task_id": "task_01J...",
  "project_id": "family_comedy",
  "episode_id": "ep002",
  "operation": "episode.produce",
  "status": "queued",
  "stage": "script_generation",
  "progress": 0,
  "attempt": 0,
  "request_id": "req-2026-000021",
  "input_hash": "sha256:...",
  "provider_tasks": [],
  "created_at": "...",
  "updated_at": "...",
  "last_error": null
}
```

任务状态建议：

```text
queued
running
waiting_provider
waiting_review
retry_pending
succeeded
failed
cancelled
submission_unknown
```

`request_id` 只作 tracing 回显（缺省时服务端生成），幂等键是
`(operation, input_hash)`：同键复用已有任务，不同键即使 `request_id`
相同也报 `REQUEST_REUSED`（§4.5）。`input_hash` 覆盖操作名、项目、
集号、目标与参与决策的输入引用，不含时间戳。

状态迁移必须由 Worker 状态机验证，不能任意覆盖字符串。

## 9.2 Worker 执行模式

- `drama mcp serve`：只处理 MCP 请求和短操作，不运行无限后台循环。
- `drama worker run`：读取队列、执行任务、轮询 Provider、恢复中断步骤。
- 第一版 Worker 单实例运行；由用户、启动脚本或服务管理器负责启动和重启。

如果 Worker 不在线，MCP 可接受符合条件的任务并入队，但必须明确返回 `queued` 和 `worker_unavailable` 提示，不
能返回 `running`。

## 9.3 任务检查点

每个 Workflow Step 必须定义：

- 输入引用和输入 hash；
- 状态；
- 开始/完成时间；
- 产物 ID；
- Provider request/task ID（如有）；
- 可安全重试标志；
- 错误信息；
- 下一步依赖。

Worker 重启后只恢复未完成步骤，不重复执行已完成且有有效产物的步骤。

## 9.4 外部提交的不确定窗口

存在一种无法简单消除的情况：请求已发给 Provider，但进程在收到/保存
provider task id 之前崩溃。

处理策略（按 Provider 类型分开写，1.2）：

- **本地队列 Provider（首版）**：提交与查历史是同一个本地服务。`prompt_id`
  由客户端生成或由服务端返回，**都能事后查**；崩溃后先扫队列/历史，
  找到就续上，找不到才允许重新提交。`submission_unknown` 在这一档很少见，
  但仍要保留该状态以防服务端被重启清空队列。
- **HTTP Provider（后续）**：支持 idempotency key / client reference 的，
  用稳定 `input_hash` 查询去重；不支持的，标 `submission_unknown`，
  只做查询与人工核对，**不得盲目自动重发**。

## 9.5 取消与重试

- 取消是尽力而为；已在远端/队列里执行的任务可能无法撤销（本地队列要
  求"能取消就真的把 job 停掉，不能只是不再 poll"）。
- 重试必须知道失败阶段和失败原因。
- 对不可幂等副作用，重试前先核验上一次是否已成功。
- 重试次数、费用上限（本地档是 GPU 分钟上限）和并发限制由配置控制。

## 9.6 预算与配额账本（1.3 新增）

百集最容易死在"跑到第 40 集发现超支"。

- 每个 Task 记 `cost`：`llm_tokens`、`gpu_minutes`、`renders`（生成次数）。
- 项目级累计 `budget/ledger.jsonl`，按集聚合。
- 三类配额：单集上限、项目总上限、单日上限。
- 超限**熔断**：停止派发新任务；已在执行的任务允许跑完（不硬杀，
  否则会产生"半成品 + 重做"的二次浪费）。
- 重做率是一等指标：`renders / shots`；实测基线 1.56×，超过 2.0× 告警
  "提示词或能力表要重审"。
- `budget.report` 按集、按阶段、按 provider 汇总，供日终查看。

---

# 10. Provider Adapter

## 10.1 统一原则

Drama 内部通过 Provider 接口调用外部服务。业务模块不能拼接特定厂商 API 请求。

首版至少区分：

- `LLMProvider`：剧本、分镜、结构化创作和文本审查；
- `ImageProvider`：人物、场景、道具参考图；
- `VideoProvider`：镜头生成、状态查询、取消和结果取回；
- `AudioProvider`：声音设计里的补充素材（**首版不做配音替换**，台词由视频
  模型直出，见 §13）；
- `MediaProvider`：FFmpeg 探测、拼接、字幕合成、响度归一。

**首版这三类 Provider 的实现形态是"既有产线的子进程适配器"**（见 §1.2.1）：
Video/Media/QA 把结构化 shot 描述交给产线脚本，收回产物与报告；
Uya 侧只负责任务状态、检查点、预算与校验。

## 10.2 LLM Provider

Drama Plugin 必须拥有自己的 LLM Adapter。

接口能力至少包括：

- 发送有版本号的 Prompt/输入；
- 请求结构化输出；
- 记录模型名、参数、输入版本和响应摘要；
- 处理超时、限流和模型错误；
- 校验返回 JSON/结构化数据；
- 对失败输出进行有次数上限的修复。

宿主 Agent 的模型能力可以未来通过显式 Provider 代理方式接入，但不能成为 Drama 核心运行的必需依赖。

## 10.3 Video Provider（1.2 改：首版是本地队列，不是云 API）

逻辑接口（两种实现共用）：

```text
video.submit(request) -> provider_task_id      # 本地档返回 prompt_id
video.poll(provider_task_id) -> status         # 排队中 / 执行中 / 完成 / 失败
video.cancel(provider_task_id) -> result
video.fetch_result(provider_task_id) -> asset  # 取回 mp4 与末帧
video.capabilities() -> 能力表                  # 见下
```

**首版实现：`LocalQueueProvider`（本机 ComfyUI 队列）**

- 地址 `http://127.0.0.1:<port>`，走 ComfyUI 的按 job 接口（提交 / 查历史 /
  取文件）；
- **`prompt_id` 就是 provider task id**，天然可查、天然幂等（同 id 不重复执行）；
- **GPU 只有一张，必须串行**：并发上限固定为 1，队列顺序即 Worker 的调度
  顺序；同一时刻只允许一个生成中的镜头任务；
- 成本模型是"GPU 分钟 + 排队时长"，不是钱；`cost_class` 取值表按
  `gpu_seconds` 记账，预算检查用分钟数；
- 崩溃恢复靠"查队列/历史"而不是"重发请求"（见 §9.4）。

**后续实现：`HttpProvider`（云 API）** —— 需要独立的提交/查询/取消/下载契约，
以及幂等键能力；在本地档跑通且有真实需求后再做。

`video.capabilities()` 返回的**能力表是一等公民**（1.2 新增）：某类动作能不能
被这个模型演出来，是既有产线实测过的（例如"走路、站定、转身、说话"可以；
"整身失衡、流体事件"不行）。分镜校验（§6.8）用它做硬校验，不允许把
模型演不出来的动作写进 `action` 然后指望重试解决。

不能在核心引擎中硬编码未经验证的模型能力：能力表必须来自配置 + 实测记录，
并且**版本化**（换了模型/量化档要换表）。

## 10.4 凭证与配置（1.2 按宿主实测行为改写）

宿主的实际行为（已核验）：MCP 子进程**只继承白名单环境变量**
（`HOME LOGNAME PATH SHELL TERM USER`）+ 配置里显式给的 `K=V`；
`command` **不做 PATH 查找**。因此：

- API Key 的目标来源只有两个：宿主配置里的 `env`（`mcp.json` 的
  `mcpServers.<name>.env`）或 Drama 自己的配置文件（0600，路径在配置里给）；
- 已实现配置文件凭证：`llm.json` 的 `api_key`（0600）会变成
  `Authorization: Bearer <key>`；仍不读取环境变量。没有代理字段，公开
  Provider 只在 `tls: 1` 时建议使用；
- **不要**假设继承 shell 里的 `OPENAI_API_KEY`/`HTTP_PROXY` 之类变量——
  要用就得在宿主配置里显式声明；Drama 当前也不会读取这些变量。
- `command` 必须写**绝对路径**；
- 不写入 Project Bible、Task 输出或 MCP 响应；
- 日志脱敏（key 只出现前 4 位 + 长度）；
- 每个 Provider 有独立超时、重试和预算配置；
- Provider 版本、模型版本、能力表版本一起进生产 manifest。

---

# 11. 资产存储和访问

## 11.1 首版传输约束

MCP 仅返回资产元数据和访问引用，不返回完整媒体二进制。

首版部署约束：Drama Plugin、MCP Host 和媒体工具位于同一台机器，且配置了明确授权的共享资产根目录。

**已核验的宿主行为（1.2）：** 宿主拉起 MCP 子进程时不套沙箱（直接 execve），
所以 Drama 读写自己的数据根目录不受工作区限制；但子进程只继承白名单环境
变量（`HOME LOGNAME PATH SHELL TERM USER` + 配置里的 `K=V`），
所以**数据根目录要写进配置**，不要依赖别的工作区变量（`PWD`、`DSH_*`
之类都不会传进来）。宿主的权限模式仍会影响能不能调用：read-only 下工具被
一律拒绝，workspace-write 下逐次批准。

资产引用示例：

```json
{
  "asset_id": "video_ep002_final_v1",
  "project_id": "family_comedy",
  "media_type": "video",
  "mime_type": "video/mp4",
  "size_bytes": 25400000,
  "sha256": "...",
  "relative_path": "projects/family_comedy/assets/final/ep002_v1.mp4",
  "delivery_mode": "shared_filesystem"
}
```

不得默认将 `file://` URI 当作所有 MCP Host 都可访问的地址，也不得无条件返回本机绝对路径。

## 11.2 安全约束

- 所有资产路径相对于配置的数据根目录解析；
- 拒绝 `..` 路径穿越；
- 对符号链接和最终真实路径进行边界检查；
- 读取前验证项目权限；
- 资产元数据包含大小、MIME 和 SHA-256；
- 不允许 Agent 通过任意路径读取文件。

## 11.3 构建与交付

`drama_plugin/build.sh [output-path]` 是独立构建入口；默认写到当前目录的
`build/drama`，并允许通过 `UYA` / `UYA_ROOT` 选择编译器与标准库。`pack.sh`
复用此入口，避免源文件顺序分叉。交付包不含编译器；构建者须提供 Uya 0.11.0
与匹配的标准库。

当前程序版本为 0.1.0，项目数据格式版本为 1；CLI 版本与 `format_version`
独立管理。`project.get` / `project.configure` 会拒绝不认识的项目格式，Canon
读取有格式守卫，但其余记录尚未统一覆盖，且没有自动迁移器。P11 当前不承诺
0.x 跨版本数据兼容；在迁移器和回归测试完成前，升级前须备份数据，且不要直接
用新版本打开既有项目。业务 CLI 接受 `--config FILE`（当前只读其中的 `data_dir`，显式
`--data-dir` 覆盖它）；LLM 适配层会读取该数据根下的 `llm.json`。
发布包 README 提供停止写入后归档整个数据根、解压到新目录并
用 `health` / `project.list` 验证的备份恢复流程；归档可能含敏感项目数据，须限制
备份文件权限。`canon.recover` 只重建项目 Canon，不替代整个数据根备份。

## 11.4 未来扩展

未来可以增加 HTTP 下载服务、短期签名 URL、对象存储或 MCP Resource，但需要单独设计认证、访问控制和过期策略，不列入首版交付。

---

# 12. 自动生产工作流

## 12.1 剧本阶段

```text
读取项目 Bible 和当前 Canon
           |
生成故事创意/冲突/笑点
           |
生成剧本草案和候选事件
           |
结构校验 + 连续性验证
           |
语义剧本审核
           |
待批准
           |
episode.approve(screenplay)
           |
提交 Canon revision
```

## 12.2 视频阶段

```text
读取已批准剧本版本
           |
生成分镜和镜头状态
           |
准备人物/场景/道具参考资产
           |
提交本地队列视频任务
           |
Worker 轮询并下载结果
           |
镜头 QA
       +---+---+
       |       |
      通过    失败
       |       |
       |    单镜头重试/修复
       |       |
       +---+---+
           |
FFmpeg 合成
           |
成片审核
           |
episode.approve(final_cut)
           |
登记正式成片资产
```

**首版每一步都是"Uya 状态 + 产线子进程"的组合（见 §1.2.1）：** 分镜出图、
逐镜 QC、剪辑合成这三步调用既有产线脚本，Uya 只负责把入参固化（镜号、
冻结文本、参考图、时长）、记录检查点、校验产物（可解码 / 时长 / 锚帧差 /
ASR 对齐），以及决定是否重试。产线脚本的退出码与产物清单是这一步的
"外部事实"，必须落进 Task 检查点，不能只看 stdout。

## 12.3 上下文控制

长剧集不将完整历史剧本持续塞入 LLM 上下文。每次创作按需组装：

- 当前 Bible 版本；
- 当前 Canon Snapshot；
- 最近 3–5 集摘要；
- 与本集相关的人物、地点、道具和事件；
- 未回收伏笔和长期梗；
- 当前创作要求。

检索结果必须保留来源 ID，避免模型把推测当成已发生事实。

---

# 13. 质量检查

质量检查分为确定性规则与模型辅助判断。

## 13.1 剧本 QA

- 结构和必需字段完整；
- 时长估算合理（用确定性口径：对白 4–5 字/秒 + 停顿，见 §16.3）；
- 人物设定一致；
- 对白角色归属正确；
- 事件前置条件成立；
- 道具位置和人物知识状态不矛盾；
- 笑点/冲突/反转满足项目目标（模型辅助，只给问题与置信度）；
- **集尾钩子存在**：本集结尾必须抛出一个下一集要兑现的问题。

## 13.2 分镜/视频 QA（1.2 按真实产线口径重写）

**声音口径（先定死，避免实现跑偏）：** 台词由视频模型直出（多语言标记里
写中文），后期**只做响度归一（loudnorm），不做配音替换**；ASR 只用来核对
台词与做定时字幕。任何"重新配音覆盖原声"的实现都属于范围外。

确定性检查（必须机器判定，能进 selftest）：

1. **静态体检**：字段完整、镜号连续、`scene_id`/人物 ID 存在、
   能力表校验（§10.3）、`Σ镜头时长 = 正片时长`（误差 ≤0.05 s）、
   画布/帧率/编码符合 `format`；
2. **ASR 对齐**：逐镜把 ASR 结果与 `line_text` 比对，字符相似度阈值
   （建议 ≥0.85，按项目配置）不达即失败；同时产出字幕时间轴；
3. **锚帧接戏差**：`cut_type="anchor"` 的镜头，取上一镜末帧与本镜第 0 帧
   做像素差，超过阈值即"接戏断了"；
4. **成片终检**：可解码、无空文件、无黑边、无长静音段、时长与
   `total_seconds` 一致、片尾卡存在。

模型辅助检查（只出问题清单 + 置信度，不改 Canon）：

- 人物外观、服装、场景锚点是否命中（对照 §6.2/§6.3 的冻结文本与锚点）；
- 道具外观与位置是否与批准剧本相符；
- 关键动作是否呈现、情绪是否过度表演；
- 剪辑前后是否连贯。

## 13.3 失败处理

每个失败项都要关联：镜头/阶段、规则或审查依据、严重程度、是否可重试、建议修复方式。达到重试上限后停止，不无限消耗费用（本地档是 GPU 分钟）。

## 13.4 闭环审计（每 10 集，1.3 新增）

每完成 10 集触发一次，报告进资产；不通过不允许批量推进。

当前 `canon.audit` 是只读的全历史完整性检查：每次扫描提交索引，并逐条重算
Commit Record 的 `state_hash`。这保证旧记录在重复审计间被篡改也会被发现，
但成本随历史增长；增量检查仍未实现。未来若引入缓存/增量，必须以已验证的
提交链前缀为基础，并覆盖旧提交篡改、索引截断/替换、canon 回退和缓存损坏
等负例，不能仅凭 revision 或提交数量复用旧结论。

1. **历史重放**：随机抽 10 集（必含第 1 集与当前集），从 Commit Record
   重建状态，与当时落盘快照逐字段比对；差异即 `REPLAY_MISMATCH`。
2. **承诺回收率**：`open` / `overdue` / `waived` 计数；`overdue` 必须为 0。
3. **人物漂移**：外观锚帧与首集基准图比对；台词画像（人称、口头禅、
   句长分布、语速）与角色声线画像比对。
4. **笑点重复**：连续 20 集内笑点结构重复率超阈值即报告。
5. **逻辑矛盾**：全历史 `ORPHAN_CHANGE` / `TIMELINE_CONFLICT` /
   `RULE_VIOLATION` 必须清零。
6. **成本**：本 10 集的 GPU 小时、重做率、人工分钟与预算对比。

## 13.5 反例库（1.3 新增，进回归）

把已经踩过的坑变成 fixture；任何新规则先过这六条，否则不算修好。

| # | 反例 | 期望错误码 |
|---|---|---|
| 1 | 道具瞬移（冰箱里的遥控器出现在茶几上） | `PROP_TELEPORT` |
| 2 | 知识越界（妈妈知道她不在场时发生的事） | `KNOWLEDGE_LEAK` |
| 3 | 场景穿帮（同一场景两集陈设不同） | `SCENE_DRIFT` |
| 4 | 伏笔落空（第 5 集抛出、第 6 集没回应） | `PROMISE_OVERDUE` |
| 5 | 时间悖论（同一天过了两个晚上） | `TIMELINE_CONFLICT` |
| 6 | 外观漂移（第三集发型变了） | `CHARACTER_DRIFT` |

每条 fixture = 一个小项目 + 一份期望错误码；检查器不报对应错误码即测试失败。

---

# 14. 安全、权限和预算

## 14.1 操作分级

每个 Operation Registry 条目声明：

- `read`：只读；
- `write`：修改项目/候选数据；
- `external_cost`：调用可能产生（钱或 GPU 时间）成本的外部服务；
- `destructive`：取消、删除或覆盖类操作。

## 14.2 插件内策略

**宿主侧的真实粒度（1.3 按源码修正）：** MCP 工具调用的批准条件是
`perm_requires_approval() || perm_confine()`，而这两个判定分别是
「模式 == read-only」与「模式 != full-access」。所以实际行为是：

| 宿主模式 | MCP 工具调用 |
|---|---|
| read-only | **每次都要用户批准** |
| workspace-write | **每次都要用户批准** |
| danger-full-access | 直接放行 |
| 无回答渠道（非交互 / 子代理） | **fail closed**（返回"需要批准但没有渠道"，等于拒绝） |

（源码：`src/plugin/mcp.uya` 的 `mcp_ask_approval`；判定在 `src/tools/perm.uya`。
1.2 曾写成"read-only 一律拒绝"，那是错的——read-only 是逐次批准，不是硬拒。）

也就是说：宿主只能按"一个工具"授权，看不到 Drama 的内部操作，而且默认是
**逐次询问**。这带来三个后果，必须写进文档与部署说明：

1. 一集会有十几次 `call`，用户会被逐次弹批准 —— 部署文档要说明这一点，
   并建议把"批量执行本集剩余步骤"做成**单个** `episode.produce` 任务，
   而不是让 Agent 循环调用；
2. 插件的二次授权与预算是**补充**，不能替代宿主批准；
3. 后台/无人值守场景（子代理、cron、无 TTY）下 MCP 调用**会 fail closed**，
   所以"百集无人值守"只能靠 **Worker 自己跑**，不能靠 Agent 反复调 `call`。

首版使用本地配置策略：

- 只读模式：只允许 list/get/inspect；
- script 模式：允许 LLM 剧本生成，按配置预算执行；
- production 模式：允许视频、音频和媒体生产，受 GPU 分钟、并发、重试和
  时长上限控制。

宿主 Agent 在发起高成本操作前应向用户解释并确认；Plugin 仍必须独立执行额度和策略校验。不能仅依赖 Agent 口头声称已获批准。

交付包的 `DRAMA_OPERATIONS.md` 将上述权限、Worker、预算、备份和已知限制
整理成部署步骤；它反映当前源码行为，不替代宿主的批准实现。

## 14.3 安全要求

- API Key 不进入模型上下文和日志；
- 文件访问限定在配置根目录；
- 拒绝任意命令执行；
- `call` 只分发注册操作；
- 所有写操作记录 request_id 和审计信息；
- 外部 Provider 请求有超时、预算和重试上限。

---

# 15. 目录结构建议

首版建议独立仓库：

```text
src/
  app/
    main.uya
    config.uya

  mcp/
    server.uya
    protocol.uya
    tools.uya
    response.uya

  registry/
    operation.uya
    schema.uya
    dispatcher.uya

  domain/
    project/
    episode/
    story/
    character/
    scene/
    prop/
    continuity/
    storyboard/
    production/
    asset/

  runtime/
    worker.uya
    task.uya
    workflow.uya
    checkpoint.uya
    lock.uya

  providers/
    llm/
    video/            # 首版：本地队列 Provider
    video_pipeline/   # 既有产线子进程适配（出图/取回/末帧）
    image/
    audio/
    media/            # FFmpeg / 剪辑合成（首版走产线脚本）
    qa/               # ASR / 接戏 / 终检

  storage/
    project_store.uya
    commit_store.uya
    task_store.uya
    asset_store.uya
    lock.uya
    idempotency.uya
    recovery.uya

  quality/
    screenplay_qa.uya
    continuity_qa.uya
    video_qa.uya

  cli/

selftest/
examples/
docs/
```

**注意（1.2 补充）：上面的文件名只是职责示意，不是定稿。** 落地时的文件
划分必须服从两件事：① Uya 当前的模块导入/编译规则；② 本仓的硬性规范
（单文件 ≤2000 行、单函数 ≤100 行、行宽 ≤80 码点）。不要为了"长得像这个
目录"而造空层级。

---

# 16. 测试和验收标准

## 16.1 单元测试

- Operation Registry 注册、查找和版本；
- 动态 Schema 参数验证；
- 事件前置条件与效果；
- 人物知识状态；
- Canon revision 递增；
- 幂等请求处理（同 `input_hash` 复用、同 `request_id` 不同 `input_hash` 拒绝）；
- Task 状态迁移；
- 资产路径边界验证；
- 时长核算（Σ镜头时长 vs 正片时长，容差内通过、容差外拒绝）；
- 锁：两进程抢同一锁只有一个成功、陈旧锁按 §8.4 处理。

## 16.2 集成测试

- MCP initialize 和 initialized；
- tools/list 仅返回三个工具（raw 名 `list`/`describe`/`call`）；
- 三个工具均可调用；
- 未注册业务操作拒绝执行；
- `describe` 与 `call` 的 Schema 一致；
- 与当前 `uya-agent` MCP Client 的端到端兼容；
- 工具名称归一化映射正确（公开名 = `mcp__drama__<raw>`）；
- **协议帧格式**：任何响应的原始字节里除结尾 `\n` 外不含 `\n`；
  单条消息超过 1 MiB 时改为返回资产引用；
- **`isError` 语义**：业务失败不带 `isError`、基础设施失败带；
- **超时**：`call` 在 60000 ms 内返回（生产类操作返回 `queued`）；
- Worker 与 MCP Server 共享数据正确；
- 插件重启后 Task 和 Canon 可恢复。

## 16.3 剧本闭环验收（M1 三集 / M2 十集 / M3 三十集 / M4 百集）

**黄金 fixture 用真实脚本，不用虚构项目（1.2 决策）。** 选用已经产出过成片的
真实短剧项目（分镜、台词、QC 清单齐备），逐集比对；虚构 fixture 只保留为
单元测试的最小样例。

必须验证：

1. 第一集产生候选剧本和事件；
2. 审核通过后提交 revision 1；
3. 关闭 MCP Server 和 Worker；
4. 重新启动两个进程；
5. 第二集基于 revision 1 生成；
6. 第二集审核通过后提交 revision 2；
7. 第三集基于 revision 2 生成并提交；
8. 人物性格、位置、服装、知识状态、道具位置和伏笔保持一致；
9. 重复 `request_id`（同 `input_hash`）不会重复创建剧集或任务；
10. 模拟提交中断后，Canon 能从 Commit Record 恢复；
11. 视频阶段失败不会回滚或污染已批准剧本 Canon。

**"人物没漂移"必须可判定，不能靠模型说没问题**：逐集比对冻结文本的 hash
（没变）、`CharacterState` 的服装/配饰字段（在允许变体集合内）、知识事实
集合的差集（不许出现"提前知道"）、道具位置表（每集变化都能追到事件）。

**文本与时长的计量口径（1.2 新增）：**

- 文本一律 UTF-8；长度按**码点**算（汉字算 1），不按字节、不按终端列；
  但"时长"按**念出来的字符数**算（标点不计时、括号里的舞台指示不计时）；
- 对白 4–5 字/秒，句号/问号/感叹号后按 0.3–0.5 s 停顿，动作描述按产线
  经验值折算；
- 校验判据：Σ镜头时长与目标正片时长误差 ≤0.05 s（§5.3）。

**回归集分三层（1.3 新增，随台阶增长）：**

| 层 | 内容 | 用来验什么 |
|---|---|---|
| L1 | 3 集单元（最小项目） | 状态机、不变量、提交门 |
| L2 | 3 题材 × 各 10 集（真实项目） | 连续性与题材通用性 |
| L3 | 100 集 Mock 压力集 | 调度、索引、恢复、预算熔断 |

L3 用 Mock provider（不真跑 GPU）：它验的是状态与调度，不是画质。
画质/一致性靠 L2 的真实产线小批抽样。

## 16.4 性能和资源

首版不设未经实测的绝对性能指标。P0/P1 建立基准：启动时间、常驻内存、MCP 调用延迟、项目读取/提交延迟、任务恢复时间、文件数量增长、单镜 GPU
 耗时。后续依据真实数据设门槛。

---

# 17. 版本路线（1.3：改为四个台阶）

1.2 的路线只到"能跑通"，1.3 把验收终局改成百集，路线随之改坡：
0.5 之前是"能跑"，0.5–1.0 是"能连续"，1.0–2.0 是"能规模"。

| 版本 | 范围 | 里程碑 | 对应阶段 |
|---|---|---|---|
| 0.1 | 独立程序、MCP 三工具、Registry | 宿主能连接并调用 | P1 + P2 |
| 0.2 | Project、Bible、文件存储、操作审计 | 可独立创建和读取项目 | P3 |
| 0.3 | Continuity、事件、Commit、恢复 | 状态可验证、可恢复 | P4 |
| 0.4 | LLM 传输层、Adapter、Story Engine | 可生成结构化剧本 | P5 |
| 0.5 | 三集 + 四轴不变量最小版 | **M1：闭环最小版** | P6 + P12（最小） |
| 0.6 | Storyboard、Asset 管理、接戏字段 | 剧本可转换分镜 | P7 |
| 0.7 | Video Provider、Worker 异步恢复 | 可生成并恢复视频任务 | P8 |
| 0.8 | QA、重试、Media 合成 | 可输出验收成片 | P9 + P10 |
| 1.0 | 十集无人值守：索引、预算熔断、跨集审计 | **M2：能连续** | P11 + P12 + P13 |
| 1.1 | 三十集跨题材（题材模板参数化） | **M3：通用性** | P13 |
| 2.0 | 百集 + 抽 10 集历史重放全绿 | **M4：终局** | P13 + P12 |

**四个台阶的通过条件（都要过四轴不变量，缺一不升）：**

- **M1（0.5）**：3 集连续，不变量零红，重放 3 集复现率 100%。
- **M2（1.0）**：10 集无人值守，中途一次崩溃恢复、一次闭环审计通过；
  `list`/`continuity.inspect` < 200 ms。
- **M3（1.1）**：30 集跨至少 2 个题材模板，模板切换不需要改代码
  （通用性定义见 §1.4）。
- **M4（2.0）**：100 集，Mock 压力集零状态错误，抽 10 集重放全绿，
  成本报告与 §0.3 基线误差 < 20%。

---

# 18. P0 必须核验的实现假设

**1.2 已把 10 条核成 6 条**（依据：宿主源码 `src/plugin/`、`DESIGN.md §21`、
`uya/stdlib/lib/`、既有产线）。剩下的 4 条才是真正需要原型验证的。

## 18.1 已核验（不必再做原型，写进实现即可）

- **MCP Client 协议版本/方法/映射**：协议 `2024-11-05`；只 tools（+ 自定义
  钩子方法）；不认的方法回 `-32601` 即放行；公开名 `mcp__<server>__<raw>`，
  非法字符换 `_`。
- **stdio 传输**：宿主只实现 stdio；帧 = 一行一条 JSON、单条 ≤1 MiB、
  超限整行丢弃。
- **工具结果**：`content[]` 的 text 段拼接；`isError:true` 前缀 `Error: `；
  `structuredContent` 已支持（可选）。
- **工具超时**：`toolCallTimeoutMs` 默认 60000 ms（可配 1–3,600,000）。
- **临时文件 + 原子重命名**：有 `os_rename`；模式「O_EXCL 建 tmp(0600) →
  写 → rename」在宿主里已有三处实现可照抄。
- **排他创建/单写者**：没有 `flock`，但 `O_CREAT|O_EXCL` 锁文件够用
  （须补陈旧锁探活，§8.4）。
- **子进程/信号/守护**：`std/process` 的 pipeline
  （fork/exec/env/cwd/capture/status）+ `os_spawn`/`os_waitpid`/`os_kill`。
- **JSON**：`std/json` 有 parser/encoder + `to_json<T>`/`from_json<T>`；
  嵌套上限 **256**。
- **FFmpeg**：既有产线已在用（拼接、抽末帧、loudnorm），可实证。

## 18.2 仍需实测（P0 的全部工作量）

1. **Uya 写 stdio MCP Server 的最小闭环**：一行一条紧凑 JSON 的读写、
   `initialize` / `notifications/initialized` / `tools/list` / `tools/call`、
   未知方法回 `-32601`、stdout 不被日志污染、EOF/断管退出。
   （可参照 Uya 已写过的 MCP server 先例来搭骨架。）
2. **HTTPS 客户端：默认校验模式已可用（1.5 实测转绿）。**
   `lib/tls/https.uya` 导出 `https_get` / `https_get_insecure` /
   `https_get_with_config`，返回 `HttpsResponse{status, response_len,
   response[]}`；`std/net/dns.uya` 能做 A 记录解析。实测（1.5）：
   `https_get("example.com", 443, "/")` **默认校验、握手完成、status 200**；
   `https_get_insecure(...)` 同样 200。
   ⇒ P5 的远程 LLM 调用可以直接走 `https_get`，不必绕本机网关；
   但禁止用 insecure 模式把 API Key 发到公网。

   **曾经为什么过不去（1.4 定位、1.5 修完的六个 bug）**：
   ① 服务器 flight 保存时跳过 5 字节记录头，捕获函数却按记录头解析 ⇒
   链永远为空；② SPKI 只按 RSA (n, e) 解析，ECDSA 公钥（P-256 65 字节 /
   P-384 97 字节）解析不出来；③ ECDSA 验签既没按曲线分派哈希，r/s 还从
   48 字节缓冲错位读取 ⇒ 签名永远验不过；④ 扩展 OID 缓冲只有 16 字节、
   扩展循环边界用了 explicit-3 末尾 ⇒ 真实中间证书的扩展被整块放弃、
   `is_ca=false`；⑤ keyUsage 要求未使用比特为 0，而 CA 证书常见 7 位用法
   ⇒ 直接判失败；⑥ 信任库 64 KB 一次读，150 张根只加载到 43 张，且
   `MPI_MAX_LIMBS=32` 放不下模幂的 4096 位中间积 ⇒ RSA 锚验签必失败。
   修法全部落在上游 `~/uya/uya/lib/tls/`（commit `b578a7ed`），
   再同步进本仓 `uya/`（编译器 v0.11.0 + 标准库），**不在本仓改 vendored
   副本**。

   **边界（写进 P5 契约）**：只验"链到信任锚 + 主机名 + 有效期"，不做吊销
   （CRL/OCSP）、不做 CT、不缓存吊销状态；错误主机名/过期证书的反例还没有
   自动回归脚本。
3. **非 ASCII 的 JSON 往返**：中文是否原样输出/是否 `\u` 转义、超长中文串的
   编码缓冲边界。
4. **本地队列 Provider 的实际契约**：本机生成服务的提交/查历史/取文件接口、
   队列满与重启清空队列的行为、单卡串行的实测吞吐（每镜耗时）。

## 18.3 交付物

P0 必须提交 `P0_FINDINGS.md`，每项标明：已验证、不可用、替代方案、对应测试。
未验证的能力不得作为后续模块的既定依赖。

---

# 19. 最终设计结论

Drama Plugin 是独立的 Uya 短剧生产引擎，uya-agent 是它的 MCP 宿主之一。

对外只有三个 MCP Tool：

```text
list
describe
call
```

内部业务通过 Registry 管理；LLM 创作与 Uya 事实状态分离；MCP 控制面与媒体数据面分离；MCP Server 与持久 Worker 
分离；剧情 Canon 与视频生产验收分离。

工程边界（1.2 定档）：Uya 负责 Canon / Task / MCP / Registry / 审批；
分镜出图、QC、剪辑合成走既有产线（子进程适配），不一次性重写。
视频 Provider 首版接**本机本地队列**（GPU 串行、`prompt_id` 即幂等键），
云 API 留作后续。

第一台阶（M1）只证明：**插件可独立运行，跨进程重启后能够基于权威状态连续
生成并提交三集剧本，且四轴不变量全绿。** 该目标通过后，再接入视频生成；
后续按 M2（十集无人值守）→ M3（三十集跨题材）→ M4（百集）推进。

**百集闭环是验收终局**：故事（承诺回收率 100%）、人物（冻结 hash 不漂移、
知识不越界）、环境（道具位置唯一、场景陈设一致）、逻辑（每个状态变化有原因、
时间轴单调、规则不被推翻）四轴全部由机器判定，任一条红即拒绝提交。
成本基线见 §0.3：单卡 3–4 周/百集，因此调度、预算与审批策略都是设计的一部分，
不是运维细节。
