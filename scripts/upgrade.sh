#!/usr/bin/env bash
# Upgrade the API to a new image tag following docs/runbooks/upgrade.md:
# preflight gate -> pre-upgrade backup (Helm hook) -> rolling upgrade with
# automatic rollback on failure -> post-checks.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm kubectl

TAG="${1:?usage: upgrade.sh <image-tag>}"
preflight

step "Upgrading ${RELEASE} to api ${TAG} (auto-rollback on failure, timeout ${HELM_TIMEOUT})"
before="$(release_revision)"
if ! run helm --kube-context "${KUBE_CONTEXT}" -n "${NAMESPACE}" upgrade "${RELEASE}" "${CHART_DIR}" \
  -f "${VALUES_FILE}" --set api.image.tag="${TAG}" \
  --rollback-on-failure --wait --timeout "${HELM_TIMEOUT}"; then
  warn "upgrade failed; Helm rolled back automatically. Current state:"
  hm history "${RELEASE}" --max 5
  exit 1
fi
ok "upgraded: revision ${before} -> $(release_revision)"

"${REPO_ROOT}/scripts/smoke-test.sh"
