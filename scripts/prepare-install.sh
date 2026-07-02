#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAR="${IMAGE_TAR:-mongo-replica-1.0.2.tar.gz}"
IMAGE="${MONGO_IMAGE:-mongo-replica:1.0.2}"
ENV_FILE="${ENV_FILE:-.env}"
KEY_FILE="${KEY_FILE:-./backup-key/backup-key.txt}"

if [ ! -f docker-compose.yml ] || [ ! -f .env.example ]; then
  echo "ERROR: docker-compose.yml and .env.example must exist in current directory"
  exit 1
fi

env_value() {
  awk -v key="$1" '
    index($0, key "=") == 1 {
      sub("^[^=]*=", "")
      sub("\r$", "")
      print
      exit
    }
  ' "$ENV_FILE"
}

if [ -f "$IMAGE_TAR" ]; then
  echo "Loading image: $IMAGE_TAR"
  docker load -i "$IMAGE_TAR"
else
  echo "Image tar not found: $IMAGE_TAR (skip docker load)"
fi

mkdir -p "$(dirname "$KEY_FILE")"
if [ ! -f "$KEY_FILE" ]; then
  echo "Generating backup age key: $KEY_FILE"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$PWD/$(dirname "$KEY_FILE"):/out" \
    --entrypoint age-keygen \
    "$IMAGE" \
    -o "/out/$(basename "$KEY_FILE")"
else
  echo "Backup age key already exists: $KEY_FILE"
fi

PUB="$(grep -m1 'public key:' "$KEY_FILE" | sed 's/.*public key: //')"
if [ -z "$PUB" ]; then
  echo "ERROR: public key not found in $KEY_FILE"
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  echo "$ENV_FILE already exists (not overwritten)"
else
  echo "Creating $ENV_FILE"
  cat > "$ENV_FILE" <<EOF_ENV
# ==================== Compose / Network ====================
COMPOSE_PROJECT_NAME=rs
MONGO_IMAGE=$IMAGE
DOCKER_NETWORK_NAME=app-net

# ==================== MongoDB Replica Set ====================
MONGO_REPLICA_HOSTS=mongo1:27017,mongo2:27017
MONGO_ARBITER_HOST=mongo3:27017
MONGO_TLS_REQUIRED=true

# ==================== MongoDB Account ====================
MONGO_ROOT_PASS=CHANGE_ME_ROOT
MONGO_NAME=myapp
MONGO_USER=appUser
MONGO_PASS=CHANGE_ME_APP

# ==================== Backup ====================
MONGO_BACKUP_USER=backupUser
MONGO_BACKUP_PASS=CHANGE_ME_BACKUP
BACKUP_DIR=./backups
BACKUP_INTERVAL=86400
BACKUP_RETENTION_DAYS=7
BACKUP_RETRY_DELAY=30
BACKUP_HEALTH_GRACE=3600
BACKUP_MIN_BYTES=500
BACKUP_AGE_RECIPIENT=$PUB
EOF_ENV
fi

PROJECT_NAME="$(env_value COMPOSE_PROJECT_NAME)"
PROJECT_NAME="${PROJECT_NAME:-rs}"

for volume in mongo_pki mongo_ca mongo1_data mongo2_data mongo3_data; do
  volume_name="${PROJECT_NAME}_${volume}"
  if docker volume inspect "$volume_name" >/dev/null 2>&1; then
    echo "Docker volume already exists: $volume_name"
  else
    echo "Creating docker volume: $volume_name"
    docker volume create "$volume_name" >/dev/null
  fi
done

NETWORK_NAME="$(env_value DOCKER_NETWORK_NAME)"
NETWORK_NAME="${NETWORK_NAME:-app-net}"
if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  echo "Docker network already exists: $NETWORK_NAME"
else
  echo "Creating docker network: $NETWORK_NAME"
  docker network create "$NETWORK_NAME" >/dev/null
fi

cat <<EOF

Prepared.

Next:
  1) Check $ENV_FILE
  2) Start:
       docker compose up -d
  3) Wait about 60 seconds, then check:
       ./scripts/check-status.sh

Note:
  Right after startup, temporary errors such as Authentication failed,
  no successful backup yet, or ECONNREFUSED can appear while MongoDB
  initializes users, elects PRIMARY, and completes the first backup.

Keep this private key safe:
  $KEY_FILE
EOF
