// 발급 이력 조회 부하: explain 튜닝(V3 인덱스) 전/후 비교의 측정 도구
// 사전 조건: coupon_issue 에 데이터가 누적되어 있어야 의미 있음 (부하테스트 데이터를 리셋하지 않고 누적)
// 사용법: k6 run -e RATE=300 -e MAX_USER=30000 k6/scenarios/read-history.js
import http from 'k6/http';
import { check } from 'k6';
import { BASE_URL } from '../lib/config.js';

const RATE = parseInt(__ENV.RATE || '300', 10);
const DURATION = __ENV.DURATION || '2m';
const MAX_USER = parseInt(__ENV.MAX_USER || '30000', 10);

export const options = {
  scenarios: {
    read: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 300,
      maxVUs: 2000,
    },
  },
  thresholds: {
    http_req_duration: ['p(99)<200'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const userId = 1 + Math.floor(Math.random() * MAX_USER);
  const res = http.get(`${BASE_URL}/api/v1/users/${userId}/issues?page=0&size=20`, {
    tags: { name: 'history' },
  });
  check(res, { 'history 200': (r) => r.status === 200 });
}
