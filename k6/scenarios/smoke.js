// 기능 회귀 확인용 스모크: 발급 → 이력 조회 → 잔여 수량 조회
// 사전 조건: scripts/seed-event.sql 로 event_id=1 이 OPEN 상태여야 함
import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { BASE_URL, EVENT_ID, USER_OFFSET } from '../lib/config.js';

export const options = {
  vus: 1,
  duration: '30s',
  thresholds: {
    checks: ['rate>0.99'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  // smoke는 900만 번대 userId를 사용해 부하테스트 대역(iterationInTest 기반)과 겹치지 않게 한다
  const userId = 9000000 + USER_OFFSET + exec.scenario.iterationInTest;

  const issueRes = http.post(`${BASE_URL}/api/v1/events/${EVENT_ID}/issues`, null, {
    headers: { 'X-USER-ID': `${userId}` },
    tags: { name: 'issue' },
  });
  check(issueRes, { 'issue 201': (r) => r.status === 201 });

  const historyRes = http.get(`${BASE_URL}/api/v1/users/${userId}/issues`, {
    tags: { name: 'history' },
  });
  check(historyRes, {
    'history 200': (r) => r.status === 200,
    'history has 1': (r) => r.json('totalElements') === 1,
  });

  const remainingRes = http.get(`${BASE_URL}/api/v1/events/${EVENT_ID}/remaining`, {
    tags: { name: 'remaining' },
  });
  check(remainingRes, { 'remaining 200': (r) => r.status === 200 });
}
