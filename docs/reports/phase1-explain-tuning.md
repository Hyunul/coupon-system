# 발급 이력 조회 explain 튜닝 — 풀스캔 51만 행 → 인덱스 룩업

> 날짜: 2026-07-21 · Phase: 1 · 커밋: `c508174` (V3 마이그레이션 포함)

## 1. 가설

인덱스 없는 `coupon_issue`(51만 행)에서 `GET /api/v1/users/{userId}/issues`는 풀스캔+filesort로 동작하며, `(user_id, issued_at)` 인덱스로 range 접근 + 정렬 제거가 가능할 것이다.

## 2. 환경

baseline과 동일 머신. 데이터: **510,000행** — 부하테스트 산출 1만 행 + `scripts/bulk-history-data.sql`로 합성한 50만 행(이벤트 101~105 × 10만 명). *읽기 경로 인덱스 실험 목적의 합성 데이터임을 명시함 — 발급 상한(이벤트당 1만) 때문에 부하테스트만으로는 이 규모를 만들 수 없다.* 부하: `read-history.js` constant-arrival-rate 300rps × 2분, 사용자 1~30,000 랜덤.

## 3. Before — 풀스캔

```
type=ALL, rows=509,679, Extra: Using where; Using filesort
EXPLAIN ANALYZE: Table scan (actual 94.8ms) → Filter → Sort  ... actual time=110ms
```

| 지표 | 값 |
|---|---|
| 달성 처리량 | **43.4rps** (목표 300rps, dropped 28,782) |
| 응답 중앙값 / p95 | **43.7s / 48.7s** (대기열 붕괴) |
| VU | 2,000개 전부 소진 |

단건 110ms짜리 풀스캔이 300rps로 들어오면 DB CPU가 즉시 포화되고, 이후는 순수 대기열 게임이다.

## 4. 인덱스 설계 판단

`V3__add_index_coupon_issue_user.sql`:

```sql
CREATE INDEX idx_issue_user_issued_at ON coupon_issue (user_id, issued_at);
```

- `user_id` 등치 조건 + `issued_at DESC` 정렬 → 복합 인덱스로 range 접근과 filesort 제거를 동시에 해결 (MySQL 8 Backward index scan).
- **완전 커버링은 의도적으로 보류**: JPA 엔티티 조회가 `notify_status` 포함 전 컬럼을 SELECT하므로 커버링하려면 인덱스에 전 컬럼이 들어가야 한다. 사용자당 행 수가 적어(≤10) PK 룩업 비용이 미미하므로, 인덱스 비대화보다 현 설계가 낫다고 판단. (커버링이 꼭 필요해지면 DTO 프로젝션으로 SELECT 컬럼을 줄이는 것이 먼저다.)

## 5. After

```
type=ref, key=idx_issue_user_issued_at, rows=5, Extra: Backward index scan
EXPLAIN ANALYZE: Index lookup (reverse) ... actual time=0.04ms  (cost 50,992 → 1.75)
```

| 지표 | Before | After | 변화 |
|---|---|---|---|
| 단건 쿼리 실측 | 110ms | **0.04ms** | ~2,750× |
| 달성 처리량 | 43.4rps | **300rps (36,000/36,000)** | 목표 완전 소화 |
| 응답 중앙값 | 43.7s | **5.73ms** | ~7,600× |
| 응답 p95 | 48.7s | **14.17ms** | |
| 실패율 | (드랍 28,782) | **0%** | |
| 필요 VU | 2,000 소진 | **16** | |

## 6. 다음 액션

- 쓰기 경로 영향(인덱스 유지 비용)은 Phase 2 재측정에서 함께 관찰.
- 변경 쿼리 자동 실행계획 검사(`/explain-check` skill)는 Phase 6 하네스 항목으로.
