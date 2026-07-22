package com.chironsoft.coupon.infrastructure;

import com.chironsoft.coupon.domain.CouponIssue;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface CouponIssueRepository extends JpaRepository<CouponIssue, Long> {

    Page<CouponIssue> findByUserId(Long userId, Pageable pageable);

    long countByEventId(Long eventId);

    @Modifying
    @Query("update CouponIssue i set i.notifyStatus = :status where i.eventId = :eventId and i.userId = :userId")
    int updateNotifyStatus(@Param("eventId") Long eventId, @Param("userId") Long userId, @Param("status") String status);
}
