-- 부하테스트 리셋: 발급 이력 비우고 카운터 초기화 (이벤트 메타는 유지)
-- 주의: explain 튜닝용 데이터 누적 중에는 실행하지 말 것 (run-loadtest.ps1 -NoReset)
TRUNCATE TABLE coupon_issue;
UPDATE coupon_event SET issued_qty = 0 WHERE id = 1;
