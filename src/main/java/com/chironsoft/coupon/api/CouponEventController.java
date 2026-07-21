package com.chironsoft.coupon.api;

import com.chironsoft.coupon.api.dto.EventDtos.CreateRequest;
import com.chironsoft.coupon.api.dto.EventDtos.EventResponse;
import com.chironsoft.coupon.api.dto.EventDtos.RemainingResponse;
import com.chironsoft.coupon.api.dto.EventDtos.StatusRequest;
import com.chironsoft.coupon.application.CouponEventService;
import com.chironsoft.coupon.domain.CouponEvent;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/events")
public class CouponEventController {

    private final CouponEventService eventService;

    public CouponEventController(CouponEventService eventService) {
        this.eventService = eventService;
    }

    @PostMapping
    public ResponseEntity<EventResponse> create(@Valid @RequestBody CreateRequest request) {
        CouponEvent event = eventService.create(
                request.name(), request.totalQty(), request.openAt(), request.closeAt());
        return ResponseEntity.status(HttpStatus.CREATED).body(EventResponse.from(event));
    }

    @GetMapping("/{eventId}")
    public EventResponse get(@PathVariable Long eventId) {
        return EventResponse.from(eventService.get(eventId));
    }

    @PatchMapping("/{eventId}/status")
    public EventResponse changeStatus(@PathVariable Long eventId, @Valid @RequestBody StatusRequest request) {
        return EventResponse.from(eventService.changeStatus(eventId, request.status()));
    }

    @GetMapping("/{eventId}/remaining")
    public RemainingResponse remaining(@PathVariable Long eventId) {
        return new RemainingResponse(eventId, eventService.remaining(eventId));
    }
}
