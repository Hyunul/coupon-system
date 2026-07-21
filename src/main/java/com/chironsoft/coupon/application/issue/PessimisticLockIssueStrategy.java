package com.chironsoft.coupon.application.issue;

import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

@Component
public class PessimisticLockIssueStrategy implements IssueStrategy {

    private final CouponEventRepository eventRepository;
    private final CouponIssueRepository issueRepository;

    public PessimisticLockIssueStrategy(CouponEventRepository eventRepository,
                                        CouponIssueRepository issueRepository) {
        this.eventRepository = eventRepository;
        this.issueRepository = issueRepository;
    }

    @Override
    @Transactional
    public CouponIssue issue(Long eventId, Long userId) {
        CouponEvent event = eventRepository.findByIdForUpdate(eventId)
                .orElseThrow(() -> new BusinessException(ErrorCode.EVENT_NOT_FOUND));

        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        if (!event.isOpen(now)) {
            throw new BusinessException(ErrorCode.NOT_OPEN);
        }
        if (event.isSoldOut()) {
            throw new BusinessException(ErrorCode.SOLD_OUT);
        }
        try {
            // 사전 중복 SELECT 없이 uk_event_user 위반에 맡긴다 — DB가 최종 방어선(defense in depth)
            CouponIssue issue = issueRepository.saveAndFlush(new CouponIssue(eventId, userId, now));
            event.increaseIssuedQty();
            return issue;
        } catch (DataIntegrityViolationException e) {
            throw new BusinessException(ErrorCode.DUPLICATE_ISSUE);
        }
    }
}
