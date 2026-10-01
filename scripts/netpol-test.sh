#!/usr/bin/env bash
# Prove the NetworkPolicies are enforced, not just rendered:
#   an unlabelled pod must NOT reach PostgreSQL, a labelled db-client must.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

PG_IMAGE="$(kc get sts "${RELEASE}-postgres" -o jsonpath='{.spec.template.spec.containers[0].image}')"

probe() { # probe <name> <extra-label-yaml-or-empty> -> prints pg_isready exit code
  local name="$1" label="$2"
  kc delete pod "${name}" --ignore-not-found --wait > /dev/null
  kc apply -f - > /dev/null << YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/instance: ${RELEASE}
    app.kubernetes.io/component: netpol-test
    ${label}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 70, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: ${PG_IMAGE}
      command: ["pg_isready", "-h", "${RELEASE}-postgres", "-p", "5432", "-t", "5"]
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
YAML
  local phase=""
  for _ in $(seq 1 90); do
    phase="$(kc get pod "${name}" -o jsonpath='{.status.phase}')"
    [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && break
    sleep 1
  done
  kc get pod "${name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'
  kc delete pod "${name}" --wait=false > /dev/null
}

step "NetworkPolicy enforcement test"
denied="$(probe netpol-test-unlabelled "")"
info "unlabelled pod -> postgres: pg_isready exit ${denied:-?} (expect 2 = no response)"
allowed="$(probe netpol-test-dbclient 'selfhosted-ops-kit/db-client: "true"')"
info "db-client pod   -> postgres: pg_isready exit ${allowed:-?} (expect 0 = accepting)"

[[ "${allowed}" == "0" ]] || die "labelled db-client could not reach PostgreSQL"
[[ "${denied}" == "2" ]] || die "unlabelled pod reached PostgreSQL - NetworkPolicy not enforced by this CNI?"
ok "NetworkPolicies enforced"
