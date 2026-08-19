package com.example.servicea;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
public class InfoController {

    private final String environment;
    private final String imageTag;
    private final RestClient serviceBClient;

    public InfoController(
            @Value("${ENVIRONMENT:unknown}") String environment,
            @Value("${IMAGE_TAG:unknown}") String imageTag,
            @Value("${SERVICE_B_URL:http://service-b}") String serviceBUrl) {
        this.environment = environment;
        this.imageTag = imageTag;
        this.serviceBClient = RestClient.create(serviceBUrl);
    }

    private static final String CHANGES = "Calls service-b and returns its response combined with its own";

    @GetMapping("/")
    public CombinedInfo info() {
        ServiceInfo serviceB = serviceBClient.get().retrieve().body(ServiceInfo.class);
        return new CombinedInfo("service-a", environment, imageTag, CHANGES, serviceB);
    }
}
