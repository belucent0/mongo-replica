#!/bin/bash
set -e

# 다중 노드 레플리카셋 초기화 (primary 노드에서만 실행)
# MONGO_REPLICA_HOSTS : 데이터 노드 목록 (host:port,host:port[,host:port])
#                       첫 번째 항목이 primary 후보(priority 2)
# MONGO_ARBITER_HOST  : 선택. 지정 시 arbiterOnly 멤버로 추가
#
# TLS 로 localhost 에 접속하여 rs.initiate 수행 후 PRIMARY 대기.

CA="${PKI_DIR:-/pki}/ca.pem"
MONGOSH_TLS=(--tls --tlsCAFile "$CA" --tlsAllowInvalidHostnames)
# directConnection=true: 레플리카셋 토폴로지 디스커버리를 끄고 127.0.0.1 직접 연결을
# 유지해야 localhost exception(인증 없는 첫 계정 생성)이 적용된다.
LOCAL_ADMIN="mongodb://127.0.0.1:27017/admin?directConnection=true"

if [ -z "$MONGO_REPLICA_HOSTS" ]; then
  echo "ERROR: MONGO_REPLICA_HOSTS is required"
  exit 1
fi

# members 배열(JS) 구성
MEMBERS_JS=""
IDX=0
IFS=',' read -ra DATA_HOSTS <<< "$MONGO_REPLICA_HOSTS"
for entry in "${DATA_HOSTS[@]}"; do
  entry="${entry//[[:space:]]/}"
  host="${entry%%:*}"
  port="${entry##*:}"
  [ -z "$host" ] && continue
  if [ "$IDX" -eq 0 ]; then
    PRIORITY=2   # 첫 데이터 노드를 primary 선호
  else
    PRIORITY=1
  fi
  [ -n "$MEMBERS_JS" ] && MEMBERS_JS="$MEMBERS_JS,"
  MEMBERS_JS="$MEMBERS_JS{ _id: $IDX, host: \"$host:$port\", priority: $PRIORITY }"
  IDX=$((IDX + 1))
done

# arbiter 추가 (선택)
if [ -n "$MONGO_ARBITER_HOST" ]; then
  MONGO_ARBITER_HOST="${MONGO_ARBITER_HOST//[[:space:]]/}"
  ah="${MONGO_ARBITER_HOST%%:*}"
  ap="${MONGO_ARBITER_HOST##*:}"
  MEMBERS_JS="$MEMBERS_JS,{ _id: $IDX, host: \"$ah:$ap\", arbiterOnly: true }"
fi

echo "=========================================="
echo "Initializing Replica Set rs0 with members:"
echo "  $MEMBERS_JS"
echo "=========================================="

mongosh "$LOCAL_ADMIN" "${MONGOSH_TLS[@]}" --quiet <<EOF
try {
  rs.status();
  print("Replica Set already initialized");
} catch (e) {
  if (e.message.includes("no replset config")) {
    var result = rs.initiate({ _id: "rs0", members: [ $MEMBERS_JS ] });
    if (result.ok === 1) {
      print("Replica Set initiated");
    } else {
      print("Replica Set initiation failed:", JSON.stringify(result));
      quit(1);
    }
  } else if (
    e.message.includes("requires authentication") ||
    e.message.includes("already initialized")
  ) {
    // 이미 초기화된 상태(인증이 켜져 status 조회는 막히지만 set 은 구성됨) → 멱등 처리
    print("Replica Set already initialized (auth required to read status)");
  } else {
    print("Error checking status:", e.message);
    throw e;
  }
}
EOF

# PRIMARY 대기
echo "Waiting for this node to become PRIMARY..."
MAX_WAIT=60
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  # mongosh 의 프로세스 종료코드만으로 판정한다(stdout 을 변수에 섞지 않음).
  # isWritablePrimary 가 참이면 0, 아니면 quit(1), 접속 실패도 0이 아님.
  if mongosh "$LOCAL_ADMIN" "${MONGOSH_TLS[@]}" --quiet \
       --eval "db.hello().isWritablePrimary || quit(1)" >/dev/null 2>&1; then
    echo "This node is now PRIMARY."
    exit 0
  fi
  echo "Waiting for PRIMARY... ($WAIT_COUNT/$MAX_WAIT)"
  sleep 2
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

echo "ERROR: Did not become PRIMARY within $MAX_WAIT attempts"
exit 1
