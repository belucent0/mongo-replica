# MongoDB 3노드 레플리카셋 + TLS 자동화 사용법

`docker-compose.replicaset.yml` 기반 **3노드 레플리카셋 배포** 가이드입니다.
단일 노드 배포는 [상위 README](../README.md) 를 참고하세요.

## 🎯 언제 쓰나

| 상황 | 추천 구성 |
|---|---|
| 단일 호스트 · 개발/테스트 · Prisma 트랜잭션만 필요 | 단일 노드 (`docker-compose.yml`) |
| **운영 환경 배포 · 가용성 필요 · 보안 스펙 준수** | **3노드 (이 문서)** |
| DB 노드를 여러 물리 서버에 분산 | 3노드 + 네트워크 설정 변경 |

본 가이드의 3노드 구성은 다음을 자동화합니다:

- **3노드 레플리카셋** 자동 초기화 (`rs.initiate` + 멤버 구성)
- **공유 PKI** 자동 생성 (CA · keyFile · 노드별 인증서)
- **TLS 1.3** 전송 암호화 (앱↔DB / 노드↔노드)
- **X.509 mTLS** 노드 간 상호 인증 (`clusterAuthMode=x509`)
- **계정/뷰** 자동 생성
- **자동 장애조치** (Primary 다운 시 Secondary 승격)

## 🏗️ 구성 요소

```
docker compose -f docker-compose.replicaset.yml up
  │
  ├─ mongo-init  (1회 실행 후 종료)
  │   └─ gen-secrets.sh → 공유 PKI 생성 (/pki 공유 볼륨)
  │
  ├─ mongo1  (데이터, primary 후보, priority 2)
  │   └─ docker-entrypoint-replica.sh
  │      ├─ rs.initiate (3멤버)
  │      ├─ 계정·뷰 생성
  │      └─ mongod (foreground)
  │
  ├─ mongo2  (데이터, secondary, priority 1)
  │   └─ docker-entrypoint-replica.sh → mongod
  │
  └─ mongo3  (arbiter, 투표만 — 데이터 없음)
      └─ docker-entrypoint-replica.sh → mongod
```

### 왜 데이터 2 + Arbiter 1인가

- **장애조치(failover)** 자동화에는 과반(majority of votes) 필요 → 최소 3개 투표 노드
- Arbiter는 투표만 하고 데이터를 저장하지 않으므로 **디스크 비용은 데이터 노드 2개분**
- mongo1 다운 → mongo2(데이터)+mongo3(arbiter) 과반 = 2/3 → mongo2 자동 PRIMARY 승격

> 데이터 3노드 구성(arbiter 없이)도 가능합니다. `.env` 의 `MONGO_REPLICA_HOSTS` 에 3개 호스트를 나열하고 `MONGO_ARBITER_HOST` 를 비우세요.

## 📋 사전 준비

| 항목 | 요구사항 |
|---|---|
| Docker | 20.10 이상 |
| Docker Compose | v2 이상 (`docker compose` 명령) |
| 호스트 OS | Linux 권장 (Windows/Mac은 WSL2/Docker Desktop 가능) |
| 디스크 | 데이터 노드당 ≥ 데이터 예상 크기 × 1.5 |
| 메모리 | 호스트 기준 최소 4GB (각 노드 약 512MB ~ 2GB) |

이미지를 사전 빌드해서 배포하는 경우 추가:

- 빌드 호스트: `docker build` 가능한 환경
- 운영 호스트: 빌드된 이미지 tar 파일 로드 가능

## ⚙️ 환경 변수 설정

`.env.replicaset.example` 를 복사해서 `.env` 또는 `.env.local` 로 저장 후 값 수정:

```bash
cp .env.replicaset.example .env
```

### 필수 항목

```env
# 프로젝트/네트워크 식별자 (컨테이너 이름 prefix 로 사용됨)
COMPOSE_PROJECT_NAME=myapp
DOCKER_NETWORK_NAME=myapp-net

# 사용할 이미지 태그 (사전 빌드 이미지 사용 시)
MONGO_IMAGE=mongo-rs:1.0.0

# 데이터 노드 목록 (첫 항목이 primary 후보, priority 2)
MONGO_REPLICA_HOSTS=mongo1:27017,mongo2:27017

# Arbiter (선택). 데이터 3노드로 가려면 비워두고 위에 3개 나열
MONGO_ARBITER_HOST=mongo3:27017

# 계정 (실제 배포 시 반드시 변경)
MONGO_ROOT_PASS=#StrongRootPass1!
MONGO_NAME=myapp
MONGO_USER=appUser
MONGO_PASS=#StrongAppPass1!

# TLS 강제 여부
#   true  → requireTLS  : 앱도 반드시 TLS 로 접속 (보안 스펙 준수)
#   false → preferTLS   : 앱은 평문/TLS 양쪽 허용 (기존 자동화 호환)
MONGO_TLS_REQUIRED=true
```

### 호스트명 vs IP

| 시나리오 | `MONGO_REPLICA_HOSTS` 값 | 비고 |
|---|---|---|
| 같은 docker-compose 안에서 컨테이너명으로 접속 (기본) | `mongo1:27017,mongo2:27017` | 도커 내부 DNS 가 해석 |
| DB 노드가 별도 물리 서버에 분산 | `192.168.1.10:27017,192.168.1.11:27017` | `gen-secrets.sh` 가 자동으로 `IP:` SAN 발급 |
| FQDN 사용 | `mongo-a.client.local:27017,mongo-b.client.local:27017` | DNS 해석 가능해야 함 |

`gen-secrets.sh` 는 IP 와 호스트명을 자동 판별해서 인증서 SAN 에 적절히(`IP:` 또는 `DNS:`) 등록합니다.

## 🚀 빌드 & 배포

### 권장 워크플로 (빌드 호스트 → 운영 호스트 로드)

```bash
# ─── 1. 빌드 호스트에서 이미지 생성 ───
cd /path/to/mongodb
docker build -t mongo-rs:1.0.0 .

# 이미지를 tar 로 export
docker save mongo-rs:1.0.0 -o mongo-rs-1.0.0.tar

# ─── 2. 운영 호스트로 전달 ───
# 아래 파일들을 같이 전달:
#   - mongo-rs-1.0.0.tar           (이미지)
#   - docker-compose.replicaset.yml
#   - .env.replicaset.example       (운영 환경에 맞춰 .env 로 수정)
#   - docs/replicaset.md            (이 문서)

# ─── 3. 운영 호스트에서 ───
docker load -i mongo-rs-1.0.0.tar
docker images | grep mongo-rs        # 이미지 로드 확인

cp .env.replicaset.example .env
vi .env                              # 비밀번호·호스트 수정

docker compose -f docker-compose.replicaset.yml up -d
```

### 개발 환경 (소스에서 직접 빌드)

```bash
docker compose -f docker-compose.replicaset.yml --env-file .env up -d --build
```

`--build` 는 코드 수정 시마다 빌드를 강제합니다. 운영 호스트에서는 사용하지 않습니다.

## ✅ 배포 검증

```bash
# ─── 1. 컨테이너 상태 ───
docker ps --filter "name=${COMPOSE_PROJECT_NAME}" --format "{{.Names}} | {{.Status}}"
# 기대: 3개 모두 "Up ... (healthy)"

# ─── 2. 레플리카셋 멤버 상태 ───
docker exec ${COMPOSE_PROJECT_NAME}-mongo1 \
  mongosh "mongodb://root:${MONGO_ROOT_PASS}@127.0.0.1:27017/admin?directConnection=true" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames --quiet \
  --eval "rs.status().members.forEach(m => print(m.name, '=>', m.stateStr))"
# 기대:
#   mongo1:27017 => PRIMARY
#   mongo2:27017 => SECONDARY
#   mongo3:27017 => ARBITER

# ─── 3. 클러스터 인증 모드 ───
docker exec ${COMPOSE_PROJECT_NAME}-mongo1 \
  mongosh "mongodb://root:${MONGO_ROOT_PASS}@127.0.0.1:27017/admin?directConnection=true" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames --quiet \
  --eval "db.adminCommand({getParameter:1, clusterAuthMode:1}).clusterAuthMode"
# 기대: x509

# ─── 4. 인증서 정보 ───
docker exec ${COMPOSE_PROJECT_NAME}-mongo1 \
  openssl x509 -in /pki/mongo1.pem -noout -text \
  | grep -E "Public-Key|Subject Alternative Name" -A1
# 기대: Public-Key: (3072 bit) + 노드 호스트가 SAN 에 등록됨
```

## 🔌 앱 측 연결 방법

### `MONGO_TLS_REQUIRED=true` (스펙 준수)

앱의 연결 문자열에 **TLS 파라미터 필수**:

```env
# master-api/.env
MONGO_DATABASE_URL=mongodb://appUser:%23StrongAppPass1%21@mongo1:27017,mongo2:27017/myapp?replicaSet=rs0&authSource=myapp&tls=true&tlsCAFile=/certs/ca.pem
```

- `tls=true` — TLS 활성화
- `tlsCAFile=/certs/ca.pem` — CA 인증서 경로 (앱 컨테이너 안 경로)
- `replicaSet=rs0` — 레플리카셋 인지 (자동 장애조치)

#### CA 인증서를 앱 컨테이너에 마운트

앱 측 `docker-compose.yml`:

```yaml
services:
  master-api:
    image: ...
    volumes:
      - mongo_pki:/certs:ro      # MongoDB 의 PKI 볼륨 공유 (같은 호스트인 경우)
    networks:
      - myapp-net                 # MongoDB 와 같은 네트워크
```

또는 `mongo1` 컨테이너에서 `ca.pem` 만 호스트로 복사 후 앱 컨테이너에 마운트:

```bash
docker cp myapp-mongo1:/pki/ca.pem ./ca.pem
# 앱 compose 에서
#   volumes:
#     - ./ca.pem:/certs/ca.pem:ro
```

### `MONGO_TLS_REQUIRED=false` (호환 모드)

기존 평문 연결 그대로 사용 가능:

```env
MONGO_DATABASE_URL=mongodb://appUser:%23StrongAppPass1%21@mongo1:27017,mongo2:27017/myapp?replicaSet=rs0&authSource=myapp
```

- 앱 측 변경 없음 (TLS 파라미터 불필요)
- 노드 간 통신은 여전히 TLS 암호화 (보안 기반선 유지)
- 감사 대응이 필요하면 운영 전환 시 `true` 로 토글

## 🔧 운영

### 컨테이너 관리

```bash
# 로그 확인
docker compose -f docker-compose.replicaset.yml logs -f mongo1

# 재시작
docker compose -f docker-compose.replicaset.yml restart

# 정지 (데이터/PKI 유지)
docker compose -f docker-compose.replicaset.yml down

# 정지 + 볼륨 삭제 (⚠️ 데이터·인증서 모두 삭제)
docker compose -f docker-compose.replicaset.yml down -v
```

### 셸 접속 (root)

```bash
docker exec -it myapp-mongo1 \
  mongosh "mongodb://root:#StrongRootPass1!@127.0.0.1:27017/admin?directConnection=true" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames
```

### 셸 접속 (앱 유저)

```bash
docker exec -it myapp-mongo1 \
  mongosh "mongodb://appUser:#StrongAppPass1!@127.0.0.1:27017/myapp?directConnection=true&authSource=myapp" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames
```

### 백업 (mongodump)

```bash
# 운영 노드에서 dump (TLS 통과)
docker exec myapp-mongo1 \
  mongodump \
    --uri="mongodb://root:#StrongRootPass1!@127.0.0.1:27017/?authSource=admin&directConnection=true" \
    --tls --tlsCAFile=/pki/ca.pem --tlsAllowInvalidHostnames \
    --archive --gzip > backup-$(date +%F).archive.gz

# 백업 매체 암호화 (스펙 6.2.3 — AEAD)
# 운영 키와 분리된 키 체계로 한 번 더 암호화
age -r $(cat backup_recipient.txt) \
  backup-$(date +%F).archive.gz > backup-$(date +%F).archive.gz.age
```

### 자동 장애조치 동작 확인

```bash
# Primary 강제 중지
docker stop myapp-mongo1

# 약 10~15초 후 mongo2 가 PRIMARY 로 승격됨
docker exec myapp-mongo2 \
  mongosh "mongodb://root:#StrongRootPass1!@127.0.0.1:27017/admin?directConnection=true" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames --quiet \
  --eval "rs.status().members.forEach(m => print(m.name, m.stateStr))"

# 복귀
docker start myapp-mongo1
# priority 2 인 mongo1 이 다시 PRIMARY 로 자동 재승격됨
```

앱은 `replicaSet=rs0` 파라미터 덕분에 PRIMARY 전환을 자동으로 감지합니다.

## 🔐 보안 스펙 매핑

본 사업 보안 문서(섹션 6.2) 와의 대응:

| 문서 요구사항 | 구현 |
|---|---|
| TLS 1.3 (1.0/1.1 비활성화) | `--tlsDisabledProtocols TLS1_0,TLS1_1` |
| Cipher AES-256-GCM 등 | TLS 1.3 기본 cipher suite (TLS_AES_256_GCM_SHA384 포함) |
| 키 교환 ECDHE X25519 | TLS 1.3 기본 그룹 |
| 인증서 RSA-3072 또는 ECDSA P-256 | **RSA-3072** (노드 인증서, `gen-secrets.sh`) |
| 내부 PKI 발급 | 자체 CA 자동 생성 (`gen-secrets.sh`) |
| 레플리카 노드 간 X.509 mTLS | `clusterAuthMode=x509` |
| `net.tls.mode=requireTLS` | `MONGO_TLS_REQUIRED=true` → `requireTLS` (기본) |
| `tlsCertificateKeyFile` / `tlsCAFile` | `/pki/<node>.pem` / `/pki/ca.pem` |
| 저장 볼륨 LUKS2 암호화 | **OS 영역** — 호스트 디스크/파티션을 LUKS2 로 설정한 위에 docker 볼륨 마운트 |
| 백업 매체 AEAD 암호화 | 위 "백업" 섹션 참고 (`age`/`gpg`) |

## 🐛 문제 해결

### 컨테이너가 `unhealthy` 상태

```bash
# 1. PKI 가 정상 생성됐는지 확인
docker exec myapp-mongo1 ls -la /pki/
# 기대: ca.pem, mongodb-keyfile, mongo1.pem 등이 존재

# 2. mongod 옵션 확인
docker exec myapp-mongo1 bash -c "ps aux | grep '[m]ongod'"
# tlsMode, clusterAuthMode 확인

# 3. 로그에서 에러 확인
docker logs myapp-mongo1 | grep -E "ERROR|FATAL" | tail -20
```

### "PKI not ready after timeout" 에러

```
ERROR: PKI not ready after ~300s. Expected node cert: /pki/mongo1.pem
       MONGO_NODE_NAME('mongo1') must match a host in MONGO_REPLICA_HOSTS/MONGO_ARBITER_HOST.
```

원인: `docker-compose.yml` 의 `MONGO_NODE_NAME` 이 `.env` 의 `MONGO_REPLICA_HOSTS`/`MONGO_ARBITER_HOST` 에 나열된 호스트명과 일치하지 않음.

해결: 두 값을 일치시키거나, 호스트 추가 후 `mongo-init` 재실행:

```bash
docker compose -f docker-compose.replicaset.yml restart mongo-init
# (PKI 가 누락된 노드 인증서만 추가 생성됨 — 기존 CA/keyFile 재사용)
```

### "No SSL certificate provided by peer; connection rejected" (앱 측)

원인: `MONGO_TLS_REQUIRED=true` 인데 앱이 `tls=true` 파라미터 없이 접속.

해결:
- 앱 연결 문자열에 `?tls=true&tlsCAFile=...` 추가
- 또는 운영 호환 모드로 `MONGO_TLS_REQUIRED=false` 로 전환

### "Hostname mismatch" 에러 (앱 측)

원인: 앱이 접속한 주소가 인증서 SAN 에 없음.

해결 시나리오별:
- 컨테이너명으로 접속하는데 SAN 에 등록 안 됨 → `MONGO_REPLICA_HOSTS` 의 호스트명 확인
- 호스트 LAN IP 로 접속 → `MONGO_REPLICA_HOSTS` 에 그 IP 를 포함시키거나 `MONGO_TLS_EXTRA_SAN` 으로 추가
- 일시적 우회 (디버깅용): 앱 연결 문자열에 `&tlsAllowInvalidHostnames=true` (운영 금지)

### PRIMARY 가 선출 안 됨

3노드 중 2개 이상이 살아있어야 PRIMARY 가 선출됩니다 (과반 필요).

```bash
# 어떤 노드가 죽어있는지 확인
docker ps -a --filter "name=${COMPOSE_PROJECT_NAME}"

# 죽은 노드를 다시 띄우거나, 의도적으로 정리한 경우 (예: 1노드만 살아있는데
# PRIMARY 가 안 되는 경우) — force reconfig 가능하지만 데이터 손실 위험이 있음
# 운영 환경에서는 추가 노드 복구를 우선시할 것
```

### PKI 재생성 (인증서 만료/유출 등)

```bash
# ⚠️ 주의: 인증서 변경 시 노드 간 통신이 일시적으로 끊김
docker compose -f docker-compose.replicaset.yml down
docker volume rm ${COMPOSE_PROJECT_NAME}_mongo_pki
docker compose -f docker-compose.replicaset.yml up -d
# → mongo-init 가 새 PKI 를 생성
# → 모든 노드가 새 인증서로 다시 핸드셰이크
# 데이터 볼륨(mongo[1-3]_data)은 그대로 → 데이터는 보존
```

## 📎 부록

### A. `MONGO_TLS_REQUIRED` 토글 동작

| 값 | TLS 모드 | 앱 평문 접속 | 앱 TLS 접속 | 노드 간 |
|---|:---:|:---:|:---:|:---:|
| `true`(기본) / 1 / yes / 그 외 | requireTLS | ❌ 거부 | ✅ 필수 | ✅ TLS |
| `false` / 0 / no / off / disabled | preferTLS | ✅ 허용 | ✅ 허용 | ✅ TLS |

대소문자·공백은 자동 정규화됩니다 (`FALSE`, `False`, ` false `, `Off` 모두 동일하게 인식).

### B. 자동 생성되는 PKI 파일들

`/pki/` 공유 볼륨:

| 파일 | 용도 | 권한 |
|---|---|:---:|
| `ca.pem` | CA 인증서 (공개) — 앱 측에도 배포 필요 | 444 |
| `ca.key` | CA 비밀키 — 외부 유출 금지 | 400 |
| `mongodb-keyfile` | 노드 간 내부 인증 (보조) | 400 |
| `<host>.pem` | 노드 서버 인증서 (key+cert 합본) | 400 |
| `<host>.key` / `<host>.crt` | 노드 인증서 구성 요소 | 400 |

소유자: `mongodb:mongodb` (uid 999)

### C. 사용된 mongod 옵션

```
--replSet rs0
--bind_ip_all
--keyFile /pki/mongodb-keyfile
--tlsMode {requireTLS | preferTLS}        # MONGO_TLS_REQUIRED 로 결정
--tlsCertificateKeyFile /pki/<node>.pem
--tlsCAFile /pki/ca.pem
--tlsDisabledProtocols TLS1_0,TLS1_1
--clusterAuthMode x509
--tlsAllowConnectionsWithoutCertificates  # 앱은 클라이언트 인증서 없어도 OK
```

### D. 호스트 토폴로지 변경 절차

레플리카셋 멤버를 추가/제거할 때:

```bash
# 1. .env 의 MONGO_REPLICA_HOSTS / MONGO_ARBITER_HOST 수정
# 2. docker-compose.replicaset.yml 에 서비스(mongo4 등) 추가 (필요 시)
# 3. PKI 재생성 (또는 누락된 노드 인증서만 추가 생성)
docker compose -f docker-compose.replicaset.yml restart mongo-init
# 4. 새 노드 기동
docker compose -f docker-compose.replicaset.yml up -d
# 5. rs.add() / rs.remove() 로 멤버 구성 수동 조정 (필요 시)
```

자동화 스크립트(`init-replica-multi.sh`)는 첫 기동에만 동작합니다. 운영 중 멤버 변경은 `mongosh` 에서 `rs.add()` / `rs.remove()` 로 수행하세요.

### E. 배포 시나리오별 환경 변수·구성 차이

대상 환경에 따라 3노드 배포가 달라집니다. 아래 표로 차이점 정리:

| 시나리오 | 설명 |
|---|---|
| **A** | 동일 호스트 · compose 가 새 Docker 네트워크 생성 (기본 가정) |
| **B** | 동일 호스트 · 앱이 사전에 만든 Docker 네트워크 공유 |
| **C** | 노드를 여러 물리 호스트에 분산 (같은 LAN 권장) |

#### 환경 변수·설정 차이

| 항목 | A (기본) | B (공유 네트워크) | C (다중 호스트) |
|---|---|---|---|
| `MONGO_REPLICA_HOSTS` | 컨테이너명 (`mongo1:27017,mongo2:27017`) | 동일 | **호스트 LAN IP / FQDN** |
| `MONGO_ARBITER_HOST` | `mongo3:27017` | 동일 | **호스트 LAN IP / FQDN** |
| `DOCKER_NETWORK_NAME` | 자유 (자동 생성) | **앱이 만든 네트워크명** | 호스트별 분리 |
| `compose networks:` | `name:` 만 지정 | **`external: true` 추가** | 호스트별 다름 |
| `ports:` | 불필요 (네트워크 공유) | 불필요 | **27017 호스트 매핑 필수** |
| 인증서 SAN | `DNS:mongo1` 자동 | 동일 | `IP:192.168.x.x` 자동 (`gen-secrets.sh`) |
| 방화벽 | — | — | **노드 간 27017 통신 허용** |
| compose 파일 구조 | 1개 | 1개 (`external: true` 한 줄 추가) | 호스트별 별도 |

#### 시나리오 B — 외부 네트워크 공유

앱이 먼저 `myapp-net` 같은 네트워크를 만들어둔 경우, 그 네트워크에 MongoDB 노드를 join 시켜서 같은 DNS 공간을 공유합니다.

`.env` 설정:
```env
DOCKER_NETWORK_NAME=myapp-net   # 앱이 만든 네트워크 이름
# (다른 값은 시나리오 A 와 동일)
```

`docker-compose.replicaset.yml` 의 networks 섹션 한 줄 추가:
```yaml
networks:
  mongo-net:
    name: ${DOCKER_NETWORK_NAME:-mongo-rs-net}
    external: true                # ← 이 줄 추가 (compose 가 만들지 않고 기존 네트워크 사용)
```

기동 순서:
1. 앱 측에서 docker compose up 으로 `myapp-net` 네트워크가 먼저 생성되어 있어야 함
2. 그 다음 MongoDB compose up

#### 시나리오 C — 다중 호스트 분산

각 노드가 다른 물리 서버에 있을 때. 같은 LAN(< 10ms latency) 권장.

각 호스트에서 자기 노드만 실행:
```env
# 호스트 1 (mongo1)
MONGO_REPLICA_HOSTS=192.168.1.10:27017,192.168.1.11:27017
MONGO_ARBITER_HOST=192.168.1.12:27017
```

`docker-compose.replicaset.yml` 을 호스트별로 분할하거나, 단일 compose 에서 자기 노드 서비스만 활성화. 각 노드에 ports 매핑 추가:
```yaml
mongo1:
  ...
  ports:
    - "27017:27017"          # ← 다른 호스트 노드가 LAN IP 로 접속할 수 있도록 노출
```

방화벽: 모든 노드 간 27017 통신 허용. SAN 은 `gen-secrets.sh` 가 IP 자동 판별로 `IP:` 등록.

> 다중 호스트 분산은 docker swarm 같은 orchestrator 사용을 우선 고려하세요. 단일 compose 다중 호스트는 운영 복잡도가 큽니다.

## 📝 버전 정보

- **MongoDB**: 8.0.17
- **TLS**: 1.3 (1.0/1.1 비활성)
- **인증서**: RSA-3072 (노드), RSA-4096 (CA)
- **레플리카셋 클러스터 인증**: x509 (mTLS)
