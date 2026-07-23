# keep-alive 미사용 — 핸드셰이크 43배와 실패율 55%의 대가 포스트모템

> 일시: 2026-07-23 01:02~01:05 (UTC) · 훈련 번호: 2 (roadmap 8장, Phase 4에서 이월) · 장애는 의도적으로 주입됨

## 요약

Nginx→업스트림(앱 2대) 구간의 keep-alive를 끄자, 같은 300rps 부하에서 **요청의 55.36%가 실패**하고 p95가 4ms→2,182ms로 폭증했다. 20초 패킷 캡처 기준 업스트림 방향 핸드셰이크(SYN)는 4,451회 vs keep-alive 시 104회 — **43배**. 매 요청 3-way handshake의 비용이 지연이 아니라 대량 연결 실패로 발현했다.

## 타임라인 (UTC)

| 시각 | 사건 |
|---|---|
| 01:02:44 | 주입: nginx.conf에서 upstream `keepalive`/`proxy_http_version 1.1`/`Connection ""` 제거 후 reload |
| 01:02~01:03 | Run A(off): 300rps 60s — 실패 55.36%, p95 2,182ms, SYN 4,451/20s |
| 01:04:01 | 복구: 설정 복원 + reload |
| 01:04~01:05 | Run B(on): 실패 0.65%, p95 4.0ms, SYN 104/20s |

## 영향 범위

Run A 18,001 요청 중 약 9,965건 실패(연결 수립 실패/타임아웃 → 502 계열). 서비스 관점에서는 간헐 실패가 아니라 과반 실패.

## 근본 원인

- keep-alive가 없으면 nginx는 요청마다 업스트림으로 새 TCP 연결을 연다. 초당 ~220회의 handshake가 Docker Desktop의 host-gateway NAT 계층을 통과하며 연결 수립이 병목이 됐고, `proxy_connect_timeout 2s` + 재시도 소진 → 실패.
- **예상과 달랐던 것 (정직한 기록)**: 교과서적 "TIME_WAIT 6만 수렴"은 컨테이너 netns에서 관찰되지 않았다(off 4개 vs on 10개). 이 토폴로지에서는 연결 상태가 Docker NAT 프록시(호스트 측)에 있고, 손상은 TIME_WAIT 누적이 아니라 **연결 수립 실패**로 먼저 나타났다. TIME_WAIT 포트 고갈의 정석 관찰은 NAT 없는 실배포(리눅스 직결)에서 재수행 예정.
- 증거: `k6-results/timewait-evidence.txt`, `tw-nokeepalive.json`, `tw-keepalive.json`.

## 재발 방지

| 조치 | 종류 | 상태 |
|---|---|---|
| upstream `keepalive 64` + `proxy_http_version 1.1` + `Connection ""` 3종 세트를 기본 구성으로 커밋 | 설정 | 적용됨 (docker/nginx/nginx.conf) |
| "keepalive는 3종 세트" — 하나라도 빠지면 무효(HTTP/1.0이나 Connection: close로 전락) 체크리스트 | 문서 | 본 문서 |
| 실배포 환경에서 TIME_WAIT 정석 관찰 + `tw_reuse`/포트 범위 튜닝 실험 | 실험 | Phase 5 실배포 백로그 |

## 배운 점

- 프록시 구간 keep-alive의 가치는 "약간의 지연 절감"이 아니었다 — 이 환경에선 **서비스 성립 여부**(실패 55%→0.65%)를 갈랐다.
- 같은 장애도 토폴로지에 따라 다른 얼굴로 나타난다: 교과서는 TIME_WAIT 고갈을 말하지만, NAT 뒤에서는 연결 수립 실패가 먼저 온다. 증상이 아니라 메커니즘(핸드셰이크 비용)을 이해해야 두 얼굴을 같은 원인으로 묶을 수 있다.
