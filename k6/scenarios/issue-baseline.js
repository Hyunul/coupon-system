// HikariCP/처리량 실험의 주력 시나리오: open model 고정 도착률
// 사용법: k6 run -e RATE=500 -e DURATION=3m k6/scenarios/issue-baseline.js
import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { BASE_URL, EVENT_ID, USER_OFFSET } from '../lib/config.js';

const RATE = parseInt(__ENV.RATE || '200', 10);
const DURATION = __ENV.DURATION || '3m';

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 500,
      maxVUs: 3000,
    },
  },
  // 기록용 threshold — Phase 1 baseline에서는 깨지는 것이 정상 (abortOnFail 금지)
  thresholds: {
    http_req_duration: ['p(99)<200'],
  },
};

export default function () {
  // iterationInTest는 테스트 전체에서 유일 → 유니크 사용자 보장 (시드 불필요)
  const userId = 1 + USER_OFFSET + exec.scenario.iterationInTest;

  const res = http.post(`${BASE_URL}/api/v1/events/${EVENT_ID}/issues`, null, {
    headers: { 'X-USER-ID': `${userId}` },
    tags: { name: 'issue' },
  });
  // 정상 응답 집합: 201(발급) / 409(SOLD_OUT · 재고 소진 후) — 그 외는 실패
  check(res, { 'issued or sold out': (r) => r.status === 201 || r.status === 409 });
}
