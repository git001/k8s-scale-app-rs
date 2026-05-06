# syntax=docker/dockerfile:1

# ---- Build stage --------------------------------------------------------
FROM docker.io/library/rust:1.95 AS builder

WORKDIR /build

COPY Cargo.toml rust-toolchain.toml ./
COPY src ./src

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release && \
    cp target/release/k8s-scale-app-rs /usr/local/bin/k8s-scale-app-rs && \
    strip /usr/local/bin/k8s-scale-app-rs

# ---- Runtime stage ------------------------------------------------------
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest

LABEL org.opencontainers.image.source="https://github.com/git001/k8s-scale-app-rs" \
      org.opencontainers.image.title="k8s-scale-app-rs" \
      org.opencontainers.image.description="Set Kubernetes Deployment replicas via the Kubernetes API" \
      org.opencontainers.image.licenses="MIT"

RUN microdnf install -y ca-certificates && microdnf clean all

COPY --from=builder /usr/local/bin/k8s-scale-app-rs /usr/local/bin/k8s-scale-app-rs

USER 1001:1001

ENTRYPOINT ["/usr/local/bin/k8s-scale-app-rs"]
