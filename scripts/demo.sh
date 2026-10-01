#!/usr/bin/env bash
# Narrated walkthrough used for the terminal recording in docs/demo/.
# Expects a running install (make up). Takes ~5 minutes.
export FORCE_COLOR=1
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
S="${REPO_ROOT}/scripts"

say() { printf '\n\e[1;35m### %s\e[0m\n' "$*"; sleep 1; }

say "selfhosted-ops-kit: day-2 operations on a local kind cluster (demo project, not production)"
run kubectl --context "${KUBE_CONTEXT}" get nodes
run kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" get pods,pdb,networkpolicy,cronjob
info "api version: $(api_version)"
good_rev="$(release_revision)"

say "1) Upgrade under synthetic traffic: preflight gate, pre-upgrade backup hook, rolling update"
"${S}/traffic.sh" start
"${S}/upgrade.sh" 1.1.0
"${S}/traffic.sh" stop

say "2) A broken release (image does not exist) is rolled back automatically"
"${S}/traffic.sh" start
HELM_TIMEOUT=60s "${S}/upgrade.sh" 9.9.9-broken || info "upgrade failed as expected; release is still serving"
"${S}/traffic.sh" stop
info "api version: $(api_version)"

say "3) Operator-initiated rollback to the known-good revision ${good_rev}"
"${S}/rollback.sh" "${good_rev}"

say "4) Backup and restore"
api POST /notes "demo-note-before-backup" > /dev/null
"${S}/backup-now.sh"
api POST /notes "demo-note-after-backup" > /dev/null
CONFIRM=yes "${S}/restore.sh" latest
info "notes after restore: $(api GET /notes | python3 -c 'import json,sys; print([n["body"] for n in json.load(sys.stdin)][:3])')"

say "Release history"
run helm --kube-context "${KUBE_CONTEXT}" -n "${NAMESPACE}" history "${RELEASE}"
say "Done."
