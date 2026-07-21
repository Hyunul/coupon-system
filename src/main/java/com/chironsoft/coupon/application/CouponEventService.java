package com.chironsoft.coupon.application;

import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

@Service
public class CouponEventService {

    private final CouponEventRepository eventRepository;

    public CouponEventService(CouponEventRepository eventRepository) {
        this.eventRepository = eventRepository;
    }

    @Transactional
    public CouponEvent create(String name, int totalQty, LocalDateTime openAt, LocalDateTime closeAt) {
        CouponEvent event = new CouponEvent(name, totalQty, openAt, closeAt, LocalDateTime.now(ZoneOffset.UTC));
        return eventRepository.save(event);
    }

    @Transactional(readOnly = true)
    public CouponEvent get(Long eventId) {
        return eventRepository.findById(eventId)
                .orElseThrow(() -> new BusinessException(ErrorCode.EVENT_NOT_FOUND));
    }

    @Transactional
    public CouponEvent changeStatus(Long eventId, EventStatus status) {
        CouponEvent event = eventRepository.findById(eventId)
                .orElseThrow(() -> new BusinessException(ErrorCode.EVENT_NOT_FOUND));
        event.changeStatus(status);
        return event;
    }

    @Transactional(readOnly = true)
    public int remaining(Long eventId) {
        CouponEvent event = get(eventId);
        return Math.max(event.getTotalQty() - event.getIssuedQty(), 0);
    }
}
