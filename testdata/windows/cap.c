/*
 * cap.c - 在真实 Windows 控制台里运行目标程序，把「屏幕上真正显示出来的字符」读回来。
 *
 * 为什么不能用重定向来测：`prog --help > out.txt` 走的是「字节」路径（写文件），
 * 控制台的代码页转换根本不会发生 —— 这样测出来的结果永远是「正确」的，
 * 而用户屏幕上却是一片乱码。本工具把子进程的 stdout/stderr 接到真实的
 * CONOUT$ 控制台句柄上，再用 ReadConsoleOutputCharacterW（宽字符）读回屏幕上
 * 实际渲染出来的字符，因此测的是「用户看到什么」，而不是「程序写了什么字节」。
 *
 * 用法: cap.exe <输出文件> <cpmode: keep|936|65001> <程序> [参数...]
 *
 * 输出文件是一份报告（UTF-8），除诊断信息外，屏幕内容放在
 * `== screen begin ==` / `== screen end ==` 之间，便于宿主侧断言。
 */
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_ROWS 200

static FILE *g_log;

static void logf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
}

/* 把 UTF-16 的一段转成 UTF-8 追加写入报告文件。 */
static void emit_utf8(const wchar_t *w, int n) {
    int need = WideCharToMultiByte(CP_UTF8, 0, w, n, NULL, 0, NULL, NULL);
    if (need <= 0) return;
    char *tmp = (char *)malloc((size_t)need + 1);
    if (tmp == NULL) return;
    WideCharToMultiByte(CP_UTF8, 0, w, n, tmp, need, NULL, NULL);
    tmp[need] = 0;
    fwrite(tmp, 1, (size_t)need, g_log);
    free(tmp);
}

/* 取尾部为空白的边界（返回最后一个非空白字符的下标+1）。 */
static int rtrim(const wchar_t *w, int n) {
    while (n > 0) {
        wchar_t c = w[n - 1];
        if (c != L' ' && c != L'\t' && c != 0) break;
        n--;
    }
    return n;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: cap <outfile> <cpmode: keep|936|65001> <prog> [args...]\n");
        return 2;
    }
    const char *out_path = argv[1];
    const char *cp_mode = argv[2];

    g_log = fopen(out_path, "wb");
    if (g_log == NULL) {
        fprintf(stderr, "cannot open outfile: %s\n", out_path);
        return 2;
    }

    /* 即使本进程的 stdio 被重定向，也要拿到真正的控制台句柄。 */
    HANDLE hOut = CreateFileA("CONOUT$", GENERIC_READ | GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                              OPEN_EXISTING, 0, NULL);
    logf("had_console=%d\n", hOut != INVALID_HANDLE_VALUE ? 1 : 0);
    if (hOut == INVALID_HANDLE_VALUE) {
        /* 无人值守（计划任务/服务，session 0）下没有控制台，就自己分配一个：
         * 本工具只关心「conhost 按控制台代码页解释字节」这条路径，
         * 这条路径不要求窗口可见，也不要求处在交互会话里。 */
        FreeConsole();
        if (AllocConsole()) {
            hOut = CreateFileA("CONOUT$", GENERIC_READ | GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                               OPEN_EXISTING, 0, NULL);
            logf("allocated_console=%d\n", hOut != INVALID_HANDLE_VALUE ? 1 : 0);
        }
    }
    HANDLE hIn = CreateFileA("CONIN$", GENERIC_READ | GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                             OPEN_EXISTING, 0, NULL);
    if (hOut == INVALID_HANDLE_VALUE) {
        logf("no_console=1 lasterror=%lu\n", (unsigned long)GetLastError());
        fclose(g_log);
        return 3;
    }

    UINT out_before = GetConsoleOutputCP();
    UINT in_before = GetConsoleCP();
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

    /* 清屏并把光标放回左上角，这样「输出起点」是确定的。 */
    CONSOLE_SCREEN_BUFFER_INFO info;
    DWORD written = 0;
    COORD home = {0, 0};
    if (GetConsoleScreenBufferInfo(hOut, &info)) {
        DWORD cells = (DWORD)info.dwSize.X * (DWORD)info.dwSize.Y;
        FillConsoleOutputCharacterW(hOut, L' ', cells, home, &written);
        FillConsoleOutputAttribute(hOut, info.wAttributes, cells, home, &written);
    }
    SetConsoleCursorPosition(hOut, home);

    /* 逐字拼命令行（不经过 shell）。 */
    char cmdline[16384];
    cmdline[0] = 0;
    for (int i = 3; i < argc; i++) {
        if (i > 3) strncat(cmdline, " ", sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, "\"", sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, argv[i], sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, "\"", sizeof(cmdline) - strlen(cmdline) - 1);
    }
    logf("command=%s\n", cmdline);

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = hIn;
    si.hStdOutput = hOut;
    si.hStdError = hOut;

    SetHandleInformation(hOut, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    if (hIn != INVALID_HANDLE_VALUE)
        SetHandleInformation(hIn, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);

    BOOL ok = CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    DWORD ec = 0;
    if (!ok) {
        logf("create_process_failed=1 lasterror=%lu\n", (unsigned long)GetLastError());
    } else {
        WaitForSingleObject(pi.hProcess, 300000);
        GetExitCodeProcess(pi.hProcess, &ec);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
    logf("exit_code=%lu\n", (unsigned long)ec);

    /* 读回屏幕上的字符：ReadConsoleOutputCharacterW 返回的是 conhost 真正
     * 渲染出来的宽字符，也就是用户眼睛看到的内容。 */
    int rows_read = 0;
    if (GetConsoleScreenBufferInfo(hOut, &info)) {
        int width = info.dwSize.X;
        /* 窗口尺寸（列/行）单独报一份：被测程序在伪终端里 `mode con` 报出的行列应当
         * 与它一致。用 srWindow 而不是 dwSize —— dwSize 是屏幕缓冲区，可以远大于窗口。 */
        logf("screen_window_cols=%d screen_window_rows=%d\n",
             (int)(info.srWindow.Right - info.srWindow.Left + 1),
             (int)(info.srWindow.Bottom - info.srWindow.Top + 1));
        int last = info.dwCursorPosition.Y;
        if (last > MAX_ROWS - 1) last = MAX_ROWS - 1;
        wchar_t *row = (wchar_t *)malloc(sizeof(wchar_t) * ((size_t)width + 1));
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
    logf("console_output_cp_after=%u\n", (unsigned)GetConsoleOutputCP());
    logf("rows_read=%d\n", rows_read);
    logf("done=1\n");

    fclose(g_log);
    if (hIn != INVALID_HANDLE_VALUE) CloseHandle(hIn);
    CloseHandle(hOut);
    return 0;
}
