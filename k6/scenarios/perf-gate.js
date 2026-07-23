// CI 성능 회귀 게이트 (roadmap Phase 5): threshold 위반 시 k6가 비정상 종료 → 워크플로 실패
// 공유 러너(2 vCPU)의 분산을 감안해 보수적 임계값 사용 — 회귀의 "감지"가 목적이지 벤치마크가 아니다
import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { BASE_URL, EVENT_ID } from '../lib/config.js';

const RATE = parseInt(__ENV.RATE || '100', 10);

export const options = {
  scenarios: {
    gate: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: '60s',
      preAllocatedVUs: 100,
      maxVUs: 500,
    },
  },
  thresholds: {
    http_req_duration: [{ threshold: 'p(95)<500', abortOnFail: true, delayAbortEval: '15s' }],
    http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true, delayAbortEval: '15s' }],
    checks: ['rate>0.99'],
  },
};

export default function () {
  const userId = 1 + exec.scenario.iterationInTest;
  const res = http.post(`${BASE_URL}/api/v1/events/${EVENT_ID}/issues`, null, {
    headers: { 'X-USER-ID': `${userId}` },
  });
  check(res, { 'issued or sold out': (r) => r.status === 201 || r.status === 409 });
}
