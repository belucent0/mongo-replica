#!/bin/bash
set -e

# TLS 인증서 자동 생성 스크립트
# 첫 기동 시 CA + 서버 인증서를 생성하고, 이후 재시작 시 기존 인증서를 재사용한다.

CERT_DIR="/data/db/certs"
CA_KEY="$CERT_DIR/ca.key"
CA_PEM="$CERT_DIR/ca.pem"
MONGO_KEY="$CERT_DIR/mongo.key"
MONGO_CRT="$CERT_DIR/mongo.crt"
MONGO_PEM="$CERT_DIR/mongo.pem"

if [ -f "$MONGO_PEM" ] && [ -f "$CA_PEM" ]; then
  echo "TLS certificates already exist. Skipping generation."
  return 0 2>/dev/null || exit 0
fi

echo "=========================================="
echo "Generating TLS certificates..."
echo "=========================================="

mkdir -p "$CERT_DIR"

# 1. CA 키 + 인증서 생성
echo "Step 1: Creating CA..."
openssl genrsa -out "$CA_KEY" 4096
openssl req -new -x509 -days 3650 -key "$CA_KEY" -out "$CA_PEM" \
  -subj "/CN=MongoDB Internal CA"

# 2. 서버 인증서 생성
echo "Step 2: Creating server certificate..."
openssl genrsa -out "$MONGO_KEY" 3072
openssl req -new -key "$MONGO_KEY" -out "$CERT_DIR/mongo.csr" \
  -subj "/CN=${MONGO_NODE_NAME:-mongodb}"

# SAN: 노드명(IPv4 면 IP:, 아니면 DNS:) + localhost + 환경변수 추가 SAN
NODE_NAME="${MONGO_NODE_NAME:-mongodb}"
if [[ "$NODE_NAME" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  SAN="IP:$NODE_NAME,DNS:localhost,IP:127.0.0.1"
else
  SAN="DNS:$NODE_NAME,DNS:localhost,IP:127.0.0.1"
fi
if [ -n "$MONGO_TLS_EXTRA_SAN" ]; then
  SAN="$SAN,$MONGO_TLS_EXTRA_SAN"
fi

openssl x509 -req -in "$CERT_DIR/mongo.csr" \
  -CA "$CA_PEM" -CAkey "$CA_KEY" -CAcreateserial \
  -days 825 -out "$MONGO_CRT" \
  -extfile <(printf "subjectAltName=%s" "$SAN")

# MongoDB는 key+cert 합본 PEM을 요구
cat "$MONGO_KEY" "$MONGO_CRT" > "$MONGO_PEM"

# 정리
rm -f "$CERT_DIR/mongo.csr" "$CERT_DIR/ca.srl"

# 권한 설정
chmod 400 "$CA_KEY" "$MONGO_KEY" "$MONGO_PEM"
chmod 444 "$CA_PEM"
chown -R mongodb:mongodb "$CERT_DIR"

echo "TLS certificates generated:"
echo "  CA:          $CA_PEM"
echo "  Server cert: $MONGO_PEM"
echo "  SAN:         $SAN"
echo "=========================================="
