package com.chironsoft.coupon.api;

import com.chironsoft.coupon.AbstractIntegrationTest;
import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import com.chironsoft.coupon.infrastructure.CouponEventRepository;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import com.chironsoft.coupon.infrastructure.redis.RedisStockStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;

import java.time.LocalDateTime;
import java.time.ZoneOffset;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 발급 API의 HTTP 계약 검증 — 부하테스트가 "정상 응답 집합: 201 / 409"로 계산하는 근거.
 * 에러코드 → 상태코드 매핑이 바뀌면 k6 시나리오의 성공 판정이 함께 깨진다.
 */
@AutoConfigureMockMvc
class CouponIssueApiTest extends AbstractIntegrationTest {

    @Autowired
    MockMvc mvc;

    @Autowired
    CouponEventRepository eventRepository;

    @Autowired
    CouponIssueRepository issueRepository;

    @Autowired
    RedisStockStore stockStore;

    Long openEventId;
    Long closedEventId;

    @BeforeEach
    void setUp() {
        issueRepository.deleteAll();
        eventRepository.deleteAll();
        LocalDateTime now = LocalDateTime.now(ZoneOffset.UTC);
        CouponEvent open = new CouponEvent("api-test-open", 1, now.minusHours(1), now.plusDays(1), now);
        open.changeStatus(EventStatus.OPEN);
        openEventId = eventRepository.save(open).getId();
        stockStore.initialize(openEventId, 1);   // 기본 전략(lua)은 Redis가 재고의 진실
        CouponEvent closed = new CouponEvent("api-test-closed", 10, now.minusHours(1), now.plusDays(1), now);
        closed.changeStatus(EventStatus.CLOSED);
        closedEventId = eventRepository.save(closed).getId();
    }

    @Test
    @DisplayName("발급 성공은 201과 발급 내역을 반환한다")
    void issueReturns201() throws Exception {
        mvc.perform(post("/api/v1/events/{id}/issues", openEventId).header("X-USER-ID", 1L))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.eventId").value(openEventId))
                .andExpect(jsonPath("$.userId").value(1L));
    }

    @Test
    @DisplayName("같은 사용자의 재발급 요청은 409 DUPLICATE_ISSUE")
    void duplicateReturns409() throws Exception {
        mvc.perform(post("/api/v1/events/{id}/issues", openEventId).header("X-USER-ID", 1L))
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/events/{id}/issues", openEventId).header("X-USER-ID", 1L))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.code").value("DUPLICATE_ISSUE"));
    }

    @Test
    @DisplayName("재고 소진 후 요청은 409 SOLD_OUT")
    void soldOutReturns409() throws Exception {
        mvc.perform(post("/api/v1/events/{id}/issues", openEventId).header("X-USER-ID", 1L))
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/events/{id}/issues", openEventId).header("X-USER-ID", 2L))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.code").value("SOLD_OUT"));
    }

    @Test
    @DisplayName("OPEN이 아닌 이벤트는 400 NOT_OPEN")
    void notOpenReturns400() throws Exception {
        mvc.perform(post("/api/v1/events/{id}/issues", closedEventId).header("X-USER-ID", 1L))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("NOT_OPEN"));
    }

    @Test
    @DisplayName("존재하지 않는 이벤트는 404 EVENT_NOT_FOUND")
    void unknownEventReturns404() throws Exception {
        mvc.perform(post("/api/v1/events/{id}/issues", 999_999L).header("X-USER-ID", 1L))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.code").value("EVENT_NOT_FOUND"));
    }

    @Test
    @DisplayName("X-USER-ID 헤더 없는 요청은 400")
    void missingUserHeaderReturns400() throws Exception {
        mvc.perform(post("/api/v1/events/{id}/issues", openEventId))
                .andExpect(status().isBadRequest());
    }
}
