/* uya_agent_libc_protos.h — 给「无体 extern "libc" fn」补 C 原型（踩坑 131）
 *
 * 为什么需要这个文件：
 *   uya 编译器对**没有函数体**的 `extern "libc" fn` 是故意不生成 C 原型的
 *   （见 ../uya/src/codegen/c99/function.uya：「extern "libc" fn 无函数体：不生成
 *   声明，链接到系统 libc」）。它假设宿主系统头已经声明了该符号 —— 对 `read` /
 *   `write` 这类确实如此，但 `setsid` / `sigaction` 需要 <unistd.h> / <signal.h>，
 *   而 split-C 生成的每个 .c 只 include 自己那套 uya_*.h，从不 include 系统头。
 *   于是这些调用在 C 里全是**隐式函数声明**。
 *
 *   老 GCC 只给 warning；GCC 14 起 -Wimplicit-function-declaration 升级为**错误**，
 *   构建直接失败（本机 cc 是 GCC 15.2）。
 *
 * 怎么用：
 *   Makefile 把本文件以 `CFLAGS=... -include src/cshim/uya_agent_libc_protos.h`
 *   注入**每一个**编译单元（driver 把外层 export 的 CFLAGS 当**命令行变量**交给生成
 *   的 build/uyacache/Makefile，压过它里面的 `CFLAGS ?=` —— 细节见 Makefile 那段注释）。
 *   原型必须在**出错的那个 .c** 里可见，
 *   放在单独的 .c 里（@c_import）没用 —— 那只是另一个翻译单元。
 *
 * 硬约束（别踩）：
 *   **绝不 include 任何系统头**。uya 生成的 uya_part1_types.h 自带 int64_t / size_t
 *   等 typedef；一旦把 glibc 的 <sys/types.h> 拉进来，两边定义冲突，
 *   会变成满屏 "conflicting types for 'int64_t'"。所以这里只用 C 内置类型。
 */
#ifndef UYA_AGENT_LIBC_PROTOS_H
#define UYA_AGENT_LIBC_PROTOS_H

/* ---- pid_t setsid(void) —— <unistd.h>。用在做「自成会话、没有控制终端」的
 * 子进程上（tools/shellx 的 bash 工具、plugin/mcprun 的 MCP server、web/websrv）。
 * 依赖这一条的 uya 侧声明：src/tools/shellx.uya、src/plugin/mcprun.uya、
 * src/web/websrv.uya 的 `extern "libc" fn setsid() i32;` */
extern int setsid(void);

/* ---- int sigaction(int, const struct sigaction *, struct sigaction *)
 * —— <signal.h>。
 * uya 侧自有布局的结构体（src/session/sigx.uya 的 SigxAction 明确按**宿主 glibc**
 * 的 x86-64 布局排的：handler(8) + mask(128) + flags(4)+pad(4) + restorer(8)），
 * 所以这里前向声明同名结构体、按同一布局写，保证原型类型准确。
 * 结构体定义由 uya_part1_types.h 提供（它就是 `struct SigxAction`，无前缀）。 */
struct SigxAction;
extern int sigaction(int sig, const struct SigxAction *act,
                     struct SigxAction *old);

/* ---- int getsockopt(int, int, int, void *, unsigned int *) —— <sys/socket.h>。
 * uya 侧声明在 src/rt/rtio.uya。为什么绕开 `libc.syscall` 的 `sys_getsockopt`：
 * 那个在 Darwin 上是**裸 syscall 指令**（编译器只给 setsockopt/getsockname/
 * getpeername 生成了 libc shim），而 Darwin 的错误判据是 carry 标志、errno 为正，
 * 现有包装层按「返回值 < 0」判错，于是永远读不到真值。libSystem 的 `getsockopt`
 * 两个平台都直接可用，语义统一成「0 = 成」。
 * `socklen_t` 两侧都是 4 字节无符号整型（Darwin `__uint32_t` / glibc `unsigned int`），
 * 所以这里用 `unsigned int *` —— 不 include 系统头（见上面的硬约束）。 */
extern int getsockopt(int fd, int level, int optname, void *val,
                      unsigned int *len);

/* ---- int ioctl(int, unsigned long, void *)：Darwin 侧 `libc/syscall.uya` 的
 * `sys_ioctl` 直接调它（`ioctl` 是变参函数，编译器只给少数几个 libc 函数生 shim，
 * 它不在名单里）。只在 Apple 平台声明：Linux 侧 `sys_ioctl` 走 `@syscall`，碰不到
 * 这个符号，而 glibc 的 `ioctl` 是变参原型，重复声明会撞类型。 */
#if defined(__APPLE__)
extern int ioctl(int fd, unsigned long request, void *arg);
#endif

/* ---- int _NSGetExecutablePath(char *, unsigned int *) —— <mach-o/dyld.h>。
 * 只有 Darwin 有：那里**没有 /proc**，`/proc/self/exe` 那条链整条失效，而 web
 * 会话要 fork+execve **自己**（子进程 cwd 已经变了，execve 也不查 PATH），
 * 所以必须拿到自己的绝对路径。uya 侧声明在 src/web/websrv.uya
 * （`extern "libc" fn _NSGetExecutablePath(...)`，符号名照抄 dyld 那个）。
 * Mach-O 里符号是 `__NSGetExecutablePath`（C 名多一个下划线，clang 自己加）。 */
#if defined(__APPLE__)
/* 第二个参数在头文件里写作 `uint32_t *`，这里必须写 `unsigned int *`：本文件被
 * `-include` 在**每个** .c 的最前面，那时 <stdint.h> 还没进来，`uint32_t` 是未知
 * 类型名（实测 63:44 error）。Darwin 的 `uint32_t` 就是 `unsigned int`，等价。 */
extern int _NSGetExecutablePath(char *buf, unsigned int *bufsize);
#endif

#endif /* UYA_AGENT_LIBC_PROTOS_H */
