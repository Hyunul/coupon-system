-- 부하테스트용 이벤트 시드: id=1, 재고 10,000, 즉시 OPEN
-- 실행: Get-Content scripts/seed-event.sql -Raw | docker exec -i coupon-mysql mysql -ucoupon -pcoupon coupon
DELETE FROM coupon_issue WHERE event_id = 1;
DELETE FROM coupon_event WHERE id = 1;
INSERT INTO coupon_event (id, name, total_qty, issued_qty, open_at, close_at, status)
VALUES (1, 'loadtest-event', 10000, 0,
        DATE_SUB(UTC_TIMESTAMP(3), INTERVAL 1 HOUR),
        DATE_ADD(UTC_TIMESTAMP(3), INTERVAL 30 DAY),
        'OPEN');
