# Phase 5 로컬 리허설 — Nginx+앱 2대, chaos 99.990%, 그리고 리허설이 잡아낸 버그 두 개

> 날짜: 2026-07-23 · Phase: 5 (로컬 리허설 — 실배포 전 단계) · 증거: `k6-results/chaos-evidence.txt`, `timewait-evidence.txt`

## 1. 가설

실배포(AWS) 전에 로컬에서 HA 구성의 역학을 검증한다: Nginx 뒤 앱 2대에서 인스턴스 1대를 강제 종료해도 발급 성공률 99.9%를 유지할 수 있는가(roadmap 2.2). 알림 규칙은 지금까지의 포스트모템이 약속한 지표를 실제로 감시하는가.

## 2. 환경

| 구성 | 값 |
|---|---|
| LB | nginx:1.27 (docker, `--profile lb`, 8080:80), upstream 앱 2대, `proxy_next_upstream` 재시도, keepalive 64 |
| 앱 | 호스트 JVM 2대 (8082/8083, lua+stream) + worker(8081) |
| 관측 | Prometheus 알림 규칙 5종(promtool 검증) + redis-exporter — pending·p99·5xx·InstanceDown·rejected_connections |
| 부하 | k6 → nginx(8080) 경유 |

### 구성 중 만난 함정: 언더스코어 Host 헤더

LB 경유 전 요청이 Tomcat 자체 400 페이지로 실패했다. 원인: `proxy_set_header Host` 미설정 시 nginx가 업스트림 이름(`coupon_api`)을 Host로 전달하는데, **언더스코어가 포함된 Host를 Tomcat이 RFC 위반으로 거부**한다. `proxy_set_header Host $host` 명시로 해결 — 직결(8082)로는 재현되지 않아 LB를 세워야만 만나는 함정이다.

## 3. 결과

### 3.1 chaos + 롤링 재시작 (500rps × 3분)

타임라인: t+40s 인스턴스 B 강제 종료 → t+70s `InstanceDown` 알림 pending 진입 확인 → t+90s B 재기동 → t+150s 인스턴스 A도 교체(롤링 리허설).

| 지표 | 값 |
|---|---|
| 총 요청 / 정상 처리 | 90,001 / 89,992 |
| **성공률** | **99.990%** (실패 9건 — 목표 99.9% 달성) |
| med / p95 | 2ms / 4ms (교체 구간 포함) |
| 동작 원리 | nginx passive health check(max_fails) + `proxy_next_upstream` 재시도가 죽은 인스턴스로 간 요청을 흡수 |

### 3.2 리허설이 잡아낸 워커 버그 2건 (이번 리허설의 최대 수확)

드레인 검증에서 `db=0`이 나왔다. 추적 결과 실제 버그 둘:

1. **NOGROUP 무한 루프**: `DEL stream:issue`가 스트림과 함께 consumer group을 삭제하는데, 워커는 그룹 재생성 없이 에러 루프에 빠졌다. → 예외에서 NOGROUP 감지 시 그룹 재생성.
2. **백로그 유실**: 그룹을 `latest($)`로 생성해, 워커 기동 전에 쌓인 메시지를 통째로 건너뛴다. → `ReadOffset.from("0")` 생성으로 수정 (at-least-once 복원).

수정 검증: 백로그 **17,884건**을 새 워커가 처음부터 소비 → DB=Redis=17,884, 중복 0 (유니크 제약 멱등 재확인), 소요 ~111초.

### 3.3 keep-alive 훈련 (이월분)

핸드셰이크 43배 차이(4,451 vs 104/20s), 실패율 55.36% vs 0.65% — 상세는 [drill4 포스트모템](../postmortems/drill4-keepalive-timewait.md). TIME_WAIT의 정석 관찰(컨테이너 NAT 뒤라 미발현)은 실배포로 이월.

## 4. 분석

- 무중단의 실체는 "인스턴스가 안 죽는 것"이 아니라 **죽었을 때 흡수하는 경로(재시도)와 감지(알림)**였다. 9건의 실패는 kill 순간 in-flight 요청 — `proxy_next_upstream`에 idempotent가 아닌 POST 재시도를 허용할지는 실배포에서 결정할 트레이드오프(현재는 error/timeout만 재시도).
- 다중 인스턴스에서 Caffeine 메타 캐시 무효화는 인스턴스별로 일어난다 — PATCH가 한 대에만 도달하므로 나머지는 10s TTL 안전망에 의존. pub/sub 브로드캐스트가 실배포 백로그.
- "리허설에서 버그가 나오면 리허설이 성공한 것": 워커 버그 2건은 단위 테스트가 아니라 **운영 시나리오(스트림 재생성, 워커 재기동)**에서만 드러나는 유형이었다.

## 5. 다음 액션 (실배포에서만 가능한 잔여)

- AWS 배포(Nginx+앱 2대 실 인스턴스), 부하 생성기 분리 후 절대 수치 재측정
- TIME_WAIT 정석 관찰 + tw_reuse/포트 범위 튜닝, tc 패킷 유실 훈련(훈련 5)
- k6 성능 회귀 CI 게이트(GitHub Actions — push 후), Alertmanager 연동(현재는 rule 평가까지)
- 메타 캐시 pub/sub 무효화, graceful shutdown(`server.shutdown=graceful`) 적용 후 롤링 재측정
