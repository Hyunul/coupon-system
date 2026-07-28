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
    private final org.springframework.kafka.core.KafkaTemplate<Object, Object> kafkaTemplate;
    private final String recordMode;

    public LuaScriptIssueStrategy(CouponEventMetaCache metaCache,
                                  RedisStockStore stockStore,
                                  CouponIssueRepository issueRepository,
                                  org.springframework.kafka.core.KafkaTemplate<Object, Object> kafkaTemplate,
                                  @Value("${coupon.record.mode:sync}") String recordMode) {
        this.metaCache = metaCache;
        this.stockStore = stockStore;
        this.issueRepository = issueRepository;
        this.kafkaTemplate = kafkaTemplate;
        this.recordMode = recordMode;
    }

    @Override
    public CouponIssue issue(Long eventId, Long userId) {
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        if (!metaCache.get(eventId).isOpen(now)) {
            throw new BusinessException(ErrorCode.NOT_OPEN);
        }

        String result = "stream".equals(recordMode)
                ? stockStore.issueAtomicallyWithStream(eventId, userId, now.toString())
                : stockStore.issueAtomically(eventId, userId);
        switch (result) {
            case RedisStockStore.SOLD_OUT -> throw new BusinessException(ErrorCode.SOLD_OUT);
            case RedisStockStore.DUPLICATE -> throw new BusinessException(ErrorCode.DUPLICATE_ISSUE);
            case RedisStockStore.OK -> { /* fall through */ }
            default -> throw new IllegalStateException("unexpected lua result: " + result);
        }

        if ("stream".equals(recordMode)) {
            // 임계 경로에서 DB 완전 제거 — 이력 INSERT는 워커가 Stream을 소비하며 수행 (at-least-once,
            // 중복 소비는 uk_event_user가 무해화). 응답의 issueId는 null (기록은 최종적 일관성).
            // 판정(Lua)과 발행(XADD)이 단일 스크립트라 원자적 — Kafka 모드와의 핵심 차이.
            return new CouponIssue(eventId, userId, now);
        }
        if ("kafka".equals(recordMode)) {
            // Kafka 비교 실험: 판정(Redis Lua)과 발행(Kafka send)이 원자가 아니다 —
            // 판정 성공 후 send 실패 시 기록 유실 가능(브로커 미가용 등). 정석 해법은
            // Transactional Outbox이며, 이 트레이드오프 자체가 비교 리포트의 핵심 논점.
            String payload = String.format("{\"eventId\":%d,\"userId\":%d,\"issuedAt\":\"%s\"}",
                    eventId, userId, now);
            kafkaTemplate.send(com.chironsoft.coupon.infrastructure.stream.KafkaIssueWorker.TOPIC,
                    eventId + ":" + userId, payload);
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
