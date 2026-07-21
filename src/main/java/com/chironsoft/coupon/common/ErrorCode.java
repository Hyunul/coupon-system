package com.chironsoft.coupon.common;

import org.springframework.http.HttpStatus;

public enum ErrorCode {
    EVENT_NOT_FOUND(HttpStatus.NOT_FOUND, "존재하지 않는 이벤트입니다."),
    NOT_OPEN(HttpStatus.BAD_REQUEST, "발급 가능한 상태가 아닙니다."),
    SOLD_OUT(HttpStatus.CONFLICT, "쿠폰이 모두 소진되었습니다."),
    DUPLICATE_ISSUE(HttpStatus.CONFLICT, "이미 발급받은 사용자입니다."),
    INVALID_REQUEST(HttpStatus.BAD_REQUEST, "요청이 올바르지 않습니다.");

    private final HttpStatus status;
    private final String defaultMessage;

    ErrorCode(HttpStatus status, String defaultMessage) {
        this.status = status;
        this.defaultMessage = defaultMessage;
    }

    public HttpStatus status() {
        return status;
    }

    public String defaultMessage() {
        return defaultMessage;
    }
}
