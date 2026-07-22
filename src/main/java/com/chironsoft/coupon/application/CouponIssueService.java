package com.chironsoft.coupon.application;

import com.chironsoft.coupon.application.issue.IssueStrategy;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;

@Service
public class CouponIssueService {

    private static final Logger log = LoggerFactory.getLogger(CouponIssueService.class);

    private final IssueStrategy issueStrategy;
    private final CouponIssueRepository issueRepository;

    /**
     * 전략은 프로퍼티로 선택 — 재빌드 없이 -Dcoupon.issue.strategy=lua 로 3전략 비교 (roadmap 4.4).
     * 빈 이름 = pessimistic | redisson | lua
     */
    public CouponIssueService(Map<String, IssueStrategy> strategies,
                              @Value("${coupon.issue.strategy:pessimistic}") String strategyName,
                              CouponIssueRepository issueRepository) {
        IssueStrategy selected = strategies.get(strategyName + "Strategy");
        if (selected == null) {
            throw new IllegalArgumentException(
                    "unknown coupon.issue.strategy: " + strategyName + " (available: " + strategies.keySet() + ")");
        }
        log.info("issue strategy = {}", strategyName);
        this.issueStrategy = selected;
        this.issueRepository = issueRepository;
    }

    public CouponIssue issue(Long eventId, Long userId) {
        return issueStrategy.issue(eventId, userId);
    }

    @Transactional(readOnly = true)
    public Page<CouponIssue> history(Long userId, int page, int size) {
        return issueRepository.findByUserId(userId,
                PageRequest.of(page, size, Sort.by(Sort.Direction.DESC, "issuedAt")));
    }
}
