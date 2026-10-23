/* win32_agent.h — Windows 目标的平台垫片接口（唯一 C ABI 面）
 *
 * 为什么需要这个文件（与 src/cshim/uya_agent_libc_protos.h 同一族，但职责不同）：
 *   1) **控制台不是字节流**。conhost 按「控制台代码页」解释输入输出，中文 Windows
 *      上读一个汉字只交出一个字节（实测打「你好」读回来是 0x60 0x60），而输出侧
 *      Uya 的 Windows 后端已经把「写控制台」单独走 WriteConsoleW（见编译器的
 *      c99 后端），**输入侧没有**。要拿到与代码页无关的字符，只能自己读
 *      INPUT_RECORD（uChar 是 UTF-16）再翻成 UTF-8 + VT 序列。
 *   2) **剪贴板要 Win32 API**。OSC 5522 在 Windows 的 cmd / PowerShell 里没人应答
 *      （conhost 不实现这条协议，DECRQM `?5522$p` 零应答，与 deepin-terminal 同款），
 *      所以 Windows 上「用户眼前那块板子」只能从 OpenClipboard 读。
 *   3) **环境变量表**。Uya 运行时按 POSIX 的 `argv + argc + 1` 取 envp，Windows 的
 *      CRT 不保证这个邻接布局 —— 实测取到空指针，于是 getenv 对任何变量都返回 null
 *      （HOME / PATH / DEEPSEEK_API_KEY 全部取不到）。这里从 Win32 环境块重建一份。
 *   4) **POSIX-only 符号**。共享源码里有 setsid / setenv / sigaction（Linux 上是
 *      glibc 符号），Windows 上既没有声明也没有实现，链接期就是 undefined。
 *
 * 硬约束（别踩）：
 *   * 所有函数在**非 Windows 目标下不声明**（整块被 `#if defined(_WIN32)` 关掉），
 *     所以本头文件只由 Makefile 的 `windows` 目标 `-include`，Linux 构建看不见它。
 *   * 只 include 最低限度的系统头；uya 生成的 uya_part1_types.h 自带 int64_t /
 *     size_t，别在这里拉进 glibc 的 <sys/types.h>（会变成满屏 conflicting types）。
 *   * 本文件里的每一条注释都对应一个在真机（dockur/windows 的 Win10）上量过的
 *     行为，改动前先读 src/cshim/win32_agent.c 的文件头。
 */
#ifndef UYA_AGENT_WIN32_AGENT_H
#define UYA_AGENT_WIN32_AGENT_H

#if defined(_WIN32)

#include <stdint.h>

/* ---- 环境与进程 ---- */

/* 启动时的一次性初始化：标准流切二进制模式，并把「运行在这个进程上的那个
 * 控制台」准备好（没有就申请一个，代码页切 UTF-8）。返回非 0 = 输出侧可用。 */
int32_t uya_win_prepare(void);

/* 还原 uya_win_prepare 改过的一切（退出路径要调）。 */
void uya_win_restore(void);

/* 从 Win32 环境块重建一份 UTF-8 的 envp（"K=V" 数组，NULL 结尾）。
 * 返回 NULL 表示取不到（调用方保持原样）。 */
char **uya_win_envp(void);

/* ---- 控制台 ---- */

/* stdin 是不是真正的控制台（管道 / 文件 / 计划任务重定向都是假）。 */
/* 时钟粒度是否拿到了 1ms（0 = 没拿到）。见实现文件头的「时钟粒度必须是 1ms」。 */
int32_t uya_win_timer_period(void);

int32_t uya_win_is_console(void);

/* 读 stdin，**永不阻塞**。返回：>0 字节数；0 = EOF（仅重定向场景）；-1 = 本轮
 * 没有数据（与 POSIX 的 EAGAIN 同义，调用方继续轮询）。
 * `timeout_ms > 0` 时最多等这么久（控制台用 WaitForSingleObject，管道按 1ms 分片
 * 问 PeekNamedPipe）；`timeout_ms == 0` 是纯非阻塞探测。 */
int32_t uya_win_read(char *buf, int32_t cap, int32_t timeout_ms);

/* 宿主控制台窗口尺寸（列 / 行）写进 out[0] / out[1]。成功返回 1。 */
int32_t uya_win_size(int32_t *out);

/* ---- 剪贴板（Windows 上 5522 的替代来源） ---- */

/* 剪贴板里有什么：0 = 空 / 都不认识，1 = 只有文本，2 = 有图（DIB）。 */
int32_t uya_win_clip_kind(void);

/* 读剪贴板文本（优先 CF_UNICODETEXT，回退 CF_TEXT 按 CP_ACP 转 UTF-8）。
 * 返回 UTF-8 字节数（0 = 没有文本），<0 = 打开剪贴板失败。 */
int32_t uya_win_clip_text(char *buf, int32_t cap);

/* 读剪贴板位图，返回**原始 CF_DIB 字节**（BITMAPINFOHEADER + 调色板 + 像素），
 * 解析与像素格式转换在 Uya 侧做（media/clipwin.uya），这里只负责搬字节。
 * 返回字节数（0 = 没有位图），<0 = 打开剪贴板失败 / 缓冲不够。 */
int32_t uya_win_clip_dib(char *buf, int32_t cap);

/* ---- POSIX-only 符号的垫片（共享源码里有调用，Windows 没有） ----
 * 语义刻意做成「尽力而为的 no-op」：这些调用点全在 fork/信号路径上，而 Windows
 * 上那条路本来就走不通（没有 fork），能编过、能链接、不崩就够了。 */
int setsid(void);
int setenv(const char *name, const char *value, int overwrite);

/* sigx 绑的是宿主 glibc 的 sigaction；Windows 上没有信号，装处理器是 no-op。
 * 结构体由 uya 侧定义（struct SigxAction），这里只用指针，不碰布局。 */
struct SigxAction;
int sigaction(int sig, const struct SigxAction *act, struct SigxAction *old);

#endif /* _WIN32 */
#endif /* UYA_AGENT_WIN32_AGENT_H */
