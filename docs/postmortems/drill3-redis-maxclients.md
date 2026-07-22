# Redis maxclients 초과 — 성능 저하가 아니라 기동 불능이었다 포스트모템

> 일시: 2026-07-22 01:50~01:56 (UTC) · 훈련 번호: 3 (roadmap 8장) · 장애는 의도적으로 주입됨

## 요약

Redis `maxclients`를 8로 낮춘 상태에서 Redisson 전략 앱을 기동하자, 예상했던 "부하 시 간헐적 락 실패"가 아니라 **애플리케이션이 아예 기동하지 못했다**. Redisson이 부트스트랩에서 커넥션 풀(기본 24+)을 미리 채우려다 `ERR max number of clients reached`로 실패하고 컨텍스트가 중단된 것. 클라이언트 풀 설정과 서버 한도의 관계는 런타임이 아니라 **기동 시점**에 먼저 충돌한다.

## 타임라인 (UTC)

| 시각 | 사건 |
|---|---|
| 01:50:49 | 주입: `CONFIG SET maxclients 8` 후 redisson 전략으로 앱 재기동 시도 |
| 01:50~01:55 | 증상: 헬스체크 응답 없음(기동 실패), 부하 100% connection refused |
| 01:55:29 | 증거: `rejected_connections` 0→**4**, `connected_clients=1`, 앱 로그 `max number of clients` 에러 2건 |
| 01:55:29 | 복구 1: `CONFIG SET maxclients 10000` (런타임 복원 — Redis 재시작 불필요) |
| 01:56~ | 복구 2: 앱 재기동 → **3,001/3,001 정상 처리, 중앙값 10ms** (죽은 JVM은 한도 복원으로 살아나지 않는다 — 재기동 필요) |

## 영향 범위

기동 불능 = 해당 인스턴스의 가용성 0%. 다중 인스턴스 환경이었다면 롤링 배포 중 새 인스턴스만 연쇄 실패하는 형태로 나타났을 것.

## 근본 원인

- 서버 한도(maxclients 8) < 클라이언트 요구량: Redisson 기본 커넥션 풀(connectionPoolSize 64, minIdle 24) + Lettuce 상시 연결 + 워커. Redisson은 기동 시 minIdle만큼 선연결을 시도하고, 실패 시 fail-fast로 컨텍스트를 중단시킨다.
- 증거: Redis `INFO stats`의 `rejected_connections` 카운터 증가분 4, 앱 로그의 `ERR max number of clients reached`.
- 교훈적 포인트: **클라이언트 풀 총합(모든 인스턴스 × 풀 크기 + 사이드카/워커)이 서버 maxclients의 실질 예산**이다. 인스턴스를 늘릴수록 예산은 빠르게 소진된다.

## 재발 방지

| 조치 | 종류 | 상태 |
|---|---|---|
| 인스턴스 수 × (redisson pool + lettuce + 워커) 합계를 maxclients의 70% 이하로 용량 계획 | 설정/문서 | 본 문서 (Phase 5 배포 스펙에 반영) |
| `rejected_connections` 증가 알림 (증가율 > 0) | 알림 | Phase 5 Prometheus rule (redis exporter 필요) |
| 복구 런북: 한도 복원(`CONFIG SET`, 무중단) 후 실패 인스턴스 재기동까지가 한 세트 | 문서 | 본 문서 |

## 배운 점

- 커넥션 한도 장애는 "느려짐"이 아니라 fail-fast 클라이언트에서는 **기동 불능**으로 나타난다 — 배포 직후에만 터지는 미스터리 장애의 유력 용의자.
- `rejected_connections`는 누적 카운터라 순간 관측이 아닌 증가분으로 봐야 한다.
- 서버 쪽 복구(CONFIG SET)는 즉시지만, 이미 죽은 클라이언트 프로세스는 재기동해야 한다 — 복구는 두 단계다.
