package com.chironsoft.coupon.config;

import com.chironsoft.coupon.application.CouponEventMetaCache;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;

import java.nio.charset.StandardCharsets;

/**
 * 다중 인스턴스 로컬캐시 무효화 (roadmap 4.5의 고전적 난제).
 * 상태 전환 시 Redis pub/sub으로 전 인스턴스에 브로드캐스트한다 —
 * Phase 5 리허설에서 확인한 "다른 인스턴스는 10s TTL 의존" 문제의 해소.
 */
@Configuration
public class CacheInvalidationConfig {

    private static final Logger log = LoggerFactory.getLogger(CacheInvalidationConfig.class);
    public static final String CHANNEL = "coupon:meta:invalidate";

    @Bean
    public RedisMessageListenerContainer metaInvalidationContainer(RedisConnectionFactory connectionFactory,
                                                                   CouponEventMetaCache metaCache) {
        RedisMessageListenerContainer container = new RedisMessageListenerContainer();
        container.setConnectionFactory(connectionFactory);
        container.addMessageListener((message, pattern) -> {
            try {
                Long eventId = Long.valueOf(new String(message.getBody(), StandardCharsets.UTF_8));
                metaCache.invalidate(eventId);
                log.info("meta invalidated via pub/sub: event={}", eventId);
            } catch (NumberFormatException e) {
                log.warn("invalid invalidation message: {}", new String(message.getBody(), StandardCharsets.UTF_8));
            }
        }, new ChannelTopic(CHANNEL));
        return container;
    }
}
