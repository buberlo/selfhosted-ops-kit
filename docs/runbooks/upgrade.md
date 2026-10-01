# Runbook: Upgrade

| | |
|---|---|
| **Purpose** | Move the release to a new application version or chart change without client-visible downtime |
| **Duration** | 2–5 min |
| **Risk** | Medium: changes running workloads, may migrate the schema |
| **Automation** | `scripts/upgrade.sh <tag>` (preflight + upgrade + post-checks) |
| **Rollback** | Automatic on failure; manual via [rollback.md](rollback.md) |

## Go / no-go: abort criteria

Do **not** start the upgrade, or abort it, if any of these is true. `scripts/upgrade.sh` checks items 1–5 itself and stops with a `FAIL` line.

| # | Criterion | Check |
|---|---|---|
| 1 | Release is not `deployed` (`failed`, `pending-*`) | `helm -n ops-demo status notes` |
| 2 | Not all API replicas are Ready | `kubectl -n ops-demo get deploy notes-api` |
| 3 | PostgreSQL not Ready | `kubectl -n ops-demo get sts notes-postgres` |
| 4 | PDB allows 0 disruptions (a rollout would stall) | `kubectl -n ops-demo get pdb` |
| 5 | DB volume ≥ 80 % full (migration or dump may fill it) | see `preflight` in `scripts/lib.sh` |
| 6 | Pre-upgrade backup hook fails | Helm aborts on its own before any workload changes |
| 7 | The release notes of the target version list a **non-backward-compatible** migration | Treat it as a change that needs a restore plan, not a rollback plan (see below) |
| 8 | The change window or approval is missing (customer environments) | Change ticket |

## Steps

1. **Record the starting point**. You need it for the rollback decision.
   ```bash
   helm -n ops-demo history notes --max 5
   ```
   Note the current `REVISION`. This is your known-good revision.
2. **Run the upgrade** with the same values file as the install:
   ```bash
   ./scripts/upgrade.sh 1.1.0
   # which runs:
   helm upgrade notes charts/notes -n ops-demo -f charts/notes/values-ha.yaml \
     --set api.image.tag=1.1.0 --rollback-on-failure --wait --timeout 5m
   ```
   What happens, in order:
   - The pre-upgrade hook Job writes and verifies a `pg_dump` (abort criterion 6).
   - The Deployment rolls one pod at a time (`maxSurge 1`, `maxUnavailable 0`). A new pod first runs the `migrate` initContainer, which holds a PostgreSQL advisory lock so replicas never migrate at the same time. It only receives traffic once `/readyz` passes.
   - Old pods get `preStop: sleep 5` so endpoints are removed before SIGTERM.
   - If the new pods are not Ready within `--timeout`, Helm runs the pre-rollback backup and returns to the previous revision.
3. **Post-checks** (the script does these too):
   ```bash
   helm -n ops-demo test notes --logs
   kubectl -n ops-demo exec deploy/notes-api -c api -- python -c \
     "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/version').read())"
   kubectl -n ops-demo logs job/notes-pre-upgrade-backup | tail -2
   ```

## Evidence from CI

CI runs this procedure under synthetic traffic (4 req/s against the Service, `scripts/traffic.sh`) and fails if even one request fails. It also runs a deliberately broken upgrade (unpullable image) and asserts that Helm rolled back automatically, the old version kept serving, and no request failed.

## Schema changes and rollback safety

`helm rollback` restores **manifests**, never **data**. A rollback of the application tier is only safe if the old version still works with the new schema. The demo enforces an **expand-only** rule: migration 2 adds a nullable column, and CI rolls back from 1.1.0 to 1.0.0 to prove the old code still runs against schema 2.

For a destructive change (dropping or renaming columns, changing types), use expand/contract over two releases. If that is not possible, the rollback plan for that release is *restore the pre-upgrade backup* ([backup-restore.md](backup-restore.md)). Abort criterion 7 exists for exactly this case.

## Communicating

Before: what, when, expected impact ("none, rolling"), abort criteria, and the rollback owner. After: the result, the new revision number, and the backup file name from the hook log.
