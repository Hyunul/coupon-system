# AWS 실배포·부하 테스트 실행 계획 — $200 크레딧 예산

> 이 문서는 **계획**이다. 실행 절차·안전 게이트는 [aws-load-test-runbook.md](aws-load-test-runbook.md)를 따르고, 이 문서는 "무엇을, 어떤 순서로, 얼마의 예산으로" 를 정한다. 모든 비용 수치는 계획용 추정이며, 매 세션 전 AWS Pricing Calculator로 확정한다(런북 게이트: 12h 총액 <$60).

## 1. 예산 원칙 — **크레딧-온리 (현금 지출 0원)**

- 총 크레딧 **$200** 안에서만 끝낸다. 런북 하드 게이트 준수: 지출 **$100** 도달 시 신규 부하 중단, **$120** 도달 시 teardown, **$200 초과 절대 금지**. 계획 지출 합계는 ~$70으로, 게이트까지의 여유가 재실행 예산이다.
- **크레딧 비적용 항목 회피**: Route53 **도메인 등록**과 Support 플랜은 크레딧으로 결제되지 않는다(현금). 도메인은 2장의 크레딧-온리 옵션으로 해결한다. hosted zone 사용료($0.50/월)·EC2·RDS·ALB·S3·데이터 전송 등 일반 사용량은 크레딧 적용 대상이다.
- **세션 간 최소 1일 간격 + 잔액 확인**: 청구 데이터는 최대 ~24시간 지연된다. 매 세션 전후 Billing → Credits 잔액과 Cost Explorer(일 단위)를 확인하고, 직전 세션 지출이 반영되기 전에는 다음 세션을 시작하지 않는다.
- **크레딧/프리 플랜 시한**: 크레딧 체제 계정은 가입 후 6개월 또는 크레딧 소진 시 프리 기간이 끝난다. 전 세션을 이 시한 안에 마치도록 일정을 잡고, 종료 시한 2주 전을 마지막 세션 데드라인으로 둔다.
- 매 세션 종료는 destroy + **서울·도쿄 양쪽 잔존 검증**(런북 Teardown 절)까지다. TTL Lambda는 partial backstop일 뿐이므로 destroy 실패·잔존 발견 시 즉시 수동 정리하고, 정리 확인 전에는 "비용이 멈췄다"고 간주하지 않는다.
- **세션제 운영**: 인프라를 상시 유지하지 않는다. 한 세션 = `terraform apply` → 실험 묶음 → `destroy` + 잔존 확인. `expires_at` 최대 12시간이 세션의 자연 상한이다.
- 세션 사이(비용 0)에 evidence 분석·리포트 작성·다음 세션 계획을 한다. 인프라를 켜 둔 채 분석하지 않는다.
- 배분: 세션 0 ≈ $10 / 세션 1 ≈ $30 / 세션 2 ≈ $30 / **예비 ≈ $130** (재실행·실수·잔존 비용 버퍼). 예비가 큰 이유: 첫 실배포는 반드시 계획에 없던 재실행이 생긴다.

### 시간당 비용 추정 (서울, 온디맨드, 계획용)

| 리소스 | 사양 | 시간당 (추정) |
|---|---|---|
| API | c7i.large ×2 | ~$0.21 |
| worker + mock-notify + monitoring | c7i.large ×1 + 소형 ×2 | ~$0.15–0.25 |
| 부하 발생기 (control, 서울) | c7i.2xlarge ×1 | ~$0.41 |
| 부하 발생기 (external, 도쿄) | c7i.2xlarge ×1 | ~$0.40 (필요 세션만) |
| RDS | db.t4g.medium | ~$0.08 + EBS 소액 |
| ElastiCache | cache.t4g.small | ~$0.04 |
| ALB | 고정 + LCU | ~$0.02 유휴 / 부하 중 +$0.1–0.2 |
| **합계** | | **유휴 ~$0.9/h · 전부하 ~$1.5–2/h** |

12시간 풀 세션 ≈ $15–25. c 계열을 쓰는 이유는 로드맵 7장에서 경고한 t 계열 CPU 크레딧 버스트(부하 중 성능 급락 → 수치 오염)를 피하기 위함이다.

## 2. 세션 전 준비 (비용 0, 지금 가능)

1. **도메인 + ACM 인증서 (크레딧-온리 결정 지점)** — 런북의 `acm_certificate_arn`·`benchmark_hostname`은 필수 입력. ACM 인증서 자체는 무료지만 검증용 도메인이 필요하다. 현금 0원 순서로:
   - **A. 이미 보유한 도메인의 서브도메인** (예: `coupon-bench.<보유도메인>`) — 비용 0, 최선. DNS 검증 CNAME 1개 + ALB CNAME 1개만 추가하면 된다.
   - **B. 회사/지인 도메인의 서브도메인 위임** — NS 위임 또는 레코드 2개 추가만 부탁. 비용 0.
   - **C. Route53 신규 등록(~$14/년)** — **크레딧이 아닌 현금 결제**이므로 크레딧-온리 원칙에서는 최후 수단. A·B가 불가능할 때만.
   - 무료 DNS 서비스(afraid.org 류)는 ACM 검증이 막히거나 포트폴리오 신뢰도를 깎으므로 계획에서 제외한다.
2. **EC2 vCPU quota 확인/증설** — 서울 On-Demand Standard 인스턴스 합산 vCPU: API 4 + worker/기타 ~6 + 발생기 8 = **약 20 vCPU** (도쿄는 8). 신규 계정 기본 quota가 이보다 낮을 수 있고 증설에 며칠 걸리므로 **가장 먼저** 요청한다. preflight가 검증하지만, 세션 당일 발견하면 하루를 날린다.
3. **프리 플랜 제약 확인** — 2025-07 이후 크레딧 체제 계정은 프리 플랜에서 일부 서비스(ALB·RDS·ElastiCache 등)가 제한될 수 있다. 제한에 걸리면 유료 플랜 전환(크레딧은 그대로 사용됨)이 필요한지 Billing 콘솔에서 먼저 확인한다.
4. **artifact S3 bucket** — 버전 관리·기본 암호화·public access block 전부 활성(런북 계약). Budget 알림 이메일 설정.
5. **로컬 dry-run 전 왕복** — `run-experiment.ps1` → `invoke-loadgen.ps1`(dry) → `collect-evidence.ps1`(dry)를 실 인자로 미리 돌려 manifest 계약 위반을 비용 0에서 잡는다.

## 3. 세션 계획

### 세션 0 — 파이프라인 검증 (반나절, ~$10)

목표는 성능 수치가 아니라 **절차 리스크 제거**. external 발생기 없이 최소 구성.

- apply → DNS 매핑 → smoke(수동 curl + `/loadgen-calibration` 204) → JAR 해시 배포 → generator-calibration 실행(rate 1,000 × 2m) → evidence 수집·검증 왕복 → destroy + 잔존 확인.
- 성공 기준: 여섯 object publication manifest가 VersionId·해시까지 통과, destroy 후 서울·도쿄 잔존 0.
- 여기서 얻는 부수 수치: **발생기 calibration 상한**(발생기 1대가 낼 수 있는 최대 rate) — 이후 모든 측정에서 "발생기가 병목이 아니다"의 근거가 된다.

### 세션 1 — 정격 처리량 + 정합성 (12h, ~$30) ← 핵심 세션

| 순서 | 실험 | 파라미터 (런북 예시 기준) |
|---|---|---|
| 1 | generator-calibration | 1,000rps × 2m — 세션마다 재수행 |
| 2 | **정격 capacity** | 5,000rps × 10m, normal (Users 3M·Stock 3.6M → 전량 201) |
| 3 | **계단식 한계 탐색** | 1k → 3k → 5k → 7k → 10k rps, 각 3–5m, p99 SLO 붕괴 지점 기록 |
| 4 | **동시 sold-out 전역 검증** | 발생기 2대(서울+도쿄) 동시, Stock 100k, aggregate verifier + `verify-aws-consistency.sql` |
| 5 | (여력 시) soak | 1,000rps × 60m — GC·누수·안정성 |

- 3의 한계 탐색은 고정 rate 재실행의 계단식으로 한다(run-experiment는 고정 rate 계약). **한계점과 그때의 병목 규명이 5,000이라는 정격 숫자보다 강한 포트폴리오다.**
- 부하 사이 SSM 포트 포워딩으로 Grafana 캡처, API 인스턴스에서 `ss -tan state time-wait` 관찰(로컬에서 못 본 TIME_WAIT 정석 — 이월 항목 해소).

### 세션 2 — 장애 훈련 + 저수준 관찰 (12h, ~$30)

| 순서 | 실험 | 근거가 되는 주장 |
|---|---|---|
| 1 | calibration + 5,000rps 정상 baseline | 장애 실험의 대조군 |
| 2 | **API fault** (부하 중 인스턴스 1대 SSM stop→start) | ALB target 전이 + 성공률 + 정합성 — 로컬 chaos 99.990%의 실환경 재현 |
| 3 | **worker recovery** (pending→reclaim→drain) | 알림 at-least-once 실증 — README ⏳ 항목 해소 |
| 4 | **tc netem 패킷 유실 5%** (EC2는 진짜 netem 가능) | drill5 정밀 재현 — WSL2 iptables 대체판의 정석 검증 |
| 5 | (스트레치) **10,000rps 합산** — 발생기 2대 × 5,000 | 로드맵 "최종 10,000 RPS" 목표 |

- 장애 주입은 전부 런북의 USER-ONLY 프로토콜(단일 인스턴스, UTC receipt, 분리된 evidence manifest)을 따른다.
- 세션 1 결과에서 튜닝거리가 나오면(예: Lettuce pool, ALB idle timeout) 2와 3 사이에 1건만 끼워 before/after를 만든다 — 실배포에서도 "측정→개선→재측정" 사이클을 1회 이상 남기는 것이 목표.

### 세션 3 (예비, 선택) — 재실행 / 심화

예비 $130 안에서: 세션 1·2의 실패 재실행, 또는 Kafka 파티션 병렬성·리밸런싱 관찰(stream-vs-kafka 리포트의 이월 항목), Redis replica failover. **크레딧 소진 목표가 아니라 주장에 필요한 evidence가 다 모이면 멈춘다.**

## 4. "대규모 트래픽 처리" 근거 테스트 카탈로그

각 테스트가 만들어 주는 이력서/면접 문장과 증거물. ①·③·⑤가 최소 필수 세트다.

| # | 테스트 | 만들어지는 주장 | 증거물 |
|---|---|---|---|
| ① | 정격 5,000rps × 10m (open model, 분리 발생기) | "실 네트워크(HTTPS ALB) 경유 초당 5,000건, 단일 실행 **300만 요청**을 p99 Xms·실패율 <0.1%로 처리" | k6 summary(offered vs achieved ≥99.9%, dropped=0) + Grafana |
| ② | 계단식 한계 탐색 | "한계 처리량 X rps에서 p99 SLO 붕괴 — 병목은 Y임을 Z로 규명" | 단계별 summary + 병목 증거(스레드덤프/GC/DB 지표) |
| ③ | 동시 sold-out 전역 검증 (발생기 2대) | "수백만 경쟁 요청에서 발급 **정확히 재고 수량**, 중복·초과 0 — k6 합산과 DB SQL로 이중 증명" | aggregate verifier 출력 + verify-aws-consistency.sql |
| ④ | 10,000rps 합산 (스트레치) | "다중 리전 발생기 합산 1만 rps 도달" (실패해도 한계·원인 기록이면 충분) | 발생기별 summary + 합산 기록 |
| ⑤ | 부하 중 API 인스턴스 강제 종료 | "부하 중 인스턴스 교체에도 성공률 99.9%+ — ALB target 전이를 UTC 타임라인으로 증빙" | api-fault evidence manifest |
| ⑥ | worker 중단→재기동 | "at-least-once 소비: pending 적체→reclaim→drain 0, 알림 최종 완료, DB 정합 유지" | worker-recovery evidence manifest |
| ⑦ | soak 1,000rps × 60m | "1시간 지속 부하에서 p99 표류·메모리 증가 없음" | 시계열 Grafana + GC 로그 |
| ⑧ | 도쿄 external 발생기 | "실 WAN 지연이 섞인 트래픽에서도 SLO 유지 — localhost 수치가 아님" | control vs external summary 비교 |
| ⑨ | TIME_WAIT·keep-alive·netem 관찰 | "커널·패킷 레벨 관찰을 실 환경에서 재검증" (drill 2·5 정식판) | ss/tcpdump 캡처, drill 포스트모템 갱신 |

### 수치를 남들이 믿게 만드는 조건 (전 테스트 공통)

1. **open model** (`constant-arrival-rate`) — 서버가 느려져도 부하가 줄지 않는 모델임을 명시.
2. **발생기 분리 + calibration** — "측정기가 병목이 아니다"를 세션마다 별도 실행으로 증명.
3. **offered vs achieved rate + dropped_iterations=0** — "5,000을 보냈다"가 아니라 "5,000이 실제 도착했다".
4. **정합성은 k6가 아니라 SQL로** — 발급 수·중복은 RDS 읽기 전용 쿼리로 별도 증명(런북 규칙).
5. **versioned evidence** — S3 VersionId + SHA-256 manifest로 사후 조작 불가능한 기록. 리포트에 커밋 해시·인스턴스 사양·JVM/pool 설정 명기(기존 _template 양식 그대로).

## 5. 산출물

- `docs/reports/phase5-aws-capacity.md` — ①②④⑦⑧ (측정 리포트, _template 양식)
- `docs/reports/phase5-aws-fault-drills.md` — ⑤⑥ (+ drill 포스트모템 갱신 ⑨)
- README 목표표의 ⏳ 3건(p99, 알림 at-least-once, 5,000rps) 실측값으로 갱신
- Phase 5 회고 (`/phase-retrospective`) — 전 세션 종료 + destroy 잔존 0 확인 후 작성
