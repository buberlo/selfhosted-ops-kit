#!/usr/bin/env bash
# Trigger an on-demand backup from the CronJob template and wait for it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

JOB="manual-backup-$(date +%s)"
step "On-demand backup (${JOB})"
run kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" create job --from=cronjob/"${RELEASE}"-backup "${JOB}"
if ! kc wait --for=condition=complete job/"${JOB}" --timeout=180s; then
  kc logs job/"${JOB}" || true
  die "backup job ${JOB} did not complete"
fi
kc logs job/"${JOB}"
ok "backup completed"
