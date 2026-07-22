package com.chironsoft.coupon.infrastructure.redis;

import org.springframework.core.io.ClassPathResource;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.scripting.support.ResourceScriptSource;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * Redis 재고/발급자 저장소. 키 규칙: stock:{eventId}, issued:{eventId}
 * Redis가 재고의 진실(source of truth)이며 MySQL coupon_issue는 이력·최종 방어선이다 (roadmap 4.4).
 */
@Component
public class RedisStockStore {

    public static final String OK = "OK";
    public static final String SOLD_OUT = "SOLD_OUT";
    public static final String DUPLICATE = "DUPLICATE";

    public static final String STREAM_KEY = "stream:issue";

    private final StringRedisTemplate redis;
    private final DefaultRedisScript<String> issueScript;
    private final DefaultRedisScript<String> issueStreamScript;

    public RedisStockStore(StringRedisTemplate redis) {
        this.redis = redis;
        this.issueScript = script("redis/issue.lua");
        this.issueStreamScript = script("redis/issue-stream.lua");
    }

    private static DefaultRedisScript<String> script(String path) {
        DefaultRedisScript<String> s = new DefaultRedisScript<>();
        s.setScriptSource(new ResourceScriptSource(new ClassPathResource(path)));
        s.setResultType(String.class);
        return s;
    }

    public static String stockKey(Long eventId) {
        return "stock:" + eventId;
    }

    public static String issuedKey(Long eventId) {
        return "issued:" + eventId;
    }

    /** 이벤트 OPEN 시 재고 카운터/발급자 Set 초기화 */
    public void initialize(Long eventId, int stock) {
        redis.delete(issuedKey(eventId));
        redis.opsForValue().set(stockKey(eventId), String.valueOf(stock));
    }

    /** 검사+차감+등록을 단일 Lua 스크립트로 원자 실행 → OK / SOLD_OUT / DUPLICATE */
    public String issueAtomically(Long eventId, Long userId) {
        return redis.execute(issueScript,
                List.of(stockKey(eventId), issuedKey(eventId)),
                String.valueOf(userId));
    }

    /** Phase 3b: 검사+차감+등록+XADD(발급 이벤트 발행)까지 원자 실행. DB 기록은 워커가 소비 */
    public String issueAtomicallyWithStream(Long eventId, Long userId, String issuedAtIso) {
        return redis.execute(issueStreamScript,
                List.of(stockKey(eventId), issuedKey(eventId), STREAM_KEY),
                String.valueOf(userId), String.valueOf(eventId), issuedAtIso);
    }

    /** Redisson 전략용 비원자 연산들 — 분산락 안에서만 호출할 것 */
    public boolean isIssued(Long eventId, Long userId) {
        return Boolean.TRUE.equals(redis.opsForSet().isMember(issuedKey(eventId), String.valueOf(userId)));
    }

    public long currentStock(Long eventId) {
        String v = redis.opsForValue().get(stockKey(eventId));
        return v == null ? -1 : Long.parseLong(v);
    }

    public void decrementAndRegister(Long eventId, Long userId) {
        redis.opsForValue().decrement(stockKey(eventId));
        redis.opsForSet().add(issuedKey(eventId), String.valueOf(userId));
    }

    /** 잔여 수량 (키 없으면 -1: 호출측이 DB 폴백) */
    public long remaining(Long eventId) {
        return currentStock(eventId);
    }
}
