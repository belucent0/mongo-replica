#!/bin/bash
set -euo pipefail
# ============================================================================
# 레플리카셋 스모크: 빌드한 이미지로 3노드 레플리카셋을 띄워 핵심 동작을 검증한다.
#   기동(rs.initiate + PKI/TLS) → backupUser 백업 once → 복원 roundtrip → 데이터 일치
# 깨진 init/엔트리포인트/백업/복원을 배포 전에 잡는다.
#
# 인자: $1 = 검증할 이미지 태그 (CI 가 build 한 mongo-rs:<버전>)
#
# CI에서 `bash scripts/smoke-replica.sh "$IMG"` 로 호출한다.
# 멀티컨테이너 compose-up 은 이 스크립트 안에서만 다루므로 템플릿 surface 를 늘리지 않는다.
# 격리: 고유 프로젝트명/네트워크 + host 포트 미노출 → 운영/타 파이프라인과 무충돌.
# ============================================================================
IMG="${1:?사용법: smoke-replica.sh <image>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ID="${CI_PIPELINE_ID:-$$}"
PROJ="mongosmoke-${ID}"
WORK="$(mktemp -d)"
ENVF="$WORK/.env"
TLS=(--tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames)
RP='CHANGE_ME_SMOKE'
# 레플리카셋 연결(directConnection 아님) — election 으로 mongo2 가 PRIMARY 여도 드라이버가
# 자동으로 PRIMARY 로 쓰기/읽기를 라우팅한다(실제 앱 연결 방식과 동일).
ADM="mongodb://root:CHANGE_ME_SMOKE@mongo1:27017,mongo2:27017/admin?replicaSet=rs0&authSource=admin"
APP="mongodb://root:CHANGE_ME_SMOKE@mongo1:27017,mongo2:27017/ci?replicaSet=rs0&authSource=admin"

dc() { docker compose -f docker-compose.yml --env-file "$ENVF" "$@"; }
cleanup() {
  if [ -n "${SMOKE_KEEP:-}" ]; then echo "SMOKE_KEEP set → 정리 생략 (project=$PROJ, work=$WORK)"; return 0; fi
  dc down -v >/dev/null 2>&1 || true
  for v in mongo_pki mongo_ca mongo1_data mongo2_data mongo3_data; do
    docker volume rm "${PROJ}_${v}" >/dev/null 2>&1 || true
  done
  docker network rm "${PROJ}-net" >/dev/null 2>&1 || true
  # 백업 파일은 컨테이너가 root 로 bind-mount 에 써서 host 에선 root 소유 → 컨테이너(root)로 제거
  [ -d "$WORK" ] && docker run --rm --user 0 -v "$WORK:/w" --entrypoint sh "$IMG" -c 'rm -rf /w/backups' >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# age 공개키 (백업 fail-closed 충족)
docker run --rm --entrypoint age-keygen "$IMG" 2>/dev/null > "$WORK/key.txt"
PUB="$(grep 'public key:' "$WORK/key.txt" | sed 's/.*public key: //')"

cat > "$ENVF" <<EOF
COMPOSE_PROJECT_NAME=$PROJ
MONGO_IMAGE=$IMG
DOCKER_NETWORK_NAME=${PROJ}-net
MONGO_REPLICA_HOSTS=mongo1:27017,mongo2:27017
MONGO_ARBITER_HOST=mongo3:27017
MONGO_ROOT_PASS=$RP
MONGO_NAME=ci
MONGO_USER=ciUser
MONGO_PASS=$RP
MONGO_BACKUP_USER=backupUser
MONGO_BACKUP_PASS=CHANGE_ME_BACKUP
MONGO_TLS_REQUIRED=true
BACKUP_DIR=$WORK/backups
BACKUP_AGE_RECIPIENT=$PUB
BACKUP_RETRY_DELAY=10
EOF

docker network create "${PROJ}-net" >/dev/null
for v in mongo_pki mongo_ca mongo1_data mongo2_data mongo3_data; do
  docker volume create "${PROJ}_${v}" >/dev/null
done

echo "── 1. 레플리카셋 기동 ($IMG)"
dc up -d

echo "── 2. PRIMARY init 대기 (최대 ~240s; election priority takeover 여유 포함)"
ok=0
for i in $(seq 1 80); do
  # ★ docker logs(대용량) | grep -q 는 금물: grep -q 가 즉시 종료→docker logs SIGPIPE→
  #   set -o pipefail 가 파이프를 실패로 만들어 매치를 못 본 것으로 오판한다.
  #   → 로그를 변수에 담고 case 로 매칭(파이프 없음).
  LOGS="$(docker logs "${PROJ}-mongo1" 2>&1 || true)"
  case "$LOGS" in *"PRIMARY initialization completed"*) ok=1; break;; esac
  # 실패 신호는 'ERROR' 문자열(기동 중 무해)이 아니라 컨테이너 종료 여부로 판정한다.
  st="$(docker inspect -f '{{.State.Status}}' "${PROJ}-mongo1" 2>/dev/null || echo gone)"
  case "$st" in exited|dead|gone) echo "mongo1 컨테이너 상태=$st"; break;; esac
  sleep 3
done
[ "$ok" = 1 ] || { echo "❌ 레플리카 init 실패"; docker logs "${PROJ}-mongo1" 2>&1 \
  | grep -avE 'client metadata|No SSL|Connection (accepted|ended)|Ingress|not authenticating' | tail -30; exit 1; }

echo "── 3. 멤버/backupUser 확인"
docker exec "${PROJ}-mongo1" mongosh "$ADM" "${TLS[@]}" --quiet \
  --eval 'rs.status().members.forEach(m=>print(m.name,m.stateStr)); print("backupRole:", JSON.stringify(db.getSiblingDB("admin").getUser("backupUser").roles))'

echo "── 4. 데이터 삽입 + 백업 once (backupUser)"
# writeConcern majority: backup 이 secondaryPreferred 로 읽으므로, 삽입이 secondary 까지
# 복제된 뒤 backup 하도록 보장한다(복제 레이스로 백업이 데이터를 놓치는 것 방지).
docker exec "${PROJ}-mongo1" mongosh "$APP" "${TLS[@]}" --quiet --eval 'db.getSiblingDB("ci").t.insertOne({_id:1,v:"smoke"},{writeConcern:{w:"majority"}})' >/dev/null
docker exec "${PROJ}-mongo-backup" /mongodb/backup.sh once 2>&1 | grep 'backup done' || { echo "❌ 백업 실패"; exit 1; }

echo "── 5. 삭제 + 복원 (root, age 복호화 → mongorestore)"
docker exec "${PROJ}-mongo1" mongosh "$APP" "${TLS[@]}" --quiet --eval 'db.getSiblingDB("ci").t.deleteMany({})' >/dev/null
docker cp "$WORK/key.txt" "${PROJ}-mongo-backup:/tmp/k.txt"
BK="$(docker exec "${PROJ}-mongo-backup" sh -c 'ls -t /backups/*.age | head -1')"
docker exec -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$RP" -e MONGO_REPLICA_HOSTS='mongo1:27017,mongo2:27017' \
  -e BK="$BK" "${PROJ}-mongo-backup" bash -c '
    set -euo pipefail
    . /mongodb/mongo-connect.sh
    age -d -i /tmp/k.txt "$BK" | mongorestore "${MONGO_CONN_ARGS[@]}" --gzip --archive' 2>&1 | tail -1

echo "── 6. 복원 검증"
V="$(docker exec "${PROJ}-mongo1" mongosh "$APP" "${TLS[@]}" --quiet --eval 'var d=db.getSiblingDB("ci").t.findOne({_id:1}); print(d?d.v:"MISSING")')"
[ "$V" = "smoke" ] || { echo "❌ 복원 검증 실패: '$V'"; exit 1; }

echo "✅ 스모크 통과: 3노드 기동 + backupUser 백업 + 복원 roundtrip 정상"
