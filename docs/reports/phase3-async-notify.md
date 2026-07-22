# 동기 알림 장애 재현 → Redis Stream 비동기 분리 — 같은 3초 지연, p95 35.9s vs 3ms

> 날짜: 2026-07-22 · Phase: 3 (3a 장애 재현 + 3b 비동기 분리) · 실행: `scripts/notify-sync-experiment.sh`, `scripts/stream-async-experiment.sh`

## 1. 가설

발급 성공 경로에 타임아웃 없는 동기 알림 호출이 있으면, 외부 API의 3초 지연만으로 발급 API 전체가 무너질 것이다(스레드 점유 전파). 알림·DB 기록을 Redis Stream 소비 워커로 밀어내면 같은 지연에서도 발급 p99가 흔들리지 않을 것이다 (roadmap Phase 3).

## 2. 환경

| 항목 | 값 |
|---|---|
| 전략 | lua (Phase 2 채택안) · 부하 `issue-baseline.js` **100rps × 2분** |
| 시드 | 재고 1,000,000 (실험 내내 매진 없음 — 매 요청이 알림 경로 통과) |
| 3a 동기 | `SyncNotifyClient`(RestClient) — **의도적으로 타임아웃 미설정** (장애 훈련 4의 사전 체험) |
| 3b 비동기 | api: Lua에 XADD 추가(`issue-stream.lua`, 원자 발행) / worker: 별도 프로세스(8081, `--spring.profiles.active=worker`)가 XREADGROUP 소비 → DB INSERT → XACK → WebClient 알림(timeout 5s + backoff 재시도 2회) |
| 지연 주입 | mock-notify `?delay=3000` — 3a는 api의 알림 URL에, 3b는 **worker의 알림 URL에만** |

## 3. 결과

| 지표 | 동기·지연 0 | 동기·지연 3s | **Stream 비동기·지연 3s** |
|---|---|---|---|
| 완료 요청 (12,000 목표) | 12,001 | 9,400 (**dropped 1,976**) | **12,000 (dropped 0)** |
| 응답 중앙값 | 9ms | **18,473ms** | **2ms** |
| 응답 p95 | 12ms | **35,943ms** | **3ms** |
| tomcat busy 최대 | 3 | 측정 불가* | 2 |
| 정합성 (드레인 후) | n/a | n/a | **DB 12,000 = Redis 12,000, 중복 0** |

\* 동기·지연 런에서는 Tomcat 스레드 전부가 알림 응답 대기에 잠겨 actuator 스크레이프까지 막혔다 — Phase 2에서 발견한 "관측도 장애 도메인" 패턴의 재연.

## 4. 분석

- **동기 3s의 붕괴는 산수다**: 처리 용량 = 스레드 200 ÷ 3s ≈ 67rps < 유입 100rps → 대기열이 발산해 응답시간이 런 내내 선형 증가(중앙값 18.5s). 에러율은 0%였다는 점이 함정 — **"실패는 없는데 느려서 죽는" 장애**는 에러율 알림으로는 잡히지 않고 지연 지표로만 보인다.
- **비동기 분리 후 2ms**: 임계 경로가 [Caffeine 메타 확인 → Lua 원자 판정+XADD]로 줄었다. DB INSERT까지 워커로 이동해 healthy 동기(9ms)보다도 빨라졌다. 지연 3초는 워커의 WebClient 큐 안에 격리되어 API에 전파되지 않는다.
- **최종적 일관성 검증**: 부하 종료 후 워커가 Stream을 드레인하면 DB=Redis=12,000 대사 일치, 중복 0. at-least-once 재소비는 `uk_event_user`가 멱등화한다 (설계대로 3중 방어의 두 번째 층이 작동).
- 워커 분리는 멀티모듈 대신 **동일 아티팩트 + `worker` 프로파일 별도 프로세스**를 택했다. 반복 실험 속도와 코드 공유가 이유이며, 배포 단위 분리가 실제로 필요해지는 Phase 5(다중 인스턴스)에서 재평가한다.

## 5. 남은 것 (Phase 3 미완 항목)

- **WebFlux/Netty + R2DBC 전환 및 Tomcat vs Netty 동일 부하 비교** — Phase 3의 후반부, 다음 사이클.
- 알림 실패 재시도 큐(지수 백오프 Stream)와 pending 메시지 재처리(XAUTOCLAIM) — 현재는 백오프 재시도 2회 후 FAILED 마킹까지.
- tcpdump/스레드덤프 증거 수집(장애 훈련 1·4와 연계) — Phase 4에서 수행.

## 6. 다음 액션

Tomcat 스레드 모델의 한계(200 블로킹 스레드)를 이벤트 루프로 대체하는 WebFlux/Netty 전환 후, 동일 스파이크로 "왜 Netty인가"를 수치로 답한다.
