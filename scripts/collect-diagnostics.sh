#!/usr/bin/env bash
# Support bundle: everything needed to triage the release without cluster access.
# Secrets are NOT collected (only their names). Output: a .tar.gz path on stdout.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl helm

OUT="${1:-diagnostics-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "${OUT}"
cap() { local f="$1"; shift; "$@" > "${OUT}/${f}" 2>&1 || echo "(command failed: $*)" >> "${OUT}/${f}"; }

cap versions.txt sh -c "kubectl version --context ${KUBE_CONTEXT}; helm version"
cap nodes.txt kubectl --context "${KUBE_CONTEXT}" get nodes -o wide
cap node-describe.txt kubectl --context "${KUBE_CONTEXT}" describe nodes
cap helm-status.txt hm status "${RELEASE}"
cap helm-history.txt hm history "${RELEASE}"
cap helm-values.yaml hm get values "${RELEASE}" --all
cap resources.txt kc get all,pvc,pdb,networkpolicy,cronjob,job,cm,resourcequota,limitrange -o wide
cap secrets-names.txt kc get secrets -o custom-columns=NAME:.metadata.name,TYPE:.type
cap events.txt kc get events --sort-by=.lastTimestamp
cap describe-pods.txt kc describe pods
cap describe-pvc.txt kc describe pvc
for pod in $(kc get pods -o name); do
  name="${pod#pod/}"
  cap "logs-${name}.txt" kc logs "${pod}" --all-containers --prefix --tail=500
  cap "logs-${name}-previous.txt" kc logs "${pod}" --all-containers --prefix --previous --tail=200
done
tar -czf "${OUT}.tar.gz" "${OUT}"
echo "${OUT}.tar.gz"
