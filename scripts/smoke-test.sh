#!/usr/bin/env bash
# Post-install / post-change verification. Exit code != 0 means "do not proceed".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm kubectl

step "Smoke test"
wait_api_ready
run helm --kube-context "${KUBE_CONTEXT}" -n "${NAMESPACE}" test "${RELEASE}" --logs
info "version: $(api GET /version)"
ok "smoke test passed"
