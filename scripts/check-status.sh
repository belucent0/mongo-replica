#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found"; exit 1; }

env_value() {
  local key="$1" val
  val="$(awk -v key="$key" '
    index($0, key "=") == 1 {
      sub("^[^=]*=", "")
      sub("\r$", "")
      print
      exit
    }
  ' "$ENV_FILE")"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s' "$val"
}

ROOT_PASS="$(env_value MONGO_ROOT_PASS)"
[ -n "$ROOT_PASS" ] || { echo "ERROR: MONGO_ROOT_PASS is empty in $ENV_FILE"; exit 1; }
APP_DB="$(env_value MONGO_NAME)"
APP_USER="$(env_value MONGO_USER)"
APP_PASS="$(env_value MONGO_PASS)"
REPLICA_HOSTS="$(env_value MONGO_REPLICA_HOSTS)"
[ -n "$APP_DB" ] || { echo "ERROR: MONGO_NAME is empty in $ENV_FILE"; exit 1; }
[ -n "$APP_USER" ] || { echo "ERROR: MONGO_USER is empty in $ENV_FILE"; exit 1; }
[ -n "$APP_PASS" ] || { echo "ERROR: MONGO_PASS is empty in $ENV_FILE"; exit 1; }
[ -n "$REPLICA_HOSTS" ] || { echo "ERROR: MONGO_REPLICA_HOSTS is empty in $ENV_FILE"; exit 1; }

COMPOSE=(docker compose --env-file "$ENV_FILE")

echo "== containers =="
"${COMPOSE[@]}" ps

echo
echo "== replica =="
"${COMPOSE[@]}" exec -T mongo1 mongosh \
  "mongodb://127.0.0.1:27017/admin?directConnection=true" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames \
  -u root -p "$ROOT_PASS" --authenticationDatabase admin --quiet \
  --eval 'const s=rs.status(); s.members.forEach(m => print(m.name, m.stateStr)); if (!s.members.some(m => m.stateStr === "PRIMARY")) quit(2);'

echo
echo "== app tls ping =="
"${COMPOSE[@]}" exec -T mongo1 mongosh \
  "mongodb://${REPLICA_HOSTS}/${APP_DB}?replicaSet=rs0&authSource=${APP_DB}&tls=true&tlsCAFile=/pki/ca.pem" \
  -u "$APP_USER" -p "$APP_PASS" --quiet \
  --eval 'const r=db.runCommand({ping:1}); print("ok:", r.ok); if (r.ok !== 1) quit(2);'

echo
echo "== backup health =="
"${COMPOSE[@]}" exec -T mongo-backup /mongodb/backup-healthcheck.sh

cat <<'EOF'

Note:
  If this was run right after docker compose up -d, temporary errors such as
  Authentication failed, no successful backup yet, quiesce mode, or ECONNREFUSED
  can appear while MongoDB initializes users, elects PRIMARY, and completes the
  first backup. Wait about 60 seconds and run this script again.
EOF
