#!/usr/bin/env bash
# The vigil mode of the Helm chart on a real cluster: jobs triggered over HTTPS
# with Basic Auth and client certificates, a schedule, RBAC.
#
# Needs KUBECONFIG, helm, curl and openssl. Creates and removes the namespace
# k8s-scale-vigil-test.
#
#   KUBECONFIG=/path/to/test-cluster.yml tests/k8s/vigil.sh
#
# Environment variables:
#   KUBECTL     kubectl binary (default: kubectl)
#   IMAGE_REPO  image repository (default: the chart's)
#   IMAGE_TAG   image tag        (default: the chart's)
#   RUN_AS_USER UID of the pod, e.g. a random one as on OpenShift (default: the chart's)

set -uo pipefail

: "${KUBECONFIG:?KUBECONFIG must point at a test cluster}"
export KUBECONFIG
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
NS=k8s-scale-vigil-test
# With this name the Service produces K8S_SCALE_APP_RS_* variables in the pods,
# which the tool must not take for unknown settings.
RELEASE=k8s-scale-app-rs
WORK="$(mktemp -d)"
FAILS=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: got [$2], want [$3]"; fi; }

cleanup() {
    [ -s "${WORK}/forward.pid" ] && kill "$(cat "${WORK}/forward.pid")" 2>/dev/null
    "${KUBECTL}" delete namespace "${NS}" --wait=true --timeout=150s --ignore-not-found >/dev/null
    rm -rf "${WORK}"
    echo "failures: ${FAILS}"
    if [ "${FAILS}" -ne 0 ]; then exit 1; fi
}
if "${KUBECTL}" get namespace "${NS}" >/dev/null 2>&1; then
    echo "namespace ${NS} already exists: is another run active?" >&2
    exit 2
fi
trap cleanup EXIT

replicas() { "${KUBECTL}" -n "${NS}" get "$1" -o jsonpath='{.spec.replicas}'; }
restarted_at() {
    "${KUBECTL}" -n "${NS}" get "$1" \
        -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}'
}

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
ca server-ca
ca client-ca
ca other-ca
sign server server-ca "subjectAltName=DNS:localhost
extendedKeyUsage=serverAuth"
sign client client-ca "keyUsage=digitalSignature
extendedKeyUsage=clientAuth"
sign stranger other-ca "keyUsage=digitalSignature
extendedKeyUsage=clientAuth"
PASSWORD="$(openssl rand -hex 16)"
openssl passwd -6 "${PASSWORD}" > password-hash

"${KUBECTL}" create namespace "${NS}" >/dev/null
K() { "${KUBECTL}" -n "${NS}" "$@"; }
K create secret tls vigil-test-server-tls --cert=server.crt --key=server.key >/dev/null
K create secret generic vigil-test-client-ca --from-file=ca.crt=client-ca.crt >/dev/null
K create secret generic vigil-test-hash --from-file=password-hash=password-hash >/dev/null

echo "==> Workloads"
K create deployment web --image=registry.k8s.io/pause:3.10 --replicas=1 >/dev/null
K create deployment scheduled --image=registry.k8s.io/pause:3.10 --replicas=1 >/dev/null
K apply -f "${REPO_ROOT}/tests/k8s/manifests/statefulset.yaml" >/dev/null
for w in deploy/web deploy/scheduled statefulset/db; do
    K rollout status "${w}" --timeout=150s >/dev/null || fail "rollout ${w}"
done

echo "==> Chart"
IMAGE_ARGS=()
[ -n "${IMAGE_REPO:-}" ] && IMAGE_ARGS+=(--set "image.repository=${IMAGE_REPO}")
[ -n "${IMAGE_TAG:-}" ] && IMAGE_ARGS+=(--set "image.tag=${IMAGE_TAG}")
[ -n "${RUN_AS_USER:-}" ] && IMAGE_ARGS+=(--set "podSecurityContext.runAsUser=${RUN_AS_USER}")
helm install "${RELEASE}" "${REPO_ROOT}/chart" -n "${NS}" -f "${REPO_ROOT}/tests/k8s/vigil-values.yaml" \
    "${IMAGE_ARGS[@]}" >/dev/null || { fail "helm install"; exit 1; }
if ! K rollout status deploy/${RELEASE} --timeout=180s >/dev/null; then
    fail "vigil rollout"
    K describe pod -l app.kubernetes.io/component=vigil | tail -25
    K logs -l app.kubernetes.io/component=vigil --all-containers --tail=30
    exit 1
fi
# Kubernetes sets the Service's variables only in pods that start after it.
K rollout restart "deploy/${RELEASE}" >/dev/null
K rollout status "deploy/${RELEASE}" --timeout=180s >/dev/null || fail "vigil restart"
pass "vigil pod ready"
check "no job ran at pod start" "$(replicas deploy/web)" 1

URL=https://localhost:18443
# kubectl port-forward ends when a connection breaks, e.g. after a rejected
# client certificate, so every request makes sure that it runs. The PID is in a
# file, as call() runs in a subshell.
ensure_forward() {
    if [ -s "${WORK}/forward.pid" ] && kill -0 "$(cat "${WORK}/forward.pid")" 2>/dev/null; then return; fi
    "${KUBECTL}" -n "${NS}" port-forward svc/${RELEASE} 18443:8443 >/dev/null 2>&1 &
    echo "$!" > "${WORK}/forward.pid"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        curl -s --max-time 2 --cacert server-ca.crt -o /dev/null "${URL}/v1/health" && return
        sleep 1
    done
}

# call <job> <curl options>: prints "<http code> <change status>".
call() {
    local job="$1"; shift
    local code status
    ensure_forward
    code="$(curl -s --max-time 150 --cacert server-ca.crt -o body.json -w '%{http_code}' "$@" \
        -H 'Content-Type: application/json' \
        -d "{\"action\":\"start\",\"services\":[\"${job}\"]}" "${URL}/v1/services")"
    status="$(sed -n 's/.*"result":{.*"status":"\([a-z]*\)".*/\1/p' body.json 2>/dev/null)"
    echo "${code} ${status}"
}
rm_body() { rm -f body.json; }

echo "==> Who may trigger"
ensure_forward
check "health is open" "$(curl -s --cacert server-ca.crt -o /dev/null -w '%{http_code}' "${URL}/v1/health")" 200
rm_body; check "no credentials" "$(call scale-up | cut -d' ' -f1)" 403
rm_body; check "wrong password" "$(call scale-up -u ci:wrong | cut -d' ' -f1)" 403
rm_body; check "read identity" "$(call scale-up -u "viewer:${PASSWORD}" | cut -d' ' -f1)" 403
rm_body; check "bearer is not supported yet" "$(call scale-up -H 'Authorization: Bearer abc' | cut -d' ' -f1)" 403
rm_body; check "client certificate of another CA" "$(call scale-up --cert stranger.crt --key stranger.key | cut -d' ' -f1)" 000
check "nothing changed so far" "$(replicas deploy/web)" 1
ensure_forward
curl -s --max-time 10 -o /dev/null -u "ci:${PASSWORD}" "${URL}/v1/health"
check "server certificate is verified" "$?" 60

echo "==> Jobs"
rm_body; check "dry-run job" "$(call scale-dry -u "ci:${PASSWORD}")" "200 done"
check "dry-run keeps replicas" "$(replicas deploy/web)" 1
rm_body; check "basic: scale" "$(call scale-up -u "ci:${PASSWORD}")" "200 done"
check "deployment scaled" "$(replicas deploy/web)" 2
rm_body; check "mTLS: restart" "$(call restart --cert client.crt --key client.key)" "200 done"
if [ -n "$(restarted_at deploy/web)" ]; then pass "deployment restarted"; else fail "deployment restarted"; fi
K rollout status deploy/web --timeout=150s >/dev/null && pass "deployment rollout" || fail "deployment rollout"
rm_body; check "statefulset scale" "$(call db-scale --cert client.crt --key client.key)" "200 done"
check "statefulset scaled" "$(replicas statefulset/db)" 2
rm_body; check "statefulset restart" "$(call db-restart -u "ci:${PASSWORD}")" "200 done"
if [ -n "$(restarted_at statefulset/db)" ]; then pass "statefulset restarted"; else fail "statefulset restarted"; fi
K rollout status statefulset/db --timeout=180s >/dev/null && pass "statefulset rollout" || fail "statefulset rollout"
rm_body; check "a failed job is HTTP 200 with status error" "$(call missing -u "ci:${PASSWORD}")" "200 error"

echo "==> Environment"
K run env-probe --image=busybox:1.37 --restart=Never --command -- env >/dev/null
K wait pod/env-probe --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null || fail "env-probe"
check "pods here see the Service's variables" \
    "$(K logs env-probe | grep -c '^K8S_SCALE_APP_RS_SERVICE_HOST=')" 1
K delete pod env-probe --wait=false >/dev/null
TOOL_IMAGE="$(K get "deploy/${RELEASE}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
K run unknown-env --image="${TOOL_IMAGE}" --restart=Never --env=K8S_SCALE_DRY_RUNN=true \
    --command -- /usr/local/bin/k8s-scale-app-rs scale --name web --namespace "${NS}" --replicas 9 >/dev/null
if K wait pod/unknown-env --for=jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'=2 --timeout=120s >/dev/null; then
    pass "unknown variable: exit code 2"
else
    fail "unknown variable: exit code 2"
fi
check "unknown variable: message" \
    "$(K logs unknown-env | grep -c 'unknown environment variable: K8S_SCALE_DRY_RUNN')" 1
check "unknown variable: nothing changed" "$(replicas deploy/web)" 2
K delete pod unknown-env --wait=false >/dev/null

echo "==> Schedule"
waited=0
while [ "$(replicas deploy/scheduled)" != 3 ] && [ "${waited}" -lt 75 ]; do sleep 5; waited=$((waited + 5)); done
check "scheduled job after ${waited}s" "$(replicas deploy/scheduled)" 3

echo "==> RBAC"
check "no access to another namespace" \
    "$("${KUBECTL}" auth can-i patch deployments/scale -n default --as="system:serviceaccount:${NS}:deploy")" no
check "no access to other kinds" \
    "$("${KUBECTL}" auth can-i patch daemonsets -n "${NS}" --as="system:serviceaccount:${NS}:deploy")" no

echo "==> Pod"
LOG="$(K logs deploy/${RELEASE} --tail=200)"
case "${LOG}" in *$'\033'*) fail "ANSI codes in the log" ;; *) pass "no ANSI codes in the log" ;; esac
check "pod did not restart" \
    "$(K get pod -l app.kubernetes.io/component=vigil -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')" 0
