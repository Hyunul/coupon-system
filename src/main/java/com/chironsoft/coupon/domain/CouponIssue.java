package com.chironsoft.coupon.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.LocalDateTime;

@Entity
@Table(name = "coupon_issue")
public class CouponIssue {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "event_id", nullable = false)
    private Long eventId;

    @Column(name = "user_id", nullable = false)
    private Long userId;

    @Column(name = "issued_at", nullable = false, updatable = false)
    private LocalDateTime issuedAt;

    @Column(name = "notify_status", nullable = false, length = 20)
    private String notifyStatus;

    protected CouponIssue() {
    }

    public CouponIssue(Long eventId, Long userId, LocalDateTime issuedAt) {
        this.eventId = eventId;
        this.userId = userId;
        this.issuedAt = issuedAt;
        this.notifyStatus = "PENDING";
    }

    public Long getId() {
        return id;
    }

    public Long getEventId() {
        return eventId;
    }

    public Long getUserId() {
        return userId;
    }

    public LocalDateTime getIssuedAt() {
        return issuedAt;
    }

    public String getNotifyStatus() {
        return notifyStatus;
    }
}
