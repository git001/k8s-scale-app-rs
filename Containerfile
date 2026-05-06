# syntax=docker/dockerfile:1

# ---- Build stage --------------------------------------------------------
FROM docker.io/library/rust:1.95 AS builder

WORKDIR /build

# cargo-about generates the consolidated LICENSES.txt for all crates that
# end up linked into the final binary. Pinned to a known-working line.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    cargo install cargo-about --locked --version "^0.6"

COPY Cargo.toml rust-toolchain.toml about.toml about.hbs ./
COPY src ./src

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release && \
    mkdir -p /out/licenses && \
    cargo about generate about.hbs > /out/licenses/LICENSES.txt && \
    cp target/release/k8s-scale-app-rs /out/k8s-scale-app-rs && \
    strip /out/k8s-scale-app-rs

# ---- Runtime stage ------------------------------------------------------
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest

LABEL org.opencontainers.image.source="https://github.com/git001/k8s-scale-app-rs" \
      org.opencontainers.image.title="k8s-scale-app-rs" \
      org.opencontainers.image.description="Set Kubernetes Deployment replicas via the Kubernetes API" \
      org.opencontainers.image.licenses="MIT"

RUN microdnf install -y ca-certificates && microdnf clean all

COPY --from=builder /out/k8s-scale-app-rs /usr/local/bin/k8s-scale-app-rs
COPY --from=builder /out/licenses/LICENSES.txt /licenses/LICENSES.txt
COPY LICENSE /licenses/LICENSE

USER 1001:1001

ENTRYPOINT ["/usr/local/bin/k8s-scale-app-rs"]
