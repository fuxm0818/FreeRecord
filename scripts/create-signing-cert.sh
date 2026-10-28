#!/usr/bin/env bash
# 在本机登录钥匙串里创建一张自签名代码签名证书（默认名 "FreeRec Dev"）。
#
# 为什么需要：macOS 的 TCC 授权按"代码签名身份"记账，ad-hoc 签名每次重新打包
# cdhash 都会变，屏幕录制授权随之失效。用一张固定的自签名证书后，授权能跨构建保留。
#
# 只需要跑一次；证书已存在时直接退出。私钥只留在本机钥匙串，不会上传。
set -euo pipefail

CERT_NAME="${CERT_NAME:-FreeRec Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$CERT_NAME\""; then
  echo "==> 证书「$CERT_NAME」已存在，无需重复创建"
  exit 0
fi

command -v openssl >/dev/null || { echo "!! 找不到 openssl"; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = code_sign_ext
prompt = no

[dn]
CN = $CERT_NAME

[code_sign_ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> 生成自签名证书"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/openssl.cnf" 2>/dev/null

openssl pkcs12 -export -name "$CERT_NAME" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:freerec 2>/dev/null

echo "==> 导入登录钥匙串"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P freerec -A

echo "==> 设为受信任的代码签名身份"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "==> 结果"
security find-identity -v -p codesigning | grep -E "\"$CERT_NAME\"|valid identities" || {
  echo "!! 未找到身份，请到「钥匙串访问」确认证书是否可用"; exit 1
}
echo "==> 完成。之后 bash scripts/build.sh 会自动用「$CERT_NAME」签名。"
echo "    撤销：security delete-identity -c \"$CERT_NAME\" \"$KEYCHAIN\""
