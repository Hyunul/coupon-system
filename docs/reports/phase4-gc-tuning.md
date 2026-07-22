# GC 튜닝 실측 — p95를 갉아먹은 것은 GC가 아니라 heap 리사이징이었다

> 날짜: 2026-07-22 · Phase: 4 · 실행: `scripts/gc-experiment.sh "default g1tuned zgc" 1000 2m`

## 1. 가설

부하 중 GC STW가 p99 스파이크를 만들 것이다. heap 고정(-Xms=-Xmx)과 ZGC 전환으로 pause를 줄이면 꼬리 지연이 개선될 것이다 (roadmap Phase 4).

## 2. 환경

| 항목 | 값 |
|---|---|
| 부하 | `issue-baseline.js` 1,000rps × 2분, lua+stream(핫패스 Redis-only) |
| 공통 | 동일 커밋, `-Xlog:gc*` 파일 로그, 각 런 JVM 콜드 스타트 |
| A. default | G1 (JVM 기본, heap 동적) |
| B. g1tuned | G1 + `-Xms2g -Xmx2g -XX:MaxGCPauseMillis=50` |
| C. zgc | `-XX:+UseZGC -XX:+ZGenerational` + heap 2g 고정 (Java 21 세대형 ZGC) |

부수 트러블: 프로젝트 경로 공백 때문에 `-Xlog:gc*:file=<절대경로>`가 JVM 기동 실패를 일으켰다 — bootRun 작업 디렉터리 기준 상대 경로로 해결. (경로 공백은 Phase 0 계획 때 경고했던 리스크가 실제로 문 것)

## 3. 결과

| 지표 | A. G1 기본 | B. G1+heap고정 | C. ZGC(gen) |
|---|---|---|---|
| GC pause 횟수 (2분) | **191** | 26 | 11 |
| pause 최대 | 8.15ms | 8.94ms | **0.03ms** |
| STW 합계 | 368ms | 95ms | **0.2ms** |
| k6 중앙값 | 1.6ms | 1.1ms | 1.0ms |
| **k6 p95** | **158.1ms** | **2.6ms** | **2.2ms** |
| dropped | 285 | 0 | 0 |

## 4. 분석

- **개선의 9할은 heap 고정이었다.** A→B에서 pause 횟수 191→26(-86%), p95 158→2.6ms. 기본 설정은 작은 초기 heap에서 출발해 부하 중 heap 확장·young 영역 재조정을 반복하고, 그 사이 잦은 young GC(191회)가 요청 대기열과 공진해 p95를 만들었다. 개별 pause는 8ms에 불과했지만 **빈도**가 문제였다.
- **ZGC는 pause를 사실상 소멸시켰지만**(최대 0.03ms), p95 이득은 B 대비 0.4ms에 그쳤다. heap이 고정된 순간 GC는 더 이상 p95의 지배 요인이 아니었기 때문이다. "더 좋은 GC"보다 "GC가 일할 필요를 줄이는 설정"이 먼저다.
- 이 워크로드(요청당 짧은 수명 객체, 2g면 충분)에선 **B(G1+고정 heap)를 기본값으로 채택**한다. ZGC는 heap이 크고 pause 요구가 엄격해지는 Phase 5(실배포) 재평가 대상.
- 한계: NewRatio/SurvivorRatio 세부 실험은 미수행(heap 고정으로 p95 문제가 소멸해 변별력 없음), 단일 런이라 런 간 분산 미측정.

## 5. 다음 액션

- `bootRun` 기본 JVM 옵션에 `-Xms2g -Xmx2g` 채택 여부는 Phase 5 배포 스펙(컨테이너 메모리 한도)과 함께 결정.
- GC가 아닌 다음 꼬리 요인 후보: TCP accept 큐(스파이크 실험에서 확인됨) — Phase 5에서 부하 생성기 분리 후 재측정.
