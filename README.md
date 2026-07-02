# MongoDB Replica Set Docker

Docker Compose로 self-managed MongoDB Replica Set을 구성하기 위한 Docker 이미지와 운영 스크립트입니다.
TLS, X.509 노드 인증, 암호화 백업/복원, 오프라인 설치 흐름을 함께 제공합니다.

## 오프라인 릴리즈 설치

오프라인 설치는 GitHub Releases에서 아래 두 파일을 내려받아 같은 폴더에 둔 뒤 진행합니다.

- `mongo-replica-<version>.tar.gz`
- `mongodb-package-<version>-files.tar.gz`

설치 절차는 [MongoDB 3노드 전환 퀵스타트](mongodb-3node-migration-quickstart.txt)를 따릅니다.

## 🎯 프로젝트 목적

MongoDB Atlas나 Kubernetes Operator를 쓰기 어려운 self-hosted/offline 환경에서
MongoDB Replica Set을 빠르게 구성하고 운영할 수 있게 하는 패키지입니다.

### 왜 Replica Set이 필요한가?

- **가용성**: MongoDB Replica Set은 primary 장애 시 secondary 승격을 통해 장애조치를 제공합니다.
- **트랜잭션 호환성**: MongoDB 트랜잭션이 필요한 애플리케이션은 Replica Set 또는 Sharded Cluster 구성이 필요합니다.
- **self-hosted 운영**: Atlas/Operator 없이 Docker Compose만으로 TLS, 계정, 백업/복원 흐름을 구성합니다.
- **개발 환경 구성**: 로컬에서도 1-멤버 Replica Set으로 운영과 비슷한 연결 조건을 테스트할 수 있습니다.

Prisma ORM은 이 패키지를 사용할 수 있는 클라이언트 중 하나일 뿐이며, 일반 MongoDB 드라이버 기반 애플리케이션에도 사용할 수 있습니다.

## 🌐 두 가지 배포 모드

하나의 Docker 이미지로 **단일 노드** 와 **3 노드(데이터 2 + Arbiter)** 두 가지 배포를 모두 지원합니다.
**둘 다 Replica Set** 구성이며 (단일 노드는 1-멤버, 3 노드는 3-멤버) Standalone 모드는 사용하지 않습니다.
트랜잭션이 필요한 애플리케이션은 양쪽에서 Replica Set 연결 조건을 테스트할 수 있습니다.

| 항목 | 단일 노드 | 3 노드 (데이터 2 + Arbiter) |
|---|:---:|:---:|
| 컨테이너 수 | 1 | 4 (init 1 + mongo 3) |
| 레플리카셋 멤버 | 1 | 3 |
| 트랜잭션 호환성 | ✅ | ✅ |
| 데이터 복제 | ❌ | ✅ (1→1 복제) |
| 자동 장애조치 (failover) | ❌ | ✅ |
| 노드 간 TLS 암호화 | — | ✅ (preferTLS) |
| 노드 간 X.509 mTLS | — | ✅ (`clusterAuthMode=x509`) |
| 자동 백업 (age/AEAD 암호화) | — | ✅ (mongo-backup 서비스) |
| 사용 파일 | `docker-compose.single.yml` | **`docker-compose.yml` (기본)** |
| 환경 변수 템플릿 | `.env.single.example` | **`.env.example` (기본)** |
| 가이드 | **본 README → "🚀 단일 노드 배포"** | **[docs/replicaset.md](docs/replicaset.md)** |

> **기본 모드는 3노드 레플리카셋입니다.** `docker compose up -d` (옵션 없이) 하면 레플리카셋이 뜹니다.
> 단일 노드는 `docker compose -f docker-compose.single.yml ...` 처럼 파일을 명시합니다.

**언제 어느 모드를 쓰나**:
- 개발·테스트 환경, Replica Set 연결 조건만 필요 → **단일 노드**
- self-hosted 운영 환경, 가용성/보안/백업 필요 → **3 노드**

두 모드 모두 TLS 1.3 전용으로 동작합니다. `MONGO_TLS_REQUIRED=true` 는 앱 TLS 접속을 강제하고, `false` 는 평문 호환을 허용합니다.

## 📋 프로젝트 구조

```
mongodb/
├── Dockerfile                          # MongoDB 커스텀 이미지 빌드 파일
├── docker-compose.yml                  # ★ 3 노드 레플리카셋 배포 (기본)
├── docker-compose.single.yml           # 단일 노드 배포
├── .env.example                        # 3 노드(기본) 환경 변수 템플릿
├── .env.single.example                 # 단일 노드 환경 변수 템플릿
├── .env                                # 실제 환경 변수 (git에서 제외)
├── docs/
│   └── replicaset.md                   # 3 노드 배포 상세 가이드
└── scripts/
    ├── docker-entrypoint.sh            # 단일 노드 entrypoint
    ├── docker-entrypoint-replica.sh    # 3 노드 entrypoint
    ├── init-replica.sh                 # 단일 노드 rs.initiate
    ├── init-replica-multi.sh           # 3 노드 rs.initiate
    ├── init-tls.sh                     # 단일 노드 TLS 인증서 생성
    ├── gen-secrets.sh                  # 3 노드 private PKI + public CA 생성 (init 컨테이너)
    ├── init-user.js                    # root·앱 사용자 생성 스크립트
    ├── init-backup-user.js             # 백업 전용 최소권한 계정(backup 롤) 생성
    ├── backup.sh                       # 백업 (mongodump→gzip→age 암호화)
    ├── backup-healthcheck.sh           # 백업 신선도 healthcheck
    ├── check-status.sh                 # 레플리카/백업 상태 확인
    ├── prepare-install.sh              # 설치 준비(.env/백업 키 생성)
    ├── restore.sh                      # ★ 복원 진입점 (호스트: ./scripts/restore.sh, 대화형)
    └── mongo-connect.sh                # backup/restore 공용 접속 설정
```

## 🚀 단일 노드 배포

> 단일 노드는 `docker-compose.single.yml` 을 사용합니다 — 이 절의 모든 명령에 `-f docker-compose.single.yml` 이 붙습니다.
> (3 노드 배포는 [docs/replicaset.md](docs/replicaset.md) 참고)

### 1. 환경 변수 설정

`.env.single.example` 파일을 복사하여 `.env` 파일을 생성하고 필요한 값을 설정합니다:

```bash
cp .env.single.example .env
```

`.env` 파일 내용:

```env
MONGO_ROOT_PASS="CHANGE_ME"
MONGO_PRIMARY_HOST='example-mongodb:27017'

MONGO_NAME='example-mongodb'
MONGO_USER='example'
MONGO_PASS='CHANGE_ME'
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
# Docker Compose로 빌드 및 실행 (단일 노드 = -f 명시)
docker compose -f docker-compose.single.yml --env-file .env up -d --build
```

Docker Compose를 사용하면 자동으로 이미지를 빌드하고 컨테이너를 실행합니다.

### 3. 컨테이너 실행

```bash
# 서비스 시작 (백그라운드)
docker compose -f docker-compose.single.yml --env-file .env up -d

# 로그 확인
docker compose -f docker-compose.single.yml logs -f
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
cp .env.example .env
vi .env   # 비밀번호·호스트·TLS 모드 수정
```

핵심 환경 변수:

```env
COMPOSE_PROJECT_NAME=myapp
MONGO_IMAGE=mongo-replica:1.0.2
DOCKER_NETWORK_NAME=myapp-net

# 데이터 노드 (첫 항목 = primary 후보)
MONGO_REPLICA_HOSTS=mongo1:27017,mongo2:27017
# Arbiter (선택, 데이터 3노드로 가려면 비우고 위에 3개 나열)
MONGO_ARBITER_HOST=mongo3:27017

# 계정
MONGO_ROOT_PASS=CHANGE_ME_ROOT
MONGO_NAME=myapp
MONGO_USER=appUser
MONGO_PASS=CHANGE_ME_APP
# 백업 전용 최소권한 계정(backup 롤) — 백업 컨테이너가 root 대신 이 계정으로 mongodump
MONGO_BACKUP_USER=backupUser
MONGO_BACKUP_PASS=CHANGE_ME_BACKUP

# TLS 강제 여부 (기본 true = 스펙 준수)
# TLS 연결은 TLS 1.3 전용이다(TLS 1.0/1.1/1.2 비활성화).
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
# docker-compose.yml 이 기본이라 -f 불필요
docker compose --env-file .env up -d --build
```

`mongo-init` 컨테이너가 MongoDB 노드 전용 private PKI(CA key · keyFile · 노드별 인증서)와 앱/백업용 public CA(`ca.pem`)를 1회 생성한 뒤 종료하고, 이어서 `mongo1`(primary 후보) / `mongo2`(secondary) / `mongo3`(arbiter) 가 자동으로 합류합니다. `mongo-backup` 컨테이너가 정기적으로 암호화 백업을 호스트 폴더에 쌓습니다(자세한 키 생성·복원 절차는 [docs/replicaset.md](docs/replicaset.md)).

### 3. 검증

```bash
# 레플리카셋/백업 상태
./scripts/check-status.sh
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

> 아래 예시는 **단일 노드 기준**입니다 (`mongodb` 서비스 / `example-mongodb` 컨테이너,
> 명령에 `-f docker-compose.single.yml` 필요). 3 노드 운영 명령(셸 접속·재시작·로그·복원
> 등 컨테이너명이 `<프로젝트>-mongo1` 형태)은 **[docs/replicaset.md](docs/replicaset.md) 의 "🔧 운영"** 을 참고하세요.

### 컨테이너 상태 확인

```bash
# 실행 중인 컨테이너 확인
docker ps

# 모든 컨테이너 확인 (중지된 컨테이너 포함)
docker ps -a
```

### 컨테이너 중지 및 재시작

```bash
# 서비스 중지/시작 (데이터 유지)
docker compose stop
docker compose start

# compose 재적용/재시작
docker compose up -d

# 컨테이너 제거 (external Mongo 볼륨은 유지)
docker compose down
```

### MongoDB 셸 접속

```bash
# MongoDB 컨테이너 내부 셸 접속
docker exec -it example-mongodb bash

# MongoDB 셸 직접 접속 (root 사용자)
docker exec -it example-mongodb mongosh -u root -p 'CHANGE_ME' --authenticationDatabase admin

# MongoDB 셸 직접 접속 (일반 사용자)
docker exec -it example-mongodb mongosh -u example -p 'CHANGE_ME'
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
# 3노드 기본 구성은 external volume을 쓰므로 down -v만으로 데이터 볼륨을 지우지 않는다.
docker compose down -v
PROJECT=${COMPOSE_PROJECT_NAME:-rs}
docker volume rm ${PROJECT}_mongo1_data ${PROJECT}_mongo2_data ${PROJECT}_mongo3_data ${PROJECT}_mongo_pki ${PROJECT}_mongo_ca
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
- **TLS**: 1.3 전용 (TLS 1.0/1.1/1.2 비활성화)
- **Base Image**: mongo:8.0.17 (mongoBleed 이슈 패치 버전)
