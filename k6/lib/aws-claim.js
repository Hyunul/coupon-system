import { Counter, Rate, Trend } from 'k6/metrics';

const DURATION_UNITS_MS = { ms: 1, s: 1000, m: 60000, h: 3600000 };

function requiredEnvironmentValue(name) {
  const value = __ENV[name];
  if (value === undefined || value === '') {
    throw new Error(`${name} must be provided explicitly`);
  }
  return value;
}

export function parsePositiveInteger(name, value) {
  const text = String(value);
  if (!/^[1-9]\d*$/.test(text)) {
    throw new Error(`${name} must be a positive integer`);
  }

  const parsed = Number(text);
  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`${name} must be a safe positive integer`);
  }
  return parsed;
}

export function parseDuration(value) {
  const match = /^([1-9]\d*)(ms|s|m|h)$/.exec(String(value));
  if (!match) {
    throw new Error('DURATION must be a positive integer followed by ms, s, m, or h');
  }

  const amount = parsePositiveInteger('DURATION', match[1]);
  const milliseconds = amount * DURATION_UNITS_MS[match[2]];
  if (!Number.isSafeInteger(milliseconds)) {
    throw new Error('DURATION is too large to calculate an achieved-iteration claim');
  }
  return { text: String(value), milliseconds };
}

export function readSummaryPath() {
  const path = String(requiredEnvironmentValue('SUMMARY_PATH'));
  if (
    path !== path.trim() ||
    /[\u0000-\u001F\u007F\\]/.test(path) ||
    path.split('/').some((segment) => segment === '.' || segment === '..')
  ) {
    throw new Error('SUMMARY_PATH must be a non-blank safe path');
  }
  if (path.split('/').pop() !== 'k6-summary.json') {
    throw new Error('SUMMARY_PATH basename must be k6-summary.json');
  }
  return path;
}

export function readClaimConfig(allowSoldOut, allowCalibration = false) {
  const rate = parsePositiveInteger('RATE', requiredEnvironmentValue('RATE'));
  const duration = parseDuration(requiredEnvironmentValue('DURATION'));
  const preAllocatedVUs = parsePositiveInteger(
    'PRE_ALLOCATED_VUS',
    requiredEnvironmentValue('PRE_ALLOCATED_VUS'),
  );
  const maxVUs = parsePositiveInteger('MAX_VUS', requiredEnvironmentValue('MAX_VUS'));
  if (maxVUs < preAllocatedVUs) {
    throw new Error('MAX_VUS must be greater than or equal to PRE_ALLOCATED_VUS');
  }

  if (String(requiredEnvironmentValue('CLAIM_MODE')).toLowerCase() !== 'true') {
    throw new Error('CLAIM_MODE must be true for AWS evidence scenarios');
  }

  const resultPolicy = String(requiredEnvironmentValue('RESULT_POLICY')).toLowerCase();
  const supportedPolicy =
    resultPolicy === 'normal' ||
    (resultPolicy === 'sold-out' && allowSoldOut) ||
    (resultPolicy === 'calibration' && allowCalibration);
  if (!supportedPolicy) {
    throw new Error('RESULT_POLICY is incompatible with this scenario');
  }

  const expectedNumerator = rate * duration.milliseconds;
  if (!Number.isSafeInteger(expectedNumerator) || expectedNumerator <= 0) {
    throw new Error('CLAIM_MODE requires a finite expected-iteration denominator');
  }
  const expectedIterations =
    Math.floor(expectedNumerator / 1000) + (expectedNumerator % 1000 === 0 ? 0 : 1);
  const minimumIterations = expectedIterations - Math.floor(expectedIterations / 1000);

  const config = {
    rate,
    duration: duration.text,
    preAllocatedVUs,
    maxVUs,
    resultPolicy,
    expectedIterations,
    minimumIterations,
  };
  return config;
}

export function readRunId() {
  const runId = String(requiredEnvironmentValue('RUN_ID'));
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(runId)) {
    throw new Error(
      'RUN_ID must be 1-128 characters starting with an alphanumeric character and containing only alphanumerics, hyphens, or underscores',
    );
  }
  return runId;
}

export function createClaimMetrics() {
  return {
    issued: new Counter('coupon_issued'),
    soldOut: new Counter('coupon_sold_out'),
    duplicate: new Counter('coupon_duplicate'),
    serverFailure: new Counter('coupon_server_failure'),
    unexpected: new Rate('coupon_unexpected'),
    transportFailure: new Rate('coupon_transport_failure'),
    requestFailure: new Rate('coupon_request_failure'),
    decisionLatency: new Trend('coupon_decision_duration', true),
  };
}

export function claimThresholds(config) {
  if (
    !Number.isSafeInteger(config.expectedIterations) ||
    config.expectedIterations <= 0 ||
    !Number.isSafeInteger(config.minimumIterations) ||
    config.minimumIterations <= 0
  ) {
    throw new Error('CLAIM_MODE requires finite integer iteration thresholds');
  }

  const thresholds = {
    dropped_iterations: ['count==0'],
    iterations: [`count>=${config.minimumIterations}`],
    coupon_unexpected: ['rate<=0.001'],
    coupon_transport_failure: ['rate<=0.001'],
    coupon_request_failure: ['rate<=0.001'],
  };

  switch (config.resultPolicy) {
    case 'normal':
      thresholds.coupon_decision_duration = ['p(99)<200'];
      thresholds.coupon_sold_out = ['count==0'];
      thresholds.coupon_duplicate = ['count==0'];
      return thresholds;
    case 'sold-out':
      thresholds.coupon_decision_duration = ['p(99)<200'];
      thresholds.coupon_duplicate = ['count==0'];
      return thresholds;
    case 'calibration':
      return thresholds;
    default:
      throw new Error('RESULT_POLICY is incompatible with claim thresholds');
  }
}

function responseCode(response) {
  try {
    return response.json('code');
  } catch (_) {
    return undefined;
  }
}

function recordFailureMetrics(metrics, transport, unexpected) {
  metrics.transportFailure.add(transport ? 1 : 0);
  metrics.unexpected.add(unexpected ? 1 : 0);
  metrics.requestFailure.add(transport || unexpected ? 1 : 0);
}

export function recordIssueResponse(response, metrics) {
  metrics.decisionLatency.add(response.timings.duration);
  if (response.status === 0) {
    recordFailureMetrics(metrics, true, false);
    return;
  }

  if (response.status === 201) {
    metrics.issued.add(1);
    recordFailureMetrics(metrics, false, false);
    return;
  }

  if (response.status === 409) {
    const code = responseCode(response);
    if (code === 'SOLD_OUT') {
      metrics.soldOut.add(1);
      recordFailureMetrics(metrics, false, false);
      return;
    }
    if (code === 'DUPLICATE_ISSUE') {
      metrics.duplicate.add(1);
      recordFailureMetrics(metrics, false, false);
      return;
    }
  }

  if (response.status >= 500) metrics.serverFailure.add(1);
  recordFailureMetrics(metrics, false, true);
}

export function recordCalibrationResponse(response, metrics) {
  metrics.decisionLatency.add(response.timings.duration);
  if (response.status === 0) {
    recordFailureMetrics(metrics, true, false);
    return;
  }
  recordFailureMetrics(metrics, false, response.status !== 204);
}

export function jsonSummary(path, data) {
  return { [path]: JSON.stringify(data, null, 2) };
}
