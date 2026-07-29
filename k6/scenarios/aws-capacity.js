import http from 'k6/http';
import exec from 'k6/execution';
import { BASE_URL, EVENT_ID, USER_OFFSET } from '../lib/config.js';
import {
  claimThresholds,
  createClaimMetrics,
  jsonSummary,
  readClaimConfig,
  readRunId,
  readSummaryPath,
  recordIssueResponse,
} from '../lib/aws-claim.js';

http.setResponseCallback(http.expectedStatuses(201, 409));

const config = readClaimConfig(true);
const RUN_ID = readRunId();
const SUMMARY_PATH = readSummaryPath();
const metrics = createClaimMetrics();

export const options = {
  scenarios: {
    capacity: {
      executor: 'constant-arrival-rate',
      rate: config.rate,
      timeUnit: '1s',
      duration: config.duration,
      preAllocatedVUs: config.preAllocatedVUs,
      maxVUs: config.maxVUs,
    },
  },
  thresholds: claimThresholds(config),
};

export default function () {
  const userId = 1 + USER_OFFSET + exec.scenario.iterationInTest;
  const response = http.post(`${BASE_URL}/api/v1/events/${EVENT_ID}/issues`, null, {
    headers: { 'X-USER-ID': String(userId), 'X-RUN-ID': RUN_ID },
    tags: { name: 'coupon_issue', run_id: RUN_ID },
  });

  recordIssueResponse(response, metrics);
}

export function handleSummary(data) {
  return jsonSummary(SUMMARY_PATH, data);
}