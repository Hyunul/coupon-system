package com.chironsoft.coupon.infrastructure.stream;

import com.chironsoft.coupon.AbstractIntegrationTest;
import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 배치 멱등 쓰기 경로 검증 — at-least-once 소비의 핵심 계약.
 * 배치에 중복(재소비)이 섞이면 saveAll 트랜잭션이 통째로 롤백되고,
 * 행 단위 폴백에서 uk_event_user가 중복만 걸러 나머지를 살려야 한다.
 */
class IssueRecordWriterTest extends AbstractIntegrationTest {

    @Autowired
    IssueRecordWriter writer;

    @Autowired
    CouponIssueRepository issueRepository;

    final Long eventId = 9_900L;
    final LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC).withNano(0);

    @BeforeEach
    void clean() {
        issueRepository.deleteAll();
    }

    @Test
    @DisplayName("중복 없는 배치는 단일 트랜잭션으로 전량 기록된다")
    void cleanBatchWritesAll() {
        writer.writeBatch(() -> List.of(
                new CouponIssue(eventId, 1L, now),
                new CouponIssue(eventId, 2L, now),
                new CouponIssue(eventId, 3L, now)));

        assertThat(issueRepository.countByEventId(eventId)).isEqualTo(3);
    }

    @Test
    @DisplayName("중복이 섞인 배치는 행 단위 폴백으로 신규 건만 살아남는다 (전량 유실 없음)")
    void duplicateInBatchFallsBackPerRow() {
        issueRepository.save(new CouponIssue(eventId, 2L, now));   // 이미 기록된 재소비 대상

        writer.writeBatch(() -> List.of(
                new CouponIssue(eventId, 1L, now),
                new CouponIssue(eventId, 2L, now),   // uk_event_user 위반 → saveAll 롤백 유발
                new CouponIssue(eventId, 3L, now)));

        assertThat(issueRepository.countByEventId(eventId))
                .as("중복 1건 때문에 신규 2건이 유실되면 안 된다")
                .isEqualTo(3);
    }

    @Test
    @DisplayName("전부 중복인 배치도 예외 없이 흡수된다 (재소비 폭주 시나리오)")
    void allDuplicatesAbsorbed() {
        issueRepository.save(new CouponIssue(eventId, 1L, now));
        issueRepository.save(new CouponIssue(eventId, 2L, now));

        writer.writeBatch(() -> List.of(
                new CouponIssue(eventId, 1L, now),
                new CouponIssue(eventId, 2L, now)));

        assertThat(issueRepository.countByEventId(eventId)).isEqualTo(2);
    }
}
