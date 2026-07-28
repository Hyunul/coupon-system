# 발급 이벤트 파이프라인: Redis Stream vs Kafka 실측 비교

> 날짜: 2026-07-28 · 실행: `--coupon.record.mode=stream|kafka` (동일 커밋, 판정은 양쪽 모두 Redis Lua) · 증거: `k6-results/kafka-cmp-evidence.txt`

## 1. 가설

발급 이벤트의 전송 계층을 Redis Stream에서 Kafka로 바꿔도 **동일한 의미론(at-least-once + 멱등 소비)을 유지**할 수 있고, 로컬 단일 노드 규모에서는 성능 차이가 크지 않을 것이다. 차이는 성능이 아니라 **원자성 경계와 운영 특성**에서 날 것이다.

## 2. 환경

| 항목 | 값 |
|---|---|
| 공통 | 판정: Redis Lua(원자) · 소비: worker 프로파일, 동일 `IssueRecordWriter`(배치 saveAll+멱등 폴백) · 부하: 500rps×30s → 백로그 15k 적재 후 워커 기동, 드레인 시간 측정 |
| stream | Lua 스크립트 안에서 XADD (판정+발행 원자) · XREADGROUP(count 100, block 2s) · 기록 후 XACK |
| kafka | apache/kafka 3.8.1 KRaft 단일 노드(파티션 1) · 판정 후 `KafkaTemplate.send`(acks=all) · 배치 리스너 + 기록 후 manual commit · `auto.offset.reset=earliest` |

## 3. 결과

| 지표 | Redis Stream | Kafka |
|---|---|---|
| 발급 API med / p95 (500rps) | 1.6ms / 3.0ms | 1.6ms / 4.0ms |
| 백로그 15k 드레인 | 15s (**1,000건/s**) | 17s (**882건/s**) |
| 정합성 (DB=Redis / 중복) | 15,000=15,000 / 0 | 15,001=15,001 / 0 |
| 신규 그룹의 백로그 소비 | `ReadOffset.from("0")` 필요 (latest면 유실 — 실제 버그로 겪음) | `auto.offset.reset=earliest` 필요 (기본 latest면 동일 사고) |

**성능은 사실상 동급**이다 (드레인 차이는 DB 쓰기 병목이 지배하는 구간이라 전송 계층 차이가 아님). 예상대로 차이는 다른 곳에 있었다.

## 4. 개념 매핑 — 같은 문제의 두 이름

| 개념 | Redis Stream | Kafka |
|---|---|---|
| 발행 | XADD | produce (acks) |
| 그룹 소비 | XREADGROUP + consumer group | poll + consumer group |
| 처리 확인 | XACK | offset commit |
| 미확인 메시지 복구 | XPENDING + XCLAIM (60s idle 회수 구현) | 리밸런싱이 자동 재할당 (커밋 안 된 오프셋부터) |
| 신규 그룹 시작점 | XGROUP CREATE `$` vs `0` | auto.offset.reset `latest` vs `earliest` |
| 밀린 정도 | XLEN − 소비 위치 | consumer lag |

**신규 그룹 시작점 함정의 대칭성**이 이번 실험의 백미다: Stream에서 `latest($)` 그룹 생성으로 백로그를 통째로 유실한 버그(Phase 5 리허설)와 Kafka의 `auto.offset.reset=latest` 기본값은 정확히 같은 사고를 낸다. 이번엔 처음부터 `earliest`로 설정해 15,001건 백로그가 전부 소비됨을 확인했다.

## 5. 진짜 차이 ① — 원자성 경계

- **Stream**: 판정과 발행이 **하나의 Lua 스크립트**다. 판정이 성공하면 발행도 반드시 존재한다 — 유실 창이 없다.
- **Kafka**: 판정(Redis)과 발행(Kafka send)이 **서로 다른 시스템**이라 원자가 아니다. 판정 성공 직후 브로커 미가용/프로세스 사망 시 "발급됐지만 기록 이벤트가 없는" 유실 창이 생긴다. 정석 해법은 Transactional Outbox(로컬 DB에 이벤트를 같은 트랜잭션으로 쓰고 릴레이) — 그러나 우리 임계 경로는 DB를 이미 제거했으므로 outbox는 그 이점을 되돌린다.

즉 이 아키텍처(판정의 진실이 Redis)에서는 **Stream이 구조적으로 유리**하다.

## 6. 진짜 차이 ② — 내구성·확장·생태계

- 내구성: 우리 Redis는 `appendonly no` — 재시작 시 스트림 유실 가능(성능 실험용 설정). Kafka는 디스크 보존+보존 기간이 기본값. 내구성 요구가 오르면 Redis도 AOF/replica가 필요해져 운영 비용이 수렴한다.
- 확장: Stream 소비자 확장은 수동적(컨슈머 추가), Kafka는 파티션 단위 병렬성과 리밸런싱이 내장. 소비자 그룹이 여럿(정산·통계·CRM 등)이 되는 순간 Kafka의 보존+리플레이+다중 그룹이 결정적이 된다.
- 운영: 단일 Redis는 이미 있고(재고 판정용) 추가 인프라 0. Kafka는 브로커 운영 부담이 별도.

## 7. 판단

| 상황 | 선택 |
|---|---|
| 지금 규모 (소비자 1종, Redis가 판정의 진실, 유실 창 최소화 우선) | **Redis Stream 유지** |
| 소비자 그룹 다수·이벤트 리플레이·장기 보존·타 시스템 연계(Connect) | Kafka 전환 — 단 outbox로 판정-발행 원자성 보강 필수 |

한계: 단일 브로커·파티션 1·단일 머신 — 파티션 병렬성과 리밸런싱 거동은 이 실험 범위 밖 (실배포 백로그).

## 8. 다음 액션

- (선택) 파티션 4 + 워커 2대에서 리밸런싱·순서 보장(키=userId) 관찰 — 로컬 가능
- 실배포 시 관리형(MSK) vs 자체 운영 비용 비교
