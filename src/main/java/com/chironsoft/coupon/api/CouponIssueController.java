package com.chironsoft.coupon.api;

import com.chironsoft.coupon.api.dto.IssueDtos.IssueResponse;
import com.chironsoft.coupon.api.dto.IssueDtos.PageResponse;
import com.chironsoft.coupon.application.CouponIssueService;
import com.chironsoft.coupon.domain.CouponIssue;
import org.springframework.data.domain.Page;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class CouponIssueController {

    private final CouponIssueService issueService;

    public CouponIssueController(CouponIssueService issueService) {
        this.issueService = issueService;
    }

    /** 핵심 FCFS 발급. 인증 대신 X-USER-ID 헤더를 신뢰한다(부하테스트 편의, roadmap 범위 통제). */
    @PostMapping("/api/v1/events/{eventId}/issues")
    public ResponseEntity<IssueResponse> issue(@PathVariable Long eventId,
                                               @RequestHeader("X-USER-ID") Long userId) {
        CouponIssue issue = issueService.issue(eventId, userId);
        return ResponseEntity.status(HttpStatus.CREATED).body(IssueResponse.from(issue));
    }

    /** 발급 이력 조회 — 의도적으로 인덱스 없이 시작하는 explain 튜닝 대상 (roadmap Phase 1). */
    @GetMapping("/api/v1/users/{userId}/issues")
    public PageResponse<IssueResponse> history(@PathVariable Long userId,
                                               @RequestParam(defaultValue = "0") int page,
                                               @RequestParam(defaultValue = "20") int size) {
        Page<CouponIssue> result = issueService.history(userId, page, size);
        return new PageResponse<>(
                result.getContent().stream().map(IssueResponse::from).toList(),
                result.getNumber(), result.getSize(), result.getTotalElements());
    }
}
