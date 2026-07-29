-- Event-scoped AWS consistency evidence.  Set @event_id in this mysql session before sourcing.
-- coupon_event.issued_qty is informational in stream mode because Async IssueRecordWriter does not update it.
-- This query always returns one diagnostic row; missing or invalid input is never a pass.
SELECT
    input.event_id AS event_id,
    input.input_valid,
    MAX(e.id IS NOT NULL) AS event_found,
    COUNT(ci.id) AS issued_count,
    COUNT(DISTINCT ci.user_id) AS distinct_user_count,
    COUNT(ci.id) - COUNT(DISTINCT ci.user_id) AS duplicate_issue_count,
    MAX(e.total_qty) AS total_qty,
    MAX(e.issued_qty) AS informational_event_issued_qty,
    CASE
        WHEN input.input_valid = 1 AND MAX(e.id IS NOT NULL) = 1 AND COUNT(ci.id) <= MAX(e.total_qty) THEN 1
        ELSE 0
    END AS issued_count_within_total_qty,
    CASE
        WHEN input.input_valid = 1 AND MAX(e.id IS NOT NULL) = 1 AND COUNT(ci.id) = COUNT(DISTINCT ci.user_id) THEN 1
        ELSE 0
    END AS duplicate_issue_count_is_zero
FROM (
    SELECT
        CASE
            WHEN @event_id IS NOT NULL
             AND CAST(@event_id AS CHAR) REGEXP '^[1-9][0-9]*$'
             AND CAST(@event_id AS UNSIGNED) <= 9223372036854775807
            THEN 1 ELSE 0
        END AS input_valid,
        CASE
            WHEN @event_id IS NOT NULL
             AND CAST(@event_id AS CHAR) REGEXP '^[1-9][0-9]*$'
             AND CAST(@event_id AS UNSIGNED) <= 9223372036854775807
            THEN CAST(@event_id AS UNSIGNED) ELSE NULL
        END AS event_id
) AS input
LEFT JOIN coupon_event e ON e.id = input.event_id
LEFT JOIN coupon_issue ci ON ci.event_id = e.id
GROUP BY input.event_id, input.input_valid;
