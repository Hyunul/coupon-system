---
name: loadtest
description: k6 부하테스트를 실행하고 결과를 요약·이전 결과와 비교한다. "부하테스트 돌려", "loadtest", "스파이크 측정" 요청 시 사용.
---

# 부하테스트 실행 → 요약 → 비교

## 절차

1. **사전 확인**: `docker info` (Docker Desktop 생존 — 반복 부하 후 죽은 전례 있음), 인프라 5종 healthy, 앱 기동 상태(8080). 앱이 없으면 실행 조건(전략/프로파일)을 사용자에게 확인하거나 CLAUDE.md 기본값으로 기동.
2. **측정 중 오염 금지**: k6가 도는 동안 빌드·이미지 풀 등 무거운 작업을 하지 않는다.
3. **실행**: `.\scripts\run-loadtest.ps1 -Scenario <이름>` (reset→seed→PATCH OPEN→k6→정합성 검증 일괄). explain용 데이터 누적 중이면 `-NoReset`.
   - 개별 실행 시에도 k6는 `--summary-export k6-results/<이름>-<조건>.json`으로 결과를 남긴다.
   - 긴 k6 출력은 파일로 저장하고 경로만 다룬다 (토큰 절약).
4. **요약**: summary JSON에서 다음만 추출해 표로 보고 — 달성 RPS, med/p95/p99, http_req_failed, checks ok, dropped, 정합성(over/dup/mismatch).
5. **비교**: `k6-results/`에서 같은 시나리오의 직전 JSON을 찾아 med/p95/실패율 델타를 함께 표기. 이전 결과가 없으면 "첫 측정"으로 명시.
6. **판정**: 부하테스트의 정상 응답 = 201/409. p95가 직전 대비 ±20% 이상 변하면 원인 후보(커밋 변경, 백그라운드 부하, 풀 설정)를 함께 제시.
7. 리포트에 옮길 수치면 `docs/reports/_template.md` 양식을 따르도록 안내.

## 주의

- 절대 수치는 상대 비교 목적임을 항상 명시 (k6+SUT 동일 머신).
- 시나리오 4종: smoke / issue-baseline(-e RATE=) / issue-spike / read-history. GC·전략·알림 실험은 scripts/의 전용 스크립트 사용.
