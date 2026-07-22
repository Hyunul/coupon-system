package com.chironsoft.coupon.config;

import com.zaxxer.hikari.HikariDataSource;
import jakarta.persistence.EntityManagerFactory;
import org.springframework.boot.autoconfigure.jdbc.DataSourceProperties;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.transaction.PlatformTransactionManager;

/**
 * JDBC + R2DBC 공존 구성.
 * R2DBC ConnectionFactory 빈이 존재하면 DataSourceAutoConfiguration이
 * @ConditionalOnMissingBean(io.r2dbc.spi.ConnectionFactory) 조건으로 물러나
 * EntityManagerFactory까지 연쇄로 사라진다 — JDBC DataSource를 명시적으로 정의해 해결.
 * (Phase 3c에서 실측으로 확인한 함정 — phase3 리포트 참조)
 */
@Configuration
public class DataSourceConfig {

    @Bean
    @Primary
    @ConfigurationProperties("spring.datasource")
    public DataSourceProperties dataSourceProperties() {
        return new DataSourceProperties();
    }

    @Bean
    @Primary
    @ConfigurationProperties("spring.datasource.hikari")   // maximum-pool-size 등 hikari.* 바인딩 유지
    public HikariDataSource dataSource(DataSourceProperties properties) {
        return properties.initializeDataSourceBuilder().type(HikariDataSource.class).build();
    }

    /** R2DBC의 ReactiveTransactionManager와 공존 — @Transactional은 JPA 쪽을 기본으로 */
    @Bean
    @Primary
    public PlatformTransactionManager transactionManager(EntityManagerFactory emf) {
        return new JpaTransactionManager(emf);
    }
}
