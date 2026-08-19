package com.example.serviceb;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class InfoController {

    private final String environment;
    private final String imageTag;

    public InfoController(
            @Value("${ENVIRONMENT:unknown}") String environment,
            @Value("${IMAGE_TAG:unknown}") String imageTag) {
        this.environment = environment;
        this.imageTag = imageTag;
    }

    private static final String CHANGES = "Added JSON pretty-printing to the response body";

    @GetMapping("/")
    public ServiceInfo info() {
        return new ServiceInfo("service-b", environment, imageTag, CHANGES);
    }
}
