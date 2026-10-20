/* win32_agent.c — Windows 目标平台垫片实现（控制台输入 + 剪贴板 + 环境块）
 *
 * 这份代码里的每一条都对应一个在真机（dockur/windows 的 Win10 客户机）上量过的
 * 行为，改动前先读：
 *
 *  * **控制台输入不能靠 _read**。conhost 的字节式读取按「控制台输入代码页」编码：
 *    把输入代码页切成 65001 之后，一个汉字只交出一个字节（实测打「你好」读回来是
 *    0x60 0x60），上层看到的就是「输入一个字符就换行」。ReadConsoleW 又会在 VT
 *    输入模式下把方向键 / F 键整条丢掉。所以字符输入一律自己读 INPUT_RECORD
 *    （ReadConsoleInputW）：uChar 是 UTF-16，与代码页无关，自己转 UTF-8；特殊键
 *    自己翻成 VT 序列 —— 这套翻译规则与 conhost 自己的一致（方向键 = 1b 5b 41）。
 *  * **回车必须是单个 CR**。终端里 Enter 产生 CRLF（或两条记录），直接把字节转发
 *    出去，TUI 会把一次回车当成两次提交；这里按「上一个发出的字节是不是 CR」收敛。
 *  * **退格送 DEL(0x7f)**：ReadConsoleInputW 给的 uChar 是 0x08，而 xterm 的约定是
 *    0x7f，TUI 的键解码器只认后者。
 *  * **噪声记录要吃掉**：焦点 / 鼠标 / 窗口尺寸 / 按键抬起这些记录不产出字符，
 *    若按「可读就去读」的老写法会读到一个空字节序列后**永久阻塞**（实测控制台上
 *    会话冻死）。这里改成「Peek + Read 一条一条翻译」，噪声就地消费。
 *  * **没有控制台时要自己申请一个**：计划任务 / 服务 / `start /b` 重定向场景下
 *    stdin 不是控制台，读之前先 AllocConsole，否则连键盘都摸不到。**不要**先
 *    FreeConsole 再 AllocConsole（那一对在服务会话里偶发卡死）。
 *  * **时钟粒度必须是 1ms**：conhost / 服务会话的默认定时器粒度是 **15.6ms** ——
 *    实测 `Sleep(1)` 真睡 15ms、`Sleep(16)` 真睡 31ms。事件循环（`rt_run`）靠
 *    `Sleep` 推进 tick，默认粒度下每个 tick 都被放大约一倍，`rt_sleep(40)` 实测要
 *    62ms，于是自测的定时预算（`async-rt`：三次 40ms 必须落在 100–1200ms）与
 *    「取消 ≤400ms 收口」全都不稳。`timeBeginPeriod(1)` 把粒度压到 1ms（Win10 起
 *    它只影响本进程，不再全局改系统）；退出时 `timeEndPeriod(1)` 还回去。
 *  * **剪贴板**：Windows 的 cmd / PowerShell（conhost）**不实现 OSC 5522** ——
 *    DECRQM `ESC[?5522$p` 零应答，与 deepin-terminal 同款。所以 Windows 上
 *    「用户眼前那块板子」只能走 OpenClipboard；5522 客户端照旧保留，用户若在
 *    kitty / ghostty / Windows Terminal 里跑就会命中它，命中不了再落到这里。
 *  * **剪贴板会被别的进程占着**：OpenClipboard 失败是常态（输入法、浏览器都在抢），
 *    实测连抢 10 次（每次 5ms）几乎总能拿到，所以带重试。
 *  * **位图给的是 DIB 不是文件**：CF_DIB 是 BITMAPINFOHEADER + 调色板 + 像素，
 *    没有文件头。解析放在 Uya 侧（media/clipwin.uya），这里只搬字节 —— 这样
 *    「DIB 的像素格式怎么转 RGBA」是可以用自测钉住的纯函数，而不是 C 里的黑盒。
 *
 * 非 Windows 目标下本文件是空 TU（整体被 #if 关掉），Linux 构建不受影响。
 */
#if defined(_WIN32)

#include "win32_agent.h"

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <io.h>
#include <fcntl.h>

/* ---------------------------------------------------------------- 通用小工具 */

static HANDLE win_std_handle(DWORD which) {
    HANDLE h = GetStdHandle(which);
    if (h == INVALID_HANDLE_VALUE || h == NULL) {
        return NULL;
    }
    return h;
}

/* 是否是真的控制台句柄（管道 / 文件 / NUL 都不算）。 */
static int win_real_console(HANDLE h) {
    DWORD mode = 0;
    if (h == NULL || h == INVALID_HANDLE_VALUE) {
        return 0;
    }
    return GetConsoleMode(h, &mode) != 0;
}

/* 按 UTF-8 写一个码位，返回字节数；放不下返回 0（剩下的一次再取，绝不拆字符）。 */
static int32_t win_utf8_put(char *out, int32_t cap, uint32_t cp) {
    if (cp < 0x80u) {
        if (cap < 1) return 0;
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800u) {
        if (cap < 2) return 0;
        out[0] = (char)(0xC0u | (cp >> 6));
        out[1] = (char)(0x80u | (cp & 0x3Fu));
        return 2;
    }
    if (cp < 0x10000u) {
        if (cap < 3) return 0;
        out[0] = (char)(0xE0u | (cp >> 12));
        out[1] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
        out[2] = (char)(0x80u | (cp & 0x3Fu));
        return 3;
    }
    if (cap < 4) return 0;
    out[0] = (char)(0xF0u | (cp >> 18));
    out[1] = (char)(0x80u | ((cp >> 12) & 0x3Fu));
    out[2] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
    out[3] = (char)(0x80u | (cp & 0x3Fu));
    return 4;
}

/* ---------------------------------------------------------------- 控制台状态 */

static DWORD g_in_mode;
static DWORD g_out_mode;
static int g_in_saved;
static int g_out_saved;
static UINT g_out_cp;
static UINT g_in_cp;
static int g_cp_saved;
static int g_prepared;
/* timeBeginPeriod(1) 是否拿到（见文件头）；退出要成对调 timeEndPeriod。 */
static int g_timer_period;
/* 落单的高代理（非 BMP 字符的 KEY_EVENT 可能拆成两条记录）。 */
static WCHAR g_pending_high;
/* 上一次发出的最后一个字节是不是 CR（CRLF 收敛，见 key_event_bytes）。 */
static int g_prev_cr;

/* 时钟粒度是否拿到了 1ms（自测与环境诊断用；0 = 没拿到，仍是 15.6ms 粒度）。 */
int32_t uya_win_timer_period(void) {
    return g_timer_period;
}

int32_t uya_win_is_console(void) {
    return win_real_console(win_std_handle(STD_INPUT_HANDLE)) ? 1 : 0;
}

/* 打开 CONOUT$：判断「本进程有没有挂着控制台」要用它，而不是看 stdout 是不是
 * 控制台 —— `uya-agent > out.txt` 时 stdout 是文件，但控制台明明还在。 */
static HANDLE win_conout(void) {
    return CreateFileA("CONOUT$", GENERIC_READ | GENERIC_WRITE,
                       FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                       OPEN_EXISTING, 0, NULL);
}

int32_t uya_win_prepare(void) {
    HANDLE h_in = win_std_handle(STD_INPUT_HANDLE);
    HANDLE h_out = win_std_handle(STD_OUTPUT_HANDLE);
    HANDLE h_con = win_conout();
    DWORD m = 0;

    /* prepare 可能被调用两次（启动一次、进 TUI 时兜底一次）。第二次再「保存现场」
     * 保存到的就是已经改过的值，restore 也就回不去了。 */
    if (g_prepared) {
        return g_out_saved;
    }
    g_pending_high = 0;
    g_prev_cr = 0;

    /* 时钟粒度 1ms（见文件头「时钟粒度必须是 1ms」）。返回值忽略：即使失败也只是
     * 回到 15.6ms 的老行为，不影响正确性、只影响预算类的自测。 */
    {
        /* 诊断：把结果写一次（`UYA_WIN_TRACE=<路径>` 才落盘，默认零开销）。 */
        const UINT tp = timeBeginPeriod(1);
        g_timer_period = (tp == TIMERR_NOERROR) ? 1 : 0;
        {
            /* 诊断走 stderr（`--selftest` 的输出就是它）：临时用，拿到数字就删。 */
        }
    }

    /* 标准流一律二进制：导出的字节（图片、剪贴板内容）必须原样，
     * 文本模式会把 0x0A 改成 0x0D 0x0A。控制台写走 WriteConsoleW，不受影响。 */
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);

    if (h_con == INVALID_HANDLE_VALUE) {
        /* 真的没有控制台：申请一个。目的不是显示，而是让「读键盘」这条路存在。 */
        if (AllocConsole()) {
            h_con = win_conout();
            h_in = win_std_handle(STD_INPUT_HANDLE);
            h_out = win_std_handle(STD_OUTPUT_HANDLE);
        }
    }
    /* 代码页切 UTF-8：图形界面的复制粘贴、重定向落盘都按 UTF-8 解释。
     * 输出侧另有一条 WriteConsoleW 的路，所以这里主要是给输入与子进程用。 */
    g_out_cp = GetConsoleOutputCP();
    g_in_cp = GetConsoleCP();
    g_cp_saved = 1;
    SetConsoleOutputCP(65001u);
    SetConsoleCP(65001u);

    /* 输入：关掉行编辑与回显（TUI 自己管），关掉鼠标与窗口事件（噪声）。
     * **不开 ENABLE_VIRTUAL_TERMINAL_INPUT**：它会把按键按控制台输入代码页编码，
     * CP65001 下汉字会被截断（见文件头）。 */
    if (win_real_console(h_in) && GetConsoleMode(h_in, &m)) {
        DWORD want;
        g_in_mode = m;
        g_in_saved = 1;
        want = m & ~(DWORD)(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT |
                            ENABLE_PROCESSED_INPUT | ENABLE_MOUSE_INPUT |
                            ENABLE_WINDOW_INPUT);
        want |= ENABLE_EXTENDED_FLAGS;
        SetConsoleMode(h_in, want);
    }
    /* 输出：打开 VT 处理，TUI 的 ANSI 序列才会被 conhost 解释成真效果。
     * 刻意**不加** DISABLE_NEWLINE_AUTO_RETURN（加了以后 `\n` 只下移不回车，
     * 屏幕上就是阶梯状缩进）。用 CONOUT$ 而不是 stdout：stdout 被重定向时它才是
     * 那个真控制台。 */
    if (h_con != INVALID_HANDLE_VALUE && GetConsoleMode(h_con, &m)) {
        g_out_mode = m;
        g_out_saved = 1;
        SetConsoleMode(h_con, m | ENABLE_PROCESSED_OUTPUT |
                                 ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
    if (h_con != INVALID_HANDLE_VALUE) {
        CloseHandle(h_con);
    }
    g_prepared = 1;
    (void)h_out;
    return g_out_saved;
}

void uya_win_restore(void) {
    HANDLE h_in = win_std_handle(STD_INPUT_HANDLE);

    if (!g_prepared && !g_cp_saved) {
        return;
    }
    if (g_cp_saved) {
        if (g_out_cp != 0) SetConsoleOutputCP(g_out_cp);
        if (g_in_cp != 0) SetConsoleCP(g_in_cp);
        g_cp_saved = 0;
    }
    if (g_in_saved && win_real_console(h_in)) {
        SetConsoleMode(h_in, g_in_mode);
    }
    if (g_out_saved) {
        HANDLE h_con = win_conout();
        if (h_con != INVALID_HANDLE_VALUE) {
            SetConsoleMode(h_con, g_out_mode);
            CloseHandle(h_con);
        }
    }
    if (g_timer_period) {
        timeEndPeriod(1);
        g_timer_period = 0;
    }
    g_in_saved = 0;
    g_out_saved = 0;
    g_prepared = 0;
}

int32_t uya_win_size(int32_t *out) {
    CONSOLE_SCREEN_BUFFER_INFO info;
    HANDLE h_con = win_conout();

    if (out == NULL || h_con == INVALID_HANDLE_VALUE) {
        return 0;
    }
    if (!GetConsoleScreenBufferInfo(h_con, &info)) {
        CloseHandle(h_con);
        return 0;
    }
    CloseHandle(h_con);
    /* srWindow 才是「窗口」；dwSize 是屏幕缓冲区，可以远大于窗口。 */
    out[0] = (int32_t)(info.srWindow.Right - info.srWindow.Left + 1);
    out[1] = (int32_t)(info.srWindow.Bottom - info.srWindow.Top + 1);
    return (out[0] > 0 && out[1] > 0) ? 1 : 0;
}

/* ---------------------------------------------------------------- 输入翻译 */

/* dwControlKeyState → 简化修饰键位（1=Shift 2=Alt 4=Ctrl）。 */
static int32_t win_key_mods(DWORD state) {
    int32_t m = 0;
    if ((state & SHIFT_PRESSED) != 0) m |= 1;
    if ((state & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0) m |= 2;
    if ((state & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0) m |= 4;
    return m;
}

/* 不带字符的按键 → xterm 形式的 VT 序列（与 conhost 自己那套翻译一致）。
 * 返回字节数；不认识的键返回 0（丢弃）。 */
static int32_t win_vt_key(WORD vk, int32_t mods, char *out, int32_t cap) {
    /* xterm 的修饰键参数：1 + 1*Shift + 2*Alt + 4*Ctrl；没有修饰时用短形式。 */
    const int m = 1 + ((mods & 1) != 0 ? 1 : 0) + ((mods & 2) != 0 ? 2 : 0) +
                  ((mods & 4) != 0 ? 4 : 0);
    char seq[16];
    char num = 0;
    char letter = 0;
    int n = 0;

    switch (vk) {
        case VK_UP:     letter = 'A'; break;
        case VK_DOWN:   letter = 'B'; break;
        case VK_RIGHT:  letter = 'C'; break;
        case VK_LEFT:   letter = 'D'; break;
        case VK_HOME:   letter = 'H'; break;
        case VK_END:    letter = 'F'; break;
        case VK_INSERT: num = 2; break;
        case VK_DELETE: num = 3; break;
        case VK_PRIOR:  num = 5; break;
        case VK_NEXT:   num = 6; break;
        case VK_F1:  letter = 'P'; break;
        case VK_F2:  letter = 'Q'; break;
        case VK_F3:  letter = 'R'; break;
        case VK_F4:  letter = 'S'; break;
        case VK_F5:  num = 15; break;
        case VK_F6:  num = 17; break;
        case VK_F7:  num = 18; break;
        case VK_F8:  num = 19; break;
        case VK_F9:  num = 20; break;
        case VK_F10: num = 21; break;
        case VK_F11: num = 23; break;
        case VK_F12: num = 24; break;
        default: return 0;
    }
    if (num != 0) {
        n = (m == 1) ? snprintf(seq, sizeof(seq), "\x1b[%d~", (int)num)
                     : snprintf(seq, sizeof(seq), "\x1b[%d;%d~", (int)num, m);
    } else if (letter == 'P' || letter == 'Q' || letter == 'R' || letter == 'S') {
        /* F1~F4 的短形式是 SS3（ESC O P），带修饰才是 CSI 1;m P。 */
        n = (m == 1) ? snprintf(seq, sizeof(seq), "\x1bO%c", letter)
                     : snprintf(seq, sizeof(seq), "\x1b[1;%d%c", m, letter);
    } else {
        n = (m == 1) ? snprintf(seq, sizeof(seq), "\x1b[%c", letter)
                     : snprintf(seq, sizeof(seq), "\x1b[1;%d%c", m, letter);
    }
    if (n <= 0 || n > cap) {
        return 0;
    }
    memcpy(out, seq, (size_t)n);
    return (int32_t)n;
}

/* 一条「按下」的 KEY_EVENT 翻成字节。返回 0 = 这条记录不产出数据。 */
static int32_t win_key_bytes(const KEY_EVENT_RECORD *k, char *out, int32_t cap) {
    const int32_t mods = win_key_mods(k->dwControlKeyState);
    uint32_t cp = (uint32_t)k->uChar.UnicodeChar;
    int32_t n = 0;

    if (cp == 0) {
        /* 没有字符的键：先处理 Ctrl+空格（xterm 送 NUL），其余交给 VT 序列表。 */
        if ((mods & 4) != 0 && k->wVirtualKeyCode == VK_SPACE) {
            if (cap < 1) return 0;
            out[0] = 0;
            return 1;
        }
        return win_vt_key(k->wVirtualKeyCode, mods, out, cap);
    }
    if (k->wVirtualKeyCode == VK_BACK) {
        /* 退格按 xterm 的约定送 DEL(0x7f)。 */
        if (cap < 1) return 0;
        out[0] = 0x7f;
        return 1;
    }
    if (k->wVirtualKeyCode == VK_TAB && (mods & 1) != 0) {
        if (cap < 3) return 0;
        memcpy(out, "\x1b[Z", 3);
        return 3;
    }
    /* 重复的 LF（粘贴的 CRLF 被 conhost 拆成 CR + LF）：只留前面那个 CR。 */
    if (cp == 0x0Au && g_prev_cr) {
        g_prev_cr = 0;
        return 0;
    }
    /* 代理对：IME 打出的非 BMP 字符（emoji 之类）拆成高 / 低两条记录。 */
    if (cp >= 0xD800u && cp <= 0xDBFFu) {
        g_pending_high = (WCHAR)cp;
        return 0;
    }
    if (cp >= 0xDC00u && cp <= 0xDFFFu) {
        if (g_pending_high == 0) return 0;
        cp = 0x10000u + ((((uint32_t)g_pending_high) - 0xD800u) << 10) +
             (cp - 0xDC00u);
        g_pending_high = 0;
    } else {
        g_pending_high = 0;
    }
    if ((mods & 2) != 0 && (mods & 4) == 0 && cp >= 0x20u) {
        /* Alt+字符：xterm 送 ESC 前缀。AltGr（Ctrl+Alt）不算 Alt。 */
        int32_t put;
        if (cap < 2) return 0;
        out[0] = 0x1b;
        put = win_utf8_put(out + 1, cap - 1, cp);
        n = (put > 0) ? (int32_t)(1 + put) : 0;
    } else {
        n = win_utf8_put(out, cap, cp);
    }
    if (n > 0) {
        g_prev_cr = (out[n - 1] == '\r') ? 1 : 0;
    }
    return n;
}

/* 把排队中的 INPUT_RECORD 翻成字节。>0 字节数；-1 = 这一轮没有可翻译的记录。
 * 控制台永不返回 0（0 在上一层表示 stdin EOF）。cap 至少留 8 字节给一条记录。 */
static int32_t win_read_events(HANDLE h_in, char *buf, int32_t cap) {
    int32_t w = 0;
    DWORD avail = 0;

    if (!GetNumberOfConsoleInputEvents(h_in, &avail) || avail == 0) {
        return -1;
    }
    while (avail > 0 && cap - w >= 8) {
        INPUT_RECORD rec;
        DWORD got = 0;
        int32_t n;
        /* 先 Peek 再 Read：Peek 不阻塞，也保证随后的 ReadConsoleInputW 有东西可拿。 */
        if (!PeekConsoleInputW(h_in, &rec, 1, &got) || got == 0) {
            break;
        }
        if (!ReadConsoleInputW(h_in, &rec, 1, &got) || got == 0) {
            break;
        }
        avail--;
        /* 焦点 / 鼠标 / 窗口尺寸 / 按键抬起：对上层没有意义，直接吃掉。 */
        if (rec.EventType != KEY_EVENT || !rec.Event.KeyEvent.bKeyDown) {
            continue;
        }
        n = win_key_bytes(&rec.Event.KeyEvent, buf + w, cap - w);
        if (n > 0) {
            w += n;
        }
    }
    return (w > 0) ? w : -1;
}

/* 句柄现在能不能读：0=没有数据 1=有数据 2=对端已关闭 -1=错误。
 * 同步管道句柄**只在写端关闭时**才被唤醒，所以「先等再 ReadFile」会阻塞在其实
 * 没有数据的管道上；先问再读，保证任何一次读都不会阻塞。 */
static int win_handle_readable(HANDLE h) {
    DWORD type;
    DWORD mode = 0;

    if (h == NULL || h == INVALID_HANDLE_VALUE) {
        return -1;
    }
    type = GetFileType(h);
    if (type == FILE_TYPE_PIPE) {
        DWORD avail = 0;
        if (PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) {
            return avail > 0 ? 1 : 0;
        }
        return (GetLastError() == ERROR_BROKEN_PIPE) ? 2 : -1;
    }
    if (type == FILE_TYPE_CHAR) {
        DWORD queued = 0;
        if (GetConsoleMode(h, &mode)) {
            if (!GetNumberOfConsoleInputEvents(h, &queued)) {
                return 0;
            }
            return queued > 0 ? 1 : 0;
        }
        /* 不是控制台的字符设备（NUL 之类）：放行，让 read 自己拿 EOF。 */
        return 1;
    }
    return 1;
}

int32_t uya_win_read(char *buf, int32_t cap, int32_t timeout_ms) {
    HANDLE h_in = win_std_handle(STD_INPUT_HANDLE);
    int32_t n;

    if (buf == NULL || cap <= 0 || h_in == NULL) {
        return -1;
    }
    if (win_real_console(h_in)) {
        n = win_read_events(h_in, buf, cap);
        if (n > 0) {
            return n;
        }
        if (timeout_ms <= 0) {
            return -1;
        }
        if (WaitForSingleObject(h_in, (DWORD)timeout_ms) != WAIT_OBJECT_0) {
            return -1;
        }
        return win_read_events(h_in, buf, cap);
    }
    /* 非控制台（管道 / 文件 / 计划任务重定向）：按字节流读，读完自然 EOF。
     * 带超时的等待按 1ms 分片问 PeekNamedPipe —— 句柄本身不会在「有数据」时被
     * 唤醒（见 win_handle_readable 的注释）。 */
    {
        int waited = 0;
        for (;;) {
            const int ready = win_handle_readable(h_in);
            int got;
            if (ready == 2) {
                return 0;
            }
            if (ready < 0) {
                return -1;
            }
            if (ready == 1) {
                got = _read(_fileno(stdin), buf, (unsigned int)cap);
                if (got < 0) {
                    return -1;
                }
                return got;
            }
            if (waited >= timeout_ms) {
                return -1;
            }
            Sleep(1);
            waited++;
        }
    }
}

/* ---------------------------------------------------------------- 环境块 */

/* 从 Win32 环境块重建一份 UTF-8 的 envp。
 * 为什么要重建：Uya 运行时是拿 `argv + argc + 1` 取 envp 的（POSIX 的紧邻布局），
 * Windows 的 CRT 不保证这个邻接关系 —— 实测取到的是空指针，于是 getenv 对**任何**
 * 变量都返回 null（HOME / PATH / DEEPSEEK_API_KEY 全都取不到）。 */
char **uya_win_envp(void) {
    static char **block = NULL;
    LPWSTR ws;
    LPWSTR p;
    int count = 0;
    int i = 0;
    size_t bytes = 0;

    if (block != NULL) {
        return block;
    }
    ws = GetEnvironmentStringsW();
    if (ws == NULL) {
        return NULL;
    }
    /* 第一遍：数条目、算 UTF-8 字节数。跳过以 '=' 开头的隐藏项（如 "=C:"）。 */
    for (p = ws; *p != 0; p += wcslen(p) + 1) {
        int need;
        if (*p == L'=') continue;
        need = WideCharToMultiByte(CP_UTF8, 0, p, -1, NULL, 0, NULL, NULL);
        if (need <= 0) continue;
        count++;
        bytes += (size_t)need;
    }
    if (count == 0) {
        FreeEnvironmentStringsW(ws);
        return NULL;
    }
    /* 一遍分配：指针数组 + 字符串数据，避免逐条 new/free。 */
    block = (char **)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
                               sizeof(char *) * (size_t)(count + 1) + bytes);
    if (block == NULL) {
        FreeEnvironmentStringsW(ws);
        return NULL;
    }
    {
        char *data = (char *)block + sizeof(char *) * (size_t)(count + 1);
        for (p = ws; *p != 0 && i < count; p += wcslen(p) + 1) {
            int need;
            if (*p == L'=') continue;
            need = WideCharToMultiByte(CP_UTF8, 0, p, -1, NULL, 0, NULL, NULL);
            if (need <= 0) continue;
            if (WideCharToMultiByte(CP_UTF8, 0, p, -1, data, need, NULL, NULL) <= 0) {
                continue;
            }
            block[i] = data;
            i++;
            data += need;
        }
        block[i] = NULL;
    }
    FreeEnvironmentStringsW(ws);
    return block;
}

/* ---------------------------------------------------------------- 剪贴板 */

/* 打开剪贴板（带重试）。返回 1 = 拿到了（调用方负责 Close）。
 * 为什么重试：输入法 / 浏览器 / 剪贴板管理器都在抢这个全局锁，实测连抢 10 次
 * （每次 5ms）几乎总能拿到；一次失败就放弃会让「按一下没反应」变成常态。 */
static int win_clip_open(void) {
    int i = 0;
    while (i < 10) {
        if (OpenClipboard(NULL)) {
            return 1;
        }
        Sleep(5);
        i++;
    }
    return 0;
}

int32_t uya_win_clip_kind(void) {
    int32_t kind = 0;

    if (!win_clip_open()) {
        return 0;
    }
    if (IsClipboardFormatAvailable(CF_DIB) ||
        IsClipboardFormatAvailable(CF_DIBV5)) {
        kind = 2;
    } else if (IsClipboardFormatAvailable(CF_UNICODETEXT) ||
               IsClipboardFormatAvailable(CF_TEXT)) {
        kind = 1;
    }
    CloseClipboard();
    return kind;
}

/* UTF-16 → UTF-8，返回字节数（不含结尾 0）；cap 不够返回 -1。 */
static int32_t win_utf16_to_utf8(const WCHAR *src, char *buf, int32_t cap) {
    int need = WideCharToMultiByte(CP_UTF8, 0, src, -1, NULL, 0, NULL, NULL);
    if (need <= 0) {
        return 0;
    }
    if (need - 1 > cap) {
        return -1;
    }
    if (WideCharToMultiByte(CP_UTF8, 0, src, -1, buf, cap, NULL, NULL) <= 0) {
        return 0;
    }
    return need - 1;
}

int32_t uya_win_clip_text(char *buf, int32_t cap) {
    HANDLE h;
    int32_t out = 0;

    if (buf == NULL || cap <= 0) {
        return -1;
    }
    if (!win_clip_open()) {
        return -1;
    }
    h = GetClipboardData(CF_UNICODETEXT);
    if (h != NULL) {
        const WCHAR *ws = (const WCHAR *)GlobalLock(h);
        if (ws != NULL) {
            out = win_utf16_to_utf8(ws, buf, cap);
            GlobalUnlock(h);
        }
        CloseClipboard();
        if (out > 0) {
            buf[out] = 0;
        }
        return out;
    }
    /* 回退 CF_TEXT。**先按 UTF-8 严格试一次，合法就直接用** —— 实测 PowerShell 的
     * `Set-Clipboard`（以及 .NET / 浏览器的多数实现）写的 CF_TEXT 就是 UTF-8 字节，
     * 而中文 Windows 的 CP_ACP 是 936：无条件按 936 转一次会把「中文测试」变成
     * 「涓枃娴嬭瘯」（UTF-8 字节被当双字节 GBK 解）。
     *
     * 判据用 `MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, …)`：它不是「猜编码」，
     * 是一个**可证伪的合法性检查** —— 真 ANSI（GBK）字节几乎必然含非法 UTF-8 序列，
     * 会在这里失败，于是才落到 CP_ACP。两条路都留，是因为剪贴板的 CF_TEXT 本来就没有
     * 编码声明，而这是唯一能同时正确解释「现代程序写的 UTF-8」与「老程序写的 ANSI」的
     * 顺序（试 UTF-8 失败比试 936 失败可靠得多：936 几乎接受任意字节对）。 */
    h = GetClipboardData(CF_TEXT);
    if (h != NULL) {
        const char *as = (const char *)GlobalLock(h);
        if (as != NULL) {
            UINT cp = CP_UTF8;
            int need = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                           as, -1, NULL, 0);
            if (need <= 0) {
                cp = CP_ACP;
                need = MultiByteToWideChar(CP_ACP, 0, as, -1, NULL, 0);
            }
            if (need > 0) {
                WCHAR *tmp = (WCHAR *)malloc(sizeof(WCHAR) * (size_t)need);
                if (tmp != NULL) {
                    const int conv = (cp == CP_UTF8)
                        ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                              as, -1, tmp, need)
                        : MultiByteToWideChar(CP_ACP, 0, as, -1, tmp, need);
                    if (conv > 0) {
                        out = win_utf16_to_utf8(tmp, buf, cap);
                    }
                    free(tmp);
                }
            }
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    if (out > 0) {
        buf[out] = 0;
    }
    return out;
}

int32_t uya_win_clip_dib(char *buf, int32_t cap) {
    HANDLE h;
    int32_t out = -1;

    if (buf == NULL || cap <= 0) {
        return -1;
    }
    if (!win_clip_open()) {
        return -1;
    }
    h = GetClipboardData(CF_DIB);
    if (h == NULL) {
        h = GetClipboardData(CF_DIBV5);
    }
    if (h != NULL) {
        const SIZE_T bytes = GlobalSize(h);
        const void *src = GlobalLock(h);
        if (src != NULL && bytes > 0 && (int32_t)bytes <= cap) {
            memcpy(buf, src, (size_t)bytes);
            out = (int32_t)bytes;
        } else if (src != NULL && bytes > 0) {
            out = -2;      /* 缓冲不够：调用方据 BIG 处理（明确拒绝，不截断） */
        }
        if (src != NULL) {
            GlobalUnlock(h);
        }
    } else {
        out = 0;
    }
    CloseClipboard();
    return out;
}

/* ---------------------------------------------------------------- POSIX 垫片 */

/* setsid：Windows 没有会话概念。返回 0（成功）—— 调用点全在 fork 之后，那条路
 * 在 Windows 上根本走不到（见各调用处的 std.cfg 分支）。 */
int setsid(void) {
    return 0;
}

int setenv(const char *name, const char *value, int overwrite) {
    if (name == NULL || value == NULL) {
        return -1;
    }
    if (!overwrite) {
        const char *old = getenv(name);
        if (old != NULL) {
            return 0;
        }
    }
    return _putenv_s(name, value);
}

/* sigaction：Windows 没有信号。装处理器是 no-op，返回 0（成功）让调用方继续。 */
int sigaction(int sig, const struct SigxAction *act, struct SigxAction *old) {
    (void)sig;
    (void)act;
    (void)old;
    return 0;
}

#endif /* _WIN32 */
