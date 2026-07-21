CREATE TABLE coupon_event (
    id            BIGINT PRIMARY KEY AUTO_INCREMENT,
    name          VARCHAR(100) NOT NULL,
    total_qty     INT NOT NULL,
    issued_qty    INT NOT NULL DEFAULT 0,
    open_at       DATETIME(3) NOT NULL,
    close_at      DATETIME(3) NOT NULL,
    status        VARCHAR(20) NOT NULL,
    created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
);
