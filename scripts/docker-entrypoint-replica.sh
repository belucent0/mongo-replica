#!/bin/bash
set -e

# 다중 노드 레플리카셋용 entrypoint (역할 인식)
#
# 환경변수:
#   MONGO_ROLE           : primary | secondary | arbiter
#   MONGO_NODE_NAME      : 이 노드의 호스트명 (= 인증서 파일명, compose 서비스명/네트워크 별칭)
#   MONGO_REPLICA_HOSTS  : 데이터 노드 목록 (host:port,...)  첫 항목이 primary 후보
#   MONGO_ARBITER_HOST   : 선택. arbiter host:port
#   MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD : root 계정
#   MONGO_NAME / MONGO_USER / MONGO_PASS : 앱 DB·계정
#
# 공유 PKI(/pki)는 init 컨테이너(gen-secrets.sh)가 먼저 생성한다.
# 노드는 항상 keyFile + TLS(preferTLS) 로 기동하며,
# primary 만 최초 1회 rs.initiate + 계정/뷰 생성을 수행한다(localhost exception 활용).

PKI="${PKI_DIR:-/pki}"
CA="$PKI/ca.pem"
KEYFILE="$PKI/mongodb-keyfile"
ROLE="${MONGO_ROLE:-secondary}"
NODE="${MONGO_NODE_NAME:?MONGO_NODE_NAME is required}"
CERT="$PKI/$NODE.pem"

# 1. 공유 PKI 준비 대기 (init 컨테이너 완료 대기, 방어적)
#    타임아웃을 둬서 인증서 누락(MONGO_NODE_NAME 이 MONGO_REPLICA_HOSTS 의 호스트와
#    불일치하는 경우 등)을 무한 대기 대신 명확한 오류로 드러낸다.
echo "Waiting for shared PKI ($CA, $CERT, $KEYFILE)..."
PKI_WAIT=0
until [ -f "$CA" ] && [ -f "$CERT" ] && [ -f "$KEYFILE" ]; do
  PKI_WAIT=$((PKI_WAIT + 1))
  if [ "$PKI_WAIT" -gt 150 ]; then
    echo "ERROR: PKI not ready after ~300s. Expected node cert: $CERT"
    echo "       MONGO_NODE_NAME('$NODE') must match a host in MONGO_REPLICA_HOSTS/MONGO_ARBITER_HOST."
    exit 1
  fi
  sleep 2
done
echo "PKI ready."

# 2. mongod 공통 옵션
#   MONGO_TLS_REQUIRED (기본 true, 스펙 준수):
#     true  → requireTLS  : 앱도 TLS 필수. mongodb://... 평문 접속은 거부됨
#     false → preferTLS   : 앱 평문/TLS 모두 허용. 노드 간은 어차피 TLS
#                            (기존 평문 자동화와 호환 — 단계적 전환용)
#   clusterAuthMode=x509: 노드 간 상호 인증을 X.509 인증서로 수행(mTLS)
#     - 모든 멤버 인증서가 동일 CA + 동일 O/OU 를 가져야 함(gen-secrets.sh 가 보장)
#     - keyFile 은 보조용으로 남겨두지만 클러스터 인증에는 x509 사용
#   tlsDisabledProtocols: 구버전 TLS(1.0/1.1) 명시적 비활성화
#   tlsAllowConnectionsWithoutCertificates: 앱이 클라이언트 인증서 없이 TLS 접속 가능
# 공백 트리밍 + 소문자 정규화 후 판정 (사용자 입력의 사소한 차이 흡수)
_tls_req="${MONGO_TLS_REQUIRED:-true}"
_tls_req="${_tls_req//[[:space:]]/}"
_tls_req="${_tls_req,,}"
case "$_tls_req" in
  false|0|no|n|off|disabled|disable) TLS_MODE=preferTLS ;;
  *)                                  TLS_MODE=requireTLS ;;  # 매칭 안 되면 안전한 쪽
esac
echo "TLS mode: $TLS_MODE (MONGO_TLS_REQUIRED=${MONGO_TLS_REQUIRED:-true})"

MONGOD_OPTS=(
  --replSet rs0
  --bind_ip_all
  --keyFile "$KEYFILE"
  --tlsMode "$TLS_MODE"
  --tlsCertificateKeyFile "$CERT"
  --tlsCAFile "$CA"
  --tlsDisabledProtocols TLS1_0,TLS1_1
  --clusterAuthMode x509
  --tlsAllowConnectionsWithoutCertificates
)

MONGOSH_TLS=(--tls --tlsCAFile "$CA" --tlsAllowInvalidHostnames)
# directConnection=true: 토폴로지 디스커버리를 끄고 127.0.0.1 직접 연결 유지
# (localhost exception 적용 및 primary 직접 타겟팅을 위해 init 단계 전체에서 사용)
LOCAL_PING="mongodb://127.0.0.1:27017/?directConnection=true"
LOCAL_ADMIN="mongodb://127.0.0.1:27017/admin?directConnection=true"
LOCAL_APPDB="mongodb://127.0.0.1:27017/${MONGO_NAME}?directConnection=true"

# 3. primary 최초 기동 시에만 초기화 수행
#    sentinel 파일로 완료를 판단한다 (WiredTiger 는 DB별 디렉토리를 만들지 않으므로
#    디렉토리 존재 여부는 신뢰할 수 없음 → 재시작 시 재초기화 방지)
INIT_DONE_MARKER=/data/db/.replica-init-done
if [ "$ROLE" = "primary" ] && [ ! -f "$INIT_DONE_MARKER" ]; then
  echo "=========================================="
  echo "PRIMARY first-boot initialization"
  echo "=========================================="

  mkdir -p /var/log/mongodb /var/run/mongodb
  chown mongodb:mongodb /var/log/mongodb /var/run/mongodb

  # keyFile + TLS 를 켠 채로 백그라운드 기동 (localhost exception 으로 초기 설정)
  mongod "${MONGOD_OPTS[@]}" --fork \
    --logpath /var/log/mongodb/mongod.log \
    --pidfilepath /var/run/mongodb/mongod.pid

  echo "Waiting for local mongod to accept connections..."
  until mongosh "$LOCAL_PING" "${MONGOSH_TLS[@]}" --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; do
    sleep 2
  done
  echo "Local mongod is ready."

  # 데이터 피어들이 TCP 로 응답할 때까지 대기 (rs.initiate 안정성)
  ALL_PEERS="$MONGO_REPLICA_HOSTS"
  [ -n "$MONGO_ARBITER_HOST" ] && ALL_PEERS="$ALL_PEERS,$MONGO_ARBITER_HOST"
  IFS=',' read -ra PEERS <<< "$ALL_PEERS"
  for entry in "${PEERS[@]}"; do
    entry="${entry//[[:space:]]/}"   # 공백 트리밍 (gen-secrets.sh 와 동일 정책)
    h="${entry%%:*}"; p="${entry##*:}"
    [ -z "$h" ] && continue
    [ "$h" = "$NODE" ] && continue
    echo "Waiting for peer $h:$p ..."
    PEER_WAIT=0
    until (echo > "/dev/tcp/$h/$p") 2>/dev/null; do
      PEER_WAIT=$((PEER_WAIT + 1))
      if [ "$PEER_WAIT" -gt 90 ]; then
        echo "ERROR: peer $h:$p not reachable after ~180s"
        exit 1
      fi
      sleep 2
    done
    echo "  peer $h:$p reachable"
  done

  # rs.initiate + PRIMARY 대기 (set -e 가 먼저 중단시키지 않도록 if 로 직접 판정)
  if ! bash /mongodb/init-replica-multi.sh; then
    echo "ERROR: Replica set initialization failed"
    exit 1
  fi

  # 이후 root 인증에 쓸 비밀번호를 미리 보관 (아래에서 env 를 unset 하므로)
  ROOT_PASS_SAVED="$MONGO_INITDB_ROOT_PASSWORD"

  # root 계정 생성 (localhost exception, 직접 연결 필수)
  echo "Creating root user..."
  export MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD
  mongosh "$LOCAL_ADMIN" "${MONGOSH_TLS[@]}" --quiet --file /mongodb/init-user.js
  echo "Root user step done."

  # 이후 작업은 root 로 인증하여 수행
  unset MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD

  if [ -z "$MONGO_NAME" ] || [ -z "$MONGO_USER" ] || [ -z "$MONGO_PASS" ]; then
    echo "ERROR: MONGO_NAME, MONGO_USER, MONGO_PASS are required"
    exit 1
  fi

  # 앱 계정 생성 (root 인증, 앱 DB 컨텍스트)
  echo "Creating application user..."
  env MONGO_NAME="$MONGO_NAME" MONGO_USER="$MONGO_USER" MONGO_PASS="$MONGO_PASS" \
    mongosh "$LOCAL_APPDB" "${MONGOSH_TLS[@]}" \
      -u root -p "$ROOT_PASS_SAVED" --authenticationDatabase admin \
      --quiet --file /mongodb/init-user.js
  echo "Application user step done."

  # 백업 전용 계정 생성 (root 인증, admin DB, 내장 'backup' 롤만)
  #   상시 도는 백업 컨테이너가 root 대신 이 최소권한 계정으로 mongodump 한다.
  #   실제 게이트는 PASS (USER 는 compose 가 backupUser 로 기본값 부여). 미설정 시 건너뜀.
  if [ -n "${MONGO_BACKUP_PASS:-}" ]; then
    echo "Creating backup user (backup role)..."
    env MONGO_BACKUP_USER="$MONGO_BACKUP_USER" MONGO_BACKUP_PASS="$MONGO_BACKUP_PASS" \
      mongosh "$LOCAL_ADMIN" "${MONGOSH_TLS[@]}" \
        -u root -p "$ROOT_PASS_SAVED" --authenticationDatabase admin \
        --quiet --file /mongodb/init-backup-user.js
    echo "Backup user step done."
  fi

  # 뷰 생성 (root 인증, 앱 DB)
  if [ -f /mongodb/init-view.js ]; then
    echo "Creating views..."
    env MONGO_NAME="$MONGO_NAME" \
      mongosh "$LOCAL_APPDB" "${MONGOSH_TLS[@]}" \
        -u root -p "$ROOT_PASS_SAVED" --authenticationDatabase admin \
        --quiet --file /mongodb/init-view.js
    echo "Views step done."
  fi

  # 초기화 완료 마커 기록 (이후 재시작 시 재초기화 방지)
  touch "$INIT_DONE_MARKER"
  chown mongodb:mongodb "$INIT_DONE_MARKER"

  echo "Shutting down init mongod..."
  mongod --shutdown
  echo "=========================================="
  echo "PRIMARY initialization completed."
  echo "=========================================="
fi

# 4. 모든 역할: 공식 entrypoint 로 제어를 넘겨 최종 mongod 를 포그라운드 실행
exec /usr/local/bin/docker-entrypoint.sh mongod "${MONGOD_OPTS[@]}"
