// 기능 회귀 확인용 스모크: 발급 → 이력 조회(최종적 일관성: 5초 내 반영) → 잔여 수량 조회
// 사전 조건: seed 후 PATCH OPEN (stream 모드는 워커 프로세스 필요 — run-loadtest.ps1/start-local-ha.ps1 참조)
import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
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

  // stream 모드는 이력 기록이 비동기(워커 소비) — "5초 내 반영"을 검증한다 (최종적 일관성 SLA)
  let historyRes;
  let recorded = false;
  for (let i = 0; i < 5; i++) {
    historyRes = http.get(`${BASE_URL}/api/v1/users/${userId}/issues`, {
      tags: { name: 'history' },
    });
    if (historyRes.status === 200 && historyRes.json('totalElements') === 1) {
      recorded = true;
      break;
    }
    sleep(1);
  }
  check(historyRes, {
    'history 200': (r) => r.status === 200,
    'history recorded within 5s': () => recorded,
  });

  const remainingRes = http.get(`${BASE_URL}/api/v1/events/${EVENT_ID}/remaining`, {
    tags: { name: 'remaining' },
  });
  check(remainingRes, { 'remaining 200': (r) => r.status === 200 });
}
