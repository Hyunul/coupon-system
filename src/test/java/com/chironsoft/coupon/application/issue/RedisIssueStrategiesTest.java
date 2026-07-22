package com.chironsoft.coupon.application.issue;

import com.chironsoft.coupon.AbstractIntegrationTest;
import com.chironsoft.coupon.application.CouponEventMetaCache;
import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Redis 기반 전략(Lua/Redisson)의 동시성 정합성 검증: 초과 발급 0, 중복 0 */
class RedisIssueStrategiesTest extends AbstractIntegrationTest {

    @Autowired
    @Qualifier("luaStrategy")
    IssueStrategy luaStrategy;

    @Autowired
    @Qualifier("redissonStrategy")
    IssueStrategy redissonStrategy;

    @Autowired
    CouponEventRepository eventRepository;

    @Autowired
    CouponIssueRepository issueRepository;

    @Autowired
    RedisStockStore stockStore;

    @Autowired
    CouponEventMetaCache metaCache;

    Long eventId;

    void createEvent(int stock) {
        issueRepository.deleteAll();
        eventRepository.deleteAll();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        CouponEvent event = new CouponEvent("redis-test", stock, now.minusHours(1), now.plusDays(1), now);
        event.changeStatus(EventStatus.OPEN);
        eventId = eventRepository.save(event).getId();
        stockStore.initialize(eventId, stock);
        metaCache.invalidate(eventId);
    }

    record Result(int success, int soldOut, int other) {
    }

    Result concurrentIssue(IssueStrategy strategy, int users) throws InterruptedException {
        ExecutorService pool = Executors.newFixedThreadPool(32);
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(users);
        AtomicInteger success = new AtomicInteger();
        AtomicInteger soldOut = new AtomicInteger();
        AtomicInteger other = new AtomicInteger();
        for (int i = 0; i < users; i++) {
            long userId = i + 1;
            pool.submit(() -> {
                try {
                    start.await();
                    strategy.issue(eventId, userId);
                    success.incrementAndGet();
                } catch (BusinessException e) {
                    if (e.getErrorCode() == ErrorCode.SOLD_OUT) soldOut.incrementAndGet();
                    else other.incrementAndGet();
                } catch (Exception e) {
                    other.incrementAndGet();
                } finally {
                    done.countDown();
                }
            });
        }
        start.countDown();
        assertThat(done.await(120, TimeUnit.SECONDS)).isTrue();
        pool.shutdown();
        return new Result(success.get(), soldOut.get(), other.get());
    }

    @Test
    @DisplayName("Lua 전략: 300명 동시 요청에도 100장만 발급, Redis 재고 0, DB 이력 100")
    void luaNoOverIssue() throws InterruptedException {
        createEvent(100);
        Result r = concurrentIssue(luaStrategy, 300);

        assertThat(r.success()).isEqualTo(100);
        assertThat(r.soldOut()).isEqualTo(200);
        assertThat(r.other()).isZero();
        assertThat(stockStore.currentStock(eventId)).isZero();
        assertThat(issueRepository.countByEventId(eventId)).isEqualTo(100);
    }

    @Test
    @DisplayName("Lua 전략: 같은 사용자 재요청은 DUPLICATE, 이력은 1건")
    void luaDuplicateRejected() {
        createEvent(10);
        luaStrategy.issue(eventId, 7L);

        assertThatThrownBy(() -> luaStrategy.issue(eventId, 7L))
                .isInstanceOf(BusinessException.class)
                .extracting(e -> ((BusinessException) e).getErrorCode())
                .isEqualTo(ErrorCode.DUPLICATE_ISSUE);
        assertThat(issueRepository.countByEventId(eventId)).isEqualTo(1);
    }

    @Test
    @DisplayName("Redisson 전략: 150명 동시 요청에도 50장만 발급")
    void redissonNoOverIssue() throws InterruptedException {
        createEvent(50);
        Result r = concurrentIssue(redissonStrategy, 150);

        assertThat(r.success()).isEqualTo(50);
        assertThat(r.soldOut()).isEqualTo(100);
        assertThat(r.other()).isZero();
        assertThat(stockStore.currentStock(eventId)).isZero();
        assertThat(issueRepository.countByEventId(eventId)).isEqualTo(50);
    }
}
