#!/usr/bin/env python3
"""testdata/win_fix_nonblock.py — `make windows` 的第 2 步之一（只改生成物）。

**为什么需要它**：本仓的 I/O 层按 **Linux 非阻塞语义**写（`rt_set_nonblock` 之后
`read` 返 `EAGAIN`、`poll` 报未就绪、事件循环去等）。而编译器的 Windows 桥有两处
把这两条前提打破了：

  1. **`uya_windows_read` 直接 `_read`**：Windows CRT 的管道没有真正的 `O_NONBLOCK`
     （`uya_windows_fcntl` 只是尽力而为），所以对**空管道**的 `_read` 会**阻塞到有数据
     为止**。实测：自测跑到 `async-io` 的「空管道读必须报 deadline」那一段就**永久
     挂住**（`[io] B:` 之后一行都不再输出，进程还在、CPU 不动）。
  2. **`uya_windows_poll` 对非 socket fd 一律报「就绪」**（原注释写的是「按超时睡眠后
     报告可读」）：于是 `async_wait_readable(pipe)` 永远立刻 Ready，`rt_read_some` 的
     `EAGAIN → 等 → 重试` 循环退化成忙转，deadline 也判不出来。

**修法**（两处一起，缺一不可）：

  * `uya_windows_read` 的非 socket 分支：先用 `PeekNamedPipe` / 控制台事件数探一次，
    **没数据就返 `EAGAIN`**，把「要不要等」交回给调用方（这正是 POSIX 语义）。
  * `uya_windows_poll` 的 `!has_socket` 分支：真正检测可读性；没有数据就按
    `timeout_ms` 等（`PeekNamedPipe` 1ms 分片，或对控制台 `WaitForSingleObject`），
    到点返 0（超时）。**不再无条件报就绪。**

这两条也是 `rtio` / `rtloop` / `net/httpsrv` 在 Windows 上能工作的前提。

**为什么修生成物**：这两处都是 codegen 的内联桥（`static` 函数），源码里没有可绕的
地方。哪天编译器改对了，本脚本找不到旧实现时会**明确报错**（不静默跳过 —— 那会让
「永久挂住」这个最难查的缺陷重新变成可能），届时删掉本节即可。

用法：
    python3 testdata/win_fix_nonblock.py <生成的 .c>
"""

import re
import sys

# ---- 1) read：非 socket 分支改成「无数据返 EAGAIN」 -------------------------
READ_OLD = '''static struct err_union_int64_t uya_windows_read(int32_t fd, char *buf, size_t count) {
    if (uya_windows_is_socket_fd(fd)) return uya_windows_socket_read(fd, buf, count);
    if (buf == (char *)0 && count != 0) return uya_win_err_i64(22);
    int ret = _read((int)fd, buf, (unsigned int)count);
    if (ret == -1) return uya_win_err_i64(uya_windows_map_errno(errno));
    return uya_win_ok_i64((int64_t)ret);
}
'''

READ_NEW = '''static struct err_union_int64_t uya_windows_read(int32_t fd, char *buf, size_t count) {
    if (uya_windows_is_socket_fd(fd)) return uya_windows_socket_read(fd, buf, count);
    if (buf == (char *)0 && count != 0) return uya_win_err_i64(22);
    /* Windows 的管道没有真正的 O_NONBLOCK（见 testdata/win_fix_nonblock.py）：
     * 对空管道直接 _read 会**阻塞**，把上层「EAGAIN → 等 → 重试」的循环变成死等。
     * 先探一次：没数据就返 EAGAIN（11），要不要等由调用方（poll）决定。 */
    {
        intptr_t osf = _get_osfhandle((int)fd);
        DWORD type = (osf == (intptr_t)-1) ? FILE_TYPE_UNKNOWN
                                           : GetFileType((HANDLE)osf);
        if (type == FILE_TYPE_PIPE) {
            DWORD avail = 0;
            if (PeekNamedPipe((HANDLE)osf, NULL, 0, NULL, &avail, NULL)) {
                if (avail == 0) return uya_win_err_i64(11);
            } else if (GetLastError() == ERROR_BROKEN_PIPE) {
                return uya_win_ok_i64(0);
            }
        } else if (type == FILE_TYPE_CHAR) {
            DWORD mode = 0;
            if (GetConsoleMode((HANDLE)osf, &mode)) {
                DWORD queued = 0;
                if (!GetNumberOfConsoleInputEvents((HANDLE)osf, &queued) || queued == 0) {
                    return uya_win_err_i64(11);
                }
            }
        }
    }
    {
        int ret = _read((int)fd, buf, (unsigned int)count);
        if (ret == -1) return uya_win_err_i64(uya_windows_map_errno(errno));
        return uya_win_ok_i64((int64_t)ret);
    }
}
'''

# ---- 2) poll：非 socket 分支真正检测可读性 -------------------------------
POLL_OLD_RE = re.compile(
    r'    if \(!has_socket\) \{\n'
    r'.*?\n    \}\n',
    re.DOTALL,
)

POLL_NEW = '''    if (!has_socket) {
        /* 没有 socket：本地 fd（管道 / 控制台）。**真正检测可读性**
         * （见 testdata/win_fix_nonblock.py）——旧实现「按超时睡眠后无条件报就绪」
         * 会让上层的 EAGAIN 重试循环空转，deadline 也永远判不出来。 */
        uint32_t waited = 0;
        uint32_t want = (timeout_ms < 0) ? 0xFFFFFFFFu : (uint32_t)timeout_ms;
        for (;;) {
            int ready = 0;
            for (i = 0; i < nfds; i++) {
                intptr_t osf = _get_osfhandle((int)fds[i].fd);
                DWORD type = (osf == (intptr_t)-1) ? FILE_TYPE_UNKNOWN
                                                   : GetFileType((HANDLE)osf);
                int16_t rev = 0;
                if (type == FILE_TYPE_PIPE) {
                    DWORD avail = 0;
                    if (PeekNamedPipe((HANDLE)osf, NULL, 0, NULL, &avail, NULL)) {
                        if (avail > 0 && (fds[i].events & 0x1) != 0) rev |= 0x1;
                    } else if (GetLastError() == ERROR_BROKEN_PIPE) {
                        rev |= 0x1;   /* EOF 也算「可读」：read 会拿到 0 */
                    }
                } else if (type == FILE_TYPE_CHAR) {
                    DWORD mode = 0, queued = 0;
                    if (GetConsoleMode((HANDLE)osf, &mode)) {
                        if (GetNumberOfConsoleInputEvents((HANDLE)osf, &queued) &&
                            queued > 0 && (fds[i].events & 0x1) != 0) {
                            rev |= 0x1;
                        }
                    } else if ((fds[i].events & 0x1) != 0) {
                        rev |= 0x1;
                    }
                } else if ((fds[i].events & 0x1) != 0) {
                    rev |= 0x1;       /* 磁盘文件：直接算可读 */
                }
                fds[i].revents = rev;
                if (rev != 0) ready++;
            }
            if (ready > 0) return uya_win_ok_i32(ready);
            if (waited >= want) return uya_win_ok_i32(0);
            Sleep(1);
            waited++;
        }
    }
'''

ALREADY = 'win_fix_nonblock'


def fix(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        text = fh.read()
    if ALREADY in text:
        return 0
    if READ_OLD not in text:
        raise SystemExit(
            'win_fix_nonblock: 找不到旧的 uya_windows_read 实现，生成物形状变了'
            '（编译器更新？）—— 请确认非阻塞读语义已由编译器保证')
    text = text.replace(READ_OLD, READ_NEW, 1)
    new_text, n = POLL_OLD_RE.subn(POLL_NEW, text, count=1)
    if n == 0:
        raise SystemExit(
            'win_fix_nonblock: 找不到旧的 uya_windows_poll 非 socket 分支，'
            '生成物形状变了（编译器更新？）')
    new_text = new_text.replace(
        'static struct err_union_int32_t uya_windows_poll(',
        '/* 见 testdata/win_fix_nonblock：' + ALREADY + ' */\n'
        'static struct err_union_int32_t uya_windows_poll(', 1)
    with open(path, 'w', encoding='utf-8', errors='replace') as fh:
        fh.write(new_text)
    return 1


def main(argv):
    if len(argv) != 2:
        print('用法: win_fix_nonblock.py <生成的 .c>', file=sys.stderr)
        return 2
    n = fix(argv[1])
    print('win_fix_nonblock: %s' % (
        '已修非阻塞语义（read 无数据返 EAGAIN + poll 真检测可读）'
        if n else '无需修补（已经是对的）'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
