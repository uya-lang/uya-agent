#!/usr/bin/env python3
"""可搬运性验收用的假 DNS 解析器 —— 对任何名字都回同一个 A 记录。

为什么需要它：`e2e-dns` 要验的是「我们**自己**找的解析器真的被用上了」，所以必须有一个
**只有它才答得出来**的名字。判据用 `.invalid` 域名（RFC 2606 保留域，任何真解析器都
一定回 NXDOMAIN）：那一轮要是跑绿了，就只可能是本进程把查询发到了这个假解析器上 ——
判据不可能靠机器上碰巧存在的 DNS 蒙对。

它同时还是**反腿**的对照组：同一个名字、同一个端口，把解析器换成一个没人听的端口，
那一轮就必须报「域名解析失败」并退出 2。

答复形状：标准 UDP DNS，A 记录、TTL 30，answer 指回问题里的名字（压缩指针 0xc00c）。

用法（首行打印 PORT）：
    python3 testdata/mock_dns.py <port> <answer-ip>
    PORT=$(awk '/^PORT/{print $2}' /tmp/dns.log)

这不是产品的一部分（产品是纯 Uya，只依赖 Uya 标准库）；它只是本地验收用的假端点。
"""
import socket
import struct
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
ANSWER = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"


def question_end(data):
    """返回 question 段（qname + qtype + qclass）的结束偏移；坏包返回 -1。

    扫描方式与真实解析器一致：qname 是一串「长度 + 标签」，遇到 0 结束，再跳 4 字节。
    压缩指针（0xC0）在**问题段**里非法，所以不处理 —— 遇到就当坏包忽略。
    """
    i = 12
    while i < len(data):
        n = data[i]
        if n == 0:
            return i + 5
        if n & 0xC0:
            return -1
        i += 1 + n
    return -1


def build_reply(data):
    """按收到的查询造一条 A 记录答复。"""
    qend = question_end(data)
    if qend < 0 or qend > len(data):
        return None
    tid = data[:2]
    question = data[12:qend]
    rdata = socket.inet_aton(ANSWER)
    # name = 指向问题里那个名字的压缩指针；type/class/ttl/rdlength = A/IN/30/4
    answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + rdata
    # flags = 0x8180（标准答复 + 递归可用），qd=1、an=1、ns=0、ar=0
    head = tid + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0)
    return head + question + answer


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind(("127.0.0.1", PORT))
    print("PORT %d" % srv.getsockname()[1], flush=True)
    while True:
        data, peer = srv.recvfrom(4096)
        reply = build_reply(data)
        if reply is None:
            continue
        srv.sendto(reply, peer)


if __name__ == "__main__":
    main()
