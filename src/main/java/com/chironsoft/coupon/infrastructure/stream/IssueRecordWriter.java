package com.chironsoft.coupon.infrastructure.stream;

import com.chironsoft.coupon.domain.CouponIssue;
import com.chironsoft.coupon.infrastructure.CouponIssueRepository;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.function.Supplier;

/**
 * 발급 이력 배치 기록기 — Stream/Kafka 워커가 공유하는 멱등 쓰기 경로.
 * 단일 트랜잭션 saveAll(커밋 1회/배치, 드레인 150→1,250건/s의 근거),
 * 중복(재소비) 포함 시 행 단위 폴백 — uk_event_user가 최종 멱등화.
 */
@Component
public class IssueRecordWriter {

    private final CouponIssueRepository issueRepository;
    private final TransactionTemplate tx;

    public IssueRecordWriter(CouponIssueRepository issueRepository, TransactionTemplate tx) {
        this.issueRepository = issueRepository;
        this.tx = tx;
    }

    /**
     * @param batchSupplier 엔티티는 매 시도마다 새로 생성해야 한다 — 롤백된 배치의 인스턴스는
     *                      IDENTITY id가 이미 할당돼 재사용 시 UPDATE로 오동작한다
     */
    public void writeBatch(Supplier<List<CouponIssue>> batchSupplier) {
        try {
            List<CouponIssue> batch = batchSupplier.get();
            tx.executeWithoutResult(s -> issueRepository.saveAll(batch));
        } catch (DataIntegrityViolationException e) {
            for (CouponIssue issue : batchSupplier.get()) {
                try {
                    tx.executeWithoutResult(s -> issueRepository.save(issue));
                } catch (DataIntegrityViolationException ignore) {
                    // at-least-once 재소비 — 무시
                }
            }
        }
    }
}
