package com.chironsoft.coupon.application.issue;

import com.chironsoft.coupon.domain.CouponIssue;

/**
 * 재고 차감 전략 추상화.
 * Phase 1: MySQL 비관적 락 → Phase 2: Redisson 분산락, Redis Lua 원자 스크립트 구현체를 추가해
 * 동일 k6 시나리오로 3전략을 비교한다 (roadmap 4.4).
 */
public interface IssueStrategy {

    /**
     * @return 발급 성공 시 발급 이력
     * @throws com.chironsoft.coupon.common.BusinessException NOT_OPEN / SOLD_OUT / DUPLICATE_ISSUE / EVENT_NOT_FOUND
     */
    CouponIssue issue(Long eventId, Long userId);
}
