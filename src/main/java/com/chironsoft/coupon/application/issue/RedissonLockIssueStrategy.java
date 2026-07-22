package com.chironsoft.coupon.application.issue;

import com.chironsoft.coupon.application.CouponEventMetaCache;
import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.concurrent.TimeUnit;

/**
 * 전략 ② Redisson 분산락 (roadmap 4.4).
 * 락을 잡은 뒤 검사→차감→등록을 수행한다. 락 자체가 병목이 되는 것을 실측하기 위한 전략.
 */
@Component("redissonStrategy")   // 이름 "redisson"은 Redisson 스타터의 빈과 충돌
public class RedissonLockIssueStrategy implements IssueStrategy {

    private static final long LOCK_WAIT_SEC = 5;
    private static final long LOCK_LEASE_SEC = 3;

    private final RedissonClient redisson;
    private final CouponEventMetaCache metaCache;
    private final RedisStockStore stockStore;
    private final CouponIssueRepository issueRepository;

    public RedissonLockIssueStrategy(RedissonClient redisson,
                                     CouponEventMetaCache metaCache,
                                     RedisStockStore stockStore,
                                     CouponIssueRepository issueRepository) {
        this.redisson = redisson;
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

        RLock lock = redisson.getLock("lock:issue:" + eventId);
        boolean locked = false;
        try {
            locked = lock.tryLock(LOCK_WAIT_SEC, LOCK_LEASE_SEC, TimeUnit.SECONDS);
            if (!locked) {
                throw new BusinessException(ErrorCode.LOCK_TIMEOUT);
            }
            if (stockStore.isIssued(eventId, userId)) {
                throw new BusinessException(ErrorCode.DUPLICATE_ISSUE);
            }
            if (stockStore.currentStock(eventId) <= 0) {
                throw new BusinessException(ErrorCode.SOLD_OUT);
            }
            stockStore.decrementAndRegister(eventId, userId);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new BusinessException(ErrorCode.LOCK_TIMEOUT);
        } finally {
            if (locked && lock.isHeldByCurrentThread()) {
                lock.unlock();
            }
        }

        try {
            return issueRepository.save(new CouponIssue(eventId, userId, now));
        } catch (DataIntegrityViolationException e) {
            throw new BusinessException(ErrorCode.DUPLICATE_ISSUE);
        }
    }
}
