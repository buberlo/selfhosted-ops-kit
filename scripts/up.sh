#!/usr/bin/env bash
# One command from zero to a verified install:
#   build images -> Terraform (kind cluster + namespace baseline) -> Helm install -> smoke test
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require docker terraform kind kubectl helm python3

S="${REPO_ROOT}/scripts"
"${S}/build-images.sh"
"${S}/cluster-up.sh"
"${S}/install.sh" 1.0.0
"${S}/smoke-test.sh"

cat << MSG

Ready. Try:
  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} get pods
  make test     # upgrade, failed upgrade + auto-rollback, rollback, backup/restore, NetworkPolicy
  make down     # delete the cluster
MSG
