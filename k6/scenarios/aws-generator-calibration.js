import http from 'k6/http';
import {
  claimThresholds,
  createClaimMetrics,
  jsonSummary,
  readClaimConfig,
  readRunId,
  readSummaryPath,
  recordCalibrationResponse,
} from '../lib/aws-claim.js';
import { BASE_URL } from '../lib/config.js';

http.setResponseCallback(http.expectedStatuses(204));

const config = readClaimConfig(false, true);
const RUN_ID = readRunId();
const SUMMARY_PATH = readSummaryPath();
const metrics = createClaimMetrics();

export const options = {
  scenarios: {
    generator_calibration: {
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
  const response = http.get(`${BASE_URL}/loadgen-calibration`, {
    tags: { name: 'loadgen_calibration', run_id: RUN_ID },
  });

  recordCalibrationResponse(response, metrics);
}

export function handleSummary(data) {
  return jsonSummary(SUMMARY_PATH, data);
}
