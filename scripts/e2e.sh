#!/usr/bin/env bash
# End-to-end day-2 test against a running install (see up.sh). Used by CI.
#   1. upgrade 1.0.0 -> 1.1.0 under synthetic traffic, data preserved
#   2. broken upgrade (unpullable image) -> automatic rollback, no client errors
#   3. manual rollback to the 1.0.0 revision, data and schema preserved
#   4. backup -> write -> restore -> data is exactly the backup state
#   5. NetworkPolicies enforced
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm kubectl python3

S="${REPO_ROOT}/scripts"
has_note() { api GET /notes | python3 -c 'import json,sys; sys.exit(0 if any(n["body"]==sys.argv[1] for n in json.load(sys.stdin)) else 1)' "$1"; }
expect_eq() { [[ "$1" == "$2" ]] || die "$3: expected '$2', got '$1'"; ok "$3 = $1"; }

step "E2E 0/5: baseline"
expect_eq "$(api_version)" "1.0.0" "api version"
api POST /notes "written-on-1.0.0" > /dev/null
has_note "written-on-1.0.0" || die "missing note written-on-1.0.0"; ok "seed note written"

step "E2E 1/5: upgrade 1.0.0 -> 1.1.0 under traffic"
"${S}/traffic.sh" start
"${S}/upgrade.sh" 1.1.0
"${S}/traffic.sh" stop
expect_eq "$(api_version)" "1.1.0" "api version after upgrade"
has_note "written-on-1.0.0" || die "missing note written-on-1.0.0"; ok "data survived upgrade"
kc logs job/"${RELEASE}"-pre-upgrade-backup | tail -n 2
expect_eq "$(kc get job "${RELEASE}-pre-upgrade-backup" -o jsonpath='{.status.succeeded}')" "1" "pre-upgrade backup job succeeded"

step "E2E 2/5: broken upgrade must roll back automatically"
rev_before="$(release_revision)"
"${S}/traffic.sh" start
if HELM_TIMEOUT=90s "${S}/upgrade.sh" 9.9.9-does-not-exist; then
  die "broken upgrade unexpectedly succeeded"
fi
"${S}/traffic.sh" stop
expect_eq "$(release_status)" "deployed" "release status after failed upgrade"
expect_eq "$(api_version)" "1.1.0" "api version after failed upgrade"
desc="$(hm history "${RELEASE}" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["description"])')"
[[ "${desc}" == Rollback* ]] || die "latest revision is not a rollback: ${desc}"
ok "revision ${rev_before} -> $(release_revision): ${desc}"

step "E2E 3/5: manual rollback to the 1.0.0 revision (1)"
"${S}/rollback.sh" 1
expect_eq "$(api_version)" "1.0.0" "api version after rollback"
has_note "written-on-1.0.0" || die "missing note written-on-1.0.0"; ok "data survived rollback"
expect_eq "$(api GET /readyz | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')" "2" \
  "schema version (expand-only migration kept, old code still works)"

step "E2E 4/5: backup and restore"
api POST /notes "A-in-backup" > /dev/null
"${S}/backup-now.sh"
api POST /notes "B-after-backup" > /dev/null
CONFIRM=yes "${S}/restore.sh" latest
has_note "A-in-backup" || die "missing note A-in-backup"; ok "note written before the backup is present"
if has_note "B-after-backup"; then die "note written after the backup survived the restore"; fi
ok "note written after the backup is gone (restore = backup state)"
"${S}/smoke-test.sh"

step "E2E 5/5: NetworkPolicies"
"${S}/netpol-test.sh"

step "Final release history"
hm history "${RELEASE}"
ok "E2E passed"
