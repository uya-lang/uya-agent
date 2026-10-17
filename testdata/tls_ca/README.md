# testdata/tls_ca — 链校验自测夹具

自签的测试 CA 出的证书，**只有证书**（私钥不提交，也不需要：自测不做签名）。
`gen.sh` 是重新生成它们的完整命令（自测不跑它，跑自测不需要 openssl、不联网）。

| 文件 | 是什么 |
|---|---|
| `root.pem` | 自签根 `CN=Uya Test Root CA`，`CA:TRUE`，2048 位 RSA |
| `inter.pem` | 中间 `CN=Uya Test Intermediate CA`，由根签，`CA:TRUE, pathlen:0` |
| `leaf.pem` | 叶子，RSA-2048，SAN = `good.test` + `*.wild.test` |
| `badhost.pem` | 叶子，SAN = `other.test`（验「主机名不符必须拒」） |
| `ecinter.pem` / `ecleaf.pem` | P-256 那条：`ec.test` 的叶子由 P-256 中间签（验 ECDSA 路径） |

全部有效期 30000 天，不会自己过期（夹具过期会让自测某天莫名变红）。
