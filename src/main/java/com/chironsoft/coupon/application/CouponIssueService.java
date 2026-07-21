package com.chironsoft.coupon.application;

import com.chironsoft.coupon.application.issue.IssueStrategy;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class CouponIssueService {

    private final IssueStrategy issueStrategy;
    private final CouponIssueRepository issueRepository;

    public CouponIssueService(IssueStrategy issueStrategy, CouponIssueRepository issueRepository) {
        this.issueStrategy = issueStrategy;
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
