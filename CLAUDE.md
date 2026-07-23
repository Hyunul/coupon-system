# coupon-system

선착순 쿠폰 발급 시스템 — "측정 → 병목 발견 → 개선 → 재측정" 사이클을 수치로 기록하는 성능 튜닝 포트폴리오.
전체 로드맵: [docs/coupon-system-roadmap.md](docs/coupon-system-roadmap.md)

## 현재 상태

- **Phase 2 완료** — 3전략 스파이크 비교: lua가 발급 응답 12s→34ms(354배)·정상 처리 3.1배, redisson은 락 이동으로 오히려 악화(절반). 정합성 3전략 모두 0/0/0. 리포트+회고 작성됨.
- **Phase 4 완료** — GC: heap 2g 고정으로 p95 158→2.6ms(pause 191→26회), ZGC는 추가 이득 미미. 장애 훈련 3건 + 포스트모템 3편(docs/postmortems/): 풀 고갈(SYN 1건 패킷 증명), 타임아웃 미설정(reactor-netty 기본 10s가 용량 결정 — 스레드덤프 증거), maxclients(기동 불능 + 2단계 복구). 리포트+회고 작성됨.
- **Phase 6 완료** — skills 4종(phase-retrospective·loadtest·postmortem·explain-check), PreToolUse 가드(.claude/hooks/guard.py, DROP·rm -rf·force push 차단, 테스트 15/15), MCP 서버 2종(tools/mcp/: mysql-explain·perf, Python 3.8 제약으로 JSON-RPC stdio 직접 구현, .mcp.json 등록). 회고 작성됨.
- **Phase 5 로컬 리허설 완료** — Nginx LB(lb 프로파일)+앱 2대(8082/8083): chaos 성공률 99.990%(인스턴스 2회 교체, 목표 99.9% 달성), 알림 규칙 5종 로드·InstanceDown 발화 확인, keep-alive 훈련(핸드셰이크 43배·실패 55%→0.65%, drill4). **리허설이 워커 버그 2건 적발·수정**: NOGROUP 루프, latest 그룹 생성 백로그 유실(→ offset 0). 리포트: docs/reports/phase5-local-rehearsal.md
- **잔여(실배포에서만 가능)**: AWS 배포 + 부하 생성기 분리 재측정, TIME_WAIT 정석 관찰·tc 패킷 유실, k6 회귀 CI 게이트, Alertmanager, 메타 캐시 pub/sub, graceful shutdown. **선행 조건: GitHub push + AWS 계정 (사용자 결정 필요)**. Phase 5 회고는 실배포 후 작성.
- HA 리허설 실행: `docker compose -f docker/docker-compose.yml --profile lb up -d` + 앱 2대(`--server.port=8082/8083`) + worker. LB 함정: upstream 이름 언더스코어 → Tomcat 400 (proxy_set_header Host 필수)
- 패킷 캡처는 netshoot 사이드카 사용: `docker run --rm --net container:<이름> nicolaka/netshoot tcpdump ...`
- GC 실험: `bash scripts/gc-experiment.sh "default g1tuned zgc"` (JVM 옵션은 -PbootJvmArgs, 로그 경로는 공백 때문에 반드시 상대 경로)
- reactive(Netty) 실행: `.\gradlew.bat bootRun --args='--spring.profiles.active=reactive'` (핫패스 논블로킹, 이력 R2DBC). JDBC+R2DBC 공존 함정은 config/DataSourceConfig 주석 참조
- 비동기 측정: `bash scripts/stream-async-experiment.sh` / Tomcat vs Netty: `bash scripts/tomcat-vs-netty-experiment.sh servlet|reactive`
- 발급 전략은 `--coupon.issue.strategy=pessimistic|redisson|lua`로 선택 (기본 pessimistic — lua 기본 전환은 Phase 3에서 이력 INSERT 비동기 분리 후. 근거: docs/reports/phase2-strategy-comparison.md)
- HikariCP 기본값은 pool=20 유지 (실험 근거: docs/reports/phase1-hikari-experiment.md)
- redis 전략은 시드 후 `PATCH /api/v1/events/1/status {OPEN}`으로 Redis 재고 초기화 필요 (run-loadtest.ps1이 자동 수행)

## 아키텍처 (현재형)

- Java 21 + Spring Boot 3.5 (MVC/Tomcat) + JPA + Flyway, 단일 모듈
- 발급: `SELECT ... FOR UPDATE` 이벤트 행 락 (의도된 baseline) + `uk_event_user` 유니크 제약이 중복의 최종 방어선
- 발급 로직은 `application/issue/IssueStrategy` 인터페이스 뒤에 있음 — Phase 2에서 Redisson/Lua 구현체 추가 예정
- 테이블 2개: `coupon_event`(재고 카운터), `coupon_issue`(발급 이력, 조회 인덱스는 의도적으로 없음 → explain 튜닝 후 V3 추가)
- 시간은 전 구간 UTC (`connectionTimeZone=UTC`, `LocalDateTime.now(ZoneOffset.UTC)`)

## 포트 맵

| 8080 | 13306 | 6379 | 9090 | 3000 | 8090 |
|---|---|---|---|---|---|
| coupon-api (호스트) | MySQL | Redis | Prometheus | Grafana | mock-notify |

앱은 호스트에서 실행, 인프라만 docker. Prometheus는 `host.docker.internal:8080`을 스크레이프.

## 자주 쓰는 명령

```powershell
docker compose -f docker/docker-compose.yml up -d      # 인프라 기동
.\gradlew.bat bootRun                                   # 앱 실행 (프로파일: --args='--spring.profiles.active=local')
.\gradlew.bat build                                     # 빌드+테스트 (Testcontainers가 Docker 필요)
Get-Content scripts\seed-event.sql -Raw | docker exec -i coupon-mysql mysql -ucoupon -pcoupon coupon   # 시드
.\scripts\run-loadtest.ps1 -Scenario issue-spike        # reset → k6 → 정합성 검증 일괄
k6 run k6/scenarios/smoke.js                            # 기능 스모크
```

- mock-notify 장애 주입: `POST http://localhost:8090/notify?delay=3000&errorRate=0.3`
- HikariCP 실험: `.\gradlew.bat bootRun --args='--spring.datasource.hikari.maximum-pool-size=5'`

## 컨벤션 / 규칙

- **모든 성능 실험은 [docs/reports/_template.md](docs/reports/_template.md) 양식 필수** (가설→환경(커밋 해시)→시나리오→결과→분석→다음 액션). 리포트는 `docs/reports/`에.
- Grafana 대시보드는 UI에서 수정 후 **반드시 JSON export하여 `docker/grafana/provisioning/dashboards/json/`에 커밋** (재현성).
- 스키마 변경은 Flyway 마이그레이션으로만 (`src/main/resources/db/migration/`). ddl-auto는 validate 고정.
- k6 결과(`k6-results/`)는 gitignore — 수치는 리포트에 옮겨 적는다.
- 부하테스트의 정상 응답 집합: 201(발급) / 409(SOLD_OUT·DUPLICATE). 5xx나 타임아웃만 실패로 계산.
- 커밋 메시지: 한국어 요약 1줄 + 필요 시 본문. Phase 태그 권장 (예: `[P1] 발급 API 비관적 락 구현`).
- **모든 Phase의 종료 조건에 회고 작성이 포함된다**: Phase를 마무리할 때 반드시 `/phase-retrospective` 스킬을 실행해 `docs/retrospectives/`에 블로그 포스팅용 회고(문제 상황 → 해결 과정(대안 기술 비교표) → 결과 수치 → 배운 점)를 작성하고 README 진행 표를 갱신한다.

## AI 작업 시 주의

- 긴 k6/빌드 출력은 파일로 저장 후 경로만 전달할 것 (토큰 절약).
- 측정 중에는 다른 무거운 프로세스를 띄우지 말 것 (수치 오염).
- `reset-test.sql`은 explain 튜닝용 누적 데이터를 지운다 — 누적 중에는 `-NoReset` 사용.
- 통합 테스트는 Docker(Testcontainers)가 필요 — Docker Desktop 기동 상태 확인.
