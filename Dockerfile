FROM mongo:8.0.17

# MongoDB 스크립트 디렉토리 생성
RUN mkdir -p /mongodb && chown mongodb:mongodb /mongodb

# 모든 초기화 스크립트를 한 번에 복사 후 실행 권한 일괄 부여
#   - .sh : 단일/다중 노드용 entrypoint, replica/PKI 초기화, TLS 인증서 생성
#   - .js : mongosh 가 실행하는 사용자/뷰 초기화
COPY scripts/ /mongodb/
RUN chmod +x /mongodb/*.sh

# MongoDB 시작 명령어
# CMD는 기본 옵션만 포함 (keyFile/TLS 옵션은 entrypoint 가 동적으로 부여)
ENTRYPOINT ["/mongodb/docker-entrypoint.sh"]
CMD ["mongod", "--replSet", "rs0", "--bind_ip_all", "--keyFile", "/data/db/mongodb-keyfile"]
