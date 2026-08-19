package com.example.servicea;

public record CombinedInfo(String service, String environment, String imageTag, ServiceInfo serviceB) {
}
