# 프로젝트 분석

## 1. 프로젝트 개요

이 프로젝트는 순간 폭주 트래픽에서 선착순 쿠폰을 **초과·중복 발급 없이 처리**하고, 측정·병목 분석·개선·재측정 과정을 실험 자료로 남기는 성능 및 운영 중심 시스템이다.

단순 CRUD보다 동시성 제어, 비동기 처리, 장애 대응, 부하 테스트와 AWS 실증에 초점을 둔다.

## 2. 기술 스택

- Java 21, Spring Boot 3.5.7
- Spring MVC/Tomcat, Spring WebFlux/Netty
- JPA/Hibernate, R2DBC, Flyway
- MySQL 8
- Redis 7, Lettuce, Redisson, Lua Script, Redis Stream
- Kafka 비교 구현
- Caffeine 로컬 캐시
- k6, Prometheus, Grafana, Alertmanager
- Docker Compose, Nginx
- AWS, Terraform, PowerShell/Python 자동화
- GitHub Actions

## 3. 핵심 기능

### 이벤트 관리

- `POST /api/v1/events`: 이벤트 생성
- `GET /api/v1/events/{eventId}`: 이벤트 조회
- `PATCH /api/v1/events/{eventId}/status`: 이벤트 상태 변경
- `GET /api/v1/events/{eventId}/remaining`: 잔여 재고 조회

### 쿠폰 발급

- `POST /api/v1/events/{eventId}/issues`
- `X-USER-ID` 헤더 기반 사용자 식별
- 총 발급 수량 제한
- 사용자당 1회 발급
- 품절, 중복, 미오픈 상태 구분

### 발급 이력

- `GET /api/v1/users/{userId}/issues`
- 페이징 조회
- MySQL 인덱스 및 `EXPLAIN` 개선 실험 포함

### 알림 처리

- Redis Stream 또는 Kafka 이벤트 소비
- WebClient 비동기 호출
- timeout 및 인라인 재시도
- Redis ZSET 지수 백오프 재시도 큐
- DB 알림 상태 기록

## 4. 동시성 제어 전략

세 가지 전략을 구현하고 비교한다.

1. **MySQL 비관적 락**
   - `SELECT ... FOR UPDATE`
   - 정합성은 단순하지만 이벤트 행 경합으로 처리량이 낮은 기준선

2. **Redisson 분산 락**
   - Redis 기반 분산 락
   - 락 대기 및 임대 시간 관리 필요

3. **Redis Lua**
   - 현재 기본 전략
   - 중복 검사, 재고 차감, 사용자 등록을 원자적으로 수행
   - Stream 모드에서는 `XADD`까지 동일 Lua 스크립트에 포함

MySQL의 `(event_id, user_id)` 유니크 제약이 중복 발급의 최종 방어선 역할을 한다.

## 5. 실행 모드

### 기본 API 모드

- MVC/Tomcat
- 기본 발급 전략: `lua`
- 기본 기록 방식: `stream`

### Reactive 모드

- `reactive` 프로파일
- WebFlux/Netty
- 핵심 발급 경로에서 Reactive Redis 사용
- 일부 JPA 작업은 `boundedElastic`으로 격리

### Worker 모드

- `worker` 프로파일
- Redis Stream consumer group 소비
- 발급 이력 저장 및 알림 처리
- stale pending reclaim과 재시도 큐 구현

### Kafka 비교 모드

- `coupon.record.mode=kafka`
- Redis 판정과 Kafka 발행 사이의 비원자성을 비교
- Transactional Outbox가 없는 구조적 한계를 실험 대상으로 유지

## 6. 시스템 구성

### 로컬 HA

- Nginx 로드밸런서
- API 인스턴스 2대
- Worker
- MySQL
- Redis
- Mock Notify API
- Prometheus
- Grafana
- Alertmanager
- k6 부하 발생기

### AWS 실험 구성

- HTTPS ALB
- 다중 API 인스턴스
- 별도 Worker
- RDS MySQL
- ElastiCache Redis
- 서울 control 부하 발생기
- 도쿄 external 부하 발생기
- SSM 중심 접근
- S3 evidence 저장 및 SHA-256/VersionId 검증
- TTL 기반 비용 안전장치
- 세션 단위 `apply → 실험 → destroy`

## 7. 테스트 및 자동화

### Java 테스트

현재 확인되는 테스트 클래스는 다음과 같다.

- `PessimisticLockIssueStrategyTest`
- `RedisIssueStrategiesTest`
- `IssueStreamWorkerTest`
- `AbstractIntegrationTest`

주요 검증 대상은 동시 발급 정합성, 초과·중복 방지, Redis 전략과 Stream worker 처리다.

### CI

- PR 및 `main` push에서 `./gradlew build`
- Testcontainers MySQL 통합 테스트
- Gradle Wrapper 검증
- Java 21 환경 고정

### 성능 게이트

- PR별 k6 실행
- MySQL, Redis, API, Worker 기동
- p95 및 실패율 기준 성능 회귀 차단

### 부하 테스트

- baseline
- spike
- history read
- smoke
- perf gate
- AWS capacity
- generator calibration
- worker recovery

### 인프라 검증

- Terraform 계약 테스트
- AWS preflight, 배포, 부하 실행, evidence 수집, 정합성 검증 및 destroy 자동화

## 8. 문서 및 실험 자산

- 성능 실험 리포트 9편
- 장애 포스트모템 5편
- Phase 회고 6편
- 전체 시스템 로드맵
- AWS 운영 런북
- AWS 예산 및 실행 계획
- AWS evidence 생성·수집·검증 스크립트
- MySQL 정합성 검증 SQL
- Stream vs Kafka 비교
- Tomcat vs Netty 비교
- GC 및 HikariCP 튜닝
- Redis 세 전략 비교
- 패킷 유실, TIME_WAIT, 커넥션 풀 장애 훈련

## 9. 현재 달성 상태

### 달성

- 초과 발급 0건
- 중복 발급 0건
- Lua 기반 원자적 발급
- Redis Stream을 통한 임계 경로 DB 제거
- 로컬 HA 구성
- 인스턴스 교체 리허설 성공률 99.990%
- 알림 timeout, 재시도 및 백오프 큐 구현
- MVC/Reactive 비교 구조
- CI 및 성능 게이트
- AWS 배포·실험 자동화 패키지 준비

### 실환경 검증 대기

- AWS 환경 발급 API p99 200ms 미만
- 분리된 부하 발생기 기준 5,000 RPS
- 최종 10,000 RPS
- AWS worker 중단 후 pending reclaim 및 최종 알림 완료
- AWS API fault 상황의 정합성
- AWS evidence 기반 최종 성능 리포트

현재 README에도 AWS 성능 결과가 아직 없다고 명시되어 있다.

## 10. 리스크 및 개선 항목

### 높은 우선순위

1. **AWS 실행 결과 부재**
   - 인프라와 자동화는 준비됐지만 핵심 성능 주장은 아직 실환경 증거가 없다.

2. **테스트 범위 부족**
   - 컨트롤러 API 계약, Reactive 경로, Kafka worker, 캐시 무효화, 오류 응답과 재시도 한계에 대한 직접 테스트 보강이 필요하다.

3. **알림 at-least-once 실증 부족**
   - retry/reclaim 구현과 실제 장애 후 최종 복구 증거를 구분해야 한다.

4. **부분적인 blocking 처리**
   - Reactive 프로파일에서도 일부 이벤트 관리 작업은 JPA를 `boundedElastic`에서 실행한다.

### 저장소 관리

- AWS 문서, Terraform, 스크립트와 k6 파일 상당수가 현재 untracked 상태다.
- `.gjc` 런타임 파일이 working tree에 대량 노출되어 있다.
- AWS 작업물을 논리적인 커밋으로 정리하고 `.gjc` 추적 정책을 정비할 필요가 있다.
- `evidence/`에는 아직 AWS 실측 결과물이 없다.

### 코드 및 문서 정합성

- `LuaScriptIssueStrategy` 일부 주석은 Stream 분리를 미래 작업처럼 설명하지만 실제 구현은 완료된 상태다.
- 단계성 주석과 현재 구현 사이의 드리프트를 정리할 필요가 있다.

## 11. 종합 평가

이 프로젝트는 운영형 백엔드 포트폴리오로 강한 편이다.

주요 강점은 다음과 같다.

- 여러 동시성 전략을 직접 구현하고 비교
- 성능과 정합성 지표를 분리해 검증
- Redis Lua와 Stream 채택 근거가 명확함
- 실패 사례와 포스트모템 보유
- 로컬 수치를 AWS 결과처럼 과장하지 않음
- AWS evidence를 SHA-256과 VersionId 계약으로 설계
- 비용 제한과 teardown을 운영 절차에 포함

현재 상태는 **애플리케이션, 로컬 HA와 실험 하네스는 대부분 완성됐고 AWS 실환경에서 핵심 성능 및 장애 복구 주장을 증명하는 단계가 남아 있는 프로젝트**로 정리할 수 있다.

> 이 문서는 저장소와 기존 실험 문서를 바탕으로 한 정적 분석 결과다. 작성 과정에서 Gradle 테스트나 AWS 실험은 실행하지 않았다.
