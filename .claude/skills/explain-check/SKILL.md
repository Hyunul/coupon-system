---
name: explain-check
description: SQL/JPA 쿼리 변경 시 실행계획을 검사한다. 리포지토리 쿼리 추가·변경, "explain 확인", "실행계획" 요청 시 사용.
---

# 실행계획 검사

쿼리(또는 리포지토리 메서드가 생성할 SQL)를 실제 데이터가 있는 로컬 MySQL에서 검사한다.

## 절차

1. 대상 SQL 확정: JPA 파생 쿼리면 하이버네이트가 만들 SQL로 번역해 명시한다 (SELECT 컬럼 목록 포함 — 커버링 판단에 필수).
2. 실행 (mysql-explain MCP 서버가 연결돼 있으면 그 도구를, 아니면 직접):
   ```bash
   docker exec -e MYSQL_PWD=coupon coupon-mysql mysql -ucoupon coupon -e "EXPLAIN <SQL>; EXPLAIN ANALYZE <SQL>\G"
   ```
3. **판정 기준** (하나라도 걸리면 경고):
   - `type=ALL` (풀스캔) 또는 rows가 테이블 크기에 비례
   - `Extra: Using filesort` / `Using temporary`
   - EXPLAIN ANALYZE actual time이 요구 지연 예산(핫패스 1ms, 조회 10ms) 초과
4. 인덱스를 제안할 때는 반드시 함께 기록: (a) 등치/범위/정렬 컬럼 순서 근거, (b) 커버링 여부와 SELECT 컬럼의 관계(JPA 전체 컬럼 조회면 커버링 불가), (c) 쓰기 비용.
5. 스키마 변경은 **Flyway 마이그레이션으로만** (V<n>__*.sql). 실행계획 before를 리포트/커밋 메시지에 남긴 후 적용한다.

## 데이터 전제

coupon_issue에 51만 행 누적(bulk-history-data.sql). 행이 부족해 실행계획이 왜곡되면 그 사실을 명시하고 데이터 적재 후 재검사한다.

## 선례

docs/reports/phase1-explain-tuning.md — 풀스캔 110ms/43rps → (user_id, issued_at) 인덱스 0.04ms/300rps, 커버링을 의도적으로 보류한 판단 근거 포함.
