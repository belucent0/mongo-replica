FROM mongo:8.0.17

# MongoDB 스크립트 디렉토리 생성
RUN mkdir -p /mongodb && chown mongodb:mongodb /mongodb

# 커스텀 entrypoint 스크립트 복사
COPY scripts/docker-entrypoint.sh /mongodb/docker-entrypoint.sh
RUN chmod +x /mongodb/docker-entrypoint.sh

# 초기화 스크립트 복사 (docker-entrypoint.sh에서 사용)
COPY scripts/init-replica.sh /mongodb/init-replica.sh
RUN chmod +x /mongodb/init-replica.sh
COPY scripts/init-user.js /mongodb/init-user.js

# MongoDB 시작 명령어
# CMD는 기본 옵션만 포함 (keyFile은 docker-entrypoint.sh에서 처리)
ENTRYPOINT ["/mongodb/docker-entrypoint.sh"]
CMD ["mongod", "--replSet", "rs0", "--bind_ip_all", "--keyFile", "/data/db/mongodb-keyfile"]
