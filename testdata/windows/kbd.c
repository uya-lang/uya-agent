/*
 * kbd.c - 在真实控制台里跑一个程序，并**真的往里敲键**（然后把屏幕读回来）。
 *
 * 为什么需要它：cap.c 只测「程序写了什么、屏幕上显示什么」，一个字都不输入。而输入路径上的
 * 缺陷（例如回车被翻译成 CRLF、方向键没变成 VT 序列）只有真的走一遍
 * 「按键 → conhost 生成 KEY_EVENT → 子进程读取」才暴露得出来。用 WriteConsoleInputW
 * 注入 KEY_EVENT 走的就是同一条路，因此这是「用户按键」的忠实替身 —— 往管道里写字节做不到。
 *
 * 每个按键都按真实键盘的样子成对注入 KEY_DOWN + KEY_UP（子进程必须忽略抬起记录，
 * 这一条也要被测到）。
 *
 * 用法: kbd.exe <报告文件> <cpmode: keep|936|65001> <按键表> <程序> [参数...]
 *
 * 按键表是逗号分隔的记号（也接受不带逗号的旧写法：纯十六进制字节串）：
 *   a z 0 9 SP              普通字符
 *   CR LF BS TAB ESC DEL    控制键
 *   UP DOWN LEFT RIGHT      方向键
 *   HOME END INS DELK PGUP PGDN
 *   F1 .. F12               功能键
 *   C-a .. C-z              控制组合键
 *   U+4E2D                  按 Unicode 码位（支持非 BMP：自动拆成代理对）
 *   CH:XX                   直接给一个 UTF-16 码元
 *   VK:XX                   只给虚拟键码（无字符，用于测「按了但不产生字符」的键）
 *
 * 报告为 UTF-8，屏幕内容在 `== screen begin ==` / `== screen end ==` 之间（与 cap.c 一致）。
 */
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_ROWS 200
#define MAX_KEYS 512

static FILE *g_log;

static void logf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fflush(g_log);
}

static void emit_utf8(const wchar_t *w, int n) {
    int need = WideCharToMultiByte(CP_UTF8, 0, w, n, NULL, 0, NULL, NULL);
    char *tmp;
    if (need <= 0) return;
    tmp = (char *)malloc((size_t)need + 1);
    if (tmp == NULL) return;
    WideCharToMultiByte(CP_UTF8, 0, w, n, tmp, need, NULL, NULL);
    tmp[need] = 0;
    fwrite(tmp, 1, (size_t)need, g_log);
    free(tmp);
}

static int rtrim(const wchar_t *w, int n) {
    while (n > 0) {
        wchar_t c = w[n - 1];
        if (c != L' ' && c != L'\t' && c != 0) break;
        n--;
    }
    return n;
}

/* 一个「要按的键」：虚拟键码 + 字符（码元）。 */
typedef struct {
    WORD vk;
    WCHAR ch;
} KeySpec;

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int hexnum(const char *s, int n, unsigned *out) {
    unsigned v = 0;
    int i;
    for (i = 0; i < n; i++) {
        int d = hexval((unsigned char)s[i]);
        if (d < 0) return 0;
        v = v * 16u + (unsigned)d;
    }
    *out = v;
    return 1;
}

/* 把 'A'-'Z' 之类的名字映射到虚拟键码（只有单字符名字才走这里）。 */
static WORD vk_of_char(WCHAR c) {
    if (c >= L'a' && c <= L'z') return (WORD)(c - 32);
    if (c >= L'A' && c <= L'Z') return (WORD)c;
    if (c >= L'0' && c <= L'9') return (WORD)c;
    if (c == L' ') return VK_SPACE;
    return 0;
}

static WORD scan_of(WORD vk) {
    WORD s = (WORD)MapVirtualKeyA(vk, MAPVK_VK_TO_VSC);
    return s;
}

/* 特殊键名表。 */
static const struct {
    const char *name;
    WORD vk;
    WCHAR ch;
} SPECIAL[] = {
    {"CR", VK_RETURN, L'\r'},
    {"LF", 0x0A, L'\n'},
    {"BS", VK_BACK, L'\b'},
    {"TAB", VK_TAB, L'\t'},
    {"ESC", VK_ESCAPE, L'\x1b'},
    {"DEL", VK_DELETE, 0},
    {"DELK", VK_DELETE, 0},
    {"UP", VK_UP, 0},
    {"DOWN", VK_DOWN, 0},
    {"LEFT", VK_LEFT, 0},
    {"RIGHT", VK_RIGHT, 0},
    {"HOME", VK_HOME, 0},
    {"END", VK_END, 0},
    {"INS", VK_INSERT, 0},
    {"PGUP", VK_PRIOR, 0},
    {"PGDN", VK_NEXT, 0},
    {"SP", VK_SPACE, L' '},
    {"F1", VK_F1, 0},
    {"F2", VK_F2, 0},
    {"F3", VK_F3, 0},
    {"F4", VK_F4, 0},
    {"F5", VK_F5, 0},
    {"F6", VK_F6, 0},
    {"F7", VK_F7, 0},
    {"F8", VK_F8, 0},
    {"F9", VK_F9, 0},
    {"F10", VK_F10, 0},
    {"F11", VK_F11, 0},
    {"F12", VK_F12, 0},
};

/* 解析一个记号，返回消耗的字节数（含分隔逗号；无逗号时正好到串尾）；0 表示解析失败。 */
static int parse_token(const char *s, KeySpec *out) {
    const char *comma = strchr(s, ',');
    int len = comma ? (int)(comma - s) : (int)strlen(s);
    /* 末尾没有逗号时只消耗 len 个字节，**不能**再 +1 —— 那会跳过结尾的 '\0'
     * 继续读后面的垃圾（实测表现为 bad_token=<乱码>）。 */
    int step = comma ? len + 1 : len;
    char name[32];
    unsigned v;
    size_t i;

    if (len <= 0 || len >= (int)sizeof(name)) return 0;
    memcpy(name, s, (size_t)len);
    name[len] = 0;
    out->vk = 0;
    out->ch = 0;

    /* CH:XXXX / VK:XX */
    if (len > 3 && (name[0] == 'C' || name[0] == 'c') && name[1] == 'H' && name[2] == ':') {
        if (!hexnum(name + 3, len - 3, &v) || v > 0xFFFFu) return 0;
        out->ch = (WCHAR)v;
        return step;
    }
    if (len > 3 && (name[0] == 'V' || name[0] == 'v') && name[1] == 'K' && name[2] == ':') {
        if (!hexnum(name + 3, len - 3, &v) || v > 0xFFFFu) return 0;
        out->vk = (WORD)v;
        return step;
    }
    /* U+XXXX */
    if (len > 2 && (name[0] == 'U' || name[0] == 'u') && name[1] == '+') {
        if (!hexnum(name + 2, len - 2, &v) || v > 0x10FFFFu) return 0;
        out->ch = (WCHAR)v;
        return step;
    }
    /* C-x 控制组合键 */
    if (len == 3 && (name[0] == 'C' || name[0] == 'c') && name[1] == '-') {
        char c = name[2];
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
        if (c >= '@' && c <= '_') {
            out->ch = (WCHAR)(c - '@');
            out->vk = (WORD)c;
            return step;
        }
        if (c == '?') {
            out->ch = 0x7f;
            return step;
        }
        return 0;
    }
    /* 特殊键名 */
    for (i = 0; i < sizeof(SPECIAL) / sizeof(SPECIAL[0]); i++) {
        if (strcmp(name, SPECIAL[i].name) == 0) {
            out->vk = SPECIAL[i].vk;
            out->ch = SPECIAL[i].ch;
            return step;
        }
    }
    /* 单个字符 */
    if (len == 1) {
        out->ch = (WCHAR)(unsigned char)name[0];
        out->vk = vk_of_char(out->ch);
        return step;
    }
    return 0;
}

static void fill_record(INPUT_RECORD *rec, const KeySpec *k, BOOL down) {
    ZeroMemory(rec, sizeof(*rec));
    rec->EventType = KEY_EVENT;
    rec->Event.KeyEvent.bKeyDown = down;
    rec->Event.KeyEvent.wRepeatCount = 1;
    rec->Event.KeyEvent.wVirtualKeyCode = k->vk;
    rec->Event.KeyEvent.wVirtualScanCode = scan_of(k->vk);
    rec->Event.KeyEvent.uChar.UnicodeChar = k->ch;
    /* 方向键/Home/End/PgUp/PgDn/Ins/Del 在真实键盘上是「扩展键」（扫描码带 E0 前缀，
     * dwControlKeyState 里有 ENHANCED_KEY）。少了这一位，注入的记录与真实按键不等价，
     * conhost 对它们的 VT 翻译就可能不生效（实测方向键一个字节都不产生）。 */
    if (k->vk == VK_UP || k->vk == VK_DOWN || k->vk == VK_LEFT || k->vk == VK_RIGHT ||
        k->vk == VK_HOME || k->vk == VK_END || k->vk == VK_PRIOR || k->vk == VK_NEXT ||
        k->vk == VK_INSERT || k->vk == VK_DELETE) {
        rec->Event.KeyEvent.dwControlKeyState = ENHANCED_KEY;
    }
}

int main(int argc, char **argv) {
    const char *out_path, *cp_mode, *keys_spec;
    KeySpec *keys;
    int nkeys = 0, i;
    HANDLE hOut, hIn;
    UINT out_before, in_before;
    CONSOLE_SCREEN_BUFFER_INFO info;
    char cmdline[16384];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    BOOL ok;
    DWORD ec = 0;
    DWORD wait_ms;
    int typed = 0;
    int legacy_hex;

    if (argc < 5) {
        fprintf(stderr, "usage: kbd <outfile> <cpmode: keep|936|65001> <keys> <prog> [args...]\n");
        return 2;
    }
    out_path = argv[1];
    cp_mode = argv[2];
    keys_spec = argv[3];

    g_log = fopen(out_path, "wb");
    if (g_log == NULL) {
        fprintf(stderr, "cannot open outfile: %s\n", out_path);
        return 2;
    }
    setvbuf(g_log, NULL, _IONBF, 0);

    hOut = CreateFileA("CONOUT$", GENERIC_READ | GENERIC_WRITE,
                       FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    logf("had_console=%d\n", hOut != INVALID_HANDLE_VALUE ? 1 : 0);
    if (hOut == INVALID_HANDLE_VALUE) {
        FreeConsole();
        if (AllocConsole()) {
            hOut = CreateFileA("CONOUT$", GENERIC_READ | GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
            logf("allocated_console=%d\n", hOut != INVALID_HANDLE_VALUE ? 1 : 0);
        }
    }
    hIn = CreateFileA("CONIN$", GENERIC_READ | GENERIC_WRITE,
                      FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (hOut == INVALID_HANDLE_VALUE || hIn == INVALID_HANDLE_VALUE) {
        logf("no_console=1 lasterror=%lu\n", (unsigned long)GetLastError());
        fclose(g_log);
        return 3;
    }

    out_before = GetConsoleOutputCP();
    in_before = GetConsoleCP();
    logf("console_output_cp_before=%u\n", (unsigned)out_before);
    logf("console_input_cp_before=%u\n", (unsigned)in_before);
    if (strcmp(cp_mode, "936") == 0) {
        SetConsoleOutputCP(936);
        SetConsoleCP(936);
    } else if (strcmp(cp_mode, "65001") == 0) {
        SetConsoleOutputCP(65001);
        SetConsoleCP(65001);
    }
    logf("console_output_cp_run=%u\n", (unsigned)GetConsoleOutputCP());

    {
        COORD home = {0, 0};
        DWORD written = 0;
        if (GetConsoleScreenBufferInfo(hOut, &info)) {
            DWORD cells = (DWORD)info.dwSize.X * (DWORD)info.dwSize.Y;
            FillConsoleOutputCharacterW(hOut, L' ', cells, home, &written);
            FillConsoleOutputAttribute(hOut, info.wAttributes, cells, home, &written);
        }
        SetConsoleCursorPosition(hOut, home);
    }

    cmdline[0] = 0;
    for (i = 4; i < argc; i++) {
        if (i > 4) strncat(cmdline, " ", sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, "\"", sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, argv[i], sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, "\"", sizeof(cmdline) - strlen(cmdline) - 1);
    }
    logf("command=%s\n", cmdline);
    logf("keys=%s\n", keys_spec);

    /* 按键表：含逗号/冒号或是已知记号 → 记号语法；否则按旧写法当十六进制字节串。 */
    legacy_hex = (strchr(keys_spec, ',') == NULL && strchr(keys_spec, ':') == NULL &&
                  strchr(keys_spec, '+') == NULL);
    if (legacy_hex) {
        size_t hl = strlen(keys_spec);
        if (hl % 2 != 0) {
            logf("bad_hex=1\n");
            fclose(g_log);
            return 2;
        }
        nkeys = (int)(hl / 2);
    }
    keys = (KeySpec *)malloc(sizeof(KeySpec) * (size_t)(nkeys > 0 ? nkeys : MAX_KEYS));
    if (legacy_hex) {
        for (i = 0; i < nkeys; i++) {
            int hi = hexval((unsigned char)keys_spec[i * 2]);
            int lo = hexval((unsigned char)keys_spec[i * 2 + 1]);
            if (hi < 0 || lo < 0) {
                logf("bad_hex=1\n");
                fclose(g_log);
                return 2;
            }
            keys[i].ch = (WCHAR)(unsigned char)((hi << 4) | lo);
            keys[i].vk = vk_of_char(keys[i].ch);
        }
    } else {
        const char *p = keys_spec;
        while (*p != 0 && nkeys < MAX_KEYS) {
            int used = parse_token(p, &keys[nkeys]);
            if (used == 0) {
                logf("bad_token=%.16s\n", p);
                fclose(g_log);
                return 2;
            }
            nkeys++;
            p += used;
        }
    }
    logf("nkeys=%d\n", nkeys);

    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = hIn;
    si.hStdOutput = hOut;
    si.hStdError = hOut;
    SetHandleInformation(hOut, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    SetHandleInformation(hIn, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);

    ok = CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    if (!ok) {
        logf("create_process_failed=1 lasterror=%lu\n", (unsigned long)GetLastError());
        fclose(g_log);
        return 3;
    }
    logf("child_pid=%lu\n", (unsigned long)pi.dwProcessId);

    /* 按键：等子进程把控制台切到 raw 之后再敲（真实用户也是在这个时刻敲的）。 */
    wait_ms = 0;
    for (;;) {
        DWORD w = WaitForSingleObject(pi.hProcess, 250);
        wait_ms += 250;
        if (w == WAIT_OBJECT_0) break;
        if (wait_ms >= 3000) {
            if (!typed) {
                for (i = 0; i < nkeys; i++) {
                    INPUT_RECORD rec;
                    DWORD put = 0;
                    fill_record(&rec, &keys[i], TRUE);
                    if (!WriteConsoleInputW(hIn, &rec, 1, &put)) {
                        logf("write_console_input_failed=1 lasterror=%lu\n",
                             (unsigned long)GetLastError());
                        break;
                    }
                    /* 抬起记录也照发：子进程必须忽略它（真实键盘就是这样）。 */
                    fill_record(&rec, &keys[i], FALSE);
                    WriteConsoleInputW(hIn, &rec, 1, &put);
                    Sleep(120); /* 模拟逐键敲入，给子进程留出转发时间 */
                }
                typed = 1;
                logf("keys_injected=%d\n", i);
            }
            if (wait_ms >= 30000) break;
        }
    }
    if (WaitForSingleObject(pi.hProcess, 3000) == WAIT_OBJECT_0) {
        GetExitCodeProcess(pi.hProcess, &ec);
    } else {
        logf("child_still_alive=1\n");
        TerminateProcess(pi.hProcess, 9);
        WaitForSingleObject(pi.hProcess, 2000);
    }
    logf("exit_code=%lu\n", (unsigned long)ec);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    {
        int rows_read = 0;
        if (GetConsoleScreenBufferInfo(hOut, &info)) {
            int width = info.dwSize.X;
            int last = info.dwCursorPosition.Y;
            wchar_t *row;
            if (last > MAX_ROWS - 1) last = MAX_ROWS - 1;
            logf("screen_window_cols=%d screen_window_rows=%d\n",
                 (int)(info.srWindow.Right - info.srWindow.Left + 1),
                 (int)(info.srWindow.Bottom - info.srWindow.Top + 1));
            row = (wchar_t *)malloc(sizeof(wchar_t) * ((size_t)width + 1));
            if (row != NULL) {
                logf("screen_width=%d screen_rows_read=%d\n", width, last + 1);
                logf("== screen begin ==\n");
                for (int y = 0; y <= last; y++) {
                    COORD pos = {(SHORT)0, (SHORT)y};
                    DWORD got = 0;
                    if (ReadConsoleOutputCharacterW(hOut, row, (DWORD)width, pos, &got) && got > 0) {
                        int n = rtrim(row, (int)got);
                        emit_utf8(row, n);
                    }
                    fputc('\n', g_log);
                    rows_read++;
                }
                logf("== screen end ==\n");
                free(row);
            }
        }
        logf("rows_read=%d\n", rows_read);
    }
    logf("done=1\n");
    fclose(g_log);
    CloseHandle(hIn);
    CloseHandle(hOut);
    return 0;
}
