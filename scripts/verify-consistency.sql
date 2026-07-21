-- 부하테스트 종료 후 정합성 검증: 세 값 모두 0 이어야 한다
-- over_issued  : 총량 초과 발급 수
-- duplicated   : 1인 2매 이상 사용자 수
-- qty_mismatch : coupon_event.issued_qty 와 실제 이력 수의 차이
SELECT
    GREATEST(
        (SELECT COUNT(*) FROM coupon_issue WHERE event_id = 1)
            - (SELECT total_qty FROM coupon_event WHERE id = 1),
        0
    ) AS over_issued,
    (SELECT COUNT(*) FROM (
        SELECT user_id FROM coupon_issue WHERE event_id = 1
        GROUP BY user_id HAVING COUNT(*) > 1
    ) d) AS duplicated,
    ABS(
        (SELECT issued_qty FROM coupon_event WHERE id = 1)
            - (SELECT COUNT(*) FROM coupon_issue WHERE event_id = 1)
    ) AS qty_mismatch;
