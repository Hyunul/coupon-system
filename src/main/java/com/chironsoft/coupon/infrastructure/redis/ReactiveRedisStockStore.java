package com.chironsoft.coupon.infrastructure.redis;

import org.springframework.context.annotation.Profile;
import org.springframework.core.io.ClassPathResource;
import org.springframework.data.redis.core.ReactiveStringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.scripting.support.ResourceScriptSource;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;

import java.util.List;

/**
 * reactive 프로파일용 논블로킹 재고 판정 — 이벤트 루프를 절대 블로킹하지 않는다.
 * 키/스크립트는 블로킹 구현(RedisStockStore)과 동일: stock:{id}, issued:{id}, stream:issue
 */
@Component
@Profile("reactive")
public class ReactiveRedisStockStore {

    private final ReactiveStringRedisTemplate redis;
    private final DefaultRedisScript<String> issueStreamScript;

    public ReactiveRedisStockStore(ReactiveStringRedisTemplate redis) {
        this.redis = redis;
        this.issueStreamScript = new DefaultRedisScript<>();
        this.issueStreamScript.setScriptSource(
                new ResourceScriptSource(new ClassPathResource("redis/issue-stream.lua")));
        this.issueStreamScript.setResultType(String.class);
    }

    /** 검사+차감+등록+XADD 원자 실행 → Mono(OK / SOLD_OUT / DUPLICATE) */
    public Mono<String> issueAtomicallyWithStream(Long eventId, Long userId, String issuedAtIso) {
        return redis.execute(issueStreamScript,
                        List.of(RedisStockStore.stockKey(eventId), RedisStockStore.issuedKey(eventId),
                                RedisStockStore.STREAM_KEY),
                        List.of(String.valueOf(userId), String.valueOf(eventId), issuedAtIso))
                .single();
    }
}
