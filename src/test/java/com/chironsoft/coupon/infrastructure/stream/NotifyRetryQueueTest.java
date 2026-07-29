package com.chironsoft.coupon.infrastructure.stream;

import com.chironsoft.coupon.AbstractIntegrationTest;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestPropertySource;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.InetSocketAddress;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 알림 재시도 지연 큐(ZSET notify:retry)의 상태 전이 검증 — at-least-once 발송 계약.
 * 스텁 HTTP 서버의 성공/실패를 토글하며 RETRYING → SENT / FAILED_PERMANENT 전이를 확인한다.
 * 스트림 소비를 거치지 않고 큐에 직접 적재해 retryLoop만 겨냥한다(교차 오염 방지).
 */
@ActiveProfiles("worker")
@TestPropertySource(properties = {"spring.flyway.enabled=true"})
// 워커 컨텍스트를 클래스 종료 시 내린다 — 살아남은 retryLoop가 다른 테스트의 큐를 훔치는 것 방지
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
class NotifyRetryQueueTest extends AbstractIntegrationTest {

    static final String RETRY_KEY = "notify:retry";
    static final HttpServer STUB;
    static final AtomicBoolean HEALTHY = new AtomicBoolean(false);

    static {
        try {
            STUB = HttpServer.create(new InetSocketAddress(0), 0);
            STUB.createContext("/notify", exchange -> {
                exchange.sendResponseHeaders(HEALTHY.get() ? 200 : 500, -1);
                exchange.close();
            });
            STUB.start();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    @DynamicPropertySource
    static void notifyProps(DynamicPropertyRegistry r) {
        r.add("coupon.notify.enabled", () -> "true");
        r.add("coupon.notify.url", () -> "http://localhost:" + STUB.getAddress().getPort() + "/notify");
        r.add("coupon.notify.timeout-ms", () -> "1000");
    }

    @Autowired
    CouponIssueRepository issueRepository;

    @Autowired
    StringRedisTemplate redis;

    final Long eventId = 9_800L;

    @BeforeEach
    void clean() {
        HEALTHY.set(false);
        redis.delete(RETRY_KEY);
        issueRepository.deleteAll();
    }

    private CouponIssue savedIssue(Long userId) {
        return issueRepository.save(
                new CouponIssue(eventId, userId, LocalDateTime.now(ZoneOffset.UTC).withNano(0)));
    }

    private String notifyStatusOf(Long userId) {
        return issueRepository.findAll().stream()
                .filter(i -> i.getEventId().equals(eventId) && i.getUserId().equals(userId))
                .findFirst().map(CouponIssue::getNotifyStatus).orElse(null);
    }

    private boolean awaitStatus(Long userId, String expected, long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (expected.equals(notifyStatusOf(userId))) {
                return true;
            }
            Thread.sleep(300);
        }
        return false;
    }

    @Test
    @DisplayName("기한이 도래한 재시도는 발송 성공 시 SENT로 전이하고 큐에서 사라진다")
    void dueRetrySucceedsAndDrains() throws InterruptedException {
        HEALTHY.set(true);
        savedIssue(1L);
        redis.opsForZSet().add(RETRY_KEY, eventId + ":1:1", System.currentTimeMillis());

        assertThat(awaitStatus(1L, "SENT", 10_000)).as("재시도 발송이 SENT로 마킹돼야 함").isTrue();
        assertThat(redis.opsForZSet().size(RETRY_KEY)).isZero();
    }

    @Test
    @DisplayName("실패한 재시도는 다음 attempt로 지수 백오프 재적재되고, 복구되면 결국 SENT")
    void failedRetryReschedulesWithBackoff() throws InterruptedException {
        savedIssue(2L);
        redis.opsForZSet().add(RETRY_KEY, eventId + ":2:1", System.currentTimeMillis());

        // attempt 1 실패 → attempt 2로 재적재(RETRYING, +4s 백오프) 확인
        long deadline = System.currentTimeMillis() + 10_000;
        boolean rescheduled = false;
        while (System.currentTimeMillis() < deadline) {
            var members = redis.opsForZSet().range(RETRY_KEY, 0, -1);
            if (members != null && members.contains(eventId + ":2:2")) {
                rescheduled = true;
                break;
            }
            Thread.sleep(300);
        }
        assertThat(rescheduled).as("실패분이 attempt=2로 재적재돼야 함").isTrue();
        assertThat(notifyStatusOf(2L)).isEqualTo("RETRYING");

        // 외부 API 복구 → 백오프 기한 도래 후 SENT
        HEALTHY.set(true);
        assertThat(awaitStatus(2L, "SENT", 15_000)).as("복구 후 SENT로 전이해야 함").isTrue();
    }

    @Test
    @DisplayName("최대 시도(5회) 초과 실패는 FAILED_PERMANENT로 마킹된다 (수동 개입 대상)")
    void exhaustedRetriesMarkedPermanentFailure() throws InterruptedException {
        savedIssue(3L);
        redis.opsForZSet().add(RETRY_KEY, eventId + ":3:5", System.currentTimeMillis());

        assertThat(awaitStatus(3L, "FAILED_PERMANENT", 10_000))
                .as("attempt=5 실패는 영구 실패로 마킹돼야 함").isTrue();
        assertThat(redis.opsForZSet().size(RETRY_KEY)).isZero();
    }
}
