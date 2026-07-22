package com.chironsoft.coupon.application;

import com.chironsoft.coupon.application.issue.IssueStrategy;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.chironsoft.coupon.infrastructure.notify.SyncNotifyClient;
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
    private final SyncNotifyClient notifyClient;

    public CouponIssueService(Map<String, IssueStrategy> strategies,
                              @Value("${coupon.issue.strategy:pessimistic}") String strategyName,
                              CouponIssueRepository issueRepository,
                              SyncNotifyClient notifyClient) {
        IssueStrategy selected = strategies.get(strategyName + "Strategy");
        if (selected == null) {
            throw new IllegalArgumentException(
                    "unknown coupon.issue.strategy: " + strategyName + " (available: " + strategies.keySet() + ")");
        }
        log.info("issue strategy = {}", strategyName);
        this.issueStrategy = selected;
        this.issueRepository = issueRepository;
        this.notifyClient = notifyClient;
    }

    public CouponIssue issue(Long eventId, Long userId) {
        CouponIssue issue = issueStrategy.issue(eventId, userId);
        // Phase 3a: 임계 경로 안의 동기 알림 — 외부 지연이 발급 p99로 전파되는 것을 재현하는 장치.
        // Phase 3b에서 Stream 소비 워커로 이동한다. (coupon.notify.enabled=false면 no-op)
        notifyClient.notifyIssued(eventId, userId);
        return issue;
    }

    @Transactional(readOnly = true)
    public Page<CouponIssue> history(Long userId, int page, int size) {
        return issueRepository.findByUserId(userId,
                PageRequest.of(page, size, Sort.by(Sort.Direction.DESC, "issuedAt")));
    }
}
