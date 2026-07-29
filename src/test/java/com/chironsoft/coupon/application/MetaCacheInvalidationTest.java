package com.chironsoft.coupon.application;

import com.chironsoft.coupon.AbstractIntegrationTest;
import com.chironsoft.coupon.config.CacheInvalidationConfig;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 메타 캐시 pub/sub 무효화 검증 — 다중 인스턴스에서 상태 전환이 TTL(10s)을 기다리지 않고
 * 전 인스턴스에 반영되는 경로. 잘못된 메시지가 리스너를 죽이지 않는 것도 계약이다.
 */
class MetaCacheInvalidationTest extends AbstractIntegrationTest {

    @Autowired
    CouponEventMetaCache metaCache;

    @Autowired
    CouponEventRepository eventRepository;

    @Autowired
    CouponIssueRepository issueRepository;

    @Autowired
    StringRedisTemplate redis;

    private Long createOpenEvent() {
        issueRepository.deleteAll();
        eventRepository.deleteAll();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        CouponEvent event = new CouponEvent("cache-test", 10, now.minusHours(1), now.plusDays(1), now);
        event.changeStatus(EventStatus.OPEN);
        return eventRepository.save(event).getId();
    }

    private boolean awaitCachedStatus(Long eventId, EventStatus expected, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (metaCache.get(eventId).status() == expected) {
                return true;
            }
            Thread.sleep(100);
        }
        return false;
    }

    @Test
    @DisplayName("pub/sub 메시지가 캐시를 무효화해 DB의 새 상태가 TTL 전에 반영된다")
    void pubSubInvalidatesCache() throws InterruptedException {
        Long eventId = createOpenEvent();
        assertThat(metaCache.get(eventId).status()).isEqualTo(EventStatus.OPEN);   // 캐시 적재

        CouponEvent event = eventRepository.findById(eventId).orElseThrow();
        event.changeStatus(EventStatus.CLOSED);
        eventRepository.save(event);

        // 무효화 전에는 캐시된 옛 상태가 보여야 캐시가 실재함이 증명된다
        assertThat(metaCache.get(eventId).status()).isEqualTo(EventStatus.OPEN);

        redis.convertAndSend(CacheInvalidationConfig.CHANNEL, String.valueOf(eventId));

        assertThat(awaitCachedStatus(eventId, EventStatus.CLOSED, 3_000))
                .as("pub/sub 무효화가 3초 내 반영돼야 함 (TTL 10s 미대기)").isTrue();
    }

    @Test
    @DisplayName("숫자가 아닌 메시지는 무시되고 리스너는 계속 동작한다")
    void malformedMessageDoesNotKillListener() throws InterruptedException {
        Long eventId = createOpenEvent();
        assertThat(metaCache.get(eventId).status()).isEqualTo(EventStatus.OPEN);

        redis.convertAndSend(CacheInvalidationConfig.CHANNEL, "not-a-number");

        CouponEvent event = eventRepository.findById(eventId).orElseThrow();
        event.changeStatus(EventStatus.CLOSED);
        eventRepository.save(event);
        redis.convertAndSend(CacheInvalidationConfig.CHANNEL, String.valueOf(eventId));

        assertThat(awaitCachedStatus(eventId, EventStatus.CLOSED, 3_000))
                .as("깨진 메시지 이후에도 정상 무효화가 동작해야 함").isTrue();
    }
}
