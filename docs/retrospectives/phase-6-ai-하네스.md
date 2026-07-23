# Phase 6 회고 — AI 하네스: 반복을 스킬로, 위험을 가드로, 데이터를 도구로

> 2026-07-22 · 커밋 범위: `bd72d24`(스킬 시작)~`c8e9fb6` · 산출물: `.claude/skills/` 4종 · `.claude/hooks/guard.py` · `tools/mcp/` 2종

## 1. 배경과 목표

[로드맵 Phase 6](../coupon-system-roadmap.md)은 "사실 Phase 0부터 병행되는" 단계입니다 — CLAUDE.md와 `/phase-retrospective` 스킬은 이미 Phase 0에서 만들었고, 이번에 체계화를 마무리했습니다. 목표: ① 반복 워크플로를 스킬로(loadtest/postmortem/explain-check), ② AI에게 권한 가드를(PreToolUse hook), ③ AI가 운영 데이터를 직접 읽게(MCP 서버 직접 제작).

## 2. 문제 상황

### 2.1 공식 MCP SDK를 쓸 수 없다

MCP 서버를 만들려니 로컬 Python이 3.8 — 공식 Python SDK는 3.10+를 요구합니다. Node 재작성, Python 업그레이드, SDK 없이 구현의 갈림길.

### 2.2 가드가 저(AI)를 먼저 막았다

가드 훅을 작성하고 테스트 명령을 실행하는 순간, **방금 만든 가드가 그 테스트 명령을 차단했습니다** — 명령 문자열 안에 "DROP TABLE"이 들어 있었기 때문입니다. 설정 파일이 세션에 즉시 활성화된다는 것, 그리고 문자열 매칭 가드의 false positive 특성을 동시에 실측한 사건입니다. 의도치 않은 실전 검증이기도 했습니다: 차단 경로(exit 2 → 도구 호출 거부)가 실제로 동작함을 스스로에게 당했습니다.

## 3. 해결 과정

### 3.1 MCP 구현 방식

| 선택지 | 장점 | 단점 | 채택 |
|---|---|---|---|
| 공식 Python SDK | 표준, 유지보수 용이 | Python 3.10+ 필요 (로컬 3.8) | ✗ |
| Node/TypeScript SDK | SDK 사용 가능 | 호스트에 Node 런타임 추가, JS/Java/Py 3언어 혼재 심화 | ✗ |
| **JSON-RPC stdio 직접 구현** | 의존성 0, 3.8 호환, 프로토콜 이해 자체가 학습 | 스펙 수동 준수 (initialize/tools/list/tools/call) | **✓** |

결과물: `mysql_explain_mcp.py`(EXPLAIN+ANALYZE, SELECT만 허용하는 읽기 전용 가드, 인덱스/행수 조회)와 `perf_mcp.py`(k6 결과 목록·요약·before/after 비교) — 각각 150줄 내외, 표준 라이브러리만 사용.

### 3.2 가드 정책 — 무엇을 막고 무엇을 흘릴 것인가

| 정책 후보 | 판단 |
|---|---|
| DROP TABLE/DATABASE 차단 | ✓ — 스키마 변경은 Flyway로만 (프로젝트 규칙의 강제화) |
| rm -rf 루트/홈/드라이브 차단 | ✓ — 로컬 하위 경로(build/ 등)는 허용 |
| force push, docker volume rm, compose down -v 차단 | ✓ — 측정 데이터(named volume)와 이력 보호 |
| TRUNCATE 차단 | **✗ 허용** — reset-test.sql이 정상 워크플로. 가드가 일상 작업을 막으면 우회 습관만 생긴다 |
| main push 전면 차단 | ✗ 완화 — 1인 개발 흐름과 충돌, force만 차단 |

## 4. 결과

| 항목 | 검증 |
|---|---|
| 스킬 4종 (phase-retrospective 포함) | 세션에 등록 확인, 회고 5편이 스킬 절차로 생산됨 |
| 가드 테스트 매트릭스 | **15/15 통과** (차단 9, 허용 6) + 세션 내 실전 차단 1회 |
| mysql-explain MCP | selftest 통과 (실제 EXPLAIN 실행, 쓰기 쿼리 거부 확인) |
| perf MCP | selftest + **라이브 호출**: 하네스가 도구로 Tomcat vs Netty 비교표 조회 성공 |
| CI 게이트 | 정합성(Testcontainers 동시성 테스트)은 Phase 2부터 CI에 편입. k6 성능 회귀 게이트는 Phase 5 이월 |

## 5. 배운 점

- 반복 워크플로(측정→요약→비교, 회고 작성)를 스킬 문서로 고정했더니 산출물의 구조가 세션과 무관하게 일정해졌습니다 — 회고 5편이 같은 뼈대(문제→비교표→수치→배운 점)를 갖게 된 것이 그 증거입니다.
- AI 권한 가드는 "많이 막기"가 아니라 "일상 워크플로를 안 막으면서 회복 불능만 막기"의 균형 문제였고, TRUNCATE 허용/DROP 차단 같은 경계선을 프로젝트 규칙(Flyway 전용 스키마 변경)에서 도출했습니다.
- 프로토콜 스펙(JSON-RPC stdio)을 직접 구현하면 SDK 버전 제약에서 자유로워진다는 것 — 그리고 그 서버가 같은 세션에서 바로 도구로 연결되어 검증 루프가 닫히는 경험을 했습니다.

## 6. 다음 Phase 예고

남은 것은 Phase 5(실배포) 하나입니다. AWS 크레딧 계정과 GitHub 원격 저장소라는 선행 조건이 필요하며, 거기서 Nginx+앱 2대 무중단 배포, chaos 실험, 포스트모템들이 약속한 Prometheus 알림 규칙, k6 성능 회귀 CI 게이트, 그리고 이월된 TIME_WAIT·패킷 유실 훈련을 수행합니다. 로컬에서 만든 모든 수치가 "부하 생성기와 SUT가 분리된 환경"에서 어떻게 달라지는지가 마지막 질문입니다.
