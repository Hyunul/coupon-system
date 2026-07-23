package com.chironsoft.coupon.infrastructure.stream;

import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.data.domain.Range;
import org.springframework.data.redis.connection.stream.Consumer;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.ReadOffset;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.connection.stream.StreamReadOptions;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.util.retry.Retry;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * notify-worker: stream:issue 를 consumer group으로 소비해
 *  ① 발급 이력 DB INSERT (at-least-once — 중복 소비는 uk_event_user가 무해화)
 *  ② WebClient 비동기 알림 (timeout+retry — Phase 3a의 "타임아웃 없는 동기 호출" 장애의 교정)
 * 같은 아티팩트를 --spring.profiles.active=worker 로 별도 프로세스 실행 (모듈 분리는 Phase 5에서 재평가).
 */
@Component
@Profile("worker")
public class IssueStreamWorker {

    private static final Logger log = LoggerFactory.getLogger(IssueStreamWorker.class);
    private static final String GROUP = "workers";
    private static final String CONSUMER = "w1";

    private final StringRedisTemplate redis;
    private final CouponIssueRepository issueRepository;
    private final TransactionTemplate tx;
    private final WebClient webClient;
    private final boolean notifyEnabled;
    private final String notifyUrl;
    private final Duration notifyTimeout;

    private final ExecutorService loop = Executors.newSingleThreadExecutor(r -> new Thread(r, "issue-stream-worker"));
    private final AtomicBoolean running = new AtomicBoolean(false);

    public IssueStreamWorker(StringRedisTemplate redis,
                             CouponIssueRepository issueRepository,
                             TransactionTemplate tx,
                             @Value("${coupon.notify.enabled:false}") boolean notifyEnabled,
                             @Value("${coupon.notify.url:http://localhost:8090/notify}") String notifyUrl,
                             @Value("${coupon.notify.timeout-ms:5000}") long notifyTimeoutMs) {
        this.redis = redis;
        this.issueRepository = issueRepository;
        this.tx = tx;
        this.webClient = WebClient.create();
        this.notifyEnabled = notifyEnabled;
        this.notifyUrl = notifyUrl;
        this.notifyTimeout = Duration.ofMillis(notifyTimeoutMs);
    }

    @PostConstruct
    void start() {
        createGroupFromBeginning();
        running.set(true);
        loop.submit(this::consumeLoop);
        log.info("issue-stream worker started (notifyEnabled={}, url={})", notifyEnabled, notifyUrl);
    }

    @PreDestroy
    void stop() {
        running.set(false);
        loop.shutdownNow();
    }

    /**
     * 그룹을 스트림 처음(0)부터 생성한다. latest($)로 만들면 워커 기동 전에 쌓인 백로그를
     * 통째로 건너뛴다 — Phase 5 리허설에서 실측한 유실 버그의 수정 (at-least-once 보장).
     */
    private void createGroupFromBeginning() {
        try {
            redis.opsForStream().createGroup(RedisStockStore.STREAM_KEY, ReadOffset.from("0"), GROUP);
        } catch (Exception e) {
            log.info("consumer group 이미 존재: {}", e.getMessage());
        }
    }

    private void consumeLoop() {
        StreamReadOptions options = StreamReadOptions.empty().count(100).block(Duration.ofSeconds(2));
        while (running.get()) {
            try {
                List<MapRecord<String, Object, Object>> records = redis.opsForStream().read(
                        Consumer.from(GROUP, CONSUMER), options,
                        StreamOffset.create(RedisStockStore.STREAM_KEY, ReadOffset.lastConsumed()));
                if (records == null || records.isEmpty()) {
                    continue;
                }
                for (MapRecord<String, Object, Object> record : records) {
                    process(record);
                }
            } catch (Exception e) {
                if (running.get()) {
                    // DEL stream:issue 등으로 스트림이 재생성되면 consumer group도 소실된다(NOGROUP).
                    // 재생성하지 않으면 영원히 에러 루프 — Phase 5 chaos 리허설에서 실측한 버그의 수정.
                    if (String.valueOf(e).contains("NOGROUP") || String.valueOf(e.getMessage()).contains("NOGROUP")) {
                        log.warn("consumer group 소실 감지 — 재생성 후 재개");
                        createGroupFromBeginning();
                    } else {
                        log.error("stream consume error", e);
                    }
                    sleepQuietly();
                }
            }
        }
    }

    private void process(MapRecord<String, Object, Object> record) {
        Long eventId = Long.valueOf(String.valueOf(record.getValue().get("eventId")));
        Long userId = Long.valueOf(String.valueOf(record.getValue().get("userId")));
        LocalDateTime issuedAt = LocalDateTime.parse(String.valueOf(record.getValue().get("issuedAt")));

        try {
            issueRepository.save(new CouponIssue(eventId, userId, issuedAt));
        } catch (org.springframework.dao.DataIntegrityViolationException e) {
            // at-least-once 재소비 — 유니크 제약이 멱등성을 보장하므로 무시하고 ACK
        }
        redis.opsForStream().acknowledge(RedisStockStore.STREAM_KEY, GROUP, record.getId());

        if (notifyEnabled) {
            webClient.post().uri(notifyUrl).retrieve().toBodilessEntity()
                    .timeout(notifyTimeout)
                    .retryWhen(Retry.backoff(2, Duration.ofMillis(500)))
                    .subscribe(
                            ok -> markNotify(eventId, userId, "SENT"),
                            err -> {
                                log.warn("notify failed: event={} user={} cause={}", eventId, userId, err.toString());
                                markNotify(eventId, userId, "FAILED");
                            });
        }
    }

    private void markNotify(Long eventId, Long userId, String status) {
        try {
            tx.executeWithoutResult(s -> issueRepository.updateNotifyStatus(eventId, userId, status));
        } catch (Exception e) {
            log.warn("notify status update failed: {}", e.getMessage());
        }
    }

    private void sleepQuietly() {
        try {
            Thread.sleep(1000);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        }
    }
}
