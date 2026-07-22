package com.chironsoft.coupon.config;

import org.springframework.boot.web.embedded.netty.NettyReactiveWebServerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;

/**
 * reactive 프로파일에서 Netty를 강제한다.
 * spring-boot-starter-web(Tomcat)이 클래스패스에 함께 있으면 reactive 모드에서도
 * Boot가 Tomcat(reactive bridge)을 먼저 선택한다 — Phase 3c에서 실측으로 확인한 함정.
 */
@Configuration
@Profile("reactive")
public class NettyServerConfig {

    @Bean
    public NettyReactiveWebServerFactory nettyReactiveWebServerFactory() {
        return new NettyReactiveWebServerFactory();
    }
}
