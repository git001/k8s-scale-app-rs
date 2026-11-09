#!/usr/bin/env bash
# The vigil mode behind a Gateway API controller: a TLSRoute with TLS up to
# vigild (Basic Auth and client certificates), an HTTPRoute with TLS ending at
# the Gateway (Basic Auth). Requests go through a port-forward to the Service
# of the Gateway, so no cloud load balancer is involved.
#
# Needs tests/k8s/gateways/install.sh. Creates and removes the namespace
# k8s-scale-gateway-test.
#
#   KUBECONFIG=/path/to/test-cluster.yml tests/k8s/vigil-gateway.sh envoy|istio|haproxy
#
# Environment variables: KUBECTL, IMAGE_REPO, IMAGE_TAG as in tests/k8s/vigil.sh.
#   ROUTES  the route types to test (default: "tls http")

set -uo pipefail

IMPL="${1:?usage: $0 envoy|istio|haproxy}"
: "${KUBECONFIG:?KUBECONFIG must point at a test cluster}"
export KUBECONFIG
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
NS=k8s-scale-gateway-test
HOST=scale.example.test
WORK="$(mktemp -d)"
FAILS=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: got [$2], want [$3]"; fi; }
K() { "${KUBECTL}" -n "${NS}" "$@"; }

stop_forward() {
    [ -s "${WORK}/forward.pid" ] && kill "$(cat "${WORK}/forward.pid")" 2>/dev/null
    rm -f "${WORK}/forward.pid"
}

cleanup() {
    stop_forward
    helm uninstall s -n "${NS}" >/dev/null 2>&1
    K delete gateway g --ignore-not-found --timeout=60s >/dev/null
    "${KUBECTL}" delete namespace "${NS}" --wait=true --timeout=150s --ignore-not-found >/dev/null
    "${KUBECTL}" delete gatewayclass eg haproxy --ignore-not-found >/dev/null
    rm -rf "${WORK}"
    echo "failures: ${FAILS}"
    if [ "${FAILS}" -ne 0 ]; then exit 1; fi
}
if "${KUBECTL}" get namespace "${NS}" >/dev/null 2>&1; then
    echo "namespace ${NS} already exists: is another run active?" >&2
    exit 2
fi
trap cleanup EXIT

case "${IMPL}" in
    envoy)
        GW_NS=envoy-gateway-system
        GW_SELECTOR="gateway.envoyproxy.io/owning-gateway-name=g,gateway.envoyproxy.io/owning-gateway-namespace=${NS}"
        ;;
    istio)
        GW_NS="${NS}"
        GW_SELECTOR="gateway.networking.k8s.io/gateway-name=g"
        ;;
    haproxy)
        GW_NS=haproxy-unified-gateway
        GW_SELECTOR="app.kubernetes.io/name=haproxy-unified-gateway"
        ;;
    *) echo "unknown gateway ${IMPL}" >&2; exit 2 ;;
esac

echo "==> Certificates and Secrets"
cd "${WORK}" || exit 1
ca() { openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -keyout "$1.key" -out "$1.crt" -subj "/CN=$1" -addext basicConstraints=critical,CA:TRUE 2>/dev/null; }
sign() { # name, CA, extensions
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$1.key" -out "$1.csr" -subj "/CN=$1" 2>/dev/null
    printf '%s\n' "$3" > "$1.ext"
    openssl x509 -req -in "$1.csr" -CA "$2.crt" -CAkey "$2.key" -CAcreateserial -days 1 \
        -out "$1.crt" -extfile "$1.ext" 2>/dev/null
}
for c in server-ca gateway-ca client-ca other-ca; do ca "${c}"; done
sign server server-ca "subjectAltName=DNS:${HOST}
extendedKeyUsage=serverAuth"
sign gateway gateway-ca "subjectAltName=DNS:${HOST}
extendedKeyUsage=serverAuth"
sign client client-ca "keyUsage=digitalSignature
extendedKeyUsage=clientAuth"
sign stranger other-ca "keyUsage=digitalSignature
extendedKeyUsage=clientAuth"
PASSWORD="$(openssl rand -hex 16)"
openssl passwd -6 "${PASSWORD}" > password-hash

"${KUBECTL}" create namespace "${NS}" >/dev/null
K create secret tls gateway-test-server-tls --cert=server.crt --key=server.key >/dev/null
K create secret tls gateway-tls --cert=gateway.crt --key=gateway.key >/dev/null
K create secret generic gateway-test-client-ca --from-file=ca.crt=client-ca.crt >/dev/null
K create secret generic gateway-test-hash --from-file=password-hash=password-hash >/dev/null
K create configmap gateway-test-backend-ca --from-file=ca.crt=server-ca.crt >/dev/null

echo "==> Workload and Gateway (${IMPL})"
K create deployment web --image=registry.k8s.io/pause:3.10 --replicas=1 >/dev/null
K rollout status deploy/web --timeout=150s >/dev/null || fail "rollout web"
K apply -f "${REPO_ROOT}/tests/k8s/gateways/${IMPL}.yaml" >/dev/null || { fail "apply gateway"; exit 1; }
# A LoadBalancer Service would create a cloud load balancer, which costs money.
for _ in $(seq 1 30); do
    GW_SVC_TYPE="$("${KUBECTL}" -n "${GW_NS}" get svc -l "${GW_SELECTOR}" -o jsonpath='{.items[0].spec.type}' 2>/dev/null)"
    [ -n "${GW_SVC_TYPE}" ] && break
    sleep 1
done
if [ "${GW_SVC_TYPE}" != ClusterIP ]; then
    fail "Gateway Service is [${GW_SVC_TYPE}], not ClusterIP: stopping"
    exit 1
fi
pass "Gateway Service is ClusterIP"
if K wait gateway/g --for=condition=Programmed --timeout=180s >/dev/null; then
    pass "Gateway programmed"
else
    fail "Gateway programmed"
    K get gateway g -o yaml | sed -n '/^status:/,$p'
fi

IMAGE_ARGS=()
[ -n "${IMAGE_REPO:-}" ] && IMAGE_ARGS+=(--set "image.repository=${IMAGE_REPO}")
[ -n "${IMAGE_TAG:-}" ] && IMAGE_ARGS+=(--set "image.tag=${IMAGE_TAG}")

replicas() { K get deploy/web -o jsonpath='{.spec.replicas}'; }

# kubectl port-forward ends when a connection breaks, so every request makes
# sure that it runs. The PID is in a file, as call() runs in a subshell.
ensure_forward() { # local port, gateway port
    if [ -s "${WORK}/forward.pid" ] && kill -0 "$(cat "${WORK}/forward.pid")" 2>/dev/null; then return; fi
    "${KUBECTL}" -n "${GW_NS}" port-forward "svc/${GW_SVC}" "$1:$2" >/dev/null 2>&1 &
    echo "$!" > "${WORK}/forward.pid"
    sleep 2
}

# call <job> <CA> <curl options>: prints "<http code> <change status>".
call() {
    local job="$1" ca_file="$2"; shift 2
    ensure_forward "${LOCAL}" "${PORT}"
    rm -f body.json
    local code status
    code="$(curl -s --max-time 60 --cacert "${ca_file}" --resolve "${HOST}:${LOCAL}:127.0.0.1" \
        -o body.json -w '%{http_code}' "$@" -H 'Content-Type: application/json' \
        -d "{\"action\":\"start\",\"services\":[\"${job}\"]}" "https://${HOST}:${LOCAL}/v1/services")"
    status="$(sed -n 's/.*"result":{.*"status":"\([a-z]*\)".*/\1/p' body.json 2>/dev/null)"
    echo "${code} ${status}"
}

# A new route takes a moment to arrive in the data plane: an unauthenticated
# request answers 403 from vigild once it has.
wait_route() { # CA
    local i code
    for i in $(seq 1 45); do
        code="$(call scale-two "$1" | cut -d' ' -f1)"
        [ "${code}" = 403 ] && { pass "route reaches vigild after ${i} tries"; return 0; }
        sleep 2
    done
    fail "route reaches vigild: last code [${code}], body: $(cut -c1-200 body.json 2>/dev/null)"
    "${KUBECTL}" -n "${NS}" get tlsroute,httproute,backendtlspolicy -o yaml 2>/dev/null \
        | grep -E '^  kind:|^    kind:|type: |reason: |message: ' | cut -c1-160 | head -30
    return 1
}

install_chart() { # route type, section
    helm upgrade --install s "${REPO_ROOT}/chart" -n "${NS}" \
        -f "${REPO_ROOT}/tests/k8s/vigil-gateway-values.yaml" \
        --set "vigil.gatewayApi.routeType=$1" --set "vigil.gatewayApi.parentRefs[0].sectionName=$2" \
        "${IMAGE_ARGS[@]}" >/dev/null || { fail "helm $1"; return 1; }
    K rollout status deploy/s-k8s-scale-app-rs --timeout=180s >/dev/null || { fail "vigil rollout"; return 1; }
    GW_SVC="$("${KUBECTL}" -n "${GW_NS}" get svc -l "${GW_SELECTOR}" -o jsonpath='{.items[0].metadata.name}')"
    echo "    Gateway Service ${GW_NS}/${GW_SVC}, type $("${KUBECTL}" -n "${GW_NS}" get svc "${GW_SVC}" -o jsonpath='{.spec.type}')"
}

test_tls() {
    echo "==> TLSRoute: TLS up to vigild"
    LOCAL=18444; PORT=31444
    install_chart tls tls || return
    wait_route server-ca.crt || return
    check "vigild's own certificate with the server CA: no credentials" "$(call scale-two server-ca.crt | cut -d' ' -f1)" 403
    check "wrong password" "$(call scale-two server-ca.crt -u ci:wrong | cut -d' ' -f1)" 403
    check "certificate of another CA" "$(call scale-two server-ca.crt --cert stranger.crt --key stranger.key | cut -d' ' -f1)" 000
    check "the Gateway's CA does not verify vigild" "$(call scale-two gateway-ca.crt | cut -d' ' -f1)" 000
    check "nothing changed" "$(replicas)" 1
    check "Basic Auth through the Gateway" "$(call scale-two server-ca.crt -u "ci:${PASSWORD}")" "200 done"
    check "scaled by Basic Auth" "$(replicas)" 2
    check "mTLS through the Gateway" "$(call scale-three server-ca.crt --cert client.crt --key client.key)" "200 done"
    check "scaled by mTLS" "$(replicas)" 3
    stop_forward
}

test_http() {
    echo "==> HTTPRoute: TLS ends at the Gateway"
    LOCAL=18443; PORT=31443
    install_chart http https || return
    wait_route gateway-ca.crt || return
    check "no credentials" "$(call scale-four gateway-ca.crt | cut -d' ' -f1)" 403
    check "wrong password" "$(call scale-four gateway-ca.crt -u ci:wrong | cut -d' ' -f1)" 403
    check "a client certificate does not reach vigild" "$(call scale-four gateway-ca.crt --cert client.crt --key client.key | cut -d' ' -f1)" 403
    check "server CA does not verify the Gateway" "$(call scale-four server-ca.crt | cut -d' ' -f1)" 000
    check "nothing changed" "$(replicas)" "${HTTP_BEFORE}"
    check "Basic Auth through the Gateway" "$(call scale-four gateway-ca.crt -u "ci:${PASSWORD}")" "200 done"
    check "scaled by Basic Auth" "$(replicas)" 4
    stop_forward
}

for route in ${ROUTES:-tls http}; do
    HTTP_BEFORE="$(replicas)"
    "test_${route}"
done
