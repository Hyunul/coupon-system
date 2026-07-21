-- explain 튜닝(read-history) 실험용 대량 이력 적재
-- 부하테스트만으로는 이벤트당 재고 상한(1만) 때문에 수십만 행을 만들 수 없어,
-- 읽기 경로 인덱스 실험 목적에 한해 SQL로 이력을 합성한다 (리포트에 명시할 것).
-- 이벤트 101~105 (각 10만 명, 총 50만 행) — 부하테스트용 event 1과 분리
SET SESSION cte_max_recursion_depth = 100000;

INSERT INTO coupon_event (id, name, total_qty, issued_qty, open_at, close_at, status)
SELECT n, CONCAT('bulk-event-', n), 100000, 100000,
       DATE_SUB(UTC_TIMESTAMP(3), INTERVAL 30 DAY),
       DATE_SUB(UTC_TIMESTAMP(3), INTERVAL 1 DAY), 'CLOSED'
FROM (SELECT 101 n UNION SELECT 102 UNION SELECT 103 UNION SELECT 104 UNION SELECT 105) e
ON DUPLICATE KEY UPDATE name = VALUES(name);

INSERT IGNORE INTO coupon_issue (event_id, user_id, issued_at, notify_status)
WITH RECURSIVE seq (u) AS (
    SELECT 1 UNION ALL SELECT u + 1 FROM seq WHERE u < 100000
)
SELECT ev.n, seq.u,
       DATE_SUB(UTC_TIMESTAMP(3), INTERVAL (seq.u MOD 43200) MINUTE),
       'SENT'
FROM seq
JOIN (SELECT 101 n UNION SELECT 102 UNION SELECT 103 UNION SELECT 104 UNION SELECT 105) ev;

SELECT COUNT(*) AS total_issue_rows FROM coupon_issue;
