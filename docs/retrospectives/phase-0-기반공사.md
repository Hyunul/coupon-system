# Phase 0 회고 — 기반 공사: 측정이 가능한 놀이터 만들기

> 2026-07-21 · 커밋 범위: ~`9d16f71` · Phase 0 (+ Phase 1 기능 구현 일부 포함)

## 1. 배경과 목표

이 프로젝트의 목표는 "만들었다"가 아니라 **"측정 → 병목 발견 → 개선 → 재측정" 사이클을 수치로 기록하는 것**입니다([로드맵](../coupon-system-roadmap.md) 5장). Phase 0의 목표는 그 사이클이 돌아갈 수 있는 기반 — 인프라(docker-compose), CI, 부하 도구(k6), 관측(Prometheus/Grafana), 그리고 AI 하네스(CLAUDE.md) — 을 1주 안에 세우는 것이었습니다.

결과적으로 이번 사이클에서는 Phase 0 전체와 Phase 1의 기능 파트(비관적 락 발급 API)까지 함께 구현되었습니다. 측정 실험(baseline, HikariCP, explain)은 다음 사이클입니다.

## 2. 문제 상황

### 2.1 발급 API가 전부 NOT_OPEN으로 거절됨 — 9시간의 미스터리

기능 구현을 끝내고 E2E 검증을 돌리자 모든 발급 요청이 `400 NOT_OPEN`으로 거절됐습니다. 시드 데이터는 분명 1시간 전에 오픈한 이벤트인데도요.

DB와 앱이 보는 값을 나란히 놓자 원인이 보였습니다:

```
DB(UTC):  open_at = 2026-07-21 06:05:16   ← UTC_TIMESTAMP - 1h, 정상
앱 응답:  openAt  = 2026-07-21T15:05:16   ← +9시간 밀림 (KST)
앱의 now: 07:05 (UTC) → "아직 오픈 전"으로 오판
```

`connectionTimeZone=UTC`와 `hibernate.jdbc.time_zone=UTC`를 다 설정했는데도 벌어진 일입니다. Hibernate는 UTC 캘린더로 JDBC 값을 읽은 뒤, **`LocalDateTime`으로 바꾸는 마지막 단계에서 JVM 기본 시간대(Asia/Seoul)를 사용**합니다. 저장 경로(SQL 시드, UTC)와 읽기 경로(JVM, KST)가 서로 다른 시간대를 쓴 것이 근본 원인이었습니다.

흥미로운 점: Testcontainers 통합 테스트는 이 버그를 잡지 못했습니다. 테스트는 쓰기와 읽기가 같은 JVM을 통과해 왜곡이 상쇄(round-trip 일관)되기 때문입니다. **"테스트가 통과해도 데이터 경로가 다르면 깨질 수 있다"**는 것을 첫날부터 확인했습니다.

### 2.2 죽지 않는 8080 — 유령 프로세스

시간대 수정 후 앱을 재시작했는데 수정 전 응답이 계속 나왔습니다. `gradlew bootRun`을 중단해도 Gradle이 fork한 자식 JVM은 살아남아 8080 포트를 계속 점유하고 있었던 것입니다. `netstat -ano`로 PID를 찾아 종료하고 나서야 새 코드가 반영됐습니다. Windows에서 bootRun을 백그라운드로 돌릴 때의 운영 함정으로 기록해 둡니다.

## 3. 해결 과정

### 3.1 시간대: "설정 두 개로는 부족하다"

| 선택지 | 장점 | 단점 | 채택 |
|---|---|---|---|
| JDBC/Hibernate 설정만 (`connectionTimeZone`, `jdbc.time_zone`) | 코드 무변경 | LocalDateTime 변환의 JVM 기본 시간대 의존이 남음 — 실제로 뚫림 | ✗ |
| DB를 KST로 통일 | 사람이 읽기 편함 | 서버 다중화·리전 이동 시 취약, UTC_TIMESTAMP 기반 시드와 충돌 | ✗ |
| **JVM 기본 시간대를 UTC로 고정** (`TimeZone.setDefault(UTC)` + 테스트 `user.timezone=UTC`) | 전 구간(UTC DB·JVM·시드)이 단일 시간대, 환경 무관 재현성 | 로그 시각도 UTC (감수) | **✓** |

### 3.2 mock 알림 서버: 무엇으로 만들 것인가

Phase 3~4의 장애 주입 실험 도구가 될 서버라 인터페이스(지연·에러율 주입)를 지금 확정해야 했습니다.

| 선택지 | 장점 | 단점 | 채택 |
|---|---|---|---|
| WireMock | 표준적, 기능 풍부 | 쿼리 파라미터 기반 동적 지연은 확장 코드가 필요 — 배보다 배꼽 | ✗ |
| 별도 Spring Boot 앱 | 익숙함 | 무겁고, 단일 모듈 결정과 충돌, "외부 시스템" 경계가 흐려짐 | ✗ |
| **의존성 0개 Node 단일 파일** (~60줄) | `?delay=3000&errorRate=0.3`을 30줄로 구현, 이미지 소형, 경계 명확 | JS/Java 혼재 | **✓** |

### 3.3 그 외 기반 결정 (요약)

- **앱은 호스트 실행, 인프라만 컨테이너**: 반복 실험 속도(재시작 10초) 우선. Prometheus만 `host.docker.internal:8080`으로 스크레이프.
- **MySQL은 named volume**: Windows bind mount는 I/O가 극단적으로 느려 측정을 왜곡하므로 배제.
- **Flyway 채택** (vs `schema.sql`): "인덱스를 나중에 추가"하는 이 프로젝트의 서사에서 `V3__add_index...` 마이그레이션 파일 자체가 explain 튜닝의 증빙물이 됨.
- **발급 로직을 `IssueStrategy` 인터페이스로 분리**: Phase 2의 3전략(비관적 락/Redisson/Lua) 비교를 구현체 추가만으로 가능하게.

## 4. 결과

| 항목 | 결과 |
|---|---|
| docker-compose 5개 서비스 (MySQL/Redis/Prometheus/Grafana/mock-notify) | 전부 기동, healthcheck 통과 |
| mock-notify 지연 주입 `?delay=1000` | 1,233ms 후 응답 (연결 오버헤드 포함) |
| mock-notify 에러 주입 `?errorRate=1` | HTTP 500 확인 |
| Prometheus → coupon-api 스크레이프 | `up` |
| 동시성 통합 테스트 (300명 동시, 재고 100) | **정확히 100건 발급, SOLD_OUT 200건** |
| k6 smoke 30초 (발급→이력→잔여) | 5,892 체크 100% 통과, p95 11.18ms |
| 정합성 검증 쿼리 (초과/중복/대사) | **0 / 0 / 0** |
| 부하 상황 성능 (baseline) | 미측정 — 다음 사이클 |

## 5. 배운 점

- 시간대 버그는 설정 두 개(`connectionTimeZone`, `hibernate.jdbc.time_zone`)로 막히지 않았고, DB에 저장된 값과 API 응답을 나란히 비교해 +9h 왜곡을 확인한 뒤 JVM 기본 시간대를 UTC로 고정해 해결했습니다.
- 통합 테스트가 통과해도 안전하지 않을 수 있습니다 — 쓰기와 읽기가 같은 JVM을 지나면 시간대 왜곡이 상쇄되어 숨습니다. 데이터가 실제로 흐르는 경로(SQL 시드 → 앱 읽기)로 검증해야 잡힙니다.
- 장애 주입 도구는 "나중에"가 아니라 기반 공사 때 인터페이스부터 확정하는 것이 싸게 먹힙니다 — 60줄짜리 Node 서버가 Phase 3~4 실험 전체의 도구가 됩니다.

## 6. 다음 Phase 예고

이제 "처참한 baseline"을 만날 차례입니다. `SELECT ... FOR UPDATE`가 이벤트 행 하나에 모든 발급을 직렬화하는 구조에서 5,000rps 스파이크를 맞으면 무슨 일이 벌어지는지 — HikariCP 풀은 어디서 고갈되고, Tomcat 스레드 200개는 어떤 모양으로 잠기는지를 k6와 Grafana로 기록합니다.
