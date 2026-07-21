export const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
export const EVENT_ID = __ENV.EVENT_ID || '1';
// 여러 런에서 userId 충돌을 피하고 싶을 때 오프셋 지정: -e USER_OFFSET=100000
export const USER_OFFSET = parseInt(__ENV.USER_OFFSET || '0', 10);
