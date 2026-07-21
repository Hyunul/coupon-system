package com.chironsoft.coupon.application.issue;

import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.MySQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 비관적 락 발급의 정합성 검증 (Testcontainers MySQL).
 * 초과 발급 0건 / 중복 발급 0건이 이 프로젝트의 핵심 불변식이다.
 */
@SpringBootTest
@Testcontainers
class PessimisticLockIssueStrategyTest {

    @Container
    @ServiceConnection
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.0");

    @Autowired
    IssueStrategy issueStrategy;

    @Autowired
    CouponEventRepository eventRepository;

    @Autowired
    CouponIssueRepository issueRepository;

    @Autowired
    TransactionTemplate tx;

    Long eventId;

    @BeforeEach
    void setUp() {
        issueRepository.deleteAll();
        eventRepository.deleteAll();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        CouponEvent event = new CouponEvent("test", 100, now.minusHours(1), now.plusDays(1), now);
        event.changeStatus(EventStatus.OPEN);
        eventId = eventRepository.save(event).getId();
    }

    @Test
    @DisplayName("300명이 동시에 요청해도 총량 100장을 초과 발급하지 않는다")
    void noOverIssueUnderConcurrency() throws InterruptedException {
        int users = 300;
        ExecutorService pool = Executors.newFixedThreadPool(32);
        CountDownLatch ready = new CountDownLatch(users);
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(users);
        AtomicInteger success = new AtomicInteger();
        AtomicInteger soldOut = new AtomicInteger();

        for (int i = 0; i < users; i++) {
            long userId = i + 1;
            pool.submit(() -> {
                ready.countDown();
                try {
                    start.await();
                    issueStrategy.issue(eventId, userId);
                    success.incrementAndGet();
                } catch (BusinessException e) {
                    if (e.getErrorCode() == ErrorCode.SOLD_OUT) {
                        soldOut.incrementAndGet();
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    done.countDown();
                }
            });
        }
        ready.await(10, TimeUnit.SECONDS);
        start.countDown();
        assertThat(done.await(60, TimeUnit.SECONDS)).isTrue();
        pool.shutdown();

        assertThat(success.get()).isEqualTo(100);
        assertThat(soldOut.get()).isEqualTo(200);
        assertThat(issueRepository.countByEventId(eventId)).isEqualTo(100);
        assertThat(eventRepository.findById(eventId).orElseThrow().getIssuedQty()).isEqualTo(100);
    }

    @Test
    @DisplayName("같은 사용자가 두 번 요청하면 DUPLICATE_ISSUE로 거절되고 이력은 1건만 남는다")
    void duplicateIssueRejected() {
        issueStrategy.issue(eventId, 7L);

        assertThatThrownBy(() -> issueStrategy.issue(eventId, 7L))
                .isInstanceOf(BusinessException.class)
                .extracting(e -> ((BusinessException) e).getErrorCode())
                .isEqualTo(ErrorCode.DUPLICATE_ISSUE);

        assertThat(issueRepository.countByEventId(eventId)).isEqualTo(1);
        assertThat(eventRepository.findById(eventId).orElseThrow().getIssuedQty()).isEqualTo(1);
    }

    @Test
    @DisplayName("OPEN 상태가 아니면 NOT_OPEN으로 거절된다")
    void notOpenRejected() {
        tx.executeWithoutResult(s -> eventRepository.findById(eventId).orElseThrow()
                .changeStatus(EventStatus.READY));

        assertThatThrownBy(() -> issueStrategy.issue(eventId, 1L))
                .isInstanceOf(BusinessException.class)
                .extracting(e -> ((BusinessException) e).getErrorCode())
                .isEqualTo(ErrorCode.NOT_OPEN);
    }
}
