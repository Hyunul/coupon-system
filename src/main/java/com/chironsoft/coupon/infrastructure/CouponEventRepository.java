package com.chironsoft.coupon.infrastructure;

import com.chironsoft.coupon.domain.CouponEvent;
import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;

public interface CouponEventRepository extends JpaRepository<CouponEvent, Long> {

    /** SELECT ... FOR UPDATE — Phase 1의 의도된 baseline. 이벤트 행 락에 모든 발급이 직렬화된다. */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select e from CouponEvent e where e.id = :id")
    Optional<CouponEvent> findByIdForUpdate(@Param("id") Long id);
}
