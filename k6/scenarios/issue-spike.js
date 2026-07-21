// 오픈 순간 폭주 재현 (roadmap 6.1): 평시 → 10초 만에 5,000rps → 유지 → 회복 관찰
// 재고 10,000 이벤트에 30,000+ 유니크 사용자를 밀어 넣고, 종료 후 정합성 검증까지가 한 세트
// (scripts/run-loadtest.ps1 이 reset → k6 → verify 를 일괄 실행)
import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { BASE_URL, EVENT_ID, USER_OFFSET } from '../lib/config.js';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-arrival-rate',
      startRate: 100,
      timeUnit: '1s',
      preAllocatedVUs: 2000,
      maxVUs: 10000,
      stages: [
        { target: 100, duration: '30s' }, // 평시
        { target: 5000, duration: '10s' }, // 오픈 폭주
        { target: 5000, duration: '2m' }, // 유지
        { target: 100, duration: '1m' }, // 회복 관찰
      ],
    },
  },
  // 기록용 threshold — Phase 1 baseline에서 깨지는 것이 정상이며 그 수치가 스토리의 출발점
  thresholds: {
    http_req_duration: ['p(99)<200'],
    http_req_failed: ['rate<0.001'],
  },
};

export default function () {
  const userId = 1 + USER_OFFSET + exec.scenario.iterationInTest;

  const res = http.post(`${BASE_URL}/api/v1/events/${EVENT_ID}/issues`, null, {
    headers: { 'X-USER-ID': `${userId}` },
    tags: { name: 'issue' },
  });
  check(res, { 'issued or sold out': (r) => r.status === 201 || r.status === 409 });
}
