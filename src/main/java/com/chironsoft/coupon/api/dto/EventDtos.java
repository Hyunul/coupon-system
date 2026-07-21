package com.chironsoft.coupon.api.dto;

import com.chironsoft.coupon.domain.CouponEvent;
import com.chironsoft.coupon.domain.EventStatus;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.time.LocalDateTime;

public final class EventDtos {

    private EventDtos() {
    }

    public record CreateRequest(
            @NotBlank String name,
            @Min(1) int totalQty,
            @NotNull LocalDateTime openAt,
            @NotNull LocalDateTime closeAt
    ) {
    }

    public record StatusRequest(@NotNull EventStatus status) {
    }

    public record EventResponse(
            Long id,
            String name,
            int totalQty,
            int issuedQty,
            LocalDateTime openAt,
            LocalDateTime closeAt,
            EventStatus status
    ) {
        public static EventResponse from(CouponEvent e) {
            return new EventResponse(e.getId(), e.getName(), e.getTotalQty(), e.getIssuedQty(),
                    e.getOpenAt(), e.getCloseAt(), e.getStatus());
        }
    }

    public record RemainingResponse(Long eventId, int remainingQty) {
    }
}
