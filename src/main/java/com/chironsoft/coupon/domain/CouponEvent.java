package com.chironsoft.coupon.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.LocalDateTime;

@Entity
@Table(name = "coupon_event")
public class CouponEvent {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 100)
    private String name;

    @Column(name = "total_qty", nullable = false)
    private int totalQty;

    @Column(name = "issued_qty", nullable = false)
    private int issuedQty;

    @Column(name = "open_at", nullable = false)
    private LocalDateTime openAt;

    @Column(name = "close_at", nullable = false)
    private LocalDateTime closeAt;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private EventStatus status;

    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    protected CouponEvent() {
    }

    public CouponEvent(String name, int totalQty, LocalDateTime openAt, LocalDateTime closeAt, LocalDateTime now) {
        this.name = name;
        this.totalQty = totalQty;
        this.issuedQty = 0;
        this.openAt = openAt;
        this.closeAt = closeAt;
        this.status = EventStatus.READY;
        this.createdAt = now;
    }

    public boolean isOpen(LocalDateTime now) {
        return status == EventStatus.OPEN && !now.isBefore(openAt) && now.isBefore(closeAt);
    }

    public boolean isSoldOut() {
        return issuedQty >= totalQty;
    }

    public void increaseIssuedQty() {
        this.issuedQty++;
    }

    public void changeStatus(EventStatus status) {
        this.status = status;
    }

    public Long getId() {
        return id;
    }

    public String getName() {
        return name;
    }

    public int getTotalQty() {
        return totalQty;
    }

    public int getIssuedQty() {
        return issuedQty;
    }

    public LocalDateTime getOpenAt() {
        return openAt;
    }

    public LocalDateTime getCloseAt() {
        return closeAt;
    }

    public EventStatus getStatus() {
        return status;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }
}
