#!/usr/bin/env python3
"""可搬运性验收用的假**明文代理** —— 真转发：解析绝对形式请求行，转发到真端点。

为什么需要它（而不是让假代理只回一句固定答复）：`e2e-proxy` 要验的是「请求真的
**穿过**代理到了上游」，判据必须落在**上游**那一头（假网关收到的请求）与代理这一头的
转发记录上。只回固定答复的假代理证明不了这一点 —— 它连上游都没连。

职责两条：
  ① 收到**绝对形式**请求行（`GET http://host:port/path HTTP/1.1`）⇒ 按 URL 连上游、
     原样转发（含请求头与体），把上游的应答原样回给客户端；
  ② 收到 **CONNECT**（`CONNECT host:port HTTP/1.1`）⇒ 连上游、回
     `HTTP/1.1 200 Connection established`，之后在两条连接之间**双向搬字节**（隧道）。
两种形态都记一行到日志（`$LOG`），供验收断言「请求行是绝对形式 / CONNECT 打给了谁」，
并把 `Proxy-Authorization` 头单独记一行（凭据腿的判据）。

用法（首行打印 PORT）：
    python3 testdata/mock_proxy.py <port> <log-path> [--reject STATUS] [--upstream H:P]
        --reject STATUS   每条请求都直接回这个状态码（反腿用），不连上游
        --upstream H:P    **目标改写**：不管请求行里写的是谁，一律连这一台上游。
        --tunnel-drop     CONNECT 照收、200 照回，然后把隧道**掐断**（模拟「代理答应了、
                          上游却没通」——客户端那边只看到握手失败）。

为什么需要 `--upstream`：验收腿故意用 `.invalid` 域名当目标（RFC 2606 保留域）—— 那是
「请求真的到了代理由它转发」这条判据的依据，但代理自己**不能**去解析它（真解析器必然
失败，于是每条腿都会变成 502）。所以目标只用来**断言**（日志里逐字记下请求行原样），
真连接落到 `--upstream` 指定的那一台（假网关）。这与 `e2e-dns` 用假解析器把 `.invalid`
指到 127.0.0.1 是同一手法，只是把「谁来做映射」从解析器换成了代理。

这不是产品的一部分（产品是纯 Uya，只依赖 Uya 标准库）；它只是本地验收用的假端点。
"""
import socket
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 0
LOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/proxy.log"
REJECT = 0
UPSTREAM = None            # (host, port)：目标改写（见文件头）
DROP_TUNNEL = False        # 隧道掐断（见文件头）
args = sys.argv[3:]
i = 0
while i < len(args):
    if args[i] == "--tunnel-drop":
        DROP_TUNNEL = True
        i += 1
    elif args[i] == "--reject" and i + 1 < len(args):
        REJECT = int(args[i + 1])
        i += 2
    elif args[i] == "--upstream" and i + 1 < len(args):
        uhost, _, uport = args[i + 1].partition(":")
        UPSTREAM = (uhost, int(uport))
        i += 2
    else:
        i += 1


def upstream_of(host, port):
    """要连哪一台：配了 `--upstream` 就一律改写（目标只用来断言，见文件头）。"""
    return UPSTREAM if UPSTREAM else (host, port)
LOCK = threading.Lock()


def log(line):
    """记一行到日志（验收断言只读它，所以格式要稳定：每行一个 `KEY value`）。"""
    with LOCK:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def read_head(conn):
    """读到请求头结束。返回 (head_bytes, rest)；对端没发全返回 (b'', b'')。"""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return b"", b""
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    return head + b"\r\n\r\n", rest


def header_value(head, name):
    """取某个头的值（大小写无关）；没有返回 None。"""
    for line in head.decode("latin-1").split("\r\n"):
        if ":" in line:
            k, _, v = line.partition(":")
            if k.strip().lower() == name.lower():
                return v.strip()
    return None


def body_len(head):
    """Content-Length（没有就是 0）。"""
    v = header_value(head, "content-length")
    return int(v) if v and v.isdigit() else 0


def relay(a, b):
    """在两个套接字之间**双向**搬字节（任一侧 EOF 就结束）。隧道与转发共用它。"""
    done = threading.Event()

    def pump(src, dst):
        try:
            while not done.is_set():
                chunk = src.recv(65536)
                if not chunk:
                    break
                dst.sendall(chunk)
        except OSError:
            pass
        finally:
            done.set()
            for s in (a, b):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    t1 = threading.Thread(target=pump, args=(a, b), daemon=True)
    t2 = threading.Thread(target=pump, args=(b, a), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()


def split_abs_target(target):
    """`http://host:port/path` → (host, port, path)；不是绝对形式返回 None。"""
    if not target.startswith("http://"):
        return None
    rest = target[len("http://"):]
    hostport, _, path = rest.partition("/")
    path = "/" + path
    host, _, port = hostport.partition(":")
    return host, int(port) if port else 80, path


def serve_connect(conn, head, rest, target):
    """CONNECT：连上游、回 200，然后双向搬字节（这一段的判据是「隧道是透明的」）。"""
    host, _, port = target.partition(":")
    log("CONNECT %s" % target)
    auth = header_value(head, "proxy-authorization")
    if auth:
        log("AUTH %s" % auth)
    if REJECT:
        conn.sendall(("HTTP/1.1 %d Nope\r\n\r\n" % REJECT).encode())
        return
    if DROP_TUNNEL:
        log("DROP %s" % target)
        conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        try:
            conn.recv(4096)   # 收下客户端的第一段 TLS 记录再掐断（不读就关会撞 RST）
        except OSError:
            pass
        return
    dhost, dport = upstream_of(host, int(port))
    try:
        up = socket.create_connection((dhost, dport), timeout=15)
    except OSError as exc:
        log("CONNECT-FAIL %s %s" % (target, exc))
        conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        return
    conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    if rest:                      # 客户端可能把隧道里的第一段数据一起发来
        up.sendall(rest)
    relay(conn, up)


def serve_absolute(conn, head, rest, method, target):
    """绝对形式：连上游、把请求行改回相对形式转发、应答原样回给客户端。"""
    parts = split_abs_target(target)
    if parts is None:
        log("BAD-TARGET %s" % target)
        conn.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        return
    host, port, path = parts
    log("ABS %s %s" % (method, target))
    auth = header_value(head, "proxy-authorization")
    if auth:
        log("AUTH %s" % auth)
    if REJECT:
        conn.sendall(("HTTP/1.1 %d Nope\r\n\r\n" % REJECT).encode())
        return
    need = body_len(head)
    body = rest
    while len(body) < need:
        chunk = conn.recv(65536)
        if not chunk:
            break
        body += chunk
    dhost, dport = upstream_of(host, port)
    try:
        up = socket.create_connection((dhost, dport), timeout=15)
    except OSError as exc:
        log("ABS-FAIL %s %s" % (target, exc))
        conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        return
    # 转发：请求行换成相对形式（源服务器模式），头与体原样；把代理专属的头去掉。
    lines = head.decode("latin-1").split("\r\n")
    rebuilt = ["%s %s HTTP/1.1" % (method, path)]
    for line in lines[1:]:
        if not line:
            continue
        k = line.split(":", 1)[0].strip().lower()
        if k in ("proxy-authorization", "proxy-connection"):
            continue
        rebuilt.append(line)
    up.sendall(("\r\n".join(rebuilt) + "\r\n\r\n").encode("latin-1"))
    up.sendall(body)
    relay(conn, up)


def handle(conn):
    head, rest = read_head(conn)
    if not head:
        return
    first = head.split(b"\r\n", 1)[0].decode("latin-1")
    bits = first.split(" ")
    if len(bits) < 2:
        conn.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        return
    method, target = bits[0], bits[1]
    if method.upper() == "CONNECT":
        serve_connect(conn, head, rest, target)
    else:
        serve_absolute(conn, head, rest, method, target)


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(16)
    print("PORT %d" % srv.getsockname()[1], flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
