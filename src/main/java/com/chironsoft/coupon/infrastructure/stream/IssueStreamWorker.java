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
    /** 알림 재시도 지연 큐(ZSET): member=eventId:userId:attempt, score=재시도 예정 시각(ms) */
    private static final String RETRY_KEY = "notify:retry";
    private static final int MAX_ATTEMPTS = 5;
    private static final Duration RECLAIM_MIN_IDLE = Duration.ofSeconds(60);

    private final StringRedisTemplate redis;
    private final CouponIssueRepository issueRepository;
    private final TransactionTemplate tx;
    private final WebClient webClient;
    private final boolean notifyEnabled;
    private final String notifyUrl;
    private final Duration notifyTimeout;

    private final ExecutorService loop = Executors.newSingleThreadExecutor(r -> new Thread(r, "issue-stream-worker"));
    private final ExecutorService retryLoopExec = Executors.newSingleThreadExecutor(r -> new Thread(r, "notify-retry-worker"));
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
        retryLoopExec.submit(this::retryLoop);
        log.info("issue-stream worker started (notifyEnabled={}, url={})", notifyEnabled, notifyUrl);
    }

    @PreDestroy
    void stop() {
        running.set(false);
        loop.shutdownNow();
        retryLoopExec.shutdownNow();
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
        int cycle = 0;
        while (running.get()) {
            try {
                // 주기적으로(약 30s) 죽은 컨슈머의 pending 메시지를 회수해 at-least-once 완성
                if (++cycle % 15 == 0) {
                    reclaimStalePending();
                }
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
                                log.warn("notify failed → 재시도 큐 등록: event={} user={} cause={}",
                                        eventId, userId, err.toString());
                                scheduleRetry(eventId, userId, 1);
                            });
        }
    }

    /** 인라인 재시도 소진 후 지수 백오프 지연 큐(ZSET)에 등록 — at-least-once 발송 보장 (roadmap 2.2) */
    private void scheduleRetry(Long eventId, Long userId, int attempt) {
        long delayMs = (long) (Math.pow(2, attempt) * 1000);   // 2s, 4s, 8s, 16s, 32s
        redis.opsForZSet().add(RETRY_KEY, eventId + ":" + userId + ":" + attempt,
                System.currentTimeMillis() + delayMs);
        markNotify(eventId, userId, "RETRYING");
    }

    /** 지연 큐 소비: 기한 도래분을 ZREM으로 선점(다중 워커 안전) 후 재발송 */
    private void retryLoop() {
        while (running.get()) {
            try {
                var due = redis.opsForZSet().rangeByScore(RETRY_KEY, 0, System.currentTimeMillis(), 0, 10);
                if (due == null || due.isEmpty()) {
                    Thread.sleep(1000);
                    continue;
                }
                for (String member : due) {
                    Long removed = redis.opsForZSet().remove(RETRY_KEY, member);
                    if (removed == null || removed != 1L) {
                        continue;   // 다른 워커가 선점
                    }
                    String[] parts = member.split(":");
                    Long eventId = Long.valueOf(parts[0]);
                    Long userId = Long.valueOf(parts[1]);
                    int attempt = Integer.parseInt(parts[2]);
                    try {
                        webClient.post().uri(notifyUrl).retrieve().toBodilessEntity()
                                .timeout(notifyTimeout).block();
                        markNotify(eventId, userId, "SENT");
                        log.info("notify 재시도 성공: event={} user={} attempt={}", eventId, userId, attempt);
                    } catch (Exception e) {
                        if (attempt >= MAX_ATTEMPTS) {
                            markNotify(eventId, userId, "FAILED_PERMANENT");
                            log.error("notify 최종 실패(수동 개입 필요): event={} user={} attempts={}",
                                    eventId, userId, attempt);
                        } else {
                            scheduleRetry(eventId, userId, attempt + 1);
                        }
                    }
                }
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
            } catch (Exception e) {
                if (running.get()) {
                    log.error("retry loop error", e);
                    sleepQuietly();
                }
            }
        }
    }

    /** 60초 이상 미처리(pending)로 남은 메시지를 회수해 재처리 — 워커 급사 시 유실 방지 */
    private void reclaimStalePending() {
        try {
            org.springframework.data.redis.connection.stream.PendingMessages pending =
                    redis.opsForStream().pending(RedisStockStore.STREAM_KEY, GROUP,
                            org.springframework.data.domain.Range.unbounded(), 100);
            java.util.List<org.springframework.data.redis.connection.stream.RecordId> stale = new java.util.ArrayList<>();
            for (org.springframework.data.redis.connection.stream.PendingMessage pm : pending) {
                if (pm.getElapsedTimeSinceLastDelivery().compareTo(RECLAIM_MIN_IDLE) > 0) {
                    stale.add(pm.getId());
                }
            }
            if (stale.isEmpty()) {
                return;
            }
            List<MapRecord<String, Object, Object>> claimed = redis.opsForStream().claim(
                    RedisStockStore.STREAM_KEY, GROUP, CONSUMER, RECLAIM_MIN_IDLE,
                    stale.toArray(new org.springframework.data.redis.connection.stream.RecordId[0]));
            log.warn("stale pending {}건 회수 — 재처리", claimed.size());
            for (MapRecord<String, Object, Object> record : claimed) {
                process(record);
            }
        } catch (Exception e) {
            log.warn("pending 회수 실패(다음 주기 재시도): {}", e.getMessage());
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
