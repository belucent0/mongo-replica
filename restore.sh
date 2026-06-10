#!/bin/bash
set -euo pipefail

# 호스트용 복원 래퍼 (대화형) — 프로젝트 디렉터리에서 실행한다.
#
# 사용:
#   ./restore.sh                       # 대화형: 키 입력 → 최근 백업 목록 → 선택 → 복원
#   ./restore.sh --list                # 최근 백업 목록만 표시 (키 불필요)
#   ./restore.sh --latest <키파일>     # 최신 백업으로 복원
#   ./restore.sh <백업파일> <키파일>   # 특정 백업으로 복원
#
# 내부적으로 백업 컨테이너의 /mongodb/restore.sh(엔진)를 docker exec 로 호출한다.
# (mongorestore·age·CA 는 컨테이너 안에 있으므로 호스트엔 docker 만 있으면 됨)
#
# 완전 덮어쓰기가 필요하면:  RESTORE_DROP=true ./restore.sh ...

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE 가 없습니다. 프로젝트 디렉터리에서 실행하세요."; exit 1; }

# .env 에서 필요한 값만 안전하게 추출 (전체 source 는 특수문자/공백에 취약)
get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
PROJECT="$(get_env COMPOSE_PROJECT_NAME)"; PROJECT="${PROJECT:-rs}"
BACKUP_DIR_HOST="$(get_env BACKUP_DIR)"; BACKUP_DIR_HOST="${BACKUP_DIR_HOST:-./backups}"
ROOT_PASS="$(get_env MONGO_ROOT_PASS)"
REPLICA_HOSTS="$(get_env MONGO_REPLICA_HOSTS)"
BACKUP_CONTAINER="${PROJECT}-mongo-backup"

docker inspect "$BACKUP_CONTAINER" >/dev/null 2>&1 || {
  echo "ERROR: '$BACKUP_CONTAINER' 컨테이너가 없습니다. 클러스터가 떠 있는지 확인하세요."; exit 1; }

# 최근 N개 백업 파일 경로(최신순)
list_files() { ls -t "$BACKUP_DIR_HOST"/backup-*.archive.gz* 2>/dev/null | head -"${1:-10}"; }

print_list() {
  local i=1 f
  echo "=== 최근 백업 (최신순) ==="
  for f in $(list_files "${1:-10}"); do
    printf "%2d) %s  (%s)\n" "$i" "$(basename "$f")" "$(du -h "$f" 2>/dev/null | cut -f1)"
    i=$((i+1))
  done
  # set -e 하에서 마지막 명령이 non-zero 를 반환하면 함수 호출부가 죽으므로 if 로 처리
  if [ "$i" -eq 1 ]; then echo "  (백업 없음)"; fi
}

KEY=""; TARGET=""
case "${1:-}" in
  --list)
    print_list 10; exit 0 ;;
  --latest)
    KEY="${2:?사용법: ./restore.sh --latest <키파일>}"
    TARGET="$(list_files 1)"
    [ -n "$TARGET" ] || { echo "ERROR: 백업이 없습니다."; exit 1; }
    ;;
  "")
    # 대화형
    read -rp "age 비밀키 파일 경로: " KEY
    [ -f "$KEY" ] || { echo "ERROR: 키 파일 없음: $KEY"; exit 1; }
    echo ""
    mapfile -t FILES < <(list_files 10)
    [ "${#FILES[@]}" -gt 0 ] || { echo "복원할 백업이 없습니다."; exit 1; }
    print_list 10
    echo ""
    read -rp "무엇을 복원하시겠습니까? (번호, q=취소): " SEL
    if [ "$SEL" = "q" ]; then echo "취소됨."; exit 0; fi
    [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#FILES[@]}" ] \
      || { echo "ERROR: 잘못된 선택: $SEL"; exit 1; }
    TARGET="${FILES[$((SEL-1))]}"
    ;;
  *)
    TARGET="$1"; KEY="${2:?사용법: ./restore.sh <백업파일> <키파일>}"
    ;;
esac

[ -f "$KEY" ]    || { echo "ERROR: 키 파일 없음: $KEY"; exit 1; }
[ -f "$TARGET" ] || { echo "ERROR: 백업 파일 없음: $TARGET"; exit 1; }
BNAME="$(basename "$TARGET")"

echo ""
echo "복원 대상 : $BNAME"
echo "키 파일   : $KEY"
[ "${RESTORE_DROP:-false}" = "true" ] && echo "모드      : 덮어쓰기(--drop)" || echo "모드      : 병합(기존 데이터 유지, 덮어쓰려면 RESTORE_DROP=true)"
read -rp "복원하시겠습니까? (y/N): " OK
[ "$OK" = "y" ] || [ "$OK" = "Y" ] || { echo "취소됨."; exit 0; }

# 비밀키를 컨테이너로 임시 전달 → 복원 → 종료 시 키 삭제
TMPKEY="/tmp/.restore-key-$$"
docker cp "$KEY" "$BACKUP_CONTAINER:$TMPKEY"
trap 'docker exec "$BACKUP_CONTAINER" rm -f "$TMPKEY" >/dev/null 2>&1 || true' EXIT

docker exec \
  -e MONGO_INITDB_ROOT_PASSWORD="$ROOT_PASS" \
  -e MONGO_REPLICA_HOSTS="$REPLICA_HOSTS" \
  -e RESTORE_DROP="${RESTORE_DROP:-false}" \
  "$BACKUP_CONTAINER" \
  /mongodb/restore.sh "/backups/$BNAME" "$TMPKEY"

echo "복원 완료: $BNAME"
