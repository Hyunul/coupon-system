package com.chironsoft.coupon.application;

import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import com.chironsoft.coupon.config.CacheInvalidationConfig;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

@Service
public class CouponEventService {

    private final CouponEventRepository eventRepository;
    private final RedisStockStore stockStore;
    private final CouponEventMetaCache metaCache;
    private final StringRedisTemplate redis;
    private final boolean redisStrategy;

    public CouponEventService(CouponEventRepository eventRepository,
                              RedisStockStore stockStore,
                              CouponEventMetaCache metaCache,
                              StringRedisTemplate redis,
                              @Value("${coupon.issue.strategy:pessimistic}") String strategyName) {
        this.eventRepository = eventRepository;
        this.stockStore = stockStore;
        this.metaCache = metaCache;
        this.redis = redis;
        this.redisStrategy = !"pessimistic".equals(strategyName);
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
        if (status == EventStatus.OPEN) {
            // Redis가 재고의 진실 — OPEN 시점에 잔여분으로 카운터/발급자 Set 초기화
            stockStore.initialize(eventId, event.getTotalQty() - event.getIssuedQty());
        }
        metaCache.invalidate(eventId);   // 로컬 즉시 무효화
        // 다른 인스턴스들은 pub/sub 브로드캐스트로 무효화 (CacheInvalidationConfig 리스너)
        redis.convertAndSend(CacheInvalidationConfig.CHANNEL, String.valueOf(eventId));
        return event;
    }

    @Transactional(readOnly = true)
    public int remaining(Long eventId) {
        if (redisStrategy) {
            long stock = stockStore.remaining(eventId);
            if (stock >= 0) {
                return (int) stock;
            }
            // Redis 키 유실 시 DB 폴백 (보수적 추정)
        }
        CouponEvent event = get(eventId);
        return Math.max(event.getTotalQty() - event.getIssuedQty(), 0);
    }
}
