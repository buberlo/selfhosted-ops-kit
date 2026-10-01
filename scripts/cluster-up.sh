#!/usr/bin/env bash
# Provision the local kind cluster + namespace baseline with Terraform.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require docker terraform kind kubectl

TF_DIR="${REPO_ROOT}/terraform/kind"
step "Terraform: kind cluster '${CLUSTER_NAME}' and namespace '${NAMESPACE}'"
run terraform -chdir="${TF_DIR}" init -input=false
run terraform -chdir="${TF_DIR}" apply -input=false -auto-approve \
  -var "cluster_name=${CLUSTER_NAME}" -var "app_namespace=${NAMESPACE}"
kubectl --context "${KUBE_CONTEXT}" get nodes -o wide

step "Loading locally built images into the cluster (no registry needed)"
for img in $(docker images --format '{{.Repository}}:{{.Tag}}' "${IMAGE_REPO}"); do
  run kind load docker-image --name "${CLUSTER_NAME}" "${img}"
done
