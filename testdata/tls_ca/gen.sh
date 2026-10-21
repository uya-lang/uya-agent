#!/bin/sh
# testdata/tls_ca/gen.sh — 重新生成这一套自测夹具（**自测本身不跑它**：夹具已经提交，
# 跑自测不需要 openssl，也不需要网络）。
#
# 为什么夹具是「自签的测试 CA」而不是抓来的真证书：自测要判「链能不能验到根」「主机名
# 对不对」「签名被改一个字节会不会红」—— 这几条必须有一份**我们知道私钥**的链才造得出来；
# 真证书的私钥不在手上，也没法造「错主机名」「签名被改」的副本。
#
# 有效期 30000 天（≈82 年）：夹具不能自己过期，否则某天自测会莫名其妙变红。
#
# 用法（在本目录下）：sh gen.sh
set -e
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/uyatest_root.key \
  -out root.pem -days 30000 -subj "/O=Uya Test/CN=Uya Test Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -new -newkey rsa:2048 -nodes -keyout /tmp/uyatest_inter.key \
  -out /tmp/uyatest_inter.csr -subj "/O=Uya Test/CN=Uya Test Intermediate CA"
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n" \
  > /tmp/uyatest_inter.ext
openssl x509 -req -in /tmp/uyatest_inter.csr -CA root.pem -CAkey /tmp/uyatest_root.key \
  -CAcreateserial -out inter.pem -days 30000 -extfile /tmp/uyatest_inter.ext -sha256
openssl req -new -newkey rsa:2048 -nodes -keyout /tmp/uyatest_leaf.key \
  -out /tmp/uyatest_leaf.csr -subj "/O=Uya Test/CN=good.test"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:good.test,DNS:*.wild.test\n" \
  > /tmp/uyatest_leaf.ext
openssl x509 -req -in /tmp/uyatest_leaf.csr -CA inter.pem -CAkey /tmp/uyatest_inter.key \
  -CAcreateserial -out leaf.pem -days 30000 -extfile /tmp/uyatest_leaf.ext -sha256
openssl req -new -newkey rsa:2048 -nodes -keyout /tmp/uyatest_bad.key \
  -out /tmp/uyatest_bad.csr -subj "/O=Uya Test/CN=other.test"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nsubjectAltName=DNS:other.test\n" \
  > /tmp/uyatest_bad.ext
openssl x509 -req -in /tmp/uyatest_bad.csr -CA inter.pem -CAkey /tmp/uyatest_inter.key \
  -CAcreateserial -out badhost.pem -days 30000 -extfile /tmp/uyatest_bad.ext -sha256
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/uyatest_ecint.key
openssl req -new -key /tmp/uyatest_ecint.key -out /tmp/uyatest_ecint.csr \
  -subj "/O=Uya Test/CN=Uya Test EC CA"
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign\n" \
  > /tmp/uyatest_ecint.ext
openssl x509 -req -in /tmp/uyatest_ecint.csr -CA root.pem -CAkey /tmp/uyatest_root.key \
  -CAcreateserial -out ecinter.pem -days 30000 -extfile /tmp/uyatest_ecint.ext -sha256
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/uyatest_ecleaf.key
openssl req -new -key /tmp/uyatest_ecleaf.key -out /tmp/uyatest_ecleaf.csr \
  -subj "/O=Uya Test/CN=ec.test"
printf "basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:ec.test\n" \
  > /tmp/uyatest_ecleaf.ext
openssl x509 -req -in /tmp/uyatest_ecleaf.csr -CA ecinter.pem -CAkey /tmp/uyatest_ecint.key \
  -CAcreateserial -out ecleaf.pem -days 30000 -extfile /tmp/uyatest_ecleaf.ext -sha256
# SHA-1 自签根：它自己的签名算法不受支持，但**只作为父证书**用时仍要能建路
# （P110 的真实现场：GTS Root R1 交叉签 → GlobalSign Root CA，后者的自签名是 SHA-1）。
openssl req -x509 -newkey rsa:2048 -nodes -sha1 \
  -keyout /tmp/uyatest_sha1root.key -out sha1root.pem -days 30000 \
  -subj "/O=Uya Test/CN=Uya Test SHA1 Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -new -newkey rsa:2048 -nodes -keyout /tmp/uyatest_sha1leaf.key \
  -out /tmp/uyatest_sha1leaf.csr -subj "/O=Uya Test/CN=sha1.test"
printf "basicConstraints=critical,CA:FALSE\n\
keyUsage=critical,digitalSignature,keyEncipherment\n\
extendedKeyUsage=serverAuth\nsubjectAltName=DNS:sha1.test\n" \
  > /tmp/uyatest_sha1leaf.ext
# 正腿：根是 SHA-1 自签，但**叶子这一跳是 SHA-256**（要验的签名受支持）。
openssl x509 -req -in /tmp/uyatest_sha1leaf.csr -CA sha1root.pem \
  -CAkey /tmp/uyatest_sha1root.key -CAcreateserial -out sha1leaf.pem \
  -days 30000 -extfile /tmp/uyatest_sha1leaf.ext -sha256
# 负腿：叶子自己也是 SHA-1 签名 ⇒ 验签必须失败（不许因为根能解析就放行）。
openssl x509 -req -in /tmp/uyatest_sha1leaf.csr -CA sha1root.pem \
  -CAkey /tmp/uyatest_sha1root.key -CAcreateserial -out sha1signedleaf.pem \
  -days 30000 -extfile /tmp/uyatest_sha1leaf.ext -sha1
rm -f *.srl
echo "gen.sh: 夹具已重新生成（root/inter/leaf/badhost/ecinter/ecleaf/sha1*）"
