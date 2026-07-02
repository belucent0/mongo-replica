// 앱 → MongoDB 레플리카셋 연결 검증 스크립트 (호스트에서 실행)
//
//   실행:  node check-app-conn.mjs
//   사전:  npm i mongodb dotenv  +  .env 에 MONGO_DATABASE_URL 설정
//          (TLS 모드면 URL 에 ?tls=true&tlsCAFile=./ca.pem, ca.pem 을 옆에 둘 것)
//
// 검증 항목: ping → hello(레플리카셋·primary) → 인증유저 → insert/read/delete 권한 → 뷰.
// ※ ESM 문법(import + top-level await)이라 .mjs (CommonJS 프로젝트에서도 그대로 실행).
import 'dotenv/config';
import { MongoClient } from 'mongodb';

const url = process.env.MONGO_DATABASE_URL;
if (!url) {
  console.error('MONGO_DATABASE_URL is not set in .env');
  process.exit(1);
}
// DB 이름: MONGO_NAME env > 연결 URL 의 경로 > 'test'
// ★ new URL() 은 다중 호스트 레플리카셋 URL(mongo1:27017,mongo2:27017)을 파싱 못 하고 throw 하므로
//   쓰지 않고 직접 추출한다: 스킴/creds 뒤 호스트목록의 첫 '/' ~ '?' 사이가 DB. +srv·콤마 호스트 모두 처리.
const dbFromUrl = (u) => {
  const m = u.match(/^mongodb(?:\+srv)?:\/\/(?:[^@/]*@)?[^/]+\/([^?]*)/i);
  return m && m[1] ? decodeURIComponent(m[1]) : null;
};
const dbName = process.env.MONGO_NAME || dbFromUrl(url) || 'test';

const mask = (u) => u.replace(/:[^@/]+@/, ':***@');
console.log('Connecting to:', mask(url), '| db:', dbName);

const client = new MongoClient(url, { serverSelectionTimeoutMS: 8000 });

try {
  await client.connect();
  const admin = client.db().admin();

  // 1) ping
  const pong = await admin.command({ ping: 1 });
  console.log('✅ PING ok:', pong.ok === 1);

  // 2) hello (레플리카셋인지·primary 확인)
  const hello = await admin.command({ hello: 1 });
  console.log('✅ hello → setName:', hello.setName, '| writablePrimary:', hello.isWritablePrimary);
  console.log('   hosts:', hello.hosts);

  // 3) 인증된 유저 확인
  const conn = await client.db(dbName).command({ connectionStatus: 1 });
  console.log('✅ authenticatedUsers:', JSON.stringify(conn.authInfo.authenticatedUsers));

  // 4) read/write 권한 검증 — 임시 컬렉션 insert/read/delete
  const db = client.db(dbName);
  const coll = db.collection('__conn_test__');
  const ins = await coll.insertOne({ source: 'mongodb-package conn-check', ts: new Date(), ok: true });
  console.log('✅ INSERT ok, _id:', ins.insertedId);
  console.log('✅ READ-BACK:', await coll.findOne({ _id: ins.insertedId }));
  const del = await coll.deleteOne({ _id: ins.insertedId });
  console.log('✅ DELETE ok, deletedCount:', del.deletedCount);

  // 5) 뷰 존재 확인 (있으면 나열, 없으면 빈 배열)
  const views = await db.listCollections({ type: 'view' }).toArray();
  console.log('✅ Views in', dbName + ':', views.map((c) => c.name));

  console.log('\n🎉 ALL CHECKS PASSED');
} catch (e) {
  console.error('❌ FAILED:', e.message);
  if (e.cause) console.error('   cause:', e.cause.message || e.cause);
  process.exit(1);
} finally {
  await client.close();
}
