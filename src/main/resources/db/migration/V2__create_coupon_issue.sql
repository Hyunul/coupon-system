CREATE TABLE coupon_issue (
    id            BIGINT PRIMARY KEY AUTO_INCREMENT,
    event_id      BIGINT NOT NULL,
    user_id       BIGINT NOT NULL,
    issued_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    notify_status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    UNIQUE KEY uk_event_user (event_id, user_id)
    -- 조회용 인덱스는 의도적으로 없음: Phase 1 explain 튜닝에서 풀스캔을 확인한 뒤
    -- V3 마이그레이션으로 추가한다 (roadmap 4.3 / 3.10 참조)
);
