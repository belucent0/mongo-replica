#!/bin/bash
# 백업/복원 스크립트 공용 — MongoDB 접속 설정을 한 곳에서 관리한다.
# source 해서 사용:  . /mongodb/mongo-conn.sh
#
# 노출 변수:
#   CA               : CA 인증서 경로
#   HOSTS            : 데이터 노드 목록 (host:port,host:port)
#   DB_USER/DB_PASS  : 접속 계정
#   MONGO_CONN_ARGS  : mongodump/mongorestore 공통 접속 인자 배열
#                      (replSet 시드 + 인증 + TLS). 배열로 두어 값에 특수문자/공백이 있어도 안전.

CA="${PKI_DIR:-/pki}/ca.pem"
HOSTS="${MONGO_REPLICA_HOSTS:?MONGO_REPLICA_HOSTS is required}"
DB_USER="${MONGO_INITDB_ROOT_USERNAME:-root}"
DB_PASS="${MONGO_INITDB_ROOT_PASSWORD:?MONGO_INITDB_ROOT_PASSWORD is required}"

MONGO_CONN_ARGS=(
  --host "rs0/$HOSTS"
  -u "$DB_USER" -p "$DB_PASS" --authenticationDatabase admin
  --ssl --sslCAFile "$CA"
)
