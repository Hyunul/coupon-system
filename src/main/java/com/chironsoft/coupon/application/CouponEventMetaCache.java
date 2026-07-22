package com.chironsoft.coupon.application;

import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.LocalDateTime;

/**
 * 쿠폰 메타데이터(오픈시각/상태) Caffeine 로컬캐시.
 * 변경이 드문 메타만 캐시하고 잔여 수량은 절대 넣지 않는다 (roadmap 4.5).
 * 무효화는 상태 전환 시 invalidate() — 다중 인스턴스 브로드캐스트(pub/sub)는 Phase 5에서.
 */
@Component
public class CouponEventMetaCache {

    public record EventMeta(Long id, int totalQty, LocalDateTime openAt, LocalDateTime closeAt, EventStatus status) {
        public boolean isOpen(LocalDateTime now) {
            return status == EventStatus.OPEN && !now.isBefore(openAt) && now.isBefore(closeAt);
        }
    }

    private final CouponEventRepository eventRepository;
    private final Cache<Long, EventMeta> cache = Caffeine.newBuilder()
            .maximumSize(10_000)
            .expireAfterWrite(Duration.ofSeconds(10))   // 무효화 누락 대비 안전망 TTL
            .recordStats()
            .build();

    public CouponEventMetaCache(CouponEventRepository eventRepository) {
        this.eventRepository = eventRepository;
    }

    public EventMeta get(Long eventId) {
        return cache.get(eventId, id -> eventRepository.findById(id)
                .map(this::toMeta)
                .orElseThrow(() -> new BusinessException(ErrorCode.EVENT_NOT_FOUND)));
    }

    /** reactive 경로용: 캐시 히트면 즉시 반환(논블로킹), 미스면 null — 호출측이 boundedElastic에서 get() 수행 */
    public EventMeta getIfCached(Long eventId) {
        return cache.getIfPresent(eventId);
    }

    public void invalidate(Long eventId) {
        cache.invalidate(eventId);
    }

    private EventMeta toMeta(CouponEvent e) {
        return new EventMeta(e.getId(), e.getTotalQty(), e.getOpenAt(), e.getCloseAt(), e.getStatus());
    }
}
