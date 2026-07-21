# [실험 제목]

> 날짜: YYYY-MM-DD · 작성자: · Phase: N

## 1. 가설

무엇을 확인/개선하려 하는가. 예상 결과는.

## 2. 환경

| 항목 | 값 |
|---|---|
| 커밋 해시 | |
| 머신 사양 | |
| 앱 설정 (pool size, threads 등) | |
| 인프라 | docker-compose (MySQL 8.0 / Redis 7.4) |
| 특이사항 (백그라운드 부하 등) | |

## 3. 시나리오

k6 시나리오 파일, 파라미터(RATE/DURATION), 실행 명령.

## 4. 결과

| 지표 | 값 |
|---|---|
| 달성 RPS | |
| p50 / p95 / p99 | |
| 에러율 | |
| CPU / 메모리 / GC | |
| hikaricp.connections.pending 최대 | |
| tomcat.threads.busy 최대 | |
| 정합성 (over/dup/mismatch) | / / |

Grafana 스크린샷·k6 summary 경로 첨부.

## 5. 분석

수치가 왜 이렇게 나왔는가. 병목의 증거는 무엇인가.

## 6. 다음 액션

이 결과로 무엇을 바꿀 것인가.
