#!/usr/bin/env bash
# Checks chart/values.schema.json without a cluster: every shipped values file
# renders, and an unknown key or a wrong value stops Helm with a message that
# names it. Needs helm.
#
# Usage: tests/chart/run.sh
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART="${REPO_ROOT}/chart"
FAILED=0
PASSED=0

pass() { PASSED=$((PASSED + 1)); echo "ok   $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1"; }

# A setup in which only the value under test can be the error.
VIGIL=(--set vigil.enabled=true --set vigil.tls.existingSecret=tls
    --set target.name=web
    --set vigil.jobs.up.mode=scale --set vigil.jobs.up.replicas=1
    --set vigil.identities.ci.access=write --set vigil.identities.ci.basic.existingSecret=hash)

accepts() { # description, helm arguments
    local description="$1" out
    shift
    if out="$(helm template s "${CHART}" "$@" 2>&1)"; then
        pass "accepts ${description}"
    else
        fail "accepts ${description}: ${out}"
    fi
}

rejects() { # the text the message must contain, then the arguments of helm
    local expected="$1" out
    shift
    if out="$(helm template s "${CHART}" "${VIGIL[@]}" "$@" 2>&1)"; then
        fail "rejects $*: helm accepted it"
    elif ! grep -qF -- "${expected}" <<<"${out}"; then
        fail "rejects $*: message without '${expected}': ${out}"
    else
        pass "rejects $*"
    fi
}

accepts "the defaults" --set target.name=web
for env in dev preprod prod; do
    accepts "values-${env}.yaml" -f "${CHART}/values-${env}.yaml"
done
accepts "tests/k8s/vigil-values.yaml" -f "${REPO_ROOT}/tests/k8s/vigil-values.yaml" \
    --set vigil.tls.existingSecret=tls
accepts "tests/k8s/vigil-gateway-values.yaml" -f "${REPO_ROOT}/tests/k8s/vigil-gateway-values.yaml"
accepts "a minimal vigil setup" "${VIGIL[@]}"
accepts "a restart job without replicas" "${VIGIL[@]}" --set vigil.jobs.re.mode=restart
accepts "scheduleTz with schedule" "${VIGIL[@]}" --set vigil.jobs.up.schedule='0 19 * * *' --set vigil.jobs.up.scheduleTz=UTC
accepts "a global section" --set target.name=web --set global.foo=bar
accepts "Kubernetes fields" --set target.name=web --set nodeSelector.disk=ssd \
    --set 'tolerations[0].key=a' --set resources.limits.cpu=1 --set securityContext.privileged=false \
    --set podSecurityContext.fsGroup=1000 --set affinity.nodeAffinity.x=y

# Unknown keys, at each level.
rejects "'bogus'" --set bogus=1
rejects "'nmae'" --set target.nmae=web
rejects "'tagg'" --set image.tagg=1
rejects "'creat'" --set serviceAccount.creat=true
rejects "'creat'" --set rbac.creat=true
rejects "'enable'" --set extraCA.enable=true
rejects "'enable'" --set vigil.enable=true
rejects "'tagg'" --set vigil.image.tagg=1
rejects "'replica'" --set vigil.jobs.up.replica=2
rejects "'dry-run'" --set vigil.jobs.up.dry-run=true
rejects "'token'" --set vigil.identities.ci.token.existingSecret=x
rejects "'existingsecret'" --set vigil.identities.ci.basic.existingsecret=x
rejects "'clientCa'" --set vigil.tls.clientCa.existingSecret=x
rejects "'keyy'" --set vigil.tls.clientCA.keyy=x
rejects "'ports'" --set vigil.service.ports=1
rejects "'enable'" --set vigil.openshift.enable=true
rejects "'hosts'" --set vigil.openshift.route.hosts=x
rejects "'routetype'" --set vigil.gatewayApi.routetype=tls
rejects "'section'" --set 'vigil.gatewayApi.parentRefs[0].name=g' --set 'vigil.gatewayApi.parentRefs[0].section=x'
rejects "'hostName'" --set vigil.gatewayApi.backendTLS.hostName=x
rejects "'limts'" --set resources.limts.cpu=1
rejects "'limts'" --set vigil.resources.limts.cpu=1
rejects "'runAsUsr'" --set podSecurityContext.runAsUsr=1
rejects "'readOnly'" --set securityContext.readOnly=true
rejects "'dropp'" --set 'securityContext.capabilities.dropp={ALL}'
rejects "'typ'" --set podSecurityContext.seccompProfile.typ=RuntimeDefault
rejects "'effekt'" --set 'tolerations[0].effekt=NoSchedule'
rejects "'nodeAffinty'" --set affinity.nodeAffinty.x=y

# Wrong values.
rejects "mode" --set mode=stop
rejects "kind" --set target.kind=daemonset
rejects "replicas" --set target.replicas=-1
rejects "replicas" --set vigil.jobs.up.replicas=many
rejects "mode" --set vigil.jobs.up.mode=stop
rejects "kind" --set vigil.jobs.up.kind=daemonset
rejects "dryRun" --set-string vigil.jobs.up.dryRun=true
rejects "access" --set vigil.identities.ci.access=root
rejects "anonymousAccess" --set vigil.tls.anonymousAccess=closed
rejects "routeType" --set vigil.gatewayApi.routeType=grpc
rejects "termination" --set vigil.openshift.route.termination=edge
rejects "port" --set vigil.service.port=70000
rejects "pullPolicy" --set image.pullPolicy=Sometimes

# Known keys without an effect.
rejects "replicas has no effect with mode restart" --set vigil.jobs.up.mode=restart
rejects "scheduleTz has no effect without schedule" --set vigil.jobs.up.scheduleTz=UTC

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
