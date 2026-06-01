#!/bin/bash
set -e

# TLS 인증서 생성 (첫 기동 시에만, 이후 재사용)
if [ -f /mongodb/init-tls.sh ]; then
  bash /mongodb/init-tls.sh
fi

# MongoDB가 처음 시작될 때만 인증 없이 시작하여 초기 설정 수행
# sentinel 파일로 완료를 판단한다 (WiredTiger 는 DB별 디렉토리를 만들지 않으므로
# 디렉토리 존재 여부는 신뢰할 수 없음 → 재시작 시 재초기화 방지)
INIT_DONE_MARKER=/data/db/.init-done
if [ ! -f "$INIT_DONE_MARKER" ]; then
  echo "=========================================="
  echo "First start detected. Initializing MongoDB..."
  echo "Step 1: Starting MongoDB without authentication..."
  echo "=========================================="
  
  # --fork 옵션 사용 시 반드시 --logpath가 필요함 (MongoDB 요구사항)
  mkdir -p /var/log/mongodb /var/run/mongodb
  chown mongodb:mongodb /var/log/mongodb /var/run/mongodb
  
  # 인증 없이 MongoDB 시작 (백그라운드, keyFile 없이, 레플리카셋 옵션 포함)
  # --fork: 백그라운드 실행 (초기 설정을 위해 필요)
  # --logpath: --fork 사용 시 필수 (초기 설정 로그 저장용)
  # --pidfilepath: 프로세스 관리용 (mongod --shutdown 시 필요)
  mongod --replSet rs0 --bind_ip_all --fork --logpath /var/log/mongodb/mongod.log --pidfilepath /var/run/mongodb/mongod.pid
  
  # MongoDB가 준비될 때까지 대기
  echo "Waiting for MongoDB to be ready..."
  until mongosh --quiet --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
    sleep 2
  done
  echo "MongoDB is ready."
  
  # Step 2: Replica Set 초기화 및 PRIMARY 대기 (분리된 스크립트 사용)
  #         실패 시 set -e 가 즉시 중단시키므로 별도 $? 체크 불필요
  if [ -f /mongodb/init-replica.sh ]; then
    bash /mongodb/init-replica.sh
  else
    echo "ERROR: init-replica.sh not found"
    exit 1
  fi

  # Step 3: Root 사용자 생성 (통합 스크립트 사용)
  # MONGO_INITDB_ROOT_USERNAME이 존재하면 init-user.js가 root 사용자로 판별함
  export MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD

  if [ -f /mongodb/init-user.js ]; then
    mongosh admin --quiet --file /mongodb/init-user.js
    echo "Root user created successfully"
  else
    echo "ERROR: init-user.js not found"
    exit 1
  fi
  
  # Step 4: 일반 사용자 생성 (인증 없이, 루트 사용자로 생성)
  echo "=========================================="
  echo "Step 4: Creating application user..."
  echo "=========================================="
  
  # 환경 변수 검증 (필수 환경변수 확인)
  if [ -z "$MONGO_NAME" ] || [ -z "$MONGO_USER" ] || [ -z "$MONGO_PASS" ]; then
    echo "ERROR: MONGO_NAME, MONGO_USER, and MONGO_PASS are required"
    exit 1
  fi
  
  # MONGO_INITDB_ROOT_USERNAME을 unset하여 init-user.js가 앱 사용자로 판별하도록 함
  unset MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD

  # 앱 사용자 생성 (mongosh 가 해당 DB 컨텍스트에서 실행, 환경변수는 env 로 안전 전달)
  if [ -f /mongodb/init-user.js ]; then
    env MONGO_NAME="$MONGO_NAME" MONGO_USER="$MONGO_USER" MONGO_PASS="$MONGO_PASS" \
      mongosh "$MONGO_NAME" --quiet --file /mongodb/init-user.js
    echo "Application user created successfully"
  else
    echo "init-user.js not found, skipping application user creation"
  fi
  
  # Step 5: 뷰 생성 (인증 없이)
  echo "=========================================="
  echo "Step 5: Creating views..."
  echo "=========================================="
  
  # 뷰 생성 (있으면 실행)
  if [ -f /mongodb/init-view.js ]; then
    export MONGO_NAME
    mongosh "$MONGO_NAME" --quiet --file /mongodb/init-view.js
    echo "Views created and verified successfully"
  else
    echo "init-view.js not found, skipping view creation"
  fi
  
  # 초기화 완료 마커 기록 (이후 재시작 시 재초기화 방지)
  touch "$INIT_DONE_MARKER"
  chown mongodb:mongodb "$INIT_DONE_MARKER"

  # MongoDB 종료
  echo "Shutting down MongoDB..."
  mongod --shutdown
  
  echo "=========================================="
  echo "Initial setup completed successfully!"
  echo "MongoDB will restart with authentication enabled."
  echo "=========================================="
fi

# keyfile 존재 확인 (최종 재시작 전)
# keyfile이 없으면 MongoDB가 --keyFile 옵션으로 시작할 수 없음
if [ ! -f /data/db/mongodb-keyfile ]; then
  echo "WARNING: MongoDB keyfile not found. Creating it now..."
  openssl rand -base64 756 > /data/db/mongodb-keyfile
  chmod 400 /data/db/mongodb-keyfile
  chown mongodb:mongodb /data/db/mongodb-keyfile
  echo "MongoDB keyfile created successfully at /data/db/mongodb-keyfile"
fi

# TLS 인증서가 존재하면 TLS 옵션을 CMD에 추가
# MONGO_TLS_REQUIRED (기본 true, 스펙 준수):
#   true  → requireTLS : 앱도 TLS 필수. 평문 접속 거부.
#   false → allowTLS   : 앱 평문/TLS 모두 허용 (기존 자동화 호환용)
# --tlsAllowConnectionsWithoutCertificates: 클라이언트 인증서(mTLS) 없이도 TLS 접속 가능
# --tlsDisabledProtocols: 구버전 TLS(1.0/1.1) 명시적 비활성화
if [ -f /data/db/certs/mongo.pem ] && [ -f /data/db/certs/ca.pem ]; then
  # 공백 트리밍 + 소문자 정규화 후 판정 (사용자 입력의 사소한 차이 흡수)
  _tls_req="${MONGO_TLS_REQUIRED:-true}"
  _tls_req="${_tls_req//[[:space:]]/}"
  _tls_req="${_tls_req,,}"
  case "$_tls_req" in
    false|0|no|n|off|disabled|disable) TLS_MODE=allowTLS ;;
    *)                                  TLS_MODE=requireTLS ;;  # 매칭 안 되면 안전한 쪽
  esac
  echo "TLS certificates found. mode=$TLS_MODE (MONGO_TLS_REQUIRED=${MONGO_TLS_REQUIRED:-true})"
  set -- "$@" \
    --tlsMode "$TLS_MODE" \
    --tlsCertificateKeyFile /data/db/certs/mongo.pem \
    --tlsCAFile /data/db/certs/ca.pem \
    --tlsDisabledProtocols TLS1_0,TLS1_1 \
    --tlsAllowConnectionsWithoutCertificates
fi

# 초기화 이후에는 공식 entrypoint로 제어를 넘겨 최종 mongod를 실행한다
# (CMD에 설정된 --replSet/--keyFile 옵션 및 신호처리 로직을 그대로 활용)
exec /usr/local/bin/docker-entrypoint.sh "$@"

