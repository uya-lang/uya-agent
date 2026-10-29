# macOS 交叉编译与真机验收

两条腿，分开验：

* **造**：在 Linux 宿主上 `make macos` → `build/macos/uya-agent`（Mach-O 64 位
  x86_64 可执行文件）。不需要 macOS 机器，只要一个 zig（`zig cc` 自带 Darwin
  libc 的 tbd 与 linker）。同一套 recipe 加 `MACOS_ARCH=arm64` 出 arm64 产物，
  见 §6。
* **跑**：把二进制丢进一台真 macOS，跑 `--help` / `--selftest`。本文的实测环境是
  [dockur/macos](https://github.com/dockur/macos) 的 **macOS 15 客户机**（x86_64
  QEMU，KVM 加速），记录见下文「实测记录」。arm64 档目前只有编译与形状证据。

## 1. 造：`make macos`

```bash
make macos          # → build/macos/uya-agent（日志 build/macos/build.log）
make macos-check    # 形状判据：Mach-O 64-bit x86_64 executable + 链接 libSystem
make macos-arm64    # = make macos macos-check MACOS_ARCH=arm64（→ uya-agent-arm64）
```

`file` 应报：

```
build/macos/uya-agent: Mach-O 64-bit x86_64 executable, flags:<NOUNDEFS|DYLDLINK|TWOLEVEL|PIE>
```

`make macos` 与 `make windows` 的差别（三处，都是 Darwin 的硬约束）：

| 差别 | 取值 | 为什么 |
|---|---|---|
| 不许 `-static` | recipe 里 `LDFLAGS=""` | Darwin 没有静态 libc（无 `libc.a` 可静链），`-static` 根本不被接受；产物动态链接 `/usr/lib/libSystem.B.dylib` |
| `-target` 是 `x86_64-macos` / `aarch64-macos` | `MACOS_TRIPLE`（由 `MACOS_ARCH` 推） | zig 0.16 的 target query **不认** `x86_64-apple-darwin`，报 `UnknownOperatingSystem` |
| 生成物后处理随每次 cc 生效 | `testdata/macos/zig-darwin-cc.sh` | 不像 windows 那样「生成 → 修 → 单 TU 编」，macOS 走 split-C，修补放在 `CC_DRIVER` 包装里 |

缓存目录按 arch 各一个：`build/macos/uyacache-<arch>`（`UYA_SPLIT_C_DIR`）。与
Linux 的 `build/uyacache`、另一个 arch 的缓存混用，增量 make 会拿错平台的 `.o` 去
链接 —— 两个 arch 的 struct 布局大多一致，链接期一声不响，跑到运行期才炸。

### 1.1 `zig-darwin-cc.sh` 干的两件事

它被当作 `CC_DRIVER` 交给编译器（`resolve_cc_driver()` 优先看 `CC_DRIVER`），
每次 cc 调用前做两处幂等修补，然后 `exec zig cc "$@"`：

1. **Mach-O 的符号下划线前缀**。uya 生成的头文件 `uya_part1_types.h` 里，libc 桥
   接写成 `extern … fn uya_host_write(…) __asm__("write");`。Mach-O 的 C 符号自带
   `_` 前缀，`__asm__("write")` 把这个前缀**顶掉了** ⇒ 链接期一屏
   `undefined symbol: _write`（自己只定义了 `write`）。脚本只改 `uya_host_` /
   `uya_macos_real_` 那几行里的 `__asm__("name")` → `__asm__("_name")`；
   `register long r10 __asm__("r10")` 这类寄存器名不受影响（正则限定
   `[a-z][a-z_0-9]*` —— 头一版没限定，第二次跑变成 `___…_write`，链接报
   `undefined symbol: ____________exit`）。
2. **u64 常量拆半的有符号左移 UB**。codegen 把 `0xCBF29CE484222325` 这类常量拆成
   `((int64_t)(uint32_t)0xCBF29CE4ULL << 32)` —— 高半 ≥ `0x80000000` 就是
   **有符号左移溢出**。宿主 GCC 不开 UBSan 看不见，而 **zig cc（clang）在 `-O0`
   下默认开 `-fsanitize=undefined` 的 shift 检查**，于是真机上启动几步就
   `Abort trap: 6`（见 §3）。脚本对「本次要编译的那个 `.c`」跑现成的
   `testdata/win_fix_shift_ub.py`（Windows 目标早就踩过同一条），生成物可重复
   生成，改它不动源码语义。

## 2. 跑：macOS 上的自测判据

`--selftest` 自带 mock LLM，**不需要网络、不需要 key**。三条硬判据，全在真机上跑：

```bash
mkdir -p /tmp/run && cd /tmp/run        # ① 必须是可写目录，见下
/tmp/ua --help | head -3                # ② 中文帮助正常打印
UYA_SELFTEST_GOAL_ONLY=1 /tmp/ua --selftest; echo "exit=$?"
UYA_SELFTEST_TUI_ONLY=1  /tmp/ua --selftest; echo "exit=$?"
```

* **cwd 必须可写**：`goal-cmd` 那几轮把 `agent_home` 钉在 `build/selftest_goal_home`
  并落 `goal.json`。在 `/` 下跑（Recovery 的默认 cwd 不可写）会一屏
  `goal_save 失败` / `盘上没有 goal.json`，`exit=3`、`SELFTEST GOAL FAIL` —— 这是
  **测试环境**问题，不是 macOS 问题。`cd /tmp/run` 之后同一份二进制就 PASS。
* 期望 `SELFTEST GOAL PASS` / `SELFTEST TUI PASS`、`exit=0`。

## 3. dockur/macos 真机环境（复现用）

本文的实测跑在 dockur/macos 客户机上，这里只记**复现要点**（容器本身按上游
README 起，`docker compose up -d`）：

| 项 | 值 |
|---|---|
| 客户机 | macOS 15.6.1，`Darwin 24.6.0 xnu-11417.140.69~1/RELEASE_X86_64`，x86_64 |
| 共享目录 | 宿主 `<data>/shared` → 容器 `/shared` → 客户机 `/Volumes/shared` |
| 上传（客户机 → 宿主） | 宿主机在容器里起一个只读的 80xx 静态服务，客户机 `curl -sT 文件 http://<容器网关>:80xx/<名字>` |
| 下载（宿主 → 客户机） | 同上，`curl -s -o /tmp/ua http://<容器网关>:80xx/uya-agent` |
| 终端 | 客户机里 GUI 才能开终端（Recovery 的 `Utilities → Terminal`，正常系统里是 `/Applications/Utilities/Terminal.app`） |
| 看屏 | VNC 到 QEMU（dockur 默认 `-vnc`）/ web console，截图 + OCR 读输出 |

> 客户机 `/etc/hosts` 是只读的（`Read-only file system`）。要改 DNS 只能在**容器侧**
> 的 dnsmasq 上做（`--address=/域名/IP`），别去动客户机。
> 容器重启后自起的服务会掉，静态服务要手动拉起来再验证一次 `curl` 拿到
> `200 <字节数>` 再传文件。

## 4. 实测记录（macOS 15.6.1 / x86_64）

| 判据 | 结果 |
|---|---|
| `file`（宿主侧） | `Mach-O 64-bit x86_64 executable`，33,723,367 B，仅依赖 `libSystem.B.dylib` |
| `make macos-check` | `LC_MAIN.stacksize = 0x4000000`（64 MB）确实写进了头里，见 §4 最后一条 |
| `codesign -dv` | `code object is not signed at all` —— **未签名照样能跑**（本机自编译自跑，不经 Gatekeeper 隔离属性） |
| `/tmp/ua --help` | 中文帮助正常打印（Recovery 客户机里没有 `file` / `otool`，用 `--help` 的输出当「跑起来了」的第一手证据） |
| `UYA_SELFTEST_GOAL_ONLY=1` | `SELFTEST GOAL PASS`，`exit=0`（goal-cmd / goal-sess / todo-resume / goal-idle 四轮全绿） |
| `UYA_SELFTEST_TUI_ONLY=1` | 修 UB 之前 `Abort trap: 6` / `exit=134`，见下；修之后 41 轮全绿、`0 FAIL`、`exit=0` |
| `./ua --selftest`（全量） | 见 §4.3 |

**`-O0` + UBSan 的坑（本节最值钱的一条）**：首版产物在 TUI 自测里当场 panic ——

```
thread 4253 panic: left shift of 3421674724 by 32 places cannot be represented
  in type 'int64_t' (aka 'long long')
???:?:?: 0x10cac9e88 in _tui_mq_key
      ← _tui_mq_touch ← _tui_mq_draw ← _term_tui_style_tui_marquee_put
      ← _tui_draw_panel_rows ← _tui_build_chat ← _term_tui_screen_tui_build
      ← _uip_status_check ← _selftest_tuis_ui_port_tui_ui_port_round
      ← _selftest_main ← _main_main ← _main
```

根因就是 §1.1 的第 2 条（生成物里 205 处），和 Windows 那次是**同一个 codegen
缺陷**。修法两条都能过，本仓选前者（不掩盖问题）：

* 修生成物（`-O0` 保持不动，与 Linux 构建同参）：`testdata/win_fix_shift_ub.py`；
* 或 `CFLAGS` 加 `-fno-sanitize=undefined` / 换 `-O2`（`-O2` 下 zig 不再默认开
  UBSan，实测同一段 C 从 661,463 B 带 2 个 `__ubsan_handle_shift_out_of_bounds`
  掉到 12,798 B 无该符号）—— 这是**掩盖**，同一处 UB 换个编译器/优化档还会咬人。

### 4.1 Darwin 裸 `readdir` 是 pre-10.5 ABI（目录遍历静默错位）

`extern "libc"` 绑的是**裸符号** `_readdir`，不是 SDK 头里那个 `readdir` 宏
（宏映射到 `readdir$INODE64`）。两者的 `struct dirent` 形状完全不同：

| 字段 | 裸 `_readdir`（实际绑到的） | `readdir$INODE64`（SDK 头） |
|---|---|---|
| `d_ino` | u32 @0 | u64 @0 |
| `d_seekoff` | 无 | u64 @8 |
| `d_reclen` | u16 @4 | u16 @16 |
| `d_type` | u8 @6 | u8 @20 |
| `d_namlen` | u8 @7 | u16 @18 |
| `d_name` | @8 | @21 |

还有两个形状差异：

* 裸 `_readdir` 返回的**不是** `sizeof(struct dirent)` 步长的数组，记录按各自的
  `d_reclen` **背靠背紧凑排列**（`dirent.h` 注释里明写「reclen 之外还有
  `d_name` 的 NUL」）；
* `readdir$INODE64` 才是 SDK 头里那个 1048 字节的 `d_name[1024]` 结构。

按新布局声明 `Dirent` 的后果：第一级目录还能碰巧读出名字（`.d_name` @21 落在
名字区的尾部），第二级就整条错位 —— 表现出来是「某个目录操作在 macOS 上静默
失效」（本轮的具体症状是会话目录扫不到 `session.jsonl`，一条粘贴消息都没落盘），
既不崩溃也不报错。

**怎么定性**（客户机上没有 `file` / `otool` / `python3`，靠自写 C 探针）：`dlsym`
取 `opendir` / `readdir` / `readdir$INODE64` 三个地址（三者地址各不相同），对同一
个目录各读一条，再把原始字节按 0/4/6/7/8 与 16/18/20/21 两套偏移各解一遍 ——
实测裸符号那条是 `u16@4=12`（reclen）、`u8@6='.'`（type）、名字在 @8，指向新布局
的 `u16@16=12 u16@18=516 u8@20=46` 全是垃圾。

修法是让 `Dirent` 跟**实际绑到的符号**分叉（`uya/stdlib/lib/libc/syscall.uya` 里
按 `std.target_os == .tos_macos` 分两支），而不是跟 SDK 头一致。

### 4.2 Darwin 的 pty 与 termios

* **没有 `openpty`**：`/dev/ptmx` + `TIOCPTYGRANT`(0x20007454) +
  `TIOCPTYGNAME`(0x40807453) + `TIOCPTYUNLK`(0x20007452) 三步缺一不可，从设备名
  从 GNAME 取（`/dev/ttysNNN`，没有 `TIOCGPTN`）。少一步 ⇒ 从设备 `open` 给
  `EBUSY`。
* **`sizeof(struct termios)` 是 72**（Linux 60）：4×u64 + `c_cc[20]` + 2×u64。
  按 Linux 的 60 字节静态缓冲去 `tcgetattr`，会被 72 字节拷写溢出。
* **窗口尺寸要设在从设备上**：设在 master 上的 `TIOCSWINSZ` 不会传到子进程。
* **从设备必须一直开着**：中途关掉再 open，同一个 master 就再也读不到子进程写进
  从设备的字节（表现为整轮抓不到输出，但子进程活着）。
* **master 在从设备还没 open 时写入会阻塞数秒**（实测 ≥4 s）⇒ master 一律
  `O_NONBLOCK`，且 `EAGAIN` **不能**当成 EOF。
* pty 驱动会自己置 `PENDIN`（`c_lflag` 的 0x20000000）⇒ termios 还原判据要先抹掉
  这一位再比，否则每次都判「没还原」。

### 4.3 现状（macOS 15.6.1 / x86_64，xnu 24.6.0）

分组自测（均为客机本地跑，日志回传到宿主核对）：

| 组 | 结果 |
|---|---|
| TUI（`UYA_SELFTEST_TUI_ONLY=1`，41 轮，其中 13 轮带真 PTY 腿） | 41 绿、`0 FAIL`、`rc=0` |
| GOAL（`UYA_SELFTEST_GOAL_ONLY=1`，4 轮） | 4 绿、`0 FAIL`、`rc=0` |
| 全量（不设 env，150 轮） | 137 绿 / 12 红 / 1 轮只打诊断，`rc=3` |

全量的对照实验（**同一 commit、同一条命令**，Linux 侧 `ulimit -s 65536`）：

| | 绿 | 红 | 只打诊断 | `rc` |
|---|---|---|---|---|
| Linux（cwd = 仓库根） | 148 | 1（`resp-build`） | 1（`api-negotiate`） | 3 |
| macOS 客机（cwd 含 `testdata/`） | 137 | 12 | 1（`api-negotiate`） | 3 |

* `resp-build`（「扁平 tools 的条数不是 29」）**在 Linux 上也红** ⇒ 与本轮改动 /
  macOS 都无关，是当前基线的既有红，照实记在这里。
* 11 条 **macOS-only 红**（按日志里的原话归类，逐条根因还没定位）：

  | 轮次 | 日志里的第一句 |
  |---|---|
  | `bash-detach` | 命令没有自成会话（pid/pgid/sid 不相等）＋ fd 0 没指向 `/dev/null` |
  | `bash-stop-recover` | `stopped_by` 不是 19、退出码不是 147、结果里没有 `[stopped by signal: 19]` |
  | `async-net` | 流式等待没按取消收口、半开上游没按空闲预算收口 |
  | `clip-parse` | 写假 Xauthority 失败 |
  | `compact-auto` | mock server verdict 88（请求里少了 `Session-Id:` 头） |
  | `fs-tools` | mock server verdict 47（请求里的 grep 输出少了 `Line N:` 预览） |
  | `responses-compact` | `agent_run` 返回 2 |
  | `skills-web-search` | mock server verdict 97（技能目录没注入请求） |
  | `think-row` | 思考行往 fd 2 写了字节（三条幂等/静默断言全红） |
  | `tty-editor` | 清掉面板之后应以提示符收尾 |
  | `turn-retry-all` | 401 那轮被当成「空响应」 |

  其中 `bash-detach` 的判据本身是 Linux 口径（命令里 `readlink /proc/self/fd/0`
  找 `/dev/null`），Darwin 没有 `/proc` 就必然红 —— 属「夹具待分叉」，不是程序
  坏了。`think-row` 更像**输出去向**差异：客机上 `out_err` 真的落到 fd 2，Linux
  上被改道到保存的 tty（这也正好解释了为什么客机日志里有全部细节行、Linux 日志
  里几乎只有 `ok` 行）。
* **跑全量时 cwd 必须有 `testdata/`**：`workflow` 轮往 `testdata/wf_runner.sh` 写
  假 runner，缺目录就红（第一次跑就栽在这儿，补上 `testdata/` 后转绿）。这不是
  macOS 差异。

判据取**退出码**（`echo "rc=$?"`），别只 grep 日志找 `SELFTEST ... PASS`：那句走
`out_err`，Linux 上不进重定向文件；而且各轮的 `ok` 行常常后面跟一段中文注解、或
被 `\n`（字面转义）接在别的行尾巴上，`grep -c "selftest\[x\] ok"` 会漏。人工核
用的口径是「`rc=0` 且日志里该轮既没 `FAIL` 也没缺结论」。

## 5. 已知限制（macOS 侧还没做透的）

* **默认 `-static` 在 Darwin 不成立**：`make build` 那条路是 Linux 口径；macOS 只
  走 `make macos`（动态链接 libSystem）。`make link-audit` 的判据（无
  `PT_INTERP`/`NEEDED`）对 Mach-O 无意义。
* **`SigxAction` 按 glibc x86-64 布局写**（`handler(8)+mask(128)+flags(4)+pad(4)+
  restorer(8)`，`SIGX_SA_RESTART = 0x10000000`）。Darwin 没有 `sa_restorer`、
  `sigaction` 的 layout 与 `SA_RESTART` 常量都不同 ⇒ 信号相关的行为**未验证**。
* **`rtloop` 的 `epoll`**：`tos_macos` 下必须走 kqueue/poll；自测里未覆盖的
  「长驻 fd 事件循环 + 信号」组合在 macOS 上是空白。
* **`fork` / `openpty` / `ioctl(TIOC*)` / `/proc`** 这些路径 macOS 上要么走别的
  实现要么如实报错，与 Windows 那档「如实标 SKIP」同口径，需逐轮核 SKIP 原因。
* **全量自测还有 11 条 macOS-only 红**（清单见 §4.3）。它们不是同一根因：有判据
  写死 `/proc` 的（`bash-detach`）、有输出去向差异的（`think-row`）、有 mock 断言
  请求形状不成立的（`fs-tools`/`compact-auto`/`skills-web-search`）、还有纯行为
  差异的（`tty-editor`/`turn-retry-all`/`responses-compact`/`async-net`/
  `bash-stop-recover`）。**TUI / GOAL 两组全绿**，所以「macOS 上能不能跑」这个问题
  已经有答案；剩下的红属于下一档的移植工作。
* **`bash-stop-recover` 一类依赖 SIGSTOP/SIGCONT 的判据**在 Darwin 上口径不同
  （Linux 用 `waitpid` 的 147 = 128+19），要分叉常量而不是直接复用。
* 产物**未签名、未公证**：拷到别的机器（带 quarantine 属性）会被 Gatekeeper 拦，
  本机自编译自跑不受影响。

## 6. arm64（Apple Silicon）

### 6.1 能验到哪一步

**本机（Linux x86_64 宿主）**只到「造得出来 + 形状对」：

```bash
make macos-arm64     # = make macos macos-check MACOS_ARCH=arm64
```

实测输出（zig 0.16.0，Linux x86_64 宿主）：

```
macos: 产物 build/macos/uya-agent-arm64（arm64）
-rwxrwxr-x 1 winger winger 31690624 build/macos/uya-agent-arm64
build/macos/uya-agent-arm64: Mach-O 64-bit arm64 executable,
                             flags:<NOUNDEFS|DYLDLINK|TWOLEVEL|NO_REEXPORTED_DYLIBS|PIE>
macho_stack: 通过（LC_MAIN.stacksize = 0x4000000（64.0 MB），门槛 0x4000000）
macos-check: 通过（Mach-O 64 位 arm64，libSystem，栈 0x4000000）
```

真机自测已经由 §7 的 GitHub `macos-14` runner 补上了（见 §6.1.1）。

默认档同时回归过：`make macos && make macos-check` 仍绿（33,725,194 B，
x86_64）。两档共用一份 recipe，arch 只由 `MACOS_ARCH` 决定。

一次 arm64 构建里踩到过**生成的 `.c` 写盘被截断**（本机 `/home` 只剩 13 GB，
codegen 写 split-C 时偶尔短一截）：报错是 `src/tools/search.c:525:66: error:
expected '}'` 这种「列号离谱」的语法错，源文件尾巴停在 `/* defer */`。删掉那两个
`.c` 与 `.o` 重跑即可恢复，与 arch 无关（x86_64 档也出现过）：

```bash
rm -f build/macos/uyacache-arm64/src/tools/search.c \
      build/macos/uyacache-arm64/src/tools/search.o \
      build/macos/uyacache-arm64/src/session/session.c \
      build/macos/uyacache-arm64/src/session/session.o
```

**三种拼法只在一处归一**（踩过这个坑的人会同时看到三种写法）：

| 在哪 | 写什么 |
|---|---|
| `make` 命令行 / `file` 输出 | `arm64` |
| zig 的 `-target` | `aarch64-macos` |
| uya 的 `TARGET_ARCH` | `arm64`（实测写 `aarch64` 也认，两者都进 `.ta_arm64`） |

`MACOS_ARCH` 传别的值直接 `$(error)` 拦下，免得拼错一个字母就静默出一份
x86_64 产物。

### 6.1.1 arm64 真机第一次跑出来的数（GitHub `macos-14`，M1）

§7 的 workflow 跑通之后，arm64 这一档第一次有了真机自测证据（run #7 / #8）：

| 项 | 结果 |
|---|---|
| `--help`（中文帮助） | 退出码 0 |
| GOAL 组（4 轮） | `SELFTEST GOAL PASS`、退出码 0 |
| TUI 组（41 轮） | 40 绿、**1 红**：`tui-paste`「真 PTY：会话日志里没有那条三行合一的 user 消息」 |
| 全量（150 轮） | 没跑到（TUI 组红在前面，Jobs 顺序是 GOAL → TUI → 全量） |

也就是说：**arm64 上 TUI 的 40 轮（含 12 条真 PTY 腿）与整个 GOAL 组都绿**，
唯一红的那条正是 x86_64 上也踩过的 `tui-paste`（§4.1 那个 readdir ABI 的邻居：
一条测试把目录遍历、pty、粘贴、会话日志四件事串在一起，任一环不对都红）。

同一个 run 里 `macos-15-intel`（x86_64 真机）那台**全绿**：`--help`、GOAL 4 轮、
TUI 41 轮、全量收集，一步步都是 success —— 这是除 dockur/macos 之外第二份 x86_64
真机证据，而且别人也能一键重跑。

`tui-paste` 在 arm64 上的诊断（证据改成走 fd 2 之后才拿到的）：

```
paste-log: nmsg=0 body=0 len=0 path=(none)   三级目录一个都没找着
paste-child: status=9                        子进程还活着（9 = 被我们 SIGKILL）
selftest[tui-paste] FAIL: 真 PTY：会话日志里没有那条三行合一的 user 消息
```

屏幕上的断言都过了（粘贴没被当回车提交、回车之后有用户条目），只有「按
`<home>/sessions/<cwd>/<session>/session.jsonl` 三级目录找日志」这条断在这里 ——
连第一级 `sessions/` 都没取到条目 ⇒ 嫌疑落在 `opendir`/`readdir` 那条路上
（`tui_paste_first_dir` 读的是 `Dirent.d_name`）。下一轮该查的就是这件事：macOS 的
`readdir` 在 arm64 上很可能**没有** pre-10.5 那套旧 ABI（arm64 是后来的平台，
Apple 的 stub 里也许只留 `readdir$INODE64`）；若如此，`Dirent` 要按 **arch** 再
分一次叉（x86_64 旧 ABI / arm64 INODE64）。

### 6.2 为什么**本机**跑不了 arm64 真机（真机验证走 §7 的 CI）

* dockur/macos 在 **x86_64 Linux 宿主**上走 QEMU + KVM，客户机只能是 x86_64 的
  macOS；本篇 §3/§4 那台就是。
* macOS **arm64 客户机**只在 Apple Silicon 上、由 Apple 的
  Virtualization.framework 提供（dockur/macos 在 macOS 宿主上也是切到那条路）。
  QEMU 侧没有能起 XNU arm64 的路子。
* 所以 arm64 这一档**一条 `--selftest` 都没跑过**。§4 的 `0 FAIL` 是 x86_64 的
  成绩，**不能挪用到 arm64**。

### 6.3 要拿到 arm64 真机证据，四条路

1. **GitHub Actions 的 `macos-14` runner**（就是 Apple Silicon 真机，见 §7）——
   不需要自己的机器、别人也能一键重跑，是这一档的首选。
2. **Apple Silicon + Rosetta 跑 x86_64 产物**（验的还是 §4 那套已绿的二进制）：
   ```bash
   softwareupdate --install-rosetta --agree-to-license
   make macos && ./build/macos/uya-agent --selftest; echo "exit=$?"
   ```
3. **Apple Silicon 上原生 arm64**：`make macos-arm64` 后照 §2 的判据跑。
4. **dockur/macos 架在 Apple Silicon 宿主上**（它自动用 vz），客户机就是 arm64
   macOS：把 `uya-agent-arm64` 传进去，按 §3/§4 的流程跑一遍。

### 6.4 静态审计：arm64 上「应该」成立的部分

| 检查 | 结论 | 依据 |
|---|---|---|
| 源码是否按 arch 分叉 | **没有** | `grep -rn target_arch src/` 为空：平台差异全在 `std.target_os` 这一层，Darwin 的行为已按 OS 分叉，arm64 复用同一份 |
| stdlib 的两处 `.ta_x86_64` 分叉 | arm64 走 libc，不是裸 syscall | `std/async.uya` 的 sendfile、`std/runtime/runtime.uya` 的 `_uya_exit`，非 x86_64 一律回落 libc —— 正是 macOS 该走的 |
| Darwin 常量是否与 CPU 相关 | 无关 | zig 的 Darwin 头只有一份 `any-darwin-any`（两档共用），`TIOCPTYGNAME = _IOC(IOC_OUT,'t',83,128)` 这类是拼出来的，两档同值 ⇒ §4.1 的 readdir 旧 ABI、§4.2 的 pty/termios 结论对 arm64 同样成立 |
| 主线程栈 | 已实测 | arm64 产物的 `LC_MAIN.stacksize = 0x4000000` |
| `long double` 差异（x86_64 16 B / arm64 8 B） | 踩不到 | 生成物里 `grep -c "long double"` 全 0 |
| Homebrew 前缀（`/opt/homebrew`） | 已覆盖 | `src/vcs/gitx.uya` 把 `/opt/homebrew/bin/git` 列进候选 |

### 6.5 arm64 上最可能先炸的地方（都未验）

1. **信号**：`SigxAction` 是 glibc x86-64 布局（见 §5），Darwin arm64 的
   `struct sigaction` / `ucontext` 与 glibc、与 Darwin x86_64 三者都不同 ⇒ 装着
   信号的那几轮（`sigselftest`、pty 腿里的信号分支）在 arm64 上是空白。**这是
   arm64 这档最大的洞**，也解释了为什么 §2 的判据在 arm64 上要重跑而不是沿用。
2. **16 KB 页**（M 系列）：本仓没有按 4096 写死的对齐假设（`grep 4096` 命中的
   全是缓冲区大小），但 `mmap` / 栈红区相关路径没验过。
3. **arm64e / PAC**：产物是 `arm64`（不是 arm64e）、未签名，本机自跑不受指针认证
   影响；一旦有人 re-sign 成 arm64e 或去做公证，签名与 entitlement 另算。
4. **UBSan 仍要显式关**：zig cc 在 `-O0` 默认开 `-fsanitize=undefined`，与 arch
   无关；codegen 里那个「常量拆半的有符号左移」在 arm64 上照样会 abort。
5. **无 Darwin ASan runtime**：zig cc 出不了可用的 ASan，两档同样。

## 7. GitHub Actions 的 macOS runner（`.github/workflows/macos.yml`）

本机没有 Apple Silicon 也能跑 arm64：GitHub 的 `macos-14` / `macos-15` 就是
Apple Silicon（arm64）真机，`macos-13` 是 Intel（x86_64）。

| job | 跑在 | 干什么 | 挡不挡合并 |
|---|---|---|---|
| `build` | `ubuntu-latest` | `make macos` + `make macos MACOS_ARCH=arm64` + 两档 `macos-check`，产物传 artifact | 挡 |
| `test`（x86_64） | `macos-15-intel` | `--help`、GOAL 组、TUI 组各跑一遍；全量只收集 | 观察项 |
| `test`（arm64） | `macos-14` | 同上，二进制换 `uya-agent-arm64` | 观察项 |

几个非显然的决定：

* **编译留在 ubuntu**：本仓自带的编译器 `uya/bin/uya` 是 Linux ELF，macOS runner
  上跑不了。所以形状与 windows job 一致 —— 交叉编译在一台、真机跑在另一台。
* **zig 自己下，不用 `mlugg/setup-zig`**：这个 workflow 第一次跑（run #1）就是红在
  那一跳，而 GitHub 的 job 日志要登录才给看（未认证 `GET .../logs` 是 403），没法
  当场查因。改成 `curl` 拉 `ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz`
  后，失败点写在 URL 上，任何人能本地重跑同一条命令。
* **版本必须钉 0.16.0**：本机 PATH 上的 `zig` 是 0.17.0-dev，`make macos` 直接
  构建失败 —— 这不是 CI 特有毛病，是「换 zig 版本 = 换一套 C 前端」，见 Makefile
  注释 ④。
* **Intel 档换过镜像**：原来写 `macos-13`，但 run #5–#8 里它**排了半小时没分到
  runner**（同一时刻 `macos-14` 8 秒就分到了）—— macOS 13 那批确实在退役，
  改成 Intel 的接班镜像 `macos-15-intel`。它同样只是把 §4 那份 x86_64 证据变成
  「别人也能重跑」；要是也排不上，就删掉那一行矩阵项，别为它改判据。
* **arm64 需要代码签名**：Apple Silicon 上 arm64 进程必须有签名，未签名的会被
  `Killed: 9`。实测 zig 的链接器已经打了 **ad-hoc 签名**
  （`LC_CODE_SIGNATURE` 在、`codesign -dv` 报 `Signature=adhoc`），再加上 artifact
  下载不带 `quarantine` 属性，所以直接 `chmod +x` 就能跑。workflow 里那步
  `codesign -dv` 只是把这件事印出来，不参与判据。
* **夹具要一起 checkout**：全量里有几轮往 `testdata/` 写假 runner / 假 Xauthority
  （§4.3 最后一条），所以 test job 也 checkout 仓库，而不是只下 artifact。
* **先当观察项**（`continue-on-error`）：arm64 一条自测都没跑过，§6.5 那 5 条
  （信号布局排第一）随时会红。等红过几轮、把数字记进 §6，再把矩阵里的
  `observe` 改成 `false` 转成硬判据 —— 顺序反了第一天就会挡所有人的 PR。
* **`timeout-minutes: 30`**：pty 类回合在 macOS 上曾**永久阻塞**（§4.2 那条
  「slave 未 open 时写 master 会阻塞」），有超时兜底才不会吃掉 runner 的 6 h。
* **计费**：macOS runner 的分钟数是 Linux 的 **×10**。公开仓免费；私有仓要算进
  配额 —— 所以这个 workflow 用 `paths:` 收窄到 `src/`、`uya/`、`Makefile`、
  `testdata/macos/`，改文档不触发。
* **构建会自己重试**（`scripts/uya_build_retry.sh`）：随仓的预编译编译器偶尔把
  split-C 的某个 `.c` 写坏 —— 症状是编译期报一屏「行号/列号离谱」的语法错，例如
  `src/diff/model.c:819:10: error: expected ')'`（同一份源码在开发机上生成的同名
  文件只有 799 行）、`src/agent/ag_workspace_model.c:1938:13: error: unknown type
  name 'line'`。`make build` / `make macos` 都经这条脚本调用：认出
  `<文件>.c:<行>:<列>: error:`、或「生成的 `.c` 末尾没有换行」，就清掉缓存重来
  （最多 4 次），并把第 1 次的失败日志留成 `<日志>.first`。**不是**吞错误 ——
  别的形状照旧原样退出。
  **它不是根治**。证据攒够之后，坏文件的形状指向一个具体嫌疑：
  * 报错的行号总是**超出**文件的实际行数（`ag_workspace_model.c:1938` vs 本地 1937
    行、`tasks.c:1236` 而本地更短），且内容是 `extraneous closing brace`、
    `redefinition of 'g_tasks_ms' with a different type`、`unknown type name 'line'`
    这种「尾巴是上一版留下的旧字节」的样子；
  * 同一份源码在开发机上生成的同名文件完全正常，重试时**换一个全新的缓存目录**也
    可能好、也可能照旧坏（run #9 连 4 次都坏在同一个文件）。

  三项合起来最像「同一个 `.c` 在一次构建里被写了不止一遍，后一遍更短却没有截断，
  旧尾巴留在文件里」。那段代码在编译器（`uya/bin/uya-real`，v0.10.4 预编译）里，
  本仓改不动 ⇒ 只能清缓存重试（macOS 档给到 6 次）。**根治**要么给编译器侧的写盘
  加 `O_TRUNC`/`ftruncate`，要么换一版编译器。
  顺带一句：同样的形状也在 `ci.yml` 的 `构建` 上出现过 —— 那条红在我这轮改动之前
  就有，`make build` 现在也走同一个重试器。

怎么触发：推到 `main`、开 PR（改了上面那几个路径），或在 Actions 页面手动
`Run workflow`（`workflow_dispatch`）。
