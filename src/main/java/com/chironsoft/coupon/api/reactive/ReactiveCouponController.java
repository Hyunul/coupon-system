package com.chironsoft.coupon.api.reactive;

import com.chironsoft.coupon.api.dto.EventDtos.CreateRequest;
import com.chironsoft.coupon.api.dto.EventDtos.EventResponse;
import com.chironsoft.coupon.api.dto.EventDtos.RemainingResponse;
import com.chironsoft.coupon.api.dto.EventDtos.StatusRequest;
import com.chironsoft.coupon.api.dto.IssueDtos.IssueResponse;
import com.chironsoft.coupon.api.dto.IssueDtos.PageResponse;
import com.chironsoft.coupon.application.CouponEventMetaCache;
import com.chironsoft.coupon.application.CouponEventService;
import com.chironsoft.coupon.common.BusinessException;
import com.chironsoft.coupon.common.ErrorCode;
import com.chironsoft.coupon.infrastructure.redis.ReactiveRedisStockStore;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
import jakarta.validation.Valid;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.r2dbc.core.DatabaseClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * reactive(Netty) 프로파일 전용 컨트롤러.
 * - 발급(핫패스): Caffeine 히트 시 완전 논블로킹 → ReactiveRedis Lua 원자 판정+XADD. DB 무접촉.
 * - 이력 조회: R2DBC(DatabaseClient) 논블로킹.
 * - 이벤트 CRUD/상태 전환(저빈도): 기존 블로킹 서비스를 boundedElastic에 위임 — 전환기 전략.
 */
@RestController
@Profile("reactive")
@RequestMapping("/api/v1")
public class ReactiveCouponController {

    private final CouponEventMetaCache metaCache;
    private final ReactiveRedisStockStore reactiveStockStore;
    private final CouponEventService eventService;
    private final DatabaseClient db;

    public ReactiveCouponController(CouponEventMetaCache metaCache,
                                    ReactiveRedisStockStore reactiveStockStore,
                                    CouponEventService eventService,
                                    DatabaseClient db) {
        this.metaCache = metaCache;
        this.reactiveStockStore = reactiveStockStore;
        this.eventService = eventService;
        this.db = db;
    }

    // ---------- 발급 (핫패스, 논블로킹) ----------

    @PostMapping("/events/{eventId}/issues")
    public Mono<ResponseEntity<IssueResponse>> issue(@PathVariable Long eventId,
                                                     @RequestHeader("X-USER-ID") Long userId) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        return meta(eventId)
                .flatMap(meta -> {
                    if (!meta.isOpen(now)) {
                        return Mono.error(new BusinessException(ErrorCode.NOT_OPEN));
                    }
                    return reactiveStockStore.issueAtomicallyWithStream(eventId, userId, now.toString());
                })
                .flatMap(result -> switch (result) {
                    case RedisStockStore.OK -> Mono.just(ResponseEntity.status(HttpStatus.CREATED)
                            .body(new IssueResponse(null, eventId, userId, now)));
                    case RedisStockStore.SOLD_OUT -> Mono.error(new BusinessException(ErrorCode.SOLD_OUT));
                    case RedisStockStore.DUPLICATE -> Mono.error(new BusinessException(ErrorCode.DUPLICATE_ISSUE));
                    default -> Mono.error(new IllegalStateException("unexpected lua result: " + result));
                });
    }

    /** 캐시 히트면 논블로킹, 미스(10s TTL 만료)면 boundedElastic에서 1회 로드 */
    private Mono<CouponEventMetaCache.EventMeta> meta(Long eventId) {
        CouponEventMetaCache.EventMeta cached = metaCache.getIfCached(eventId);
        if (cached != null) {
            return Mono.just(cached);
        }
        return Mono.fromCallable(() -> metaCache.get(eventId))
                .subscribeOn(Schedulers.boundedElastic());
    }

    // ---------- 이력 조회 (R2DBC 논블로킹) ----------

    @GetMapping("/users/{userId}/issues")
    public Mono<PageResponse<IssueResponse>> history(@PathVariable Long userId,
                                                     @RequestParam(defaultValue = "0") int page,
                                                     @RequestParam(defaultValue = "20") int size) {
        int limit = Math.min(Math.max(size, 1), 100);
        int offset = Math.max(page, 0) * limit;
        Mono<java.util.List<IssueResponse>> content = db.sql(
                        "SELECT id, event_id, user_id, issued_at FROM coupon_issue "
                                + "WHERE user_id = :userId ORDER BY issued_at DESC LIMIT " + limit + " OFFSET " + offset)
                .bind("userId", userId)
                .map((row, meta) -> new IssueResponse(
                        row.get("id", Long.class),
                        row.get("event_id", Long.class),
                        row.get("user_id", Long.class),
                        row.get("issued_at", LocalDateTime.class)))
                .all().collectList();
        Mono<Long> total = db.sql("SELECT COUNT(*) AS cnt FROM coupon_issue WHERE user_id = :userId")
                .bind("userId", userId)
                .map((row, meta) -> row.get("cnt", Long.class))
                .one();
        return Mono.zip(content, total)
                .map(t -> new PageResponse<>(t.getT1(), Math.max(page, 0), limit, t.getT2()));
    }

    // ---------- 저빈도 경로 (블로킹 서비스 → boundedElastic 위임) ----------

    @PostMapping("/events")
    public Mono<ResponseEntity<EventResponse>> create(@Valid @RequestBody CreateRequest request) {
        return Mono.fromCallable(() -> eventService.create(
                        request.name(), request.totalQty(), request.openAt(), request.closeAt()))
                .subscribeOn(Schedulers.boundedElastic())
                .map(e -> ResponseEntity.status(HttpStatus.CREATED).body(EventResponse.from(e)));
    }

    @GetMapping("/events/{eventId}")
    public Mono<EventResponse> get(@PathVariable Long eventId) {
        return Mono.fromCallable(() -> EventResponse.from(eventService.get(eventId)))
                .subscribeOn(Schedulers.boundedElastic());
    }

    @PatchMapping("/events/{eventId}/status")
    public Mono<EventResponse> changeStatus(@PathVariable Long eventId, @Valid @RequestBody StatusRequest request) {
        return Mono.fromCallable(() -> EventResponse.from(eventService.changeStatus(eventId, request.status())))
                .subscribeOn(Schedulers.boundedElastic());
    }

    @GetMapping("/events/{eventId}/remaining")
    public Mono<RemainingResponse> remaining(@PathVariable Long eventId) {
        return Mono.fromCallable(() -> new RemainingResponse(eventId, eventService.remaining(eventId)))
                .subscribeOn(Schedulers.boundedElastic());
    }
}
