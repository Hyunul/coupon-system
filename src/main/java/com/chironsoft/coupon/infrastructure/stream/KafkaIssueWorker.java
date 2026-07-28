package com.chironsoft.coupon.infrastructure.stream;

import com.chironsoft.coupon.domain.CouponIssue;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;

/**
 * record.mode=kafka 비교 실험용 워커 — Redis Stream 워커(IssueStreamWorker)와 동일한
 * 멱등 배치 쓰기 경로(IssueRecordWriter)를 공유한다.
 * at-least-once: manual ack(커밋)를 DB 기록 후에 수행 — Stream의 XACK와 대칭.
 */
@Component
@Profile("worker")
@ConditionalOnProperty(name = "coupon.record.mode", havingValue = "kafka")
public class KafkaIssueWorker {

    public static final String TOPIC = "coupon.issue";

    private static final Logger log = LoggerFactory.getLogger(KafkaIssueWorker.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final IssueRecordWriter writer;

    public KafkaIssueWorker(IssueRecordWriter writer) {
        this.writer = writer;
        log.info("kafka issue worker 활성 (topic={})", TOPIC);
    }

    @KafkaListener(topics = TOPIC)
    public void onMessages(List<String> messages, Acknowledgment ack) {
        writer.writeBatch(() -> {
            List<CouponIssue> batch = new ArrayList<>(messages.size());
            for (String message : messages) {
                try {
                    JsonNode n = MAPPER.readTree(message);
                    batch.add(new CouponIssue(n.get("eventId").asLong(), n.get("userId").asLong(),
                            LocalDateTime.parse(n.get("issuedAt").asText())));
                } catch (Exception e) {
                    log.error("메시지 파싱 실패(스킵): {}", message, e);
                }
            }
            return batch;
        });
        ack.acknowledge();   // 기록 완료 후 오프셋 커밋 — 워커 급사 시 미커밋분 재소비(멱등)
    }
}
