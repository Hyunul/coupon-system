package com.chironsoft.coupon.application.issue;

import com.chironsoft.coupon.application.CouponEventMetaCache;
import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
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

    public LuaScriptIssueStrategy(CouponEventMetaCache metaCache,
                                  RedisStockStore stockStore,
                                  CouponIssueRepository issueRepository) {
        this.metaCache = metaCache;
        this.stockStore = stockStore;
        this.issueRepository = issueRepository;
    }

    @Override
    public CouponIssue issue(Long eventId, Long userId) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        if (!metaCache.get(eventId).isOpen(now)) {
            throw new BusinessException(ErrorCode.NOT_OPEN);
        }

        String result = stockStore.issueAtomically(eventId, userId);
        switch (result) {
            case RedisStockStore.SOLD_OUT -> throw new BusinessException(ErrorCode.SOLD_OUT);
            case RedisStockStore.DUPLICATE -> throw new BusinessException(ErrorCode.DUPLICATE_ISSUE);
            case RedisStockStore.OK -> { /* fall through */ }
            default -> throw new IllegalStateException("unexpected lua result: " + result);
        }

        try {
            return issueRepository.save(new CouponIssue(eventId, userId, now));
        } catch (DataIntegrityViolationException e) {
            // Redis가 OK인데 DB 유니크 위반 = 두 저장소 불일치 신호. 최종 방어선이 막았으므로 DUPLICATE로 응답.
            throw new BusinessException(ErrorCode.DUPLICATE_ISSUE);
        }
    }
}
