#!/bin/bash
set -euo pipefail

# 백업 복원 스크립트 — 호스트에서 실행하는 단 하나의 진입점이다.
#
#   ./scripts/restore.sh                     # 대화형: 키 입력 → 백업 목록 → 선택 → 방식 → 복원
#   ./scripts/restore.sh --list              # 최근 백업 목록만 (키 불필요)
#   ./scripts/restore.sh --latest <키파일>   # 최신 백업으로 복원
#   ./scripts/restore.sh <백업파일> <키파일> # 특정 백업으로 복원
#   RESTORE_DROP=true ./scripts/restore.sh   # 덮어쓰기(컬렉션 drop 후 복원)
#
# 동작: .env 로드 → 백업 컨테이너로 비밀키를 잠깐 복사 → 컨테이너 안에서
#       age 복호화 + mongorestore 를 인라인 실행 → 비밀키 삭제.
#       ★ 컨테이너의 restore.sh 가 아니라 안정적인 mongo-conn.sh(접속 헬퍼)만 사용하므로,
#         백업 컨테이너 이미지가 구버전이어도(restore 코드 갱신 전이어도) 복원이 동작한다.
# 호스트엔 docker 만 있으면 된다(mongorestore·age·CA 는 컨테이너 안).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # scripts/ 의 상위 = 프로젝트 루트(.env 위치)
cd "$PROJECT_ROOT"

ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE 가 없습니다. 프로젝트 루트에서 ./scripts/restore.sh 로 실행하세요."; exit 1; }

# .env 에서 필요한 값만 안전하게 추출 (전체 source 는 특수문자/공백에 취약)
get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
PROJECT="$(get_env COMPOSE_PROJECT_NAME)"; PROJECT="${PROJECT:-rs}"
BACKUP_DIR_HOST="$(get_env BACKUP_DIR)"; BACKUP_DIR_HOST="${BACKUP_DIR_HOST:-./backups}"
ROOT_PASS="$(get_env MONGO_ROOT_PASS)"
REPLICA_HOSTS="$(get_env MONGO_REPLICA_HOSTS)"
BACKUP_CONTAINER="${PROJECT}-mongo-backup"

docker inspect "$BACKUP_CONTAINER" >/dev/null 2>&1 || {
  echo "ERROR: '$BACKUP_CONTAINER' 컨테이너가 없습니다. 클러스터가 떠 있는지 확인하세요."; exit 1; }

list_files() { ls -t "$BACKUP_DIR_HOST"/backup-*.archive.gz* 2>/dev/null | head -"${1:-10}"; }
print_list() {
  local i=1 f
  echo "=== 최근 백업 (최신순) ==="
  for f in $(list_files "${1:-10}"); do
    printf "%2d) %s  (%s)\n" "$i" "$(basename "$f")" "$(du -h "$f" 2>/dev/null | cut -f1)"
    i=$((i+1))
  done
  if [ "$i" -eq 1 ]; then echo "  (백업 없음)"; fi
}

KEY=""; TARGET=""
case "${1:-}" in
  --list)
    print_list 10; exit 0 ;;
  --latest)
    KEY="${2:?사용법: ./scripts/restore.sh --latest <키파일>}"
    TARGET="$(list_files 1)"
    [ -n "$TARGET" ] || { echo "ERROR: 백업이 없습니다."; exit 1; }
    ;;
  "")
    INTERACTIVE=1
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
    TARGET="$1"; KEY="${2:?사용법: ./scripts/restore.sh <백업파일> <키파일>}"
    ;;
esac

[ -f "$KEY" ]    || { echo "ERROR: 키 파일 없음: $KEY"; exit 1; }
[ -f "$TARGET" ] || { echo "ERROR: 백업 파일 없음: $TARGET"; exit 1; }
BNAME="$(basename "$TARGET")"

# --- 복원 방식 선택 ---
# 대화형은 묻고, 플래그 모드(--latest 등)는 RESTORE_DROP 환경변수로 제어한다.
if [ "${INTERACTIVE:-0}" = "1" ]; then
  echo ""
  echo "복원 방식을 선택하세요:"
  echo "  1) 병합 (기본)  — 삭제·누락된 문서만 되살립니다. 기존 데이터는 그대로 둡니다."
  echo "  2) 덮어쓰기      — 컬렉션을 비우고 백업 시점 상태로 되돌립니다."
  echo "                    ⚠️  백업 이후에 생기거나 수정된 데이터는 사라집니다."
  read -rp "선택 [1]: " MODE
  case "${MODE:-1}" in
    2) RESTORE_DROP=true ;;
    *) RESTORE_DROP=false ;;
  esac
fi
RESTORE_DROP="${RESTORE_DROP:-false}"

echo ""
echo "복원 대상 : $BNAME"
echo "키 파일   : $KEY"
if [ "$RESTORE_DROP" = "true" ]; then
  echo "복원 방식 : 덮어쓰기 (백업 시점으로 완전 복구 — 이후 변경분 손실)"
  read -rp "정말 진행하려면 'overwrite' 를 입력하세요 (취소=엔터): " CONFIRM
  [ "$CONFIRM" = "overwrite" ] || { echo "취소됨."; exit 0; }
else
  echo "복원 방식 : 병합 (없는 문서만 추가, 기존 데이터 유지)"
  read -rp "복원하시겠습니까? (y/N): " OK
  [ "$OK" = "y" ] || [ "$OK" = "Y" ] || { echo "취소됨."; exit 0; }
fi

# 비밀키를 컨테이너로 임시 전달 → 복원 → 종료 시 키 삭제
TMPKEY="/tmp/.restore-key-$$"
docker cp "$KEY" "$BACKUP_CONTAINER:$TMPKEY" >/dev/null
trap 'docker exec "$BACKUP_CONTAINER" rm -f "$TMPKEY" >/dev/null 2>&1 || true' EXIT

# 여기부터 mongorestore 의 종료코드/출력을 직접 해석하므로 set -e 를 끈다(스크립트 끝).
set +e
echo ""
echo "복원 중..."
LOG="$(mktemp)"
# 복호화 + mongorestore 를 컨테이너 안에서 인라인 실행한다.
# 컨테이너의 restore.sh 에 의존하지 않고 mongo-conn.sh 만 사용 → 백업 이미지 버전과 무관.
# RESTORE_FILE/RESTORE_KEY 는 -e 로 전달(인라인 문자열 따옴표 문제 회피).
docker exec \
  -e MONGO_INITDB_ROOT_PASSWORD="$ROOT_PASS" \
  -e MONGO_REPLICA_HOSTS="$REPLICA_HOSTS" \
  -e RESTORE_DROP="$RESTORE_DROP" \
  -e RESTORE_FILE="/backups/$BNAME" \
  -e RESTORE_KEY="$TMPKEY" \
  "$BACKUP_CONTAINER" \
  bash -c '
    set -euo pipefail
    . /mongodb/mongo-conn.sh
    drop=(); if [ "${RESTORE_DROP:-false}" = "true" ]; then drop=(--drop); fi
    case "$RESTORE_FILE" in
      *.age) age -d -i "$RESTORE_KEY" "$RESTORE_FILE" | mongorestore "${MONGO_CONN_ARGS[@]}" --gzip --archive "${drop[@]}" ;;
      *)     mongorestore "${MONGO_CONN_ARGS[@]}" --gzip --archive "${drop[@]}" < "$RESTORE_FILE" ;;
    esac
  ' >"$LOG" 2>&1
RC=$?

# --- 결과 해석 (mongorestore 원문을 사람 친화적으로) ---
SUMMARY="$(grep 'restored successfully' "$LOG" | tail -1)"
OK_N="$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ document\(s\) restored' | grep -oE '^[0-9]+' | tail -1)"; OK_N="${OK_N:-0}"
FAIL_N="$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ document\(s\) failed' | grep -oE '^[0-9]+' | tail -1)"; FAIL_N="${FAIL_N:-0}"

echo ""
echo "── 결과 ──────────────────────────────────"
if [ "$RC" -ne 0 ] && [ -z "$SUMMARY" ]; then
  echo "❌ 복원 실패 (복호화·연결·인증 오류일 수 있음). 로그 마지막:"
  tail -5 "$LOG" | sed 's/^/   /'
  rm -f "$LOG"; exit 1
elif [ "$RESTORE_DROP" = "true" ]; then
  echo "✅ 백업 시점으로 복구 완료 (복원 ${OK_N}건)."
elif [ "$FAIL_N" -gt 0 ]; then
  echo "✅ 복원 ${OK_N}건. ${FAIL_N}건은 이미 존재하여 건너뜀(병합 모드 — 데이터 손실 아님)."
  echo "   백업 시점으로 완전히 되돌리려면 '덮어쓰기' 모드로 다시 실행하세요."
else
  echo "✅ 복원 ${OK_N}건 완료."
fi
rm -f "$LOG"
