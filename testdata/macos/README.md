# macOS 交叉编译与真机验收

两条腿，分开验：

* **造**：在 Linux 宿主上 `make macos` → `build/macos/uya-agent`（Mach-O 64 位
  x86_64 可执行文件）。不需要 macOS 机器，只要一个 zig（`zig cc` 自带 Darwin
  libc 的 tbd 与 linker）。
* **跑**：把二进制丢进一台真 macOS，跑 `--help` / `--selftest`。本文的实测环境是
  [dockur/macos](https://github.com/dockur/macos) 的 **macOS 15 客户机**（x86_64
  QEMU，KVM 加速），记录见下文「实测记录」。

## 1. 造：`make macos`

```bash
make macos          # → build/macos/uya-agent（日志 build/macos/build.log）
make macos-check    # 形状判据：Mach-O 64-bit x86_64 executable + 链接 libSystem
```

`file` 应报：

```
build/macos/uya-agent: Mach-O 64-bit x86_64 executable, flags:<NOUNDEFS|DYLDLINK|TWOLEVEL|PIE>
```

`make macos` 与 `make windows` 的差别（三处，都是 Darwin 的硬约束）：

| 差别 | 取值 | 为什么 |
|---|---|---|
| 不许 `-static` | recipe 里 `LDFLAGS=""` | Darwin 没有静态 libc（无 `libc.a` 可静链），`-static` 根本不被接受；产物动态链接 `/usr/lib/libSystem.B.dylib` |
| `-target` 是 `x86_64-macos` | `MACOS_TRIPLE`，可用 `make macos MACOS_TRIPLE=…` 换 | zig 0.16 的 target query **不认** `x86_64-apple-darwin`，报 `UnknownOperatingSystem` |
| 生成物后处理随每次 cc 生效 | `testdata/macos/zig-darwin-cc.sh` | 不像 windows 那样「生成 → 修 → 单 TU 编」，macOS 走 split-C，修补放在 `CC_DRIVER` 包装里 |

缓存目录单独一个：`build/macos/uyacache`（`UYA_SPLIT_C_DIR`）。与 Linux 的
`build/uyacache` 混用，增量 make 会拿错平台的 `.o` 去链接。

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
