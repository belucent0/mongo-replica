#!/bin/bash
# 백업 컨테이너 healthcheck — "최근에 정상 백업이 있었는가"(신선도)로 판정한다.
#
# backup.sh 가 성공 시마다 기록하는 $BACKUP_DIR/.last-success(epoch) 를 읽어,
# 마지막 성공이 (BACKUP_INTERVAL + BACKUP_HEALTH_GRACE) 보다 오래되면 unhealthy(exit 1).
#   → 일시적 실패는 재시도로 흡수되어 healthy 유지,
#     정해진 기간 내 정상 백업이 없으면 docker ps/모니터링이 unhealthy 로 감지.
#
# 환경변수:
#   BACKUP_DIR           : 기본 /backups
#   BACKUP_INTERVAL      : 기본 86400(초)
#   BACKUP_HEALTH_GRACE  : 신선도 허용 여유(초). 기본 3600

MARKER="${BACKUP_DIR:-/backups}/.last-success"
INTERVAL="${BACKUP_INTERVAL:-86400}"
GRACE="${BACKUP_HEALTH_GRACE:-3600}"

# 아직 성공한 백업이 없음 → unhealthy (start_period 동안은 docker 가 무시)
[ -f "$MARKER" ] || { echo "no successful backup yet"; exit 1; }

last="$(cat "$MARKER" 2>/dev/null)"
case "$last" in
  ''|*[!0-9]*) echo "invalid marker"; exit 1 ;;
esac

now="$(date +%s)"
age=$(( now - last ))
threshold=$(( INTERVAL + GRACE ))

if [ "$age" -le "$threshold" ]; then
  echo "healthy: last backup ${age}s ago (<= ${threshold}s)"
  exit 0
else
  echo "STALE: last backup ${age}s ago (> ${threshold}s)"
  exit 1
fi
