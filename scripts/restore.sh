#!/bin/bash
set -euo pipefail

# Host-side restore wrapper.
# Usage:
#   ./scripts/restore.sh
#   ./scripts/restore.sh --list
#   ./scripts/restore.sh --latest backup-key/backup-key.txt
#   ./scripts/restore.sh backups/backup-YYYY-MM-DD_HHMMSS.archive.gz.age backup-key/backup-key.txt
#   RESTORE_DROP=true ./scripts/restore.sh --latest backup-key/backup-key.txt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found. Run from package root."; exit 1; }

get_env() {
  grep -m1 -E "^$1=" "$ENV_FILE" | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'
}

PROJECT="$(get_env COMPOSE_PROJECT_NAME)"; PROJECT="${PROJECT:-rs}"
BACKUP_DIR_HOST="$(get_env BACKUP_DIR)"; BACKUP_DIR_HOST="${BACKUP_DIR_HOST:-./backups}"
ROOT_PASS="$(get_env MONGO_ROOT_PASS)"
REPLICA_HOSTS="$(get_env MONGO_REPLICA_HOSTS)"
APP_DB="$(get_env MONGO_NAME)"
BACKUP_CONTAINER="${PROJECT}-mongo-backup"
RESTORE_NS_INCLUDE="${RESTORE_NS_INCLUDE:-${APP_DB}.*}"

[ -n "$ROOT_PASS" ] || { echo "ERROR: MONGO_ROOT_PASS is empty in $ENV_FILE"; exit 1; }
[ -n "$REPLICA_HOSTS" ] || { echo "ERROR: MONGO_REPLICA_HOSTS is empty in $ENV_FILE"; exit 1; }
[ -n "$APP_DB" ] || { echo "ERROR: MONGO_NAME is empty in $ENV_FILE"; exit 1; }

docker inspect "$BACKUP_CONTAINER" >/dev/null 2>&1 || {
  echo "ERROR: container not found: $BACKUP_CONTAINER"; exit 1; }

mapfile -t FILES < <(ls -t "$BACKUP_DIR_HOST"/backup-*.archive.gz* 2>/dev/null | head -10)
print_list() {
  local i=1 f
  echo "=== Recent backups, newest first ==="
  for f in "${FILES[@]}"; do
    printf "%2d) %s  (%s)\n" "$i" "$(basename "$f")" "$(du -h "$f" 2>/dev/null | cut -f1)"
    i=$((i+1))
  done
  if [ "$i" -eq 1 ]; then echo "  (no backups found)"; fi
}

KEY=""; TARGET=""
case "${1:-}" in
  --list)
    print_list; exit 0 ;;
  --latest)
    KEY="${2:?Usage: ./scripts/restore.sh --latest <key-file>}"
    TARGET="${FILES[0]:-}"
    [ -n "$TARGET" ] || { echo "ERROR: no backups found"; exit 1; }
    ;;
  "")
    read -rp "age secret key file path: " KEY
    [ -f "$KEY" ] || { echo "ERROR: key file not found: $KEY"; exit 1; }
    [ "${#FILES[@]}" -gt 0 ] || { echo "ERROR: no backups found"; exit 1; }
    echo ""
    print_list
    echo ""
    read -rp "Select backup number (q=cancel): " SEL
    if [ "$SEL" = "q" ]; then echo "Canceled."; exit 0; fi
    [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#FILES[@]}" ] \
      || { echo "ERROR: invalid selection: $SEL"; exit 1; }
    TARGET="${FILES[$((SEL-1))]}"
    ;;
  *)
    TARGET="$1"; KEY="${2:?Usage: ./scripts/restore.sh <backup-file> <key-file>}"
    ;;
esac

[ -f "$KEY" ] || { echo "ERROR: key file not found: $KEY"; exit 1; }
[ -f "$TARGET" ] || { echo "ERROR: backup file not found: $TARGET"; exit 1; }
BNAME="$(basename "$TARGET")"

if [ "${RESTORE_DROP:-}" != "true" ] && [ "${1:-}" = "" ]; then
  echo ""
  echo "Restore mode:"
  echo "  1) merge (default): keep existing documents"
  echo "  2) overwrite: drop matching collections and restore backup state"
  read -rp "Select [1]: " MODE
  case "${MODE:-1}" in
    2) RESTORE_DROP=true ;;
    *) RESTORE_DROP=false ;;
  esac
fi
RESTORE_DROP="${RESTORE_DROP:-false}"

echo ""
echo "Backup file : $BNAME"
echo "Key file    : $KEY"
echo "Namespace   : $RESTORE_NS_INCLUDE"
if [ "$RESTORE_DROP" = "true" ]; then
  echo "Mode        : overwrite (drop app DB, then restore backup)"
  read -rp "Type 'overwrite' to continue: " CONFIRM
  [ "$CONFIRM" = "overwrite" ] || { echo "Canceled."; exit 0; }
else
  echo "Mode        : merge"
  read -rp "Continue? (y/N): " OK
  [ "$OK" = "y" ] || [ "$OK" = "Y" ] || { echo "Canceled."; exit 0; }
fi

TMPKEY="/tmp/.restore-key-$$"
docker cp "$KEY" "$BACKUP_CONTAINER:$TMPKEY" >/dev/null
trap 'docker exec "$BACKUP_CONTAINER" rm -f "$TMPKEY" >/dev/null 2>&1 || true' EXIT

set +e
LOG="$(mktemp)"
echo ""
echo "Restoring..."
docker exec \
  -e MONGO_INITDB_ROOT_USERNAME=root \
  -e MONGO_INITDB_ROOT_PASSWORD="$ROOT_PASS" \
  -e MONGO_REPLICA_HOSTS="$REPLICA_HOSTS" \
  -e RESTORE_DROP="$RESTORE_DROP" \
  -e RESTORE_FILE="/backups/$BNAME" \
  -e RESTORE_KEY="$TMPKEY" \
  -e RESTORE_NS_INCLUDE="$RESTORE_NS_INCLUDE" \
  -e RESTORE_DROP_DB="$APP_DB" \
  "$BACKUP_CONTAINER" \
  bash -c '
    set -euo pipefail
    helper=/mongodb/mongo-connect.sh
    [ -f "$helper" ] || helper=/mongodb/mongo-conn.sh
    . "$helper"
    if [ "${RESTORE_DROP:-false}" = "true" ] && [ -n "${RESTORE_DROP_DB:-}" ]; then
      mongosh --host "rs0/$HOSTS" \
        -u "$DB_USER" -p "$DB_PASS" --authenticationDatabase admin \
        --tls --tlsCAFile "$CA" "$RESTORE_DROP_DB" --quiet \
        --eval "db.dropDatabase()" >/dev/null
    fi
    drop=(); if [ "${RESTORE_DROP:-false}" = "true" ]; then drop=(--drop); fi
    ns=(); if [ -n "${RESTORE_NS_INCLUDE:-}" ]; then ns=(--nsInclude "$RESTORE_NS_INCLUDE"); fi
    case "$RESTORE_FILE" in
      *.age) age -d -i "$RESTORE_KEY" "$RESTORE_FILE" | mongorestore "${MONGO_CONN_ARGS[@]}" --gzip --archive "${drop[@]}" "${ns[@]}" ;;
      *)     mongorestore "${MONGO_CONN_ARGS[@]}" --gzip --archive "${drop[@]}" "${ns[@]}" < "$RESTORE_FILE" ;;
    esac
  ' >"$LOG" 2>&1
RC=$?

SUMMARY="$(grep 'restored successfully' "$LOG" | tail -1)"
OK_N="$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ document\(s\) restored' | grep -oE '^[0-9]+')"; OK_N="${OK_N:-0}"
FAIL_N="$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ document\(s\) failed' | grep -oE '^[0-9]+')"; FAIL_N="${FAIL_N:-0}"

echo ""
echo "== result =="
if [ "$RC" -ne 0 ] && [ -z "$SUMMARY" ]; then
  echo "Restore failed. Last log lines:"
  tail -5 "$LOG" | sed 's/^/  /'
  rm -f "$LOG"; exit 1
elif [ "$RESTORE_DROP" = "true" ]; then
  echo "Dropped app DB first, then restored backup state (${OK_N} documents restored)."
  if [ "$OK_N" = "0" ]; then
    echo "0 restored means the selected backup had no matching documents for $RESTORE_NS_INCLUDE."
  fi
elif [ "$FAIL_N" -gt 0 ]; then
  echo "Restored ${OK_N} documents. Skipped ${FAIL_N} existing documents in merge mode."
  echo "Use overwrite mode to return exactly to the backup state."
else
  echo "Restored ${OK_N} documents."
fi
rm -f "$LOG"
