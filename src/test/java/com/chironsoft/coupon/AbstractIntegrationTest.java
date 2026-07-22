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
    }
}
