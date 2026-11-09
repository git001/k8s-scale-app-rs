#!/usr/bin/env bash
# Installs or removes the Gateway API CRDs and the controllers on a test cluster
# for tests/k8s/vigil-gateway.sh, one controller at a time on a small node. No
# LoadBalancer Service is created.
#
#   KUBECONFIG=/path/to/test-cluster.yml tests/k8s/gateways/install.sh install envoy|istio|haproxy
#   KUBECONFIG=/path/to/test-cluster.yml tests/k8s/gateways/install.sh uninstall envoy|istio|haproxy|crds

set -uo pipefail

: "${KUBECONFIG:?KUBECONFIG must point at a test cluster}"
KUBECTL="${KUBECTL:-kubectl}"
GATEWAY_API=v1.6.3
ENVOY_GATEWAY=v1.10.0
ISTIO=1.31.4
HUG=v1.0.10
# The charts of a release are not always published. Local directories also work,
# from an Istio checkout: manifests/charts/base and manifests/charts/istio-control/istio-discovery.
ISTIO_BASE_CHART="${ISTIO_BASE_CHART:-oci://gcr.io/istio-release/charts/base}"
ISTIOD_CHART="${ISTIOD_CHART:-oci://gcr.io/istio-release/charts/istiod}"
GATEWAY_API_CRDS="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API}/experimental-install.yaml"
HUG_RAW="https://raw.githubusercontent.com/haproxytech/haproxy-unified-gateway/${HUG}"
HUG_CRDS="backends defaults globals hugconfs huggates"
HUG_MANIFESTS="rbac hugconf global controller"

install_crds() {
    "${KUBECTL}" apply --server-side -f "${GATEWAY_API_CRDS}" >/dev/null
}

envoy_crds() {
    helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version "${ENVOY_GATEWAY}" \
        --set crds.gatewayAPI.enabled=false --set crds.envoyGateway.enabled=true \
        | grep -vE '^(Pulled|Digest): '
}

install_envoy() {
    envoy_crds | "${KUBECTL}" apply --server-side -f - >/dev/null || return 1
    helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "${ENVOY_GATEWAY}" \
        -n envoy-gateway-system --create-namespace --skip-crds --wait --timeout 4m >/dev/null
}

uninstall_envoy() {
    helm uninstall eg -n envoy-gateway-system >/dev/null 2>&1
    "${KUBECTL}" delete namespace envoy-gateway-system --ignore-not-found --timeout=150s >/dev/null
    # What the chart's certgen job created outside of the release.
    "${KUBECTL}" delete --ignore-not-found clusterrole,clusterrolebinding eg-gateway-helm-certgen:envoy-gateway-system >/dev/null
    "${KUBECTL}" delete --ignore-not-found mutatingwebhookconfiguration envoy-gateway-topology-injector.envoy-gateway-system >/dev/null
    envoy_crds | "${KUBECTL}" delete --ignore-not-found -f - >/dev/null
}

install_istio() {
    helm upgrade --install istio-base "${ISTIO_BASE_CHART}" --version "${ISTIO}" \
        -n istio-system --create-namespace --wait --timeout 4m >/dev/null || return 1
    helm upgrade --install istiod "${ISTIOD_CHART}" --version "${ISTIO}" -n istio-system \
        --set global.hub=docker.io/istio --set "global.tag=${ISTIO}" \
        --set pilot.resources.requests.memory=256Mi --set pilot.resources.requests.cpu=100m \
        --set pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true \
        --wait --timeout 4m >/dev/null
}

uninstall_istio() {
    helm uninstall istiod -n istio-system >/dev/null 2>&1
    helm uninstall istio-base -n istio-system >/dev/null 2>&1
    "${KUBECTL}" delete namespace istio-system --ignore-not-found --timeout=150s >/dev/null
    # Helm keeps the CRDs of a chart.
    "${KUBECTL}" get crd -o name | grep -E '\.istio\.io$' | xargs -r "${KUBECTL}" delete >/dev/null
}

install_haproxy() {
    for crd in ${HUG_CRDS}; do
        "${KUBECTL}" apply --server-side -f "${HUG_RAW}/api/definition/gate.v3.haproxy.org_${crd}.yaml" >/dev/null || return 1
    done
    "${KUBECTL}" apply -f "${HUG_RAW}/example/deploy/hug/namespace.yaml" >/dev/null || return 1
    for m in ${HUG_MANIFESTS}; do
        curl -fsSL "${HUG_RAW}/example/deploy/hug/${m}.yaml" \
            | sed -e 's/type: LoadBalancer/type: ClusterIP/' \
                -e "s#haproxy-unified-gateway:v1.0#haproxy-unified-gateway:${HUG#v}#" \
            | "${KUBECTL}" apply -f - >/dev/null || return 1
    done
    "${KUBECTL}" -n haproxy-unified-gateway rollout status deploy/haproxy-unified-gateway --timeout=240s >/dev/null
}

uninstall_haproxy() {
    for m in ${HUG_MANIFESTS}; do
        curl -fsSL "${HUG_RAW}/example/deploy/hug/${m}.yaml" | "${KUBECTL}" delete --ignore-not-found -f - >/dev/null
    done
    "${KUBECTL}" delete namespace haproxy-unified-gateway --ignore-not-found --timeout=150s >/dev/null
    for crd in ${HUG_CRDS}; do
        "${KUBECTL}" delete --ignore-not-found -f "${HUG_RAW}/api/definition/gate.v3.haproxy.org_${crd}.yaml" >/dev/null
    done
}

uninstall_crds() {
    "${KUBECTL}" delete --ignore-not-found -f "${GATEWAY_API_CRDS}" >/dev/null
}

case "${1:-}:${2:-}" in
    install:envoy | install:istio | install:haproxy) install_crds && "install_$2" ;;
    uninstall:envoy | uninstall:istio | uninstall:haproxy | uninstall:crds) "uninstall_$2" ;;
    *) echo "usage: $0 install envoy|istio|haproxy, or uninstall envoy|istio|haproxy|crds" >&2; exit 2 ;;
esac
