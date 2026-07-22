# Phase 3 회고 — 비동기와 Netty: 병목을 옮기고, 없애고, 그리고 예상이 빗나간 이야기

> 2026-07-22 · 커밋 범위: `e29d44f`~`fd69f62` · 근거 리포트: [동기→비동기](../reports/phase3-async-notify.md) · [Tomcat vs Netty](../reports/phase3-tomcat-vs-netty.md)

## 1. 배경과 목표

[로드맵 Phase 3](../coupon-system-roadmap.md)의 각본은 이렇습니다: 먼저 알림을 동기 호출로 넣고 3초 지연을 주입해 **발급 API 전체가 함께 무너지는 장애를 재현**한다. 그다음 Redis Stream + 워커 + WebClient로 분리해 같은 지연에서 p99가 흔들리지 않음을 보인다. 마지막으로 Tomcat을 Netty로 바꿔 "왜 Netty인가"를 남의 글이 아닌 내 수치로 답한다.

## 2. 문제 상황

### 2.1 에러율 0%인 채로 죽는 장애

동기 알림에 3초 지연을 주입하고 100rps를 걸자 발급 API의 응답 중앙값이 9ms에서 **18.5초**로 치솟았습니다. 흥미로운 건 에러율이 **0%** 였다는 점입니다. 산수는 단순합니다: 처리 용량 = Tomcat 스레드 200 ÷ 3초 ≈ 67rps < 유입 100rps → 대기열 발산. 실패 알림은 울리지 않고, 지연 지표만이 진실을 말합니다. 이때 Tomcat 스레드 전원이 알림 대기에 잠겨 **actuator 스크레이프까지 막혔습니다** — Phase 2에서 배운 "관측도 장애 도메인"의 재연.

### 2.2 JDBC와 R2DBC를 한 지붕에 — 연쇄 함정 4개

Netty 전환을 위해 R2DBC를 추가하자 **멀쩡하던 JPA 테스트가 전부 죽었습니다**. 원인 규명 과정에서 함정 4개를 연달아 밟았습니다:

1. R2DBC `ConnectionFactory` 빈이 생기면 `DataSourceAutoConfiguration`이 `@ConditionalOnMissingBean(io.r2dbc.spi.ConnectionFactory)` 조건으로 통째로 물러남 → EntityManagerFactory 연쇄 소멸
2. 다중 Spring Data 모듈 strict mode → JPA 리포지토리 스캔 누락
3. TransactionManager 2개(JPA/R2DBC) → `@Transactional` 모호성 폭발
4. reactive 모드로 바꿔도 **Tomcat이 뜬다** — `spring-boot-starter-web`이 클래스패스에 있으면 Boot는 reactive 서버로도 Tomcat(bridge)을 우선 선택

해결: DataSource 명시 빈 + `@EnableJpaRepositories` + JPA TxManager `@Primary` + `NettyReactiveWebServerFactory` 강제. "스타터 두 개를 얹으면 알아서 되겠지"가 얼마나 순진한지 배운 하루였습니다.

### 2.3 Netty가 이기지 않았다

전환 후 동일 5,000rps 스파이크에서 **극적인 역전은 없었습니다**. TCP 거부는 양쪽 ~37만 건으로 동일. 원인을 따져보니 Phase 2~3b에서 핫패스를 [Caffeine 히트 + Redis 왕복 1회]로 줄여버린 탓에, **Tomcat 스레드 200개가 잠길 일 자체가 없어진** 것입니다. 스레드 모델이 병목이려면 스레드가 I/O에 묶여야 하는데, 그 조건은 이미 3a(동기 알림)에서 제거했습니다.

## 3. 해결 과정 — 선택지 비교

**알림/기록 처리 방식** (실제 구현·측정한 것만):

| 선택지 | 장점 | 단점 | 채택 |
|---|---|---|---|
| 동기 호출 (타임아웃 없음) | 구현 최단순 | 외부 3s 지연 → API 전체 붕괴 (p95 35.9s) | ✗ (의도된 장애 재현용) |
| **Redis Stream + 워커 분리** | 지연이 워커에 격리 (p95 3ms), at-least-once + 유니크 제약 멱등화 | 최종적 일관성 (issueId 즉시 미반환) | **✓** |

**워커 배포 형태**:

| 선택지 | 장점 | 단점 | 채택 |
|---|---|---|---|
| 멀티모듈 분리 | 배포 단위 명확 | 초기 구조 공사 큼, 반복 속도 저하 | ✗ (Phase 5 재평가) |
| **동일 아티팩트 + worker 프로파일** | 코드 공유, 즉시 별도 프로세스 실행 | 아티팩트 경계 없음 | **✓** |

**서버 런타임** — 결과가 "조건부"였다는 것이 핵심:

| 선택지 | 실측 | 판단 |
|---|---|---|
| Tomcat (MVC) | 정상 처리 51.0%, 발급 p95 29ms, 60s 타임아웃 100건, 드랍 32,992 | 핫패스가 논블로킹에 가까우면 충분히 경쟁력 |
| Netty (WebFlux) | 정상 처리 51.8%, 전체 p95 3.9s→2.2s, 타임아웃 **0건**, 드랍 **−42%** | 붕괴 상황의 꼬리 거동 우위. 단 발급 p95는 열세(356ms, 웜업 추정·미검증) |

## 4. 결과

| 지표 | Phase 3 이전 | Phase 3 이후 |
|---|---|---|
| 외부 API 3s 지연 시 발급 p95 | 35,943ms (동기) | **3ms** (Stream 분리) |
| 같은 조건 드랍 | 1,976 | **0** |
| 임계 경로 구성 | Redis 판정 + 동기 DB INSERT | **Redis 판정+XADD만** (DB·알림은 워커) |
| 드레인 후 정합성 | — | DB=Redis=12,000 (3b) / 10,000 (3c 양쪽), 중복 0 |
| 5,000rps 스파이크 정상 처리 | 336,727 (P2 lua, 동기 INSERT) | 381,982 (Tomcat) / **394,556 (Netty)** |

## 5. 배운 점

- 외부 API에 3초 지연을 주입해 에러율 0%인 채 응답시간만 발산하는 장애를 재현했고, 원인이 스레드 용량 산수(200÷3s < 100rps)임을 확인한 뒤 Redis Stream 워커로 분리해 같은 지연에서 p95를 35.9초에서 3ms로 만들었습니다.
- JDBC와 R2DBC를 공존시키면서 자동구성이 물러나는 조건(`@ConditionalOnMissingBean(ConnectionFactory)`)을 실측으로 확인했고, DataSource·리포지토리·트랜잭션 매니저를 명시 구성으로 고정해 해결했습니다.
- Tomcat을 Netty로 바꾸면 무조건 빨라질 거라 예상했지만, 핫패스가 이미 초경량이라 스파이크 처리량은 +3%에 그쳤고 이점은 꼬리 거동(타임아웃 100→0, 드랍 −42%)에서만 나타났습니다 — "Netty가 이기는 조건은 스레드가 I/O에 묶이는 워크로드"임을 내 수치로 말할 수 있게 됐습니다.

## 6. 다음 Phase 예고

이제 저수준으로 내려갑니다. Phase 4는 GC 로그가 p99에 만드는 스파이크(G1 vs ZGC), 그리고 계획된 장애 훈련 — 풀 고갈·TIME_WAIT 폭증·타임아웃 미설정을 일부러 만들고 **tcpdump로 패킷 수준의 증거**를 잡아 포스트모템을 쓰는 단계입니다. 3a에서 재현했던 붕괴를 이번엔 패킷으로 다시 봅니다.
