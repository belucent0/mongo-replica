#!/bin/bash
set -e

# 레플리카셋 초기화 및 PRIMARY 대기 스크립트
# 사용법: init-replica.sh

echo "=========================================="
echo "Initializing Replica Set..."
echo "=========================================="

# 레플리카셋 초기화
mongosh admin --quiet <<EOF
try {
  var status = rs.status();
  print("Replica Set already initialized");
} catch(e) {
  if (e.message.includes("no replset config")) {
    print("Initializing Replica Set...");
    var result = rs.initiate({
      _id: "rs0",
      members: [{
        _id: 0,
        host: "${MONGO_PRIMARY_HOST:-mongodb:27017}"
      }]
    });
    if (result.ok === 1) {
      print("Replica Set initialized successfully");
    } else {
      print("Replica Set initialization failed:", result);
      quit(1);
    }
  } else if (
    e.message.includes("requires authentication") ||
    e.message.includes("already initialized")
  ) {
    // 인증 켜진 상태에서 status 조회만 막혔거나, 이미 초기화 된 경우 → 멱등 처리
    print("Replica Set already initialized (auth required to read status)");
  } else {
    print("Error checking Replica Set status:", e.message);
    throw e;
  }
}
EOF

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to initialize Replica Set"
  exit 1
fi

# Replica Set이 PRIMARY가 될 때까지 대기
echo "Waiting for Replica Set to become PRIMARY..."
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  PRIMARY_CHECK=$(mongosh admin --quiet --eval "try { var status = rs.status(); if (status.ok === 1 && status.members && status.members.length > 0) { var primary = status.members.find(m => m.stateStr === 'PRIMARY'); if (primary) { quit(0); } else { quit(1); } } else { quit(1); } } catch(e) { quit(1); }" 2>/dev/null; echo $?)
  if [ "$PRIMARY_CHECK" = "0" ]; then
    echo "Replica Set is PRIMARY and ready."
    exit 0
  fi
  echo "Waiting for PRIMARY state... ($WAIT_COUNT/$MAX_WAIT)"
  sleep 2
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

echo "ERROR: Replica Set did not become PRIMARY within $MAX_WAIT attempts"
exit 1