package com.chironsoft.coupon.infrastructure;

import com.chironsoft.coupon.domain.CouponIssue;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

public interface CouponIssueRepository extends JpaRepository<CouponIssue, Long> {

    Page<CouponIssue> findByUserId(Long userId, Pageable pageable);

    long countByEventId(Long eventId);
}
