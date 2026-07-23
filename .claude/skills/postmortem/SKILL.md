---
name: postmortem
description: 장애(훈련 포함)의 포스트모템을 증거 기반으로 작성한다. "포스트모템", "장애 회고", "postmortem" 요청 시 사용.
---

# 포스트모템 작성

`docs/postmortems/_template.md` 양식으로 `docs/postmortems/<슬러그>.md`를 작성한다.

## 절차

1. **증거 먼저, 글은 나중**: 타임라인(UTC)·지표(k6/Prometheus)·패킷/스레드덤프/로그 발췌를 먼저 수집한다. 증거 파일은 `k6-results/`에 남기고 문서에서 경로를 인용한다.
   - 패킷: netshoot 사이드카 `docker run --rm --net container:<이름> nicolaka/netshoot tcpdump ...`
   - 스레드덤프: `jcmd <pid> Thread.print` (8080 리스닝 PID는 netstat으로)
   - Redis: `INFO stats`(rejected_connections는 누적 — 증가분으로), `INFO clients`
2. **구조 고정**: 요약 → 타임라인 → 영향 범위 → 근본 원인(증상→가설→**증거**→결론; 기각된 가설도 기록) → 재발 방지(설정/코드/알림 구분, 상태 명시) → 배운 점.
3. **규칙**:
   - 수치는 실측만. 훈련이면 "장애는 의도적으로 주입됨"을 헤더에 명시.
   - "로그가 침묵하는 장애"인지 확인해 명시 (풀 대기·예외 삼킴 등은 에러 로그가 없다).
   - 재발 방지 중 알림 항목은 Phase 5 Prometheus rule 백로그로 연결.
4. 작성 후 README/회고에서 링크할 수 있도록 파일명을 보고한다.

## 기존 사례 (문체·깊이 기준)

- drill1-connection-pool-exhaustion.md — 증거의 부재(SYN 1건)가 증거인 사례
- drill2-missing-timeout.md — 스레드덤프 프레임으로 서드파티 기본값을 특정한 사례
- drill3-redis-maxclients.md — 기동 불능 + 2단계 복구 아크
