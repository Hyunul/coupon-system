package com.chironsoft.coupon.application.issue;

import com.chironsoft.coupon.application.CouponEventMetaCache;
import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * 전략 ③ Redis Lua 원자 스크립트 (roadmap 4.4 최종 채택안).
 * 임계 경로: Caffeine 메타 검사 → Lua 원자 판정. DB는 이력 INSERT만 (행 락 없음).
 * DB INSERT는 Phase 2에선 동기, Phase 3에서 Stream 소비 워커로 분리 예정.
 */
@Component("luaStrategy")
public class LuaScriptIssueStrategy implements IssueStrategy {

    private final CouponEventMetaCache metaCache;
    private final RedisStockStore stockStore;
    private final CouponIssueRepository issueRepository;
    private final boolean streamMode;

    public LuaScriptIssueStrategy(CouponEventMetaCache metaCache,
                                  RedisStockStore stockStore,
                                  CouponIssueRepository issueRepository,
                                  @Value("${coupon.record.mode:sync}") String recordMode) {
        this.metaCache = metaCache;
        this.stockStore = stockStore;
        this.issueRepository = issueRepository;
        this.streamMode = "stream".equals(recordMode);
    }

    @Override
    public CouponIssue issue(Long eventId, Long userId) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        if (!metaCache.get(eventId).isOpen(now)) {
            throw new BusinessException(ErrorCode.NOT_OPEN);
        }

        String result = streamMode
                ? stockStore.issueAtomicallyWithStream(eventId, userId, now.toString())
                : stockStore.issueAtomically(eventId, userId);
        switch (result) {
            case RedisStockStore.SOLD_OUT -> throw new BusinessException(ErrorCode.SOLD_OUT);
            case RedisStockStore.DUPLICATE -> throw new BusinessException(ErrorCode.DUPLICATE_ISSUE);
            case RedisStockStore.OK -> { /* fall through */ }
            default -> throw new IllegalStateException("unexpected lua result: " + result);
        }

        if (streamMode) {
            // 임계 경로에서 DB 완전 제거 — 이력 INSERT는 워커가 Stream을 소비하며 수행 (at-least-once,
            // 중복 소비는 uk_event_user가 무해화). 응답의 issueId는 null (기록은 최종적 일관성).
            return new CouponIssue(eventId, userId, now);
        }
        try {
            return issueRepository.save(new CouponIssue(eventId, userId, now));
        } catch (DataIntegrityViolationException e) {
            // Redis가 OK인데 DB 유니크 위반 = 두 저장소 불일치 신호. 최종 방어선이 막았으므로 DUPLICATE로 응답.
            throw new BusinessException(ErrorCode.DUPLICATE_ISSUE);
        }
    }
}
