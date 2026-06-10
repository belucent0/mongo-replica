#!/bin/bash
set -euo pipefail

# 백업 복원 스크립트 (수동 실행 — 비밀키가 있는 안전한 환경에서)
#
# 암호화 백업(.age)을 복원하려면 age 비밀키(identity)가 필요하다.
# 비밀키는 운영 서버에 두지 않으므로, 보통 비밀키를 가진 별도 신뢰 환경에서 실행한다.
#
# 사용법:
#   restore.sh <backup-file> [age-identity-file]
#     - backup-*.archive.gz.age  : age 비밀키 파일 인자 필수
#     - backup-*.archive.gz      : 평문 백업, 비밀키 불필요
#
# 환경변수: backup.sh 와 동일 (MONGO_REPLICA_HOSTS, MONGO_INITDB_ROOT_*, PKI_DIR)
#
# 주의: mongorestore 는 기본적으로 기존 데이터에 병합한다.
#       완전 덮어쓰기가 필요하면 RESTORE_DROP=true 로 실행한다(컬렉션 drop 후 복원).

# shellcheck source=/mongodb/mongo-conn.sh
. /mongodb/mongo-conn.sh

FILE="${1:?복원할 backup 파일 경로가 필요합니다}"
IDENTITY="${2:-}"

DROP_ARG=()
if [ "${RESTORE_DROP:-false}" = "true" ]; then
  DROP_ARG=(--drop)
  echo "RESTORE_DROP=true → 기존 컬렉션을 drop 후 복원합니다."
fi

restore_stream() {
  mongorestore "${MONGO_CONN_ARGS[@]}" --gzip --archive "${DROP_ARG[@]}"
}

case "$FILE" in
  *.age)
    if [ -z "$IDENTITY" ]; then
      echo "ERROR: 암호화 백업(.age)은 age 비밀키 파일이 필요합니다."
      echo "       사용법: restore.sh $FILE <age-identity-file>"
      exit 1
    fi
    # age -d 는 AEAD 인증 태그를 검증한다. 변조되었거나 키가 틀리면 실패하여
    # 파이프가 끊기고 mongorestore 는 실행되지 않는다(스펙 6.2.3 무결성 검증).
    echo "복호화 + 복원 시작: $FILE"
    age -d -i "$IDENTITY" "$FILE" | restore_stream
    ;;
  *)
    echo "복원 시작(평문): $FILE"
    restore_stream < "$FILE"
    ;;
esac

echo "복원 완료: $FILE"
