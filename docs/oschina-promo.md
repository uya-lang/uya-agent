# 9 MB，一个文件，一个编程 Agent：连 TUI、沙箱和 TLS 都塞进去了

> 给它一句话，它自己读文件、改文件、跑命令，循环到给出结论。
> 而它本身只有一个 9.3 MB 的静态二进制：拷到任何 x86-64 Linux 上就能跑，
> **不要 node、不要 python、不要 glibc、不要容器**。

官网：https://uya-lang.github.io/uya-agent/
GitHub：https://github.com/uya-lang/uya-agent

---

## 0. 先别讲道理，先跑一下

```bash
curl -fsSL https://raw.githubusercontent.com/uya-lang/uya-agent/main/install.sh | sh
~/.local/bin/uya-agent --tui-demo
```

`--tui-demo` 不联网、不要 key，几毫秒出一屏纯文本，先看界面长什么样。
真要干活的时候，把一句话丢给它：

```bash
export DEEPSEEK_API_KEY=...
uya-agent "把 hello.uya 的问候语改成 Hello, uya!"
```

![uya-agent 跑完一个真实任务：读文件 → 改一行 → 跑命令 → 给结论](https://raw.githubusercontent.com/uya-lang/uya-agent/main/docs/tui-demo.png)

这不是演示动画，是一次任务真正跑完后的屏幕：读了文件、改了一行、
跑了命令、给了结论。

---

## 1. 我们受够了「装一个 Agent 要半小时」

今天装一个编程 Agent，通常意味着：先对齐 Node 版本，再 `npm i`，
或者 `pip install` 一堆包，再不济也得先拉一个容器镜像。
等你终于跑起来，环境里已经多了几百 MB 你自己都说不清是什么的东西。

`uya-agent` 走的是另一条路：**交付物就是一个文件**。

| | 常见做法 | uya-agent |
|---|---|---|
| 交付物 | 依赖树 + 入口脚本 | 9,291,192 字节的单个 ELF |
| 动态依赖 | 一堆 `.so` | `PT_INTERP` 0 条、`NEEDED` 0 条 |
| 安装 | `npm i` / `pip install` / `docker pull` | `curl \| sh`，或手工 `curl -LO` + `chmod` |
| 运行时 | 用户自己装 node / python | 编译器与标准库就在仓库的 `uya/` 里 |

`make link-audit` 每次构建都核对「真的没有动态依赖」，不是文档里嘴上说说。
`file` 看到的是 `statically linked`；`Dockerfile` 是 `FROM scratch`，
镜像里除了这个二进制什么都没有。

`install.sh` 也刻意做得极其无聊：判断架构、下载那个二进制、`chmod`。
不写配置、不改 `PATH`、不装任何运行时。它会先查一次 GitHub API 拿到
本次发布的资产名与 `SHA256SUMS`，校验和对不上就不装；
「一次都没发过 release」「钉的 tag 不存在」「API 连不上」是三种不同的提示，
因为它们对应的下一步完全不同。

---

## 2. 一个文件里到底装了什么

* **全屏 TUI**：常驻状态区、实时推理行、任务块、`/diff` 浮窗、markdown 渲染；
  放不下的文本会滚动显示，而不是把关键那行裁掉。
* **浏览器界面**（`--web`）：每个会话一个标签，标题下面就是**那个会话的真 TTY**；
  页面零 JavaScript、零 CDN、零外部字体——官网本身就是这个约定的活样本。
* **三级权限 + 内核沙箱**：read-only / workspace-write / danger-full-access，
  另有 bwrap 沙箱；plan / chat / build 三种会话模式按 `tab` 循环。
* **30 个工具**：文件、执行、会话、技能与搜索、子代理、目标、编排、MCP 插件……
  工具名沿用 DSH 的叫法，`~/.dsh` 可以直接读，连 DSH 的会话（含 zstd）都能导入。
* **Git worktree**：每个会话一个分支，执行 → 合并 → 删除，默认就开着。
* **会话与项目记忆**：落盘可恢复；跨会话记住「这个项目怎么跑、关键文件在哪、
  上次什么还红着」。记忆按归一化仓库根归类，只追加分片存储，
  开工包作为**一条独立 user 消息**注入，不打掉 system 前缀缓存。
* **子代理一族**：并行委派、`ralph` 循环、`/watch` 跟读、`/stop` 叫停，
  还有 `.ush` 脚本编排的 `workflow`。
* **图片与剪贴板**：纯 Uya 写的 X11 剪贴板客户端；MCP 插件可以用任意语言写。

完整清单在 README 里，这里只挑了几个我认为最「不像一个 9 MB 文件能干的事」。

---

## 3. 为什么这么极端？因为三条约束一路推下来

这不是炫技，是三个限制逼出来的设计：

1. **没有 libc 的通用设施** →
   TLS、OpenAI 的两种线协议、SSE、YAML、diff、markdown 全部自己实现
   （`src/net/` 9.8k 行、`src/diff/` 2.2k 行）。
2. **不能引 xterm.js** → 它要么走 CDN（自测就别想离线），
   要么把几十万行压缩 JS vendor 进仓库。所以浏览器界面里的
   **终端解释器写在服务端**（`src/web/ttyemu.uya`）。
3. **没有 zlib** → 图片缩放自己写；PNG/GIF/WebP 只能明确说「不支持」，
   而不是静默给出一张坏图。

约束链的副作用是：**整套东西可以离线证明自己能用**。
104 处断言、30 多个 `make e2e-*` 目标、内置 mock LLM——
`make selftest` 全程不联网、不要 key；`make selftest-fast` 是给 CI 的 10 秒档。
mock LLM 会讲两种线协议，还会断言收到的请求体，
所以「通过」意味着协议写对了，而不只是「模型恰好说了句好话」。

---

## 4. 顺便说一句：它是用一种没什么人听过的语言写的

`src/` 下参与构建的 **183 个文件、152,730 行，全是 Uya 源码**，
没有一个 `@c_import`。其中自测占 35%，生产代码是 128 个文件、99,589 行。
唯一的 C 是 `src/cshim/` 那 840 行——一段 Windows 控制台桥，
只有 `make windows` 才用到；**Linux 产物不含本仓写的任何 C 逻辑**。

为什么用冷门语言写这么大的东西？因为编译器和工具链就在仓库里
（`uya/bin/uya`，0.10.4），`make build` 不需要预装编译器、不需要联网。
代价也真实存在：没有 `let` / `mut` / `i++`，只有 `while` 没有 `for`，
错误处理是 `!T` + `defer`。这些限制反过来塑形了架构，
仓库甚至把「文件 ≤2000 行、函数 ≤100 行、行宽 ≤80 字符」
做成了 `make lint-size` 的硬门槛。

---

## 5. 跑分：我们没赢，但也没输，所以把表贴出来

第三方基准 OpenBench，四个任务，两臂用**同一个模型**
（`deepseek-v4.1-flash`，effort max，输出上限都是 256000），
各跑三次、串行。每格都是这次跑出来的，不是引用旧记录。

| 中位数 | taskflow | make-ci-green | add-feature | webcore |
|---|---|---|---|---|
| uya-agent 轮数 | 21 | 10 | 11 | 64 |
| dsh 轮数 | 18 | 6 | 11 | 14 |
| uya-agent token | 533k | 106k | 131k | 3,384k |
| dsh token | 911k | 65k | 150k | 554k |
| uya-agent 耗时 | 86 s | 50 s | 134 s | 1372 s |
| dsh 耗时 | 279 s | 32 s | 175 s | 419 s |

解出数：uya-agent 12/12，dsh 11/12（`webcore` 有一格停在基线 0.3）。
所以「这东西根本跑不通」不成立——四题两侧都解得出来。

差的是效率，而且方向按题而分：

* `webcore`（多模块、要读大量代码）我们明显吃亏：64 轮 / 3,384k token /
  1372 s，对面是 14 轮 / 554k / 419 s。这是差距最大的一项，得认。
* `taskflow` 反过来：轮数只少 3 轮，token 却省了近一半（533k 对 911k），
  耗时 86 s 对 279 s。
* `make-ci-green` 对面全面占优；`add-feature` 基本打平。

n=3，报方向不报显著性。两臂走的是同一条真路线，装置与结果文件都在
`testdata/openbench_adapters/`，复现方法见该目录的 README。
把这张不怎么好看的表原样放上来，是因为「只看对自己有利的数字」的评测，
我们不相信。

---

## 6. 已知限制：先说清楚，别踩坑

* web 界面**没有认证、也没有 HTTPS**，默认只绑 `127.0.0.1`；
  绑到 `0.0.0.0` 是显式决定，启动时会打警告。
* web 的终端解释器是白名单实现，只解这个 TUI 真会发的序列；
  在里面跑依赖滚屏区、字符集切换或图形协议的全屏程序会显示不对。
* markdown 是实用子集：没有语法高亮、引用式链接、HTML 块、脚注。
* 只有 Linux 和 Windows 构建，没有 macOS。
* `--selftest` 是端到端套件，要在仓库根跑；只想验「这二进制在本机能不能跑」，
  用 `--tui-demo`。

---

## 7. 最后：一个刚起步的 MIT 项目，想要你的一个 star

`uya-agent` 现在是 v0.1.4，MIT 许可，star 还是个位数，
Discussions 已经打开——我们更缺的是**提问的地方**，issue 门槛对 newcomers
太高。`GOOD-FIRST-ISSUES.md` 里准备了几个 30 分钟、零风险的入口，
从改文档到加测试，都有「改哪个文件、跑什么验证、怎么算做完」。

如果你受够了「装个 Agent 先装半个运行时」，
或者单纯觉得「用冷门语言把 15 万行写完还塞进一个静态二进制」这件事有点意思：

* 官网：https://uya-lang.github.io/uya-agent/
* GitHub：https://github.com/uya-lang/uya-agent （求 star、求 issue、求拍砖）
* 安装：`curl -fsSL https://raw.githubusercontent.com/uya-lang/uya-agent/main/install.sh | sh`
* 源码：`git clone https://github.com/uya-lang/uya-agent.git && cd uya-agent && make build`

给它一句话试试。不好用直接骂，我们真的会看。

---

## 附：备选标题（发布时可挑）

1. 9 MB、单文件、无 glibc：我们把整个编程 Agent 塞进了一个二进制
2. 15 万行冷门语言、0 个 `@c_import`，最后交付物是 9.3 MB
3. 装 Agent 要半小时？这个项目的安装脚本只做三件事
4. 把跑分表里对自己不利的那半也贴出来：一个 9 MB 编程 Agent 的实话

## 附：发布小提示

* 配图用 `docs/tui-demo.png`（上正文已用 raw 链接，可直接显示）。
* GitHub 仓库的 Social preview 也建议设成这张图，贴到群里时的预览卡就是它。
* 文中所有数据来自官网首页与仓库 README；数字会随版本变化，发布前建议对一遍。
