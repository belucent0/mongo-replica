#!/bin/bash
set -e

# 공유 PKI 생성 스크립트 (init 컨테이너에서 1회 실행)
# 레플리카셋 전 노드가 공유해야 하는 비밀을 생성한다:
#   - CA (ca.pem / ca.key)            : 모든 노드가 신뢰하는 루트 인증서
#   - keyFile (mongodb-keyfile)        : 노드 간 내부 인증 (모든 노드 동일해야 함)
#   - 노드별 서버 인증서 (<host>.pem)  : 각 노드 고유, 같은 CA로 서명
#
# 노드 인증서의 O/OU는 모든 노드가 동일하게 발급한다.
# (추후 clusterAuthMode=x509 로 승격 시 멤버 인증서 매칭 조건을 충족하기 위함)

PKI="${PKI_DIR:-/pki}"
# 모든 노드 인증서가 동일 O/OU 를 가져야 clusterAuthMode=x509 클러스터 멤버로 인정됨
# 운영자가 자기 조직명으로 발급하고 싶으면 MONGO_CERT_O / MONGO_CERT_OU 환경변수로 덮어쓰기
CERT_SUBJ_PREFIX="/O=${MONGO_CERT_O:-MongoDB-RS}/OU=${MONGO_CERT_OU:-Cluster}"

if [ -z "$MONGO_REPLICA_HOSTS" ]; then
  echo "ERROR: MONGO_REPLICA_HOSTS is required (e.g. mongo1:27017,mongo2:27017)"
  exit 1
fi

mkdir -p "$PKI"

echo "=========================================="
echo "Ensuring shared PKI in $PKI"
echo "=========================================="

# 1. CA (없을 때만 생성 — 부분 실패/노드 추가 시에도 재사용)
if [ ! -f "$PKI/ca.pem" ] || [ ! -f "$PKI/ca.key" ]; then
  echo "Step 1: Creating CA..."
  openssl genrsa -out "$PKI/ca.key" 4096
  openssl req -new -x509 -days 3650 -key "$PKI/ca.key" -out "$PKI/ca.pem" \
    -subj "${CERT_SUBJ_PREFIX}/CN=MongoDB Internal CA"
else
  echo "Step 1: CA already exists, reusing."
fi

# 2. 공유 keyFile (없을 때만 생성)
if [ ! -f "$PKI/mongodb-keyfile" ]; then
  echo "Step 2: Creating shared keyFile..."
  openssl rand -base64 756 > "$PKI/mongodb-keyfile"
else
  echo "Step 2: keyFile already exists, reusing."
fi

# 3. 노드별 서버 인증서 (arbiter 포함 모든 호스트) — 없는 것만 생성
ALL_HOSTS="$MONGO_REPLICA_HOSTS"
if [ -n "$MONGO_ARBITER_HOST" ]; then
  ALL_HOSTS="$ALL_HOSTS,$MONGO_ARBITER_HOST"
fi

echo "Step 3: Ensuring per-node certificates..."
IFS=',' read -ra HOST_ENTRIES <<< "$ALL_HOSTS"
for entry in "${HOST_ENTRIES[@]}"; do
  entry="${entry//[[:space:]]/}"   # 사용자가 'host1, host2' 처럼 공백 넣어도 안전하게
  host="${entry%%:*}"
  [ -z "$host" ] && continue
  if [ -f "$PKI/$host.pem" ]; then
    echo "  ✓ $host.pem (exists)"
    continue
  fi

  # SAN: host 가 IPv4 면 IP: 로, 아니면 DNS: 로 등록해야 mongod 의 노드 간
  # TLS 호스트명 검증을 통과한다(IP 연결은 DNS SAN 과 매칭되지 않음).
  if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    san="IP:$host,DNS:localhost,IP:127.0.0.1"
  else
    san="DNS:$host,DNS:localhost,IP:127.0.0.1"
  fi

  openssl genrsa -out "$PKI/$host.key" 3072
  openssl req -new -key "$PKI/$host.key" -out "$PKI/$host.csr" \
    -subj "${CERT_SUBJ_PREFIX}/CN=$host"

  openssl x509 -req -in "$PKI/$host.csr" \
    -CA "$PKI/ca.pem" -CAkey "$PKI/ca.key" -CAcreateserial \
    -days 825 -out "$PKI/$host.crt" \
    -extfile <(printf "subjectAltName=%s" "$san")

  cat "$PKI/$host.key" "$PKI/$host.crt" > "$PKI/$host.pem"
  rm -f "$PKI/$host.csr"
  echo "  ✓ $host.pem (created, SAN=$san)"
done

# 4. 권한 설정 (mongod 는 keyFile/key 가 그룹·기타 접근 불가여야 기동)
rm -f "$PKI/ca.srl"
chmod 400 "$PKI"/*.key "$PKI"/*.pem "$PKI/mongodb-keyfile"
chmod 444 "$PKI/ca.pem"
chown -R mongodb:mongodb "$PKI"

echo "=========================================="
echo "Shared PKI generation completed."
echo "  CA:       $PKI/ca.pem"
echo "  keyFile:  $PKI/mongodb-keyfile"
echo "  hosts:    $ALL_HOSTS"
echo "=========================================="
