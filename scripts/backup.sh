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
MIN_BYTES="${BACKUP_MIN_BYTES:-500}"          # 이보다 작으면 비정상 dump 로 간주(빈/깨진 백업 차단)
SUCCESS_MARKER="$BACKUP_DIR/.last-success"    # healthcheck 가 신선도 판정에 사용

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
# ★ run_backup 은 호출 측에서 `if run_backup` 로 평가되어 함수 내부 set -e 가 무력화되므로,
#   dump/encrypt 실패를 반드시 명시적으로 검사한다(실패본을 성공처럼 저장하지 않기 위함).
run_backup() {
  local ts out tmp
  ts="$(date +%Y-%m-%d_%H%M%S)"
  out="$BACKUP_DIR/backup-$ts.archive.gz$EXT"
  tmp="$out.tmp"
  echo "[$(date -Is)] backup start"

  # pipefail 덕분에 파이프라인 종료코드는 mongodump 실패를 반영한다.
  # 실패 시: 부분 .tmp 제거 + 실패 로그 + return 1 (mv/“done”에 도달하지 않음).
  if ! mongodump "${MONGO_CONN_ARGS[@]}" \
        --readPreference=secondaryPreferred \
        --gzip --archive \
        | "${ENC[@]}" > "$tmp"; then
    rm -f "$tmp"
    echo "[$(date -Is)] backup FAILED (dump/encrypt error)"
    return 1
  fi

  # 크기 하한 검사: mongodump 가 exit 0 이어도 출력이 비정상적으로 작으면 실패 처리
  # (정상 백업은 system 컬렉션만으로도 1KB 이상. 빈/깨진 dump 를 성공으로 남기지 않음)
  local sz
  sz="$(stat -c%s "$tmp")"
  if [ "$sz" -lt "$MIN_BYTES" ]; then
    rm -f "$tmp"
    echo "[$(date -Is)] backup FAILED (output too small: ${sz}B < ${MIN_BYTES}B)"
    return 1
  fi

  mv "$tmp" "$out"
  # 정상 성공 시각 기록 → healthcheck 가 "최근 성공 백업이 있는가" 판정에 사용
  date +%s > "$SUCCESS_MARKER"
  echo "[$(date -Is)] backup done: $out (${sz}B)"

  # 보관 정책: RETENTION_DAYS 초과 파일 삭제 (mv 가 정리하지 못한 .tmp 잔여물 포함)
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup-*.archive.gz*' \
    -mtime +"$RETENTION_DAYS" -print -delete || true
}

# 단일 실행 모드: `backup.sh once` 는 1회 백업 후 종료한다.
#   수동 백업 / 동작 확인 / 외부(bo-be 등)에서 온디맨드 트리거할 때 사용.
#   성공 시 exit 0, 실패 시 exit 1.
if [ "${1:-}" = "once" ]; then
  echo "Backup (once) interval=n/a retention=${RETENTION_DAYS}d encrypt=${ENCRYPT}"
  if run_backup; then exit 0; else exit 1; fi
fi

echo "Backup service started. interval=${INTERVAL}s retention=${RETENTION_DAYS}d encrypt=${ENCRYPT}"
# 주의: 주기는 직전 백업 종료 시점부터 sleep 으로 측정한다. 컨테이너가 재시작되면
#       스케줄이 초기화되므로 고정된 벽시계 시각을 보장하지 않는다(정밀 시각이 필요하면 cron 사용).
# 성공 시 INTERVAL, 실패 시 RETRY_DELAY 후 재시도한다.
#   → 기동 직후 root 계정 생성 전 race 로 첫 백업이 실패해도, 하루를 기다리지 않고 곧 재시도한다.
while true; do
  if run_backup; then
    sleep "$INTERVAL"
  else
    echo "[$(date -Is)] retrying in ${BACKUP_RETRY_DELAY:-300}s"
    sleep "${BACKUP_RETRY_DELAY:-300}"
  fi
done
