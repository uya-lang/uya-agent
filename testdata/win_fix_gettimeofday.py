#!/usr/bin/env python3
"""testdata/win_fix_gettimeofday.py — `make windows` 的第 2 步之一（只改生成物）。

**为什么需要它**：`sys_gettimeofday` 的 ABI 是 `(TimeVal *tv, void *tz)`：

    export fn sys_gettimeofday(tv: &TimeVal, tz: &void) !i32 {
        return @syscall(SYS_gettimeofday, tv as i64, tz as i64) as! i32;
    }

而编译器的 Windows 桥把**第二个参数当成了 usec 的输出指针**：

    static struct err_union_int32_t uya_windows_gettimeofday(
            int64_t *sec_out, int64_t *usec_out) {
        int64_t ns = uya_windows_realtime_ns();
        if (sec_out != (int64_t *)0) *sec_out = ns / 1000000000LL;
        if (usec_out != (int64_t *)0) *usec_out = (ns % 1000000000LL) / 1000LL;

调用点传的第二参是 `tz`，而 `sys_gettimeofday` 把 `tz` 显式丢掉（`_ = tz;`）传 null，
于是 `usec_out == NULL` ⇒ **`tv.tv_usec` 永远不被写**，`TimeVal` 里只剩下秒。

后果不是「差一点」，而是 `ua_now_ms()`（`tv_sec * 1000 + tv_usec/1000`）在 Windows 上
**精度退化成 1000ms**。实测症状（dockur/windows 的 Win10 客户机）：

  * `async-rt` 轮的「三次 40ms 的 sleep 必须落在 100–1200ms」——实测被取整成 0 或 1000+；
  * 同一轮的「取消要在 400ms 内收口」也量不出来（时钟自己就不走）；
  * 因为这两条同时红，一度误判成「时钟粒度 15.6ms」的问题（那次修复是对的，但不是本因）。

**修法**：第二个参数按 ABI 忽略（它是 timezone），把 `tv` 当成 `{int64_t tv_sec;
int64_t tv_usec;}` 整块写（与 `libc/syscall.uya` 的 `TimeVal` 布局一致）。

**为什么修生成物**：`gettimeofday` 是 `extern "libc"` 的裸系统调用，源码里没有可绕的地方。
哪天编译器改对了，本脚本替换 0 处并退出 0。

用法：
    python3 testdata/win_fix_gettimeofday.py <生成的 .c>
"""

import re
import sys

OLD_RE = re.compile(
    r'static struct err_union_int32_t uya_windows_gettimeofday\('
    r'int64_t \*sec_out, int64_t \*usec_out\) \{\n'
    r'.*?\n\}\n',
    re.DOTALL,
)

NEW = r'''static struct err_union_int32_t uya_windows_gettimeofday(int64_t *tv_ptr, int64_t *tz_ptr) {
    /* 第二个参数是 **timezone**（`sys_gettimeofday(tv, tz)` 的 `tz`），不是 usec 输出位
     * —— 见 testdata/win_fix_gettimeofday.py。按 `TimeVal{tv_sec, tv_usec}` 整块写。 */
    const struct uya_windows_timeval_local {
        int64_t tv_sec;
        int64_t tv_usec;
    } *tv = (const struct uya_windows_timeval_local *)(intptr_t)tv_ptr;
    int64_t ns;
    (void)tz_ptr;
    if (tv == (const struct uya_windows_timeval_local *)0) return uya_win_err_i32(22);
    ns = uya_windows_realtime_ns();
    {
        int64_t *fields = (int64_t *)(intptr_t)tv_ptr;
        fields[0] = ns / 1000000000LL;
        fields[1] = (ns % 1000000000LL) / 1000LL;
    }
    return uya_win_ok_i32(0);
}
'''

ALREADY = 'uya_windows_timeval_local'


def fix(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        text = fh.read()
    if ALREADY in text:
        return 0
    new_text, n = OLD_RE.subn(NEW, text)
    if n == 0:
        raise SystemExit(
            'win_fix_gettimeofday: 找不到旧的 uya_windows_gettimeofday 实现，'
            '生成物形状变了（编译器更新？）—— 请确认 gettimeofday 的 ABI 已按 '
            '(TimeVal*, tz) 生成')
    with open(path, 'w', encoding='utf-8', errors='replace') as fh:
        fh.write(new_text)
    return n


def main(argv):
    if len(argv) != 2:
        print('用法: win_fix_gettimeofday.py <生成的 .c>', file=sys.stderr)
        return 2
    n = fix(argv[1])
    print('win_fix_gettimeofday: %s' % (
        '已把 gettimeofday 改成按 TimeVal* 写（原来第二参当 usec ⇒ 毫秒精度退化为 1 秒）'
        if n else '无需修补（已经是对的）'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
