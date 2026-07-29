# coupon-system 실험 노트

순간 폭주 트래픽을 **초과 발급 0건**으로 처리하는 선착순 쿠폰 시스템을 만들며,
"측정 → 병목 발견 → 개선 → 재측정" 사이클을 수치로 기록한 글 모음입니다.
코드와 원자료는 [GitHub 리포](https://github.com/Hyunul/coupon-system)에 있습니다.

## 회고 (블로그 포스팅)

문제 상황 → 해결 과정(대안 비교) → 결과 수치 → 배운 점 순서로 정리한 Phase별 회고입니다.

1. [Phase 2 — 재고 차감 3전략 실측: 락을 옮기는 것과 없애는 것의 차이](retrospectives/phase-2-redis-3전략.md) ★ 추천 첫 글
2. [Phase 1 — 정직한 MVP: 비관적 락 baseline과 측정 인프라](retrospectives/phase-1-정직한-mvp.md)
3. [Phase 3 — 비동기 알림과 Tomcat vs Netty 실측](retrospectives/phase-3-비동기와-netty.md)
4. [Phase 4 — 저수준 튜닝: p95를 갉아먹은 것은 GC가 아니었다](retrospectives/phase-4-저수준-튜닝.md)
5. [Phase 0 — 기반 공사: 인프라·CI·AI 하네스](retrospectives/phase-0-기반공사.md)
6. [Phase 6 — AI 하네스 체계화: skills·hooks·MCP](retrospectives/phase-6-ai-하네스.md)

## 실험 리포트 (원자료)

가설 → 환경(커밋 해시) → 시나리오 → 결과 → 분석 양식으로 기록한 실측 리포트입니다.

- [Phase 1 baseline](reports/phase1-baseline.md) · [HikariCP 풀 크기](reports/phase1-hikari-experiment.md) · [explain 튜닝](reports/phase1-explain-tuning.md)
- [3전략 스파이크 비교](reports/phase2-strategy-comparison.md)
- [동기 알림 장애와 Stream 분리](reports/phase3-async-notify.md) · [Tomcat vs Netty](reports/phase3-tomcat-vs-netty.md)
- [GC 튜닝](reports/phase4-gc-tuning.md)
- [Phase 5 로컬 HA 리허설](reports/phase5-local-rehearsal.md) · [Redis Stream vs Kafka](reports/phase5-stream-vs-kafka.md)

## 장애 훈련 포스트모템

- [훈련 1 — 커넥션 풀 고갈](postmortems/drill1-connection-pool-exhaustion.md)
- [훈련 2 — 타임아웃 미설정](postmortems/drill2-missing-timeout.md)
- [훈련 3 — Redis maxclients](postmortems/drill3-redis-maxclients.md)
- [훈련 4 — keep-alive와 TIME_WAIT](postmortems/drill4-keepalive-timewait.md)
- [훈련 5 — 패킷 유실 5%](postmortems/drill5-packet-loss.md)

## 설계 문서

- [전체 로드맵](coupon-system-roadmap.md)
- [AWS 부하 테스트 런북](aws-load-test-runbook.md) · [실행 계획](aws-execution-plan.md)
