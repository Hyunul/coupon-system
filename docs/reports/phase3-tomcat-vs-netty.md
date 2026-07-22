# Tomcat vs Netty — 임계 경로가 이미 가벼우면 스레드 모델은 병목이 아니다

> 날짜: 2026-07-22 · Phase: 3c · 시나리오: `issue-spike.js` (100→5,000rps) · 실행: `scripts/tomcat-vs-netty-experiment.sh servlet|reactive`

## 1. 가설

Tomcat 스레드 200개가 잠기는 구조를 Netty 이벤트 루프로 바꾸면 같은 스파이크에서 처리량·꼬리 지연이 개선될 것이다 (roadmap Phase 3: "왜 Netty인가"를 내 수치로).

## 2. 환경

| 항목 | 값 |
|---|---|
| 공통 | 동일 커밋, lua+stream 모드(핫패스 = Caffeine 메타 + Redis Lua 원자 판정+XADD, DB 무접촉), worker 프로세스가 Stream 드레인 |
| servlet | Spring MVC + Tomcat(기본 200 threads), 블로킹 Lettuce |
| reactive | `--spring.profiles.active=reactive` — WebFlux + **Netty**(명시 팩토리 빈), ReactiveStringRedisTemplate, 이력 조회 R2DBC |
| 머신 | 12코어/32GB, k6+SUT 동일 머신 — 상대 비교 목적 |

### 전환기에서 만난 함정들 (전부 실측으로 확인)

1. **R2DBC ConnectionFactory 빈이 생기면 `DataSourceAutoConfiguration`이 통째로 물러난다** (`@ConditionalOnMissingBean(io.r2dbc.spi.ConnectionFactory)`) → EntityManagerFactory 연쇄 소멸. 해법: JDBC DataSource 명시적 빈 정의(`DataSourceConfig`).
2. 다중 Spring Data 모듈 strict mode로 JPA 리포지토리 스캔 누락 → `@EnableJpaRepositories` 명시.
3. TransactionManager 2개(JPA+R2DBC) 모호성 → JPA 쪽 `@Primary`.
4. **reactive 모드에서도 Tomcat이 선택된다** — spring-boot-starter-web이 클래스패스에 있으면 Boot는 Tomcat(reactive bridge)을 우선한다. `NettyReactiveWebServerFactory` 빈으로 강제해야 "Netty started" 로그를 볼 수 있다.
5. 전면 R2DBC 재작성 대신 **핫패스 논블로킹 + 이력 R2DBC + 저빈도 경로 boundedElastic 위임**을 택했다 — R2DBC 생태계 제약(JPA 기능 부재, 페이징/매핑 수작업)을 감안한 전환기 전략.

## 3. 결과

| 지표 | Tomcat (servlet) | Netty (reactive) |
|---|---|---|
| 총 요청 | 748,503 | 762,292 |
| 정상 처리 (201/409) | 381,982 (51.0%) | **394,556 (51.8%)** |
| 발급(201) med / p95 | **2ms / 29ms** | 3ms / 356ms |
| 전체 med / p95 | 1ms / 3,948ms | 2ms / **2,164ms** |
| dropped iterations | 32,992 | **19,205 (−42%)** |
| 60s 타임아웃 | 100 | **0** |
| TCP 거부 | 366,421 | 367,736 (동일 수준) |
| 드레인 후 정합성 | 10,000/10,000, 중복 0 | 10,000/10,000, 중복 0 |

## 4. 분석 — 예상과 달랐던 것이 가장 큰 수확

- **극적인 역전은 없었다.** TCP 거부(~37만)는 두 서버가 동일하다 — 5,000rps에서의 1차 병목은 이미 서버 스레드 모델이 아니라 **단일 머신의 accept 큐/CPU(k6 공존) 한계**다.
- 이유는 Phase 2~3b에서 핫패스를 너무 가볍게 만들어버렸기 때문이다. 요청당 서버 작업이 [Caffeine 히트 + Redis 왕복 1회]뿐이라 Tomcat 스레드 200개가 잠길 일이 없다. **"Tomcat 스레드가 잠기는 그래프"는 3a(동기 알림 3s)에서 이미 나왔고, 그것이 Netty가 이기는 조건이다** — 스레드가 외부 I/O에 묶이는 워크로드.
- 그럼에도 Netty의 이점은 꼬리에서 보였다: 60초 타임아웃 0건(vs 100), 드랍 −42%, 전체 p95 절반. 붕괴 상황에서의 degradation이 더 부드럽다.
- 발급(201) p95는 Tomcat이 더 좋았다(29ms vs 356ms) — 발급 성공은 부하 초반(램프 구간)에 몰리는데, Netty 런은 초반 웜업(리액터 파이프라인 JIT)이 낀 것으로 추정. 단정하려면 웜업 후 재측정이 필요하다(미측정, 한계로 기록).

## 5. 다음 액션

- "Netty가 이기는 조건"의 실증: 3a의 동기 지연 시나리오를 reactive + 논블로킹 WebClient로 재현해 스레드 고갈 유무를 비교하는 실험 — Phase 4 후보.
- 서버 무관 병목(accept 큐, 에페메랄 포트, k6 공존)의 해소는 Phase 5 실배포(부하 생성기 분리)에서.
