package com.chironsoft.coupon;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.MySQLContainer;

/**
 * MySQL + Redis Testcontainers 공용 베이스 (singleton container 패턴).
 * Redisson이 컨텍스트 기동 시 Redis에 연결하므로 모든 통합 테스트가 Redis를 필요로 한다.
 */
@SpringBootTest
public abstract class AbstractIntegrationTest {

    static final MySQLContainer<?> MYSQL = new MySQLContainer<>("mysql:8.0");
    static final GenericContainer<?> REDIS =
            new GenericContainer<>("redis:7.4-alpine").withExposedPorts(6379);

    static {
        MYSQL.start();
        REDIS.start();
    }

    @DynamicPropertySource
    static void containerProps(DynamicPropertyRegistry r) {
        r.add("spring.datasource.url", MYSQL::getJdbcUrl);
        r.add("spring.datasource.username", MYSQL::getUsername);
        r.add("spring.datasource.password", MYSQL::getPassword);
        // R2DBC 자동구성이 URL을 요구하므로 같은 컨테이너를 가리키게 한다 (reactive 경로 테스트에도 사용 가능)
        r.add("spring.r2dbc.url", () -> "r2dbc:mysql://" + MYSQL.getHost() + ":" + MYSQL.getMappedPort(3306)
                + "/" + MYSQL.getDatabaseName());
        r.add("spring.r2dbc.username", MYSQL::getUsername);
        r.add("spring.r2dbc.password", MYSQL::getPassword);
        r.add("spring.data.redis.host", REDIS::getHost);
        r.add("spring.data.redis.port", () -> REDIS.getMappedPort(6379));
        // 기본값은 stream(워커 소비)이지만 테스트 컨텍스트엔 워커가 없어 DB 단언이 불가 —
        // 전략 테스트는 sync 경로로 검증하고, stream 경로는 E2E 실험(드레인 대사)으로 검증한다
        r.add("coupon.record.mode", () -> "sync");
    }
}
