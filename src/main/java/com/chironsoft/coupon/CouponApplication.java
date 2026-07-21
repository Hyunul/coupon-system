package com.chironsoft.coupon;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

import java.util.TimeZone;

@SpringBootApplication
public class CouponApplication {

    public static void main(String[] args) {
        // 전 구간 UTC 통일: JVM 기본 시간대가 KST면 Hibernate의 DATETIME↔LocalDateTime 변환이 +9h 왜곡된다
        TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
        SpringApplication.run(CouponApplication.class, args);
    }
}
