# MongoDB 3노드 레플리카셋 + TLS 자동화 사용법

`docker-compose.yml` 기반 **3노드 레플리카셋 배포** 가이드입니다.
단일 노드 배포는 [상위 README](../README.md) 를 참고하세요.

## 🎯 언제 쓰나

| 상황 | 추천 구성 |
|---|---|
| 단일 호스트 · 개발/테스트 · Replica Set 연결 조건만 필요 | 단일 노드 (`docker-compose.single.yml`) |
| **운영 환경 배포 · 가용성 필요 · 보안 스펙 준수** | **3노드 (이 문서)** |
| DB 노드를 여러 물리 서버에 분산 | 3노드 + 네트워크 설정 변경 |

본 가이드의 3노드 구성은 다음을 자동화합니다:

- **3노드 레플리카셋** 자동 초기화 (`rs.initiate` + 멤버 구성)
- **PKI 자동 생성** (private PKI: CA key · keyFile · 노드 인증서 / public CA: 앱·백업용 `ca.pem`)
- **TLS 1.3 전용** 전송 암호화 (TLS 1.0/1.1/1.2 비활성화)
- **X.509 mTLS** 노드 간 상호 인증 (`clusterAuthMode=x509`)
- **계정/뷰** 자동 생성
- **자동 장애조치** (Primary 다운 시 Secondary 승격)

## 🏗️ 구성 요소

```
docker compose up
  │
  ├─ mongo-init  (1회 실행 후 종료)
  │   └─ gen-secrets.sh → private PKI(/pki) + public CA(/pki-public) 생성
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
  ├─ mongo3  (arbiter, 투표만 — 데이터 없음)
  │   └─ docker-entrypoint-replica.sh → mongod
  │
  └─ mongo-backup  (백업 전용, 상시)
      └─ backup.sh → mongodump(secondaryPreferred)→gzip→age 암호화→호스트 폴더
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

`.env.example` 를 복사해서 `.env` 또는 `.env.local` 로 저장 후 값 수정:

```bash
cp .env.example .env
```

### 필수 항목

```env
# 프로젝트/네트워크 식별자 (컨테이너 이름 prefix 로 사용됨)
COMPOSE_PROJECT_NAME=myapp
DOCKER_NETWORK_NAME=myapp-net

# 사용할 이미지 태그 (사전 빌드 이미지 사용 시)
MONGO_IMAGE=mongo-replica:1.0.2

# 데이터 노드 목록 (첫 항목이 primary 후보, priority 2)
MONGO_REPLICA_HOSTS=mongo1:27017,mongo2:27017

# Arbiter (선택). 데이터 3노드로 가려면 비워두고 위에 3개 나열
MONGO_ARBITER_HOST=mongo3:27017

# 계정 (실제 배포 시 반드시 변경)
MONGO_ROOT_PASS=CHANGE_ME_ROOT
MONGO_NAME=myapp
MONGO_USER=appUser
MONGO_PASS=CHANGE_ME_APP

# TLS 강제 여부
#   true  → requireTLS  : 앱도 반드시 TLS 로 접속 (보안 스펙 준수)
#   false → preferTLS   : 앱은 평문/TLS 양쪽 허용 (기존 자동화 호환)
# TLS 연결은 TLS 1.3 전용이다(TLS 1.0/1.1/1.2 비활성화).
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
docker build -t mongo-replica:1.0.2 .

# 이미지를 tar.gz 로 export
docker save mongo-replica:1.0.2 | gzip > mongo-replica-1.0.2.tar.gz

# ─── 2. 운영 호스트로 전달 ───
# 아래 파일들을 같이 전달:
#   - mongo-replica-1.0.2.tar.gz    (이미지)
#   - docker-compose.yml
#   - .env.example       (운영 환경에 맞춰 .env 로 수정)
#   - docs/replicaset.md            (이 문서)

# ─── 3. 운영 호스트에서 ───
docker load -i mongo-replica-1.0.2.tar.gz
docker images | grep mongo-replica   # 이미지 로드 확인

cp .env.example .env
vi .env                              # 비밀번호·호스트 수정

docker compose up -d
```

### 개발 환경 (소스에서 직접 빌드)

```bash
docker compose --env-file .env up -d --build
```

`--build` 는 코드 수정 시마다 빌드를 강제합니다. 운영 호스트에서는 사용하지 않습니다.

## ✅ 배포 검증

```bash
# ─── 1. 컨테이너/레플리카셋/백업 상태 ───
./scripts/check-status.sh
# 기대:
#   mongo1:27017 => PRIMARY
#   mongo2:27017 => SECONDARY
#   mongo3:27017 => ARBITER

# ─── 2. 클러스터 인증 모드 ───
docker exec ${COMPOSE_PROJECT_NAME}-mongo1 \
  mongosh "mongodb://root:${MONGO_ROOT_PASS}@127.0.0.1:27017/admin?directConnection=true" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames --quiet \
  --eval "db.adminCommand({getParameter:1, clusterAuthMode:1}).clusterAuthMode"
# 기대: x509

# ─── 3. 인증서 정보 ───
docker exec ${COMPOSE_PROJECT_NAME}-mongo1 \
  openssl x509 -in /pki/mongo1.pem -noout -text \
  | grep -E "Public-Key|Subject Alternative Name" -A1
# 기대: Public-Key: (3072 bit) + 노드 호스트가 SAN 에 등록됨
```

## 🔌 앱 측 연결 방법

### `MONGO_TLS_REQUIRED=true` (스펙 준수)

앱의 연결 문자열에 **TLS 파라미터 필수**:

```env
# app-api/.env
MONGO_DATABASE_URL=mongodb://appUser:CHANGE_ME_APP@mongo1:27017,mongo2:27017/myapp?replicaSet=rs0&authSource=myapp&tls=true&tlsCAFile=/certs/ca.pem
```

- `tls=true` — TLS 활성화
- `tlsCAFile=/certs/ca.pem` — CA 인증서 경로 (앱 컨테이너 안 경로)
- `replicaSet=rs0` — 레플리카셋 인지 (자동 장애조치)

#### CA 인증서를 앱 컨테이너에 마운트

앱 측 `docker-compose.yml`:

```yaml
services:
  app-api:
    image: ...
    volumes:
      - mongo_ca:/certs:ro       # ca.pem 만 포함된 공개 CA 볼륨
    networks:
      - myapp-net                 # MongoDB 와 같은 네트워크

volumes:
  mongo_ca:
    external: true
    name: myapp_mongo_ca          # MongoDB compose 의 COMPOSE_PROJECT_NAME 이 myapp 인 경우
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
MONGO_DATABASE_URL=mongodb://appUser:CHANGE_ME_APP@mongo1:27017,mongo2:27017/myapp?replicaSet=rs0&authSource=myapp
```

- 앱 측 변경 없음 (TLS 파라미터 불필요)
- 노드 간 통신은 여전히 TLS 1.3 으로 암호화 (보안 기반선 유지)
- 감사 대응이 필요하면 운영 전환 시 `true` 로 토글

## 🔁 기존 단일 멤버 rs0 마이그레이션

기존 패키지(`legacy package` 등)의 단일 노드 MongoDB가 이미 `replicaSet=rs0` 로 운영 중인
경우에도, 데이터 볼륨을 새 3노드 레플리카셋에 직접 끼우지 말고 앱 DB만 논리 백업/복원하세요.
`admin`, `local`, `config` DB 와 기존 replica set 내부 메타데이터는 이관하지 않습니다.

전환 시점에는 API 를 잠시 중지하거나 쓰기를 막은 뒤 dump 를 뜨는 것이 안전합니다.

```bash
# 기존 단일 MongoDB 컨테이너에서 앱 DB 만 archive dump
# 예: 기존 컨테이너 legacy-mongodb, 앱 DB legacydb
docker compose exec mongodb mongodump \
  --uri "mongodb://root:CHANGE_ME_ROOT@127.0.0.1:27017/admin?authSource=admin&directConnection=true" \
  --db legacydb \
  --gzip \
  --archive=/tmp/legacydb.archive.gz

docker cp legacy-mongodb:/tmp/legacydb.archive.gz ./legacydb.archive.gz
```

새 레플리카셋은 빈 볼륨으로 먼저 기동한 뒤, `mongo1` 에 archive 를 복사해서 root 로 복원합니다.
기본 `COMPOSE_PROJECT_NAME=rs` 라면 컨테이너명은 `rs-mongo1` 입니다.

```bash
docker compose up -d

docker cp ./legacydb.archive.gz rs-mongo1:/tmp/legacydb.archive.gz

docker exec rs-mongo1 bash -lc '
  . /mongodb/mongo-connect.sh
  mongorestore "${MONGO_CONN_ARGS[@]}" \
    --gzip \
    --archive=/tmp/legacydb.archive.gz \
    --drop
'
```

복원 후 API 서비스에는 `mongo_ca` 볼륨을 마운트하고, 애플리케이션의 MongoDB URL 을
레플리카셋 + TLS 1.3 연결 문자열로 교체합니다.

```env
MONGO_DATABASE_URL=mongodb://appUser:CHANGE_ME_APP@mongo1:27017,mongo2:27017/legacydb?replicaSet=rs0&authSource=legacydb&tls=true&tlsCAFile=/certs/ca.pem
```

새 클러스터의 앱 계정은 `.env` 의 `MONGO_NAME`, `MONGO_USER`, `MONGO_PASS` 로 생성됩니다.
기존 `admin` 계정이나 과거 앱 유저를 dump 로 옮기지 말고 새 클러스터 기준으로 재생성하는
방식을 권장합니다.

## 🔧 운영

### 컨테이너 관리

```bash
# 로그 확인
docker compose logs -f mongo1

# 재시작
docker compose restart

# 정지 (데이터/PKI 유지)
docker compose down

# 정지 + compose 소유 볼륨 삭제
# 3노드 기본 구성의 Mongo 데이터/PKI 볼륨은 external이라 삭제되지 않음
docker compose down -v
```

### 셸 접속 (root)

```bash
docker exec -it myapp-mongo1 \
  mongosh "mongodb://root:CHANGE_ME_ROOT@127.0.0.1:27017/admin?directConnection=true" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames
```

### 셸 접속 (앱 유저)

```bash
docker exec -it myapp-mongo1 \
  mongosh "mongodb://appUser:CHANGE_ME_APP@127.0.0.1:27017/myapp?directConnection=true&authSource=myapp" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames
```

### 백업 (자동 — mongo-backup 서비스)

`docker-compose.yml` 의 **mongo-backup** 컨테이너가 정기적으로 백업을 수행합니다.
별도 명령 없이 `docker compose up -d` 만으로 동작합니다.

> **최소권한 계정**: 상시 도는 백업 컨테이너는 root 가 아니라 내장 `backup` 롤만 가진 전용
> 계정(`MONGO_BACKUP_USER`, primary 가 init 시 자동 생성)으로 mongodump 합니다. 이 계정은
> 읽기만 가능해, 유출돼도 데이터를 쓰거나 지우거나 서버를 제어할 수 없습니다.
>
> 복원(쓰기)은 운영자가 `./scripts/restore.sh` 로 수행하며, **그때만** root 를 사용합니다
> (restore.sh 가 `docker exec` 시점에 root 자격증명을 백업 컨테이너에 일시 주입 → mongorestore
> 종료와 함께 사라짐). 즉 백업 컨테이너는 **평상시 root-free, 운영자 복원 중에만 일시적으로
> root 를 받습니다**. 복원은 드물고 운영자가 직접 실행하므로 수용 가능한 트레이드오프입니다.
>
> ⚠️ **기존(이미 초기화된) 클러스터 업그레이드** (sentinel 존재 → init 이 backupUser 를
> 자동 생성하지 않음). 순서대로:
> ```bash
> # 1) .env 에 두 변수 추가 (값은 자유, 단 2·3 에서 동일하게 사용)
> #    MONGO_BACKUP_USER=backupUser
> #    MONGO_BACKUP_PASS=<강한 비밀번호>
> # 2) mongo1 을 새 env 로 재생성 (init 재실행 아님, env 주입용)
> docker compose up -d mongo1
> # 3) PRIMARY 에서 멱등 스크립트로 backupUser 1회 생성 (비밀번호는 컨테이너 env 로 전달, cmdline 노출 X)
> #    mongo1 이 PRIMARY 인지 먼저 확인: rs.status(). 아니면 현재 PRIMARY 노드로 바꿔 실행.
> docker exec <프로젝트>-mongo1 bash -c \
>   'mongosh "mongodb://127.0.0.1:27017/admin?directConnection=true" \
>     --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames \
>     -u root -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin \
>     --quiet --file /mongodb/init-backup-user.js'
> # 4) 백업 컨테이너 재생성
> docker compose up -d mongo-backup
> ```

```
mongo-backup 동작:
  secondaryPreferred 로 mongodump (평소 secondary 에서 읽어 primary 부하 최소화,
                                    secondary 가 없으면 primary 로 폴백, TLS)
    → gzip 압축
    → age 공개키로 암호화 (스펙 6.2.3 — AEAD)
    → 호스트 폴더(${BACKUP_DIR}) 에 저장
    → BACKUP_RETENTION_DAYS 초과분 자동 삭제
  ⟳ BACKUP_INTERVAL 간격 반복
```

```
호스트:  ${BACKUP_DIR}/   (예: ./backups)
         ├── backup-2026-06-03_030000.archive.gz.age
         ├── backup-2026-06-04_030000.archive.gz.age
         └── ...  (보관 일수만큼 유지, 컨테이너를 지워도 보존)
```

관련 환경 변수 (`.env`):

```env
BACKUP_DIR=./backups            # 호스트 백업 폴더 (bind mount)
BACKUP_INTERVAL=86400           # 백업 주기(초). 86400=매일
BACKUP_RETENTION_DAYS=7         # 보관 일수
BACKUP_AGE_RECIPIENT=age1...    # age 공개키 (아래 "백업 키 생성" 참고)
```

#### 백업 키 생성 (최초 1회, 운영 서버가 아닌 안전한 환경에서)

스펙 6.2.3 은 "운영 TLS·LUKS 키와 완전히 다른 키 체계" 를 요구합니다. `age` 키쌍이 이를 만족합니다.

```bash
# 안전한 작업 PC 에서 (서버 아님)
age-keygen -o backup-key.txt
# 출력 예:
#   Public key: age1qz9x...          ← 이 공개키를 .env 의 BACKUP_AGE_RECIPIENT 에 입력
# backup-key.txt 안에 비밀키가 들어있음 ← ★서버에 두지 말 것★
```

- **공개키(recipient)** → `.env` 의 `BACKUP_AGE_RECIPIENT` 에 입력 → 백업 컨테이너는 암호화만 가능
- **비밀키(`backup-key.txt`)** → 비밀번호 관리자 / vault / 오프라인 매체에 보관. 복원 시에만 사용

> 백업 컨테이너는 공개키만 가지므로 **자기가 만든 백업을 복호화할 수 없습니다.**
> 서버와 백업 파일을 통째로 탈취당해도 비밀키 없이는 내용을 읽을 수 없습니다 (스펙의 "매체 분실·침해 대비").

> ⚠️ `BACKUP_AGE_RECIPIENT` 가 비어 있으면 백업 컨테이너는 **실패**합니다(fail-closed).
> 암호화 없는 백업을 막기 위함입니다. 의도적으로 평문 백업이 필요한 경우에만
> `BACKUP_ALLOW_PLAINTEXT=true` 를 함께 설정하세요(스펙 6.2.3 미충족).

#### 수동 즉시 백업 (온디맨드)

`backup.sh once` 는 1회만 백업하고 종료합니다(성공 exit 0 / 실패 exit 1).
수동 백업·동작 확인·외부 트리거에 사용합니다.

```bash
docker exec ${COMPOSE_PROJECT_NAME}-mongo-backup /mongodb/backup.sh once
ls -l ${BACKUP_DIR}/
```

백업/시점 복원 동작 테스트:

```text
1. 테스트 데이터 A 생성
2. docker exec rs-mongo-backup /mongodb/backup.sh once
3. 테스트 데이터 B 생성
4. ./scripts/restore.sh 실행
5. 2번에서 만든 백업 선택
6. Restore mode는 overwrite 선택
7. 앱에서 A는 보이고 B는 안 보이면 정상
```

### 복원 (restore)

비밀키가 있는 안전한 환경에서 수행합니다. 호스트 래퍼 **`./scripts/restore.sh`** 가
`.env` 로드 + 비밀키 전달 + 컨테이너 엔진 호출을 한 번에 처리합니다.

```bash
# 대화형: 키 입력 → 최근 백업 목록 → 번호 선택 → 복원
./scripts/restore.sh

# 목록만 보기 (키 불필요)
./scripts/restore.sh --list

# 최신 백업으로 복원
./scripts/restore.sh --latest /path/to/backup-key.txt

# 특정 백업으로 복원
./scripts/restore.sh backups/backup-2026-06-03_030000.archive.gz.age /path/to/backup-key.txt

# 백업 시점으로 되돌리려면 overwrite를 사용한다.
# overwrite는 .env의 MONGO_NAME 앱 DB를 먼저 비운 뒤 선택 백업의 MONGO_NAME.*만 복원한다.
RESTORE_DROP=true ./scripts/restore.sh --latest /path/to/backup-key.txt
```

> `./scripts/restore.sh`(호스트 래퍼)는 `docker exec` 로 백업 컨테이너 안에서
> `age -d` 와 `mongorestore` 를 인라인 실행합니다. mongorestore·age·CA 는 컨테이너 안에
> 있으므로 호스트엔 docker 만 있으면 됩니다.
> 비밀키는 컨테이너로 잠깐 전달했다가 종료 시 삭제됩니다(서버에 영구 보관하지 않음).

> `age -d` 가 AEAD 인증 태그를 검증하므로, 백업 파일이 변조되었거나 키가 틀리면
> 복호화가 실패하고 mongorestore 는 실행되지 않습니다 (스펙 6.2.3 무결성 검증 충족).

#### ⚠️ 레플리케이션 ≠ 백업

3노드 레플리카셋은 **하드웨어 장애** 에 대비한 가용성 장치이지 백업이 아닙니다.
`deleteMany`/`dropDatabase` 같은 실수나 앱 버그, 랜섬웨어는 **3노드에 즉시 복제**되어
복구할 곳이 없습니다. 과거 시점 복구·논리적 사고 대비를 위해 백업은 별도로 필요합니다.

### 자동 장애조치 동작 확인

```bash
# Primary 강제 중지
docker stop myapp-mongo1

# 약 10~15초 후 mongo2 가 PRIMARY 로 승격됨
docker exec myapp-mongo2 \
  mongosh "mongodb://root:CHANGE_ME_ROOT@127.0.0.1:27017/admin?directConnection=true" \
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
| TLS 1.3 전용 (1.0/1.1/1.2 비활성화) | `--tlsDisabledProtocols TLS1_0,TLS1_1,TLS1_2` |
| Cipher AES-256-GCM 등 | TLS 1.3 기본 cipher suite (TLS_AES_256_GCM_SHA384 포함) |
| 키 교환 ECDHE X25519 | TLS 1.3 기본 그룹 |
| 인증서 RSA-3072 또는 ECDSA P-256 | **RSA-3072** (노드 인증서, `gen-secrets.sh`) |
| 내부 PKI 발급 | 자체 CA 자동 생성 (`gen-secrets.sh`) |
| 레플리카 노드 간 X.509 mTLS | `clusterAuthMode=x509` |
| `net.tls.mode=requireTLS` | `MONGO_TLS_REQUIRED=true` → `requireTLS` (기본) |
| `tlsCertificateKeyFile` / `tlsCAFile` | `/pki/<node>.pem` / `/pki/ca.pem` |
| 저장 볼륨 LUKS2 암호화 | **OS 영역** — 호스트 디스크/파티션을 LUKS2 로 설정한 위에 docker 볼륨 마운트 |
| 백업 매체 AEAD 암호화 | **mongo-backup 서비스 자동화** — mongodump→gzip→age(ChaCha20-Poly1305) 공개키 암호화, 복원 시 AEAD 태그 검증 (위 "백업" 섹션) |

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
docker compose restart mongo-init
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
docker compose down
docker volume rm ${COMPOSE_PROJECT_NAME}_mongo_pki
docker volume rm ${COMPOSE_PROJECT_NAME}_mongo_ca
docker compose up -d
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
TLS 로 접속하는 경우에는 두 모드 모두 TLS 1.3 만 허용합니다.

### B. 자동 생성되는 PKI 파일들

`/pki/` 공유 볼륨:

| 파일 | 용도 | 권한 |
|---|---|:---:|
| `ca.pem` | CA 인증서 (공개) — `mongo_ca` 볼륨에도 복사되어 앱/백업에 배포 가능 | 444 |
| `ca.key` | CA 비밀키 — 외부 유출 금지 | 400 |
| `mongodb-keyfile` | 노드 간 내부 인증 (보조) | 400 |
| `<host>.pem` | 노드 서버 인증서 (key+cert 합본) | 400 |
| `<host>.key` / `<host>.crt` | 노드 인증서 구성 요소 | 400 |

`mongo_pki` 볼륨은 MongoDB 노드 전용 private 볼륨입니다. 앱/백업 컨테이너에는
`mongo_ca` 볼륨 또는 별도로 복사한 `ca.pem` 파일만 전달하세요.

소유자: `mongodb:mongodb` (uid 999)

### C. 사용된 mongod 옵션

```
--replSet rs0
--bind_ip_all
--keyFile /pki/mongodb-keyfile
--tlsMode {requireTLS | preferTLS}        # MONGO_TLS_REQUIRED 로 결정
--tlsCertificateKeyFile /pki/<node>.pem
--tlsCAFile /pki/ca.pem
--tlsDisabledProtocols TLS1_0,TLS1_1,TLS1_2
--clusterAuthMode x509
--tlsAllowConnectionsWithoutCertificates  # 앱은 클라이언트 인증서 없어도 OK
```

### D. 호스트 토폴로지 변경 절차

레플리카셋 멤버를 추가/제거할 때:

```bash
# 1. .env 의 MONGO_REPLICA_HOSTS / MONGO_ARBITER_HOST 수정
# 2. docker-compose.yml 에 서비스(mongo4 등) 추가 (필요 시)
# 3. PKI 재생성 (또는 누락된 노드 인증서만 추가 생성)
docker compose restart mongo-init
# 4. 새 노드 기동
docker compose up -d
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
| `DOCKER_NETWORK_NAME` | 기본값 또는 앱 네트워크명 | **앱이 만든 네트워크명** | 호스트별 분리 |
| `compose networks:` | `external: true` 기본 | `external: true` 기본 | 호스트별 다름 |
| `ports:` | 불필요 (네트워크 공유) | 불필요 | **27017 호스트 매핑 필수** |
| 인증서 SAN | `DNS:mongo1` 자동 | 동일 | `IP:192.168.x.x` 자동 (`gen-secrets.sh`) |
| 방화벽 | — | — | **노드 간 27017 통신 허용** |
| compose 파일 구조 | 1개 | 1개 | 호스트별 별도 |

#### 시나리오 B — 외부 네트워크 공유

앱이 먼저 `myapp-net` 같은 네트워크를 만들어둔 경우, 그 네트워크에 MongoDB 노드를 join 시켜서 같은 DNS 공간을 공유합니다.

`.env` 설정:
```env
DOCKER_NETWORK_NAME=myapp-net   # 앱이 만든 네트워크 이름
# (다른 값은 시나리오 A 와 동일)
```

`docker-compose.yml` 의 networks 섹션은 기본으로 external 네트워크를 사용합니다:
```yaml
networks:
  mongo-net:
    name: ${DOCKER_NETWORK_NAME:-mongo-rs-net}
    external: true
```

기동 순서:
1. `prepare-install.sh` 실행. 네트워크가 없으면 생성됨
2. MongoDB compose up

#### 시나리오 C — 다중 호스트 분산

각 노드가 다른 물리 서버에 있을 때. 같은 LAN(< 10ms latency) 권장.

각 호스트에서 자기 노드만 실행:
```env
# 호스트 1 (mongo1)
MONGO_REPLICA_HOSTS=192.168.1.10:27017,192.168.1.11:27017
MONGO_ARBITER_HOST=192.168.1.12:27017
```

`docker-compose.yml` 을 호스트별로 분할하거나, 단일 compose 에서 자기 노드 서비스만 활성화. 각 노드에 ports 매핑 추가:
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
- **TLS**: 1.3 전용 (1.0/1.1/1.2 비활성)
- **인증서**: RSA-3072 (노드), RSA-4096 (CA)
- **레플리카셋 클러스터 인증**: x509 (mTLS)
