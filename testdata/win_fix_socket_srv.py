#!/usr/bin/env python3
"""testdata/win_fix_socket_srv.py — `make windows` 的第 2 步之一（只改生成物）。

**为什么需要它**：编译器的 Windows 后端（`uya_windows_syscall` 那张 case 表）**没有实现
服务端 socket 的那几个系统调用** —— `bind`(49) / `listen`(50) / `accept`(43) /
`getsockname`(51) / `getpeername`(52) / `shutdown`(48) 全落到 `default: return -38`
（= `ENOSYS`）。于是任何**监听端口**的东西在 Windows 上都起不来：

    selftest: bind() failed          ← 离线自测的 mock LLM 起不来（整轮自测的底座）
    --web / --dsh-web                ← 自己的 HTTP 服务端（net/httpsrv）

实测现场：dockur/windows 的 Win10 客户机里跑 `uya-agent.exe --selftest`，
第一行就是 `selftest: bind() failed`，随后 20 多轮因为「mock LLM 起不来」连锁失败。
而**同一个 Winsock 在客户机上 bind 到 127.0.0.1:0 是成功的**（用一个最小 C 程序证过：
`socket()` / `bind()` / `getsockname()` / `listen()` 全返回 0），所以这不是平台限制，
是桥漏了。

**修法**：在生成物的 `uya_windows_syscall` 里插一组 case，转给本文件的辅助函数。
辅助函数直接调 Winsock（`bind` / `listen` / `accept` / `getsockname` / `getpeername` /
`shutdown`），把描述符换算与 errno 映射走**桥里已有的那些**（`uya_windows_fd_to_socket`
/ `uya_windows_is_socket_fd` / `uya_windows_map_wsa_error`）—— 不新造一套。

几个必须踩准的点（都是 Winsock 与 POSIX 的差异，写错了会「能编过、跑起来不对」）：

  * **`accept` 必须把新连接也设成非阻塞**：uya 的网络层按 Linux 非阻塞语义写
    （`accept` 返回后立刻 read/write，EAGAIN 再 poll）。Winsock 的 `accept` 继承监听
    套接字的非阻塞**与否在 Windows 上不可靠**（实测新句柄回来是阻塞的），不显式
    `ioctlsocket(FIONBIO)` 会让整条事件循环卡在一次 read 上。
  * **`bind` / `getsockname` 的 `addrlen` 是「传入容量、传出实际」**：Winsock 的
    参数是 `int*`，而 uya 侧传的是 `u32*`；长度不一致会让 `getsockname` 写坏栈。
    这里用局部 `int` 转一次，两端都按各自约定。
  * **`listen` 的 backlog**：Winsock 用 `SOMAXCONN` 兜上限，传多少都接受。
  * **错误映射统一走 `uya_windows_map_wsa_error`**：它会 `WSAEWOULDBLOCK → 11`(EAGAIN)，
    这正是 uya 上层在非阻塞 `accept` 上等的那一条。

**为什么修生成物而不是改 Uya 源码**：`bind` 这些是 `extern "libc"` 的裸系统调用，
源码里没有可绕的地方；而桥是 codegen 的产物。哪天编译器补上这几个 case，本脚本会
替换 0 处并退出 0，构建不受影响。

用法：
    python3 testdata/win_fix_socket_srv.py <生成的 .c>
"""

import re
import sys

# 插在 `uya_windows_syscall` 的 switch 开头（case 1 之前）。锚点取那一行本身，
# 保证只插一次、且插在函数体内。
ANCHOR = '    switch (nr) {\n'

# 辅助函数：放在 `uya_windows_syscall` 定义**之前**。用 static，避免与其他 TU 撞名
# （单 TU 下也一致）。
HELPERS = r'''
/* --- 服务端 socket：编译器桥里**没有**这几个 case（见 testdata/win_fix_socket_srv.py）--- */
static struct err_union_int32_t uya_win_srv_bind(int32_t fd, const void *addr, uint32_t len) {
    if (!uya_windows_is_socket_fd(fd)) return uya_win_err_i32(9);
    if (bind(uya_windows_fd_to_socket(fd), (const struct sockaddr *)addr, (int)len) != 0)
        return uya_win_err_i32(uya_windows_map_wsa_error(WSAGetLastError()));
    return uya_win_ok_i32(0);
}
static struct err_union_int32_t uya_win_srv_listen(int32_t fd, int32_t backlog) {
    if (!uya_windows_is_socket_fd(fd)) return uya_win_err_i32(9);
    if (backlog <= 0) backlog = SOMAXCONN;
    if (listen(uya_windows_fd_to_socket(fd), backlog) != 0)
        return uya_win_err_i32(uya_windows_map_wsa_error(WSAGetLastError()));
    return uya_win_ok_i32(0);
}
/* accept：新句柄**必须**显式设成非阻塞（见脚本头注释）。 */
static struct err_union_int32_t uya_win_srv_accept(int32_t fd, void *addr, uint32_t *len) {
    SOCKET s;
    u_long nb = 1;
    if (!uya_windows_is_socket_fd(fd)) return uya_win_err_i32(9);
    s = accept(uya_windows_fd_to_socket(fd), (struct sockaddr *)addr, (int *)len);
    if (s == INVALID_SOCKET) return uya_win_err_i32(uya_windows_map_wsa_error(WSAGetLastError()));
    ioctlsocket(s, FIONBIO, &nb);
    return uya_win_ok_i32((int32_t)(UYA_WINDOWS_SOCKET_BASE + (int32_t)(uintptr_t)s));
}
/* getsockname / getpeername：uya 侧传 u32*，Winsock 要 int* —— 用局部 int 转一次。 */
static struct err_union_int32_t uya_win_srv_getsockname(int32_t fd, void *addr, uint32_t *len) {
    int n;
    int rc;
    if (!uya_windows_is_socket_fd(fd)) return uya_win_err_i32(9);
    n = (len != (uint32_t *)0) ? (int)*len : 0;
    rc = getsockname(uya_windows_fd_to_socket(fd), (struct sockaddr *)addr, &n);
    if (len != (uint32_t *)0) *len = (uint32_t)n;
    if (rc != 0) return uya_win_err_i32(uya_windows_map_wsa_error(WSAGetLastError()));
    return uya_win_ok_i32(0);
}
static struct err_union_int32_t uya_win_srv_getpeername(int32_t fd, void *addr, uint32_t *len) {
    int n;
    int rc;
    if (!uya_windows_is_socket_fd(fd)) return uya_win_err_i32(9);
    n = (len != (uint32_t *)0) ? (int)*len : 0;
    rc = getpeername(uya_windows_fd_to_socket(fd), (struct sockaddr *)addr, &n);
    if (len != (uint32_t *)0) *len = (uint32_t)n;
    if (rc != 0) return uya_win_err_i32(uya_windows_map_wsa_error(WSAGetLastError()));
    return uya_win_ok_i32(0);
}
static struct err_union_int32_t uya_win_srv_shutdown(int32_t fd, int32_t how) {
    if (!uya_windows_is_socket_fd(fd)) return uya_win_err_i32(9);
    /* Linux 的 how：0=RD 1=WR 2=RDWR；Winsock 的 SD_* 是 0/1/2 —— 同值，直接用。 */
    if (shutdown(uya_windows_fd_to_socket(fd), how) != 0)
        return uya_win_err_i32(uya_windows_map_wsa_error(WSAGetLastError()));
    return uya_win_ok_i32(0);
}
'''

# 插进 switch 的 case（Linux x86-64 的号，与 lib/libc/syscall.uya 一致）
CASES = '''        /* 服务端 socket（编译器桥缺这几个 case，见 testdata/win_fix_socket_srv.py）*/
        case 49: { struct err_union_int32_t r = uya_win_srv_bind((int32_t)a1, (const void *)a2, (uint32_t)a3); return (r.error_id != 0) ? -(int64_t)r.error_id : (int64_t)r.value; }
        case 50: { struct err_union_int32_t r = uya_win_srv_listen((int32_t)a1, (int32_t)a2); return (r.error_id != 0) ? -(int64_t)r.error_id : (int64_t)r.value; }
        case 43: { struct err_union_int32_t r = uya_win_srv_accept((int32_t)a1, (void *)a2, (uint32_t *)a3); return (r.error_id != 0) ? -(int64_t)r.error_id : (int64_t)r.value; }
        case 51: { struct err_union_int32_t r = uya_win_srv_getsockname((int32_t)a1, (void *)a2, (uint32_t *)a3); return (r.error_id != 0) ? -(int64_t)r.error_id : (int64_t)r.value; }
        case 52: { struct err_union_int32_t r = uya_win_srv_getpeername((int32_t)a1, (void *)a2, (uint32_t *)a3); return (r.error_id != 0) ? -(int64_t)r.error_id : (int64_t)r.value; }
        case 48: { struct err_union_int32_t r = uya_win_srv_shutdown((int32_t)a1, (int32_t)a2); return (r.error_id != 0) ? -(int64_t)r.error_id : (int64_t)r.value; }
'''

# 桥里那个函数定义的签名行（辅助函数要插在它前面）
DEF_RE = re.compile(
    r'^static int64_t uya_windows_syscall\(int64_t nr, int64_t a1, '
    r'int64_t a2, int64_t a3, int64_t a4, int64_t a5, int64_t a6\) \{\n',
    re.MULTILINE,
)

ALREADY = 'uya_win_srv_bind'


def fix(path):
    """插入辅助函数 + switch case。返回 1 = 已插入，0 = 无需（或已插过）。"""
    with open(path, encoding='utf-8', errors='replace') as fh:
        text = fh.read()
    if ALREADY in text:
        return 0
    m = DEF_RE.search(text)
    if m is None:
        # 生成器换了形状：不猜，明确报出来（让调用方看见，而不是静默跳过一个洞）
        raise SystemExit(
            'win_fix_socket_srv: 找不到 uya_windows_syscall 的定义，'
            '生成物形状变了（编译器更新？）')
    text = text[:m.start()] + HELPERS + '\n' + text[m.start():]
    # 辅助函数插完之后锚点位置会变，重新定位
    m2 = DEF_RE.search(text)
    switch_at = text.index(ANCHOR, m2.end())
    ins = switch_at + len(ANCHOR)
    text = text[:ins] + CASES + text[ins:]
    with open(path, 'w', encoding='utf-8', errors='replace') as fh:
        fh.write(text)
    return 1


def main(argv):
    if len(argv) != 2:
        print('用法: win_fix_socket_srv.py <生成的 .c>', file=sys.stderr)
        return 2
    n = fix(argv[1])
    if n == 0:
        print('win_fix_socket_srv: 无需修补（已经补过）')
    else:
        print('win_fix_socket_srv: 已补服务端 socket 桥（bind/listen/accept/'
              'getsockname/getpeername/shutdown）')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
