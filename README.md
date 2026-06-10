# MongoDB Replica Set Docker

MongoDB 8.0.17 기반의 Replica Set 구성을 위한 Docker 이미지 및 환경 설정입니다.

## 🎯 프로젝트 목적

**온프레미스(On-Premise)** 환경에서 **Prisma**와 **MongoDB**를 연동할 때 **트랜잭션(Transaction)** 기능을 사용하기 위해 **Replica Set** 구성이 반드시 필요합니다.

### 왜 Replica Set이 필요한가?

- **온프레미스 환경 요구사항**: 클라우드가 아닌 온프레미스 환경에서 MongoDB를 운영하면서 Prisma의 트랜잭션 기능을 사용하기 위함
- **Prisma의 트랜잭션 요구사항**: Prisma는 MongoDB에서 트랜잭션을 사용하기 위해 Replica Set 환경을 요구합니다.
- **MongoDB 트랜잭션 제약**: MongoDB는 단일 노드(Standalone) 환경에서는 트랜잭션을 지원하지 않습니다.
- **개발 환경 구성**: 로컬 개발 환경에서도 Replica Set을 구성하여 프로덕션 환경과 동일한 조건에서 개발할 수 있습니다.

이 프로젝트는 **온프레미스 환경에서 Docker를 사용하여 Replica Set을 간편하게 구성**하고, Prisma와 MongoDB를 원활하게 연동할 수 있도록 설계되었습니다.

## 🌐 두 가지 배포 모드

하나의 Docker 이미지로 **단일 노드** 와 **3 노드(데이터 2 + Arbiter)** 두 가지 배포를 모두 지원합니다.
**둘 다 Replica Set** 구성이며 (단일 노드는 1-멤버, 3 노드는 3-멤버) Standalone 모드는 사용하지 않습니다.
Prisma 트랜잭션은 양쪽에서 모두 동작합니다.

| 항목 | 단일 노드 | 3 노드 (데이터 2 + Arbiter) |
|---|:---:|:---:|
| 컨테이너 수 | 1 | 4 (init 1 + mongo 3) |
| 레플리카셋 멤버 | 1 | 3 |
| Prisma 트랜잭션 | ✅ | ✅ |
| 데이터 복제 | ❌ | ✅ (1→1 복제) |
| 자동 장애조치 (failover) | ❌ | ✅ |
| 노드 간 TLS 암호화 | — | ✅ (preferTLS) |
| 노드 간 X.509 mTLS | — | ✅ (`clusterAuthMode=x509`) |
| 자동 백업 (age/AEAD 암호화) | — | ✅ (mongo-backup 서비스) |
| 사용 파일 | `docker-compose.yml` | `docker-compose.replicaset.yml` |
| 환경 변수 템플릿 | `.env.example` | `.env.replicaset.example` |
| 가이드 | **본 README → "🚀 단일 노드 배포"** | **[docs/replicaset.md](docs/replicaset.md)** |

**언제 어느 모드를 쓰나**:
- 개발·테스트 환경, Prisma 트랜잭션만 필요 → **단일 노드**
- 운영 환경 배포, 가용성/보안 스펙(전송 암호화·mTLS·요구사항 문서) 필요 → **3 노드**

두 모드 모두 TLS 토글(`MONGO_TLS_REQUIRED`)을 지원하여 `requireTLS`(스펙 준수, 기본) / `allowTLS`·`preferTLS`(평문 호환) 선택이 가능합니다.

## 📋 프로젝트 구조

```
mongodb/
├── Dockerfile                          # MongoDB 커스텀 이미지 빌드 파일
├── docker-compose.yml                  # 단일 노드 배포
├── docker-compose.replicaset.yml       # 3 노드 배포 (init + mongo1/2/3)
├── .env.example                        # 단일 노드 환경 변수 템플릿
├── .env.replicaset.example             # 3 노드 환경 변수 템플릿
├── .env                                # 실제 환경 변수 (git에서 제외)
├── docs/
│   └── replicaset.md                   # 3 노드 배포 가이드
└── scripts/
    ├── docker-entrypoint.sh            # 단일 노드 entrypoint
    ├── docker-entrypoint-replica.sh    # 3 노드 entrypoint
    ├── init-replica.sh                 # 단일 노드 rs.initiate
    ├── init-replica-multi.sh           # 3 노드 rs.initiate
    ├── init-tls.sh                     # 단일 노드 TLS 인증서 생성
    ├── gen-secrets.sh                  # 3 노드 공유 PKI 생성 (init 컨테이너)
    ├── init-user.js                    # 사용자 생성 스크립트
    ├── backup.sh                       # 백업 (mongodump→gzip→age 암호화)
    ├── restore.sh                      # 복원 (age 복호화→mongorestore)
    └── mongo-conn.sh                   # backup/restore 공용 접속 설정
```

## 🚀 단일 노드 배포

> 3 노드 배포는 [docs/replicaset.md](docs/replicaset.md) 의 가이드를 따르세요.

### 1. 환경 변수 설정

`.env.example` 파일을 복사하여 `.env` 파일을 생성하고 필요한 값을 설정합니다:

```bash
cp .env.example .env
```

`.env` 파일 내용:

```env
MONGO_ROOT_PASS="#example123!"
MONGO_PRIMARY_HOST='example-mongodb:27017'

MONGO_NAME='example-mongodb'
MONGO_USER='example'
MONGO_PASS='#example123!'
```

### 2. Docker 이미지 빌드

#### 방법 1: Docker Build 명령어 사용

```bash
# 기본 빌드
docker build -t mongo-alone:latest .

# 캐시 없이 클린 빌드
docker build --no-cache -t mongo-alone:latest .

# 특정 플랫폼용 빌드
docker buildx build --platform linux/amd64 -t mongo-alone:latest .
```

#### 방법 2: Docker Compose 사용 (권장)

```bash
# Docker Compose로 빌드 및 실행
docker compose up -d
```

Docker Compose를 사용하면 자동으로 이미지를 빌드하고 컨테이너를 실행합니다.

### 3. 컨테이너 실행

```bash
# 서비스 시작 (백그라운드)
docker compose up -d

# 특정 서비스만 시작
docker compose up -d mongodb

# 로그 확인
docker compose logs -f

# 특정 서비스 로그만 확인
docker compose logs -f mongodb
```

### 4. 빌드된 이미지 확인

```bash
# 모든 이미지 목록 확인
docker images

# MongoDB 관련 이미지만 확인
docker images | grep mongo
```

## 🚀 3 노드 배포 (Quick-start)

> 자세한 사항은 **[docs/replicaset.md](docs/replicaset.md)** 를 참고하세요 (구성·배포 워크플로·검증·연결·운영·보안 스펙 매핑·문제 해결까지 상세).

### 1. 환경 변수 설정

```bash
cp .env.replicaset.example .env
vi .env   # 비밀번호·호스트·TLS 모드 수정
```

핵심 환경 변수:

```env
COMPOSE_PROJECT_NAME=myapp
MONGO_IMAGE=mongo-rs:1.0.0
DOCKER_NETWORK_NAME=myapp-net

# 데이터 노드 (첫 항목 = primary 후보)
MONGO_REPLICA_HOSTS=mongo1:27017,mongo2:27017
# Arbiter (선택, 데이터 3노드로 가려면 비우고 위에 3개 나열)
MONGO_ARBITER_HOST=mongo3:27017

# 계정
MONGO_ROOT_PASS=#StrongRootPass1!
MONGO_NAME=myapp
MONGO_USER=appUser
MONGO_PASS=#StrongAppPass1!

# TLS 강제 여부 (기본 true = 스펙 준수)
MONGO_TLS_REQUIRED=true

# 백업 (mongo-backup 서비스)
BACKUP_DIR=./backups                 # 호스트 백업 폴더 (bind mount)
BACKUP_INTERVAL=86400                # 백업 주기(초). 86400=매일
BACKUP_RETENTION_DAYS=7              # 보관 일수
# age 공개키(recipient). 안전한 환경에서 `age-keygen` 으로 생성한 공개키를 입력.
# 비어 있으면 백업 컨테이너는 실패한다(fail-closed). 자세한 절차는 docs/replicaset.md.
BACKUP_AGE_RECIPIENT=
```

### 2. 빌드 + 기동

```bash
docker compose -f docker-compose.replicaset.yml --env-file .env up -d --build
```

`mongo-init` 컨테이너가 공유 PKI(CA · keyFile · 노드별 인증서)를 1회 생성한 뒤 종료하고, 이어서 `mongo1`(primary 후보) / `mongo2`(secondary) / `mongo3`(arbiter) 가 자동으로 합류합니다. `mongo-backup` 컨테이너가 정기적으로 암호화 백업을 호스트 폴더에 쌓습니다(자세한 키 생성·복원 절차는 [docs/replicaset.md](docs/replicaset.md)).

### 3. 검증

```bash
# 컨테이너 healthy 확인
docker ps --filter "name=${COMPOSE_PROJECT_NAME}" --format "{{.Names}} | {{.Status}}"

# 레플리카셋 멤버 상태
docker exec ${COMPOSE_PROJECT_NAME}-mongo1 \
  mongosh "mongodb://root:${MONGO_ROOT_PASS}@127.0.0.1:27017/admin?directConnection=true" \
  --tls --tlsCAFile /pki/ca.pem --tlsAllowInvalidHostnames --quiet \
  --eval "rs.status().members.forEach(m => print(m.name, '=>', m.stateStr))"
```

기대 결과: `mongo1:27017 => PRIMARY`, `mongo2:27017 => SECONDARY`, `mongo3:27017 => ARBITER`.

앱 측 연결 문자열 예시·CA 인증서 배포·백업·문제 해결은 [docs/replicaset.md](docs/replicaset.md) 를 참고하세요.

## 🔧 주요 기능

### Replica Set 자동 구성

- 컨테이너 시작 시 자동으로 Replica Set(`rs0`) 초기화
- Primary 노드 설정 대기 및 자동 재시도 메커니즘

### 사용자 자동 생성

- root 사용자 외에 애플리케이션용 사용자 자동 생성
- `.env` 파일에서 설정한 사용자 정보 사용

### 보안 설정

- KeyFile 기반 인증 자동 설정
- 외부 접근 제어를 위한 bind_ip 설정

### Health Check

- MongoDB 연결 상태 자동 모니터링
- 30초 간격으로 health check 수행
- 90초의 시작 대기 시간 제공

## 📦 컨테이너 관리

### 컨테이너 상태 확인

```bash
# 실행 중인 컨테이너 확인
docker ps

# 모든 컨테이너 확인 (중지된 컨테이너 포함)
docker ps -a
```

### 컨테이너 중지 및 재시작

```bash
# 서비스 중지
docker compose down

# 볼륨까지 삭제하며 중지 (데이터 삭제 주의!)
docker compose down -v

# 서비스 재시작
docker compose restart

# 특정 서비스만 재시작
docker compose restart mongodb
```

### MongoDB 셸 접속

```bash
# MongoDB 컨테이너 내부 셸 접속
docker exec -it example-mongodb bash

# MongoDB 셸 직접 접속 (root 사용자)
docker exec -it example-mongodb mongosh -u root -p '#example123!' --authenticationDatabase admin

# MongoDB 셸 직접 접속 (일반 사용자)
docker exec -it example-mongodb mongosh -u example -p '#example123!'
```

### 컨테이너 로그 확인

```bash
# 실시간 로그 확인
docker compose logs -f

# 마지막 100줄만 확인
docker compose logs --tail=100

# 특정 시간 이후 로그 확인
docker compose logs --since 30m
```

## 🐛 문제 해결

### Replica Set 초기화 실패

로그에서 Replica Set 초기화 실패 메시지를 확인한 경우:

```bash
# 컨테이너 재시작
docker compose restart mongodb

# 완전히 재시작 (볼륨 유지)
docker compose down
docker compose up -d
```

### 볼륨 데이터 초기화

데이터를 완전히 초기화하고 싶은 경우:

```bash
# 경고: 모든 데이터가 삭제됩니다!
docker compose down -v
docker compose up -d
```

### 네트워크 문제

컨테이너 간 통신 문제가 있는 경우:

```bash
# 네트워크 확인
docker network ls

# 네트워크 상세 정보 확인
docker network inspect mongodb_mongo-net
```

## 🔐 보안 권장사항

1. **비밀번호 변경**: `.env` 파일의 기본 비밀번호를 반드시 변경하세요
2. **포트 노출 제한**: 운영 환경에서는 필요한 경우에만 포트를 외부에 노출하세요
3. **환경 변수 관리**: `.env` 파일을 절대 git에 커밋하지 마세요 (`.gitignore`에 포함됨)

## 📝 버전 정보

- **MongoDB**: 8.0.17
- **Base Image**: mongo:8.0.17 (mongoBleed 이슈 패치 버전)
