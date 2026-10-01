#!/usr/bin/env bash
# Destroy the local cluster (and everything in it, including backups).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require terraform

step "Destroying kind cluster '${CLUSTER_NAME}'"
run terraform -chdir="${REPO_ROOT}/terraform/kind" destroy -input=false -auto-approve \
  -var "cluster_name=${CLUSTER_NAME}" -var "app_namespace=${NAMESPACE}"
