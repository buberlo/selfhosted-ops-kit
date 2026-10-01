#!/usr/bin/env bash
# Roll the release back to an explicit, known-good revision.
# Data is NOT rolled back: see docs/runbooks/rollback.md for when you need a restore instead.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm kubectl

REVISION="${1:-}"
step "Release history before rollback"
hm history "${RELEASE}" --max 10
# Always name the target: "previous revision" may be a failed one after an auto-rollback.
[[ "${REVISION}" =~ ^[0-9]+$ ]] || die "usage: rollback.sh <revision>  (pick a 'deployed'/'superseded' revision from the history above)"

step "Rolling back ${RELEASE} to revision ${REVISION}"
run helm --kube-context "${KUBE_CONTEXT}" -n "${NAMESPACE}" rollback "${RELEASE}" "${REVISION}" \
  --wait --timeout "${HELM_TIMEOUT}"
ok "now at revision $(release_revision), api version $(api_version)"

"${REPO_ROOT}/scripts/smoke-test.sh"
