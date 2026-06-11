// 백업 전용 최소권한 사용자 생성 — admin DB 에 내장 'backup' 롤만 부여한다.
//
// 'backup' 롤은 전체 클러스터 mongodump 에 필요한 읽기 권한(모든 DB find,
// listDatabases/listCollections, config·local·system 컬렉션 읽기)만 갖고,
// 어떤 쓰기·삭제·서버관리(shutdown, rs.reconfig 등)도 못 한다.
// → 상시 도는 백업 컨테이너가 root 자격증명을 들고 있지 않게 한다(유출 시 피해 최소화).
//
// 복원(mongorestore, 쓰기)은 운영자가 수동 수행 시 root 를 쓴다(restore.sh).
//
// root 인증으로 admin DB 컨텍스트에서 실행된다. 멱등(이미 있으면 통과).

const userName = process.env.MONGO_BACKUP_USER;
const userPassword = process.env.MONGO_BACKUP_PASS;

if (!userName || !userPassword) {
  print("❌ ERROR: MONGO_BACKUP_USER and MONGO_BACKUP_PASS are required");
  quit(1);
}

try {
  db.getSiblingDB("admin").createUser({
    user: userName,
    pwd: userPassword,
    roles: [{ role: "backup", db: "admin" }],
  });
  print(`✅ Backup user '${userName}' created (role: backup)`);
} catch (e) {
  // 이 스크립트는 항상 root 인증 하에 실행되므로 'already exists'(code 51003)만 멱등 성공으로
  // 본다. 'requires authentication' 등 다른 오류는 진짜 실패(예: 잘못된 root 비번)이므로
  // 삼키지 않고 전파한다 — backupUser 없이 init 이 성공처럼 끝나는 것을 막는다.
  if (e.message && e.message.includes("already exists")) {
    print(`ℹ️ Backup user '${userName}' already exists`);
  } else {
    print(`❌ Error: ${e.message}`);
    throw e;
  }
}
