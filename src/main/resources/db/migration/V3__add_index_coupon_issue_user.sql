-- explain 튜닝 결과 (docs/reports/phase1-explain-tuning.md):
-- 이력 조회가 type=ALL 풀스캔(51만 행) + filesort → (user_id, issued_at) 복합 인덱스로
-- range 접근 + 정렬 제거. JPA가 전체 컬럼을 SELECT하므로 완전 커버링은 불가 —
-- PK 룩업이 남지만 사용자당 행 수가 적어(≤10) 비용 미미. 상세 근거는 리포트 참조.
CREATE INDEX idx_issue_user_issued_at ON coupon_issue (user_id, issued_at);
