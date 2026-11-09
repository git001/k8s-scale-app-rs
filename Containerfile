# syntax=docker/dockerfile:1
#
# Default image: distroless — only the app binary, CA trust store and
# license files. No shell, no package manager, no OS utilities. For
# debugging use Containerfile.debug (contains bash/curl/dig).

# ---- Build stage --------------------------------------------------------
FROM docker.io/library/rust:1.99 AS builder

WORKDIR /build

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    cargo install cargo-about --locked --features cli --version "^0.9"

COPY Cargo.toml Cargo.lock rust-toolchain.toml about.toml about.hbs ./
COPY src ./src

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release && \
    mkdir -p /out/licenses && \
    cargo about generate about.hbs > /out/licenses/LICENSES.txt && \
    cp target/release/k8s-scale-app-rs /out/k8s-scale-app-rs && \
    strip /out/k8s-scale-app-rs

# ---- ca-certificates source stage ---------------------------------------
# ubi10-micro ships without ca-certificates. Pull them from ubi-minimal so
# TLS to arbitrary APIs (KUBECONFIG use-case) works. The in-cluster CA is
# still mounted from the ServiceAccount secret at runtime.
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest AS ca-source
RUN microdnf install -y ca-certificates && microdnf clean all

# ---- Runtime stage (distroless via ubi10-micro) -------------------------
FROM registry.access.redhat.com/ubi10/ubi-micro:latest

LABEL org.opencontainers.image.source="https://github.com/git001/k8s-scale-app-rs" \
      org.opencontainers.image.title="k8s-scale-app-rs" \
      org.opencontainers.image.description="Set Kubernetes Deployment replicas via the Kubernetes API (distroless)" \
      org.opencontainers.image.licenses="MIT"

COPY --from=ca-source /etc/pki /etc/pki
COPY --from=builder /out/k8s-scale-app-rs /usr/local/bin/k8s-scale-app-rs
COPY --from=builder /out/licenses/LICENSES.txt /licenses/LICENSES.txt
COPY LICENSE /licenses/LICENSE

USER 1001:1001

ENTRYPOINT ["/usr/local/bin/k8s-scale-app-rs"]
