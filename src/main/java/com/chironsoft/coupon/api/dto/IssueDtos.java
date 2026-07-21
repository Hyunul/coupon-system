package com.chironsoft.coupon.api.dto;

import com.chironsoft.coupon.domain.CouponIssue;

import java.time.LocalDateTime;
import java.util.List;

public final class IssueDtos {

    private IssueDtos() {
    }

    public record IssueResponse(Long issueId, Long eventId, Long userId, LocalDateTime issuedAt) {
        public static IssueResponse from(CouponIssue issue) {
            return new IssueResponse(issue.getId(), issue.getEventId(), issue.getUserId(), issue.getIssuedAt());
        }
    }

    public record PageResponse<T>(List<T> content, int page, int size, long totalElements) {
    }
}
