// ============================================
// 사용자 타입 판별 및 변수 설정
// ============================================
// MONGO_INITDB_ROOT_USERNAME이 존재하면 root 사용자 생성, 아니면 앱 사용자 생성
const isRootUser = !!(
  process.env.MONGO_INITDB_ROOT_USERNAME &&
  process.env.MONGO_INITDB_ROOT_PASSWORD
);

let userName, userPassword, userDb, userRole, targetDb;

if (isRootUser) {
  // Root 사용자 생성
  userName = process.env.MONGO_INITDB_ROOT_USERNAME;
  userPassword = process.env.MONGO_INITDB_ROOT_PASSWORD;
  userDb = "admin";
  userRole = "root";
  targetDb = db; // admin DB

  if (!userName || !userPassword) {
    print(
      "❌ ERROR: MONGO_INITDB_ROOT_USERNAME and MONGO_INITDB_ROOT_PASSWORD are required"
    );
    quit(1);
  }
} else {
  // 애플리케이션 사용자 생성 (표준 관행: 애플리케이션 DB에 생성)
  // 이 스크립트는 이미 해당 DB 컨텍스트에서 실행됨 (mongosh "$MONGO_NAME")
  userName = process.env.MONGO_USER;
  userPassword = process.env.MONGO_PASS;
  userDb = process.env.MONGO_NAME; // 사용자를 생성할 DB (권한을 부여할 DB와 동일)
  userRole = "readWrite";
  targetDb = db; // 이미 해당 DB 컨텍스트에서 실행되므로 db를 직접 사용

  if (!userName || !userPassword || !userDb) {
    print("❌ ERROR: MONGO_USER, MONGO_PASS, and MONGO_NAME are required");
    quit(1);
  }
}

try {
  targetDb.createUser({
    user: userName,
    pwd: userPassword,
    roles: [{ role: userRole, db: userDb }],
  });
  print(`✅ User '${userName}' created`);

  // 생성 후 즉시 확인
  // localhost exception 으로 첫 계정을 만든 경우, 계정이 생기는 즉시 exception 이
  // 소진되어 getUser(usersInfo) 는 인증을 요구한다. createUser 가 이미 성공했으므로
  // 이 경우 검증을 건너뛴다(비치명).
  try {
    const createdUser = targetDb.getUser(userName);
    if (!createdUser || createdUser.user !== userName) {
      print(`❌ ERROR: User '${userName}' was not created properly`);
      quit(1);
    }
    print(`✅ User '${userName}' verified successfully`);
  } catch (ve) {
    if (ve.message && ve.message.includes("requires authentication")) {
      print(
        `ℹ️ Verification skipped (localhost exception consumed): '${userName}' created`
      );
    } else {
      throw ve;
    }
  }
} catch (e) {
  // "requires authentication": localhost exception 이 이미 소진된 경우로,
  // 첫 계정(root)이 이전 실행에서 생성되었음을 의미 → 재시작 시 멱등하게 통과.
  if (
    e.message &&
    (e.message.includes("already exists") ||
      e.message.includes("requires authentication"))
  ) {
    print(`ℹ️ User '${userName}' already exists`);
  } else {
    print(`❌ Error: ${e.message}`);
    throw e;
  }
}
