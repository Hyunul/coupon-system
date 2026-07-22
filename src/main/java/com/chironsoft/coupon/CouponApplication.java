package com.chironsoft.coupon;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;

import java.util.TimeZone;

@SpringBootApplication
// JPA+R2DBC 공존(다중 Spring Data 모듈) 시 strict mode로 JPA 리포지토리 스캔이 빠질 수 있어 명시적으로 활성화
@EnableJpaRepositories(basePackages = "com.chironsoft.coupon.infrastructure")
public class CouponApplication {

    public static void main(String[] args) {
        // 전 구간 UTC 통일: JVM 기본 시간대가 KST면 Hibernate의 DATETIME↔LocalDateTime 변환이 +9h 왜곡된다
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
        SpringApplication.run(CouponApplication.class, args);
    }
}
