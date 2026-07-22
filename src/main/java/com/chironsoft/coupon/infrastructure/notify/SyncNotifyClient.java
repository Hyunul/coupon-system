package com.chironsoft.coupon.infrastructure.notify;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

/**
 * Phase 3a "정직한" 동기 알림 클라이언트.
 * 의도적으로 connect/read 타임아웃을 설정하지 않는다 — 외부 API 지연이 발급 API 전체를
 * 무너뜨리는 장애를 재현하기 위한 장치 (roadmap Phase 3 / 장애 훈련 4).
 * Phase 3b에서 Stream 소비 워커의 WebClient(타임아웃+재시도)로 대체된다.
 */
@Component
public class SyncNotifyClient {

    private static final Logger log = LoggerFactory.getLogger(SyncNotifyClient.class);

    private final boolean enabled;
    private final String url;   // 절대 URI로 호출해 ?delay=3000 같은 장애 주입 쿼리를 보존한다
    private final RestClient restClient;

    public SyncNotifyClient(@Value("${coupon.notify.enabled:false}") boolean enabled,
                            @Value("${coupon.notify.url:http://localhost:8090/notify}") String url) {
        this.enabled = enabled;
        this.url = url;
        this.restClient = RestClient.create();
    }

    /** 발급 성공 직후 동기 호출. 실패해도 발급은 유지(로그만) — 지연이 전파되는 것이 관찰 대상. */
    public void notifyIssued(Long eventId, Long userId) {
        if (!enabled) {
            return;
        }
        try {
            restClient.post().uri(url).retrieve().toBodilessEntity();
        } catch (Exception e) {
            log.warn("notify failed: event={} user={} cause={}", eventId, userId, e.getMessage());
        }
    }
}
