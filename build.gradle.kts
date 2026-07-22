plugins {
    java
    id("org.springframework.boot") version "3.5.7"
    id("io.spring.dependency-management") version "1.1.7"
}

group = "com.chironsoft"
version = "0.0.1-SNAPSHOT"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-validation")
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    implementation("org.springframework.boot:spring-boot-starter-data-redis")
    implementation("org.springframework.boot:spring-boot-starter-webflux")   // WebClient + reactive 프로파일의 Netty 서버
    implementation("org.springframework.boot:spring-boot-starter-data-r2dbc") // reactive 프로파일 이력 조회
    runtimeOnly("io.asyncer:r2dbc-mysql")
    implementation("org.springframework.boot:spring-boot-starter-cache")
    implementation("com.github.ben-manes.caffeine:caffeine")
    implementation("org.redisson:redisson-spring-boot-starter:3.37.0")
    implementation("org.flywaydb:flyway-mysql")
    runtimeOnly("com.mysql:mysql-connector-j")
    runtimeOnly("io.micrometer:micrometer-registry-prometheus")

    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.springframework.boot:spring-boot-testcontainers")
    testImplementation("org.testcontainers:mysql")
    testImplementation("org.testcontainers:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.withType<Test> {
    useJUnitPlatform()
    // 런타임(main의 TimeZone.setDefault)과 동일하게 테스트도 UTC로 고정
    systemProperty("user.timezone", "UTC")
}

// GC 실험용 JVM 옵션 주입: .\gradlew.bat bootRun -PbootJvmArgs="-Xms2g -Xmx2g -Xlog:gc*:file=..."
// (JAVA_TOOL_OPTIONS는 Gradle 데몬까지 오염시키므로 bootRun 태스크에만 적용)
tasks.named<org.springframework.boot.gradle.tasks.run.BootRun>("bootRun") {
    (findProperty("bootJvmArgs") as String?)?.let { jvmArgs = it.split(" ") }
}
