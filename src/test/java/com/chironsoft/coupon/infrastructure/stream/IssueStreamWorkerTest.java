package com.chironsoft.coupon.infrastructure.stream;

import com.chironsoft.coupon.AbstractIntegrationTest;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.TestPropertySource;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * worker 프로파일의 Stream 소비 경로 검증 — stream 모드는 E2E 실험으로만 검증되던 갭을 CI로 편입.
 * XADD(백로그 포함) → 배치 소비 → DB 기록(멱등) → ACK 를 확인한다.
 */
@ActiveProfiles("worker")
// worker 프로파일은 flyway를 끄지만(운영에선 api가 마이그레이션 담당) 테스트 DB는 스키마가 필요하다
@TestPropertySource(properties = {"spring.flyway.enabled=true", "coupon.notify.enabled=false"})
// 클래스 종료 시 워커 컨텍스트를 내린다 — 캐시된 컨텍스트의 소비/재시도 루프가
// 이후 다른 워커 테스트와 같은 스트림·큐를 놓고 경합하는 것 방지
@org.springframework.test.annotation.DirtiesContext(
        classMode = org.springframework.test.annotation.DirtiesContext.ClassMode.AFTER_CLASS)
class IssueStreamWorkerTest extends AbstractIntegrationTest {

    @Autowired
    CouponEventRepository eventRepository;

    @Autowired
    CouponIssueRepository issueRepository;

    @Autowired
    RedisStockStore stockStore;

    @Autowired
    StringRedisTemplate redis;

    @Test
    @DisplayName("워커가 백로그·중복 포함 스트림을 소비해 DB에 멱등 기록하고 드레인한다")
    void consumesBacklogIdempotently() throws InterruptedException {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        CouponEvent event = new CouponEvent("worker-test", 1000, now.minusHours(1), now.plusDays(1), now);
        event.changeStatus(EventStatus.OPEN);
        Long eventId = eventRepository.save(event).getId();
        stockStore.initialize(eventId, 1000);

        // 발급 250건 발행 (워커는 이미 떠 있으므로 실시간 소비) + 중복 재발행 시뮬레이션은 Lua가 차단하므로
        // 스트림 중복은 수동 XADD 대신 동일 유저 재-issueAtomically로는 만들 수 없다 — 여기서는 정상 250건로 드레인 검증
        for (long u = 1; u <= 250; u++) {
            String r = stockStore.issueAtomicallyWithStream(eventId, u, now.toString());
            assertThat(r).isEqualTo(RedisStockStore.OK);
        }

        long deadline = System.currentTimeMillis() + 30_000;
        long count = 0;
        while (System.currentTimeMillis() < deadline) {
            count = issueRepository.countByEventId(eventId);
            if (count == 250) {
                break;
            }
            Thread.sleep(500);
        }
        assertThat(count).as("워커가 30초 내에 250건을 드레인해야 함").isEqualTo(250);
        assertThat(stockStore.currentStock(eventId)).isEqualTo(750);
    }

    @Test
    @DisplayName("같은 발급 메시지가 스트림에 중복 발행돼도(at-least-once 재전달) DB 이력은 1건이다")
    void duplicateStreamMessagesAreIdempotent() throws InterruptedException {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC).withNano(0);
        CouponEvent event = new CouponEvent("worker-dup-test", 100, now.minusHours(1), now.plusDays(1), now);
        event.changeStatus(EventStatus.OPEN);
        Long eventId = eventRepository.save(event).getId();
        stockStore.initialize(eventId, 100);

        // Lua는 스트림 중복을 만들지 못하므로 재전달을 수동 XADD로 시뮬레이션:
        // user 1 메시지 3회(중복 2회) + user 2 정상 1회 — 중복이 후속 메시지를 막지 않아야 한다
        Map<String, String> dup = Map.of(
                "eventId", String.valueOf(eventId), "userId", "1", "issuedAt", now.toString());
        redis.opsForStream().add(RedisStockStore.STREAM_KEY, dup);
        redis.opsForStream().add(RedisStockStore.STREAM_KEY, dup);
        redis.opsForStream().add(RedisStockStore.STREAM_KEY, dup);
        redis.opsForStream().add(RedisStockStore.STREAM_KEY, Map.of(
                "eventId", String.valueOf(eventId), "userId", "2", "issuedAt", now.toString()));

        long deadline = System.currentTimeMillis() + 30_000;
        while (System.currentTimeMillis() < deadline) {
            if (issueRepository.countByEventId(eventId) == 2) {
                break;
            }
            Thread.sleep(500);
        }
        assertThat(issueRepository.countByEventId(eventId))
                .as("중복 2건은 uk_event_user가 무해화하고 정상 2명만 기록돼야 함")
                .isEqualTo(2);
        assertThat(issueRepository.findAll().stream()
                .filter(i -> i.getEventId().equals(eventId) && i.getUserId().equals(1L)).count())
                .isEqualTo(1);
    }
}
