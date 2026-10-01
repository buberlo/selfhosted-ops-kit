#!/usr/bin/env bash
# First install of the release (idempotent: re-running upgrades with the same values).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm kubectl

TAG="${1:-1.0.0}"
step "Installing ${RELEASE} (api ${TAG}) into ${NAMESPACE}"
run helm --kube-context "${KUBE_CONTEXT}" -n "${NAMESPACE}" upgrade --install "${RELEASE}" "${CHART_DIR}" \
  -f "${VALUES_FILE}" --set api.image.tag="${TAG}" \
  --wait --timeout "${HELM_TIMEOUT}"
kc get pods -o wide
ok "installed revision $(release_revision)"
