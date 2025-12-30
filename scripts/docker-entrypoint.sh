#!/bin/bash
set -e

# MongoDB가 처음 시작될 때만 인증 없이 시작하여 초기 설정 수행
# /data/db/admin 디렉토리가 없으면 (첫 시작) 인증 없이 시작
if [ ! -d /data/db/admin ]; then
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
  if [ -f /mongodb/init-replica.sh ]; then
    bash /mongodb/init-replica.sh
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to initialize Replica Set"
      exit 1
    fi
  else
    echo "ERROR: init-replica.sh not found"
    exit 1
  fi
  
  # Step 3: Root 사용자 생성 (통합 스크립트 사용)
  # docker-compose.yml에서 이미 설정된 환경변수 사용
  # MONGO_INITDB_ROOT_USERNAME이 존재하면 init-user.js가 root 사용자로 판별함
  export MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD
  
  if [ -f /mongodb/init-user.js ]; then
    mongosh admin --quiet --file /mongodb/init-user.js
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to create root user"
      exit 1
    else
      echo "Root user created successfully"
    fi
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
  # 표준 변수 직접 export (특수문자 포함 비밀번호를 위해 명시적으로 export)
  # 주의: 변수 값에 #이 포함되어 있어도 안전하게 전달되도록 따옴표 사용
  export MONGO_NAME="$MONGO_NAME"
  export MONGO_USER="$MONGO_USER"
  # MONGO_PASS는 특수문자(# 등)가 포함될 수 있으므로 안전하게 export
  export MONGO_PASS="$MONGO_PASS"
  
  # 디버깅: 환경변수 길이 확인 (비밀번호는 출력하지 않음)
  echo "DEBUG: MONGO_NAME length: ${#MONGO_NAME}"
  echo "DEBUG: MONGO_USER length: ${#MONGO_USER}"
  echo "DEBUG: MONGO_PASS length: ${#MONGO_PASS}"
    
  # init-user.js 파일이 있으면 실행, 없으면 스킵
  # 인증 없이 실행 (루트 사용자가 이미 생성되었지만 아직 인증이 활성화되지 않음)
  # 앱 사용자는 해당 DB에 생성하므로 해당 DB 컨텍스트에서 실행
    if [ -f /mongodb/init-user.js ]; then
    # 환경변수를 mongosh에 안전하게 전달 (env 명령어 사용)
    env MONGO_NAME="$MONGO_NAME" MONGO_USER="$MONGO_USER" MONGO_PASS="$MONGO_PASS" \
      mongosh "$MONGO_NAME" --quiet --file /mongodb/init-user.js
      if [ $? -ne 0 ]; then
      echo "ERROR: Failed to create application user"
      exit 1
      else
      echo "Application user created successfully"
      fi
    else
      echo "init-user.js not found, skipping application user creation"
  fi
  
  # Step 5: 뷰 생성 (인증 없이)
  echo "=========================================="
  echo "Step 5: Creating views..."
  echo "=========================================="
  
  # init-view.js 파일이 있으면 실행, 없으면 스킵
  # 인증 없이 실행
  if [ -f /mongodb/init-view.js ]; then
    export MONGO_NAME
    mongosh "$MONGO_NAME" --quiet --file /mongodb/init-view.js
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to create or verify views"
      exit 1
    else
      echo "Views created and verified successfully"
    fi
  else
    echo "init-view.js not found, skipping view creation"
  fi
  
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

# 초기화 이후에는 공식 entrypoint로 제어를 넘겨 최종 mongod를 실행한다
# (CMD에 설정된 --replSet/--keyFile 옵션 및 신호처리 로직을 그대로 활용)
exec /usr/local/bin/docker-entrypoint.sh "$@"

