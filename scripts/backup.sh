#!/bin/bash
set -euo pipefail

# 백업 전용 컨테이너 entrypoint
# 일정 간격으로:  mongodump(secondaryPreferred, TLS) → gzip → age 암호화 → /backups
# 보관 기간(BACKUP_RETENTION_DAYS) 초과분은 자동 삭제한다.
#
# 환경변수:
#   MONGO_REPLICA_HOSTS          : 데이터 노드 목록 (host:port,host:port)
#   MONGO_INITDB_ROOT_USERNAME   : 백업에 사용할 계정 (기본 root)
#   MONGO_INITDB_ROOT_PASSWORD   : 위 계정 비밀번호 (필수)
#   BACKUP_DIR                   : 컨테이너 내 백업 경로 (호스트 폴더가 마운트됨, 기본 /backups)
#   BACKUP_INTERVAL              : 백업 주기(초). 기본 86400(매일)
#   BACKUP_RETENTION_DAYS        : 보관 일수. 기본 7
#   BACKUP_AGE_RECIPIENT         : age 공개키(recipient). 미설정 시 기본은 실패(fail-closed)
#   BACKUP_ALLOW_PLAINTEXT       : true 면 recipient 없이 평문 백업 허용(스펙 미충족, 의도적일 때만)
#   PKI_DIR                      : CA 위치 (기본 /pki)

# shellcheck source=/mongodb/mongo-conn.sh
. /mongodb/mongo-conn.sh

BACKUP_DIR="${BACKUP_DIR:-/backups}"
INTERVAL="${BACKUP_INTERVAL:-86400}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"

mkdir -p "$BACKUP_DIR"

# 암호화 설정 결정 — 백업 파일이 만들어지기 전에 fail-closed 로 검증한다.
# (recipient 미설정 시 조용히 평문으로 떨어지면 스펙 6.2.3 의 유일한 보안 속성이 사라지므로)
if [ -n "$RECIPIENT" ]; then
  EXT=".age"
  ENC=(age -r "$RECIPIENT")
  ENCRYPT=yes
elif [ "${BACKUP_ALLOW_PLAINTEXT:-false}" = "true" ]; then
  EXT=""
  ENC=(cat)
  ENCRYPT=no
  echo "WARNING: BACKUP_ALLOW_PLAINTEXT=true → 평문 백업입니다 (스펙 6.2.3 미충족)."
else
  echo "ERROR: BACKUP_AGE_RECIPIENT 가 비어 있습니다."
  echo "       age 공개키를 설정하거나, 의도적 평문이면 BACKUP_ALLOW_PLAINTEXT=true 로 실행하세요."
  exit 1
fi

# mongodump → gzip(archive) → (age | cat) → 호스트 폴더
# 평문이 디스크에 닿지 않도록 스트림으로 연결하고, .tmp → mv 로 원자적 저장한다.
run_backup() {
  local ts out tmp
  ts="$(date +%Y-%m-%d_%H%M%S)"
  out="$BACKUP_DIR/backup-$ts.archive.gz$EXT"
  tmp="$out.tmp"
  echo "[$(date -Is)] backup start"

  mongodump "${MONGO_CONN_ARGS[@]}" \
    --readPreference=secondaryPreferred \
    --gzip --archive \
    | "${ENC[@]}" > "$tmp"
  mv "$tmp" "$out"
  echo "[$(date -Is)] backup done: $out"

  # 보관 정책: RETENTION_DAYS 초과 파일 삭제 (mv 가 정리하지 못한 .tmp 잔여물 포함)
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup-*.archive.gz*' \
    -mtime +"$RETENTION_DAYS" -print -delete || true
}

echo "Backup service started. interval=${INTERVAL}s retention=${RETENTION_DAYS}d encrypt=${ENCRYPT}"
# 주의: 주기는 직전 백업 종료 시점부터 sleep 으로 측정한다. 컨테이너가 재시작되면
#       스케줄이 초기화되므로 고정된 벽시계 시각을 보장하지 않는다(정밀 시각이 필요하면 cron 사용).
while true; do
  # 한 번의 백업 실패가 서비스를 죽이지 않도록 실패를 흡수한다
  run_backup || echo "[$(date -Is)] backup FAILED"
  sleep "$INTERVAL"
done
