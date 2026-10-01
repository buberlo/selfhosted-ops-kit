# Runbook: Backup and restore

| | |
|---|---|
| **Purpose** | Logical backups of the PostgreSQL database and restoring them |
| **RPO (demo defaults)** | 24 h scheduled (`values.yaml`) / 6 h (`values-ha.yaml`), plus a backup before every upgrade and rollback |
| **RTO (measured in CI)** | about 1 min for the demo dataset. Real RTO depends on dump size: measure it, don't assume it |
| **Automation** | `scripts/backup-now.sh`, `scripts/restore.sh` |

## How backups work

- A `CronJob` (`notes-backup`, `concurrencyPolicy: Forbid`) runs `pg_dump --format=custom` into the PVC `notes-backups`.
- A dump only counts once `pg_restore --list` can read it. It is written as `.partial` and renamed only after that check passes.
- Retention keeps the newest `backup.retention` dumps.
- A Helm hook runs the same Job **before every upgrade and rollback**. If it fails, the upgrade does not start.
- The backup PVC carries `helm.sh/resource-policy: keep`, so it survives `helm uninstall`.
- The backup PVC is `ReadWriteOnce` and is also mounted read-only by the PostgreSQL pod, which binds it at install time and makes listing easy. Because of that, backup and restore pods have a required pod affinity to the PostgreSQL pod's node.

> **Demo limitation:** the backups sit on a PVC in the same cluster as the database. That protects against bad upgrades and operator mistakes, but **not** against losing the cluster or the storage backend. In a real deployment, copy the dumps off-cluster (object storage with versioning or object lock, or the customer's backup tooling), or use an operator with WAL archiving and point-in-time recovery (for example CloudNativePG with barman-cloud). Logical dumps also cannot give you point-in-time recovery.

## On-demand backup

```bash
./scripts/backup-now.sh
# = kubectl -n ops-demo create job --from=cronjob/notes-backup manual-backup-<ts>
```
Expected log tail: `backup ok: /backups/notes-<UTC timestamp>.dump (<size>)`.

## List backups

The PostgreSQL pod mounts the backup volume read-only:

```bash
kubectl -n ops-demo exec notes-postgres-0 -c postgres -- ls -lt /backups
```

## Restore

**Decision first:** a restore throws away every write since the backup. Get explicit approval from whoever owns the data and write down the chosen dump file.

1. **Pick the dump**: `latest`, or a file name from the listing above, such as `notes-20261001T021700Z.dump`.
2. **Run**:
   ```bash
   ./scripts/restore.sh notes-20261001T021700Z.dump     # asks for confirmation
   CONFIRM=yes ./scripts/restore.sh latest              # non-interactive (CI)
   ```
   What the script does:
   1. Scales `notes-api` to 0 and waits until all API pods are gone. No writes can arrive during the restore.
   2. Runs a restore Job: `pg_restore --clean --if-exists --single-transaction --exit-on-error`. It is all-or-nothing, so a failed restore leaves the previous data in place.
   3. Prints the row count and schema version of the restored database.
   4. Scales the API back to its previous replica count and waits for readiness.
3. **Verify**:
   ```bash
   ./scripts/smoke-test.sh
   ```
   Also check one or two records you know should, or should not, be present.

### Restore failed

The script **leaves the API at 0 replicas** on purpose. Do not scale it up until you understand what happened.

- `kubectl -n ops-demo logs job/notes-restore-<ts>`
- `--single-transaction` means PostgreSQL still holds the pre-restore data. Scaling the API back up (`kubectl -n ops-demo scale deploy/notes-api --replicas=3`) resumes the old state.
- Corrupt dump → try the next older one.

### Note on Helm ownership

The scale-down and scale-up go through `kubectl scale` and change nothing in the Helm release. The script restores the original replica count, so the next `helm upgrade` sees no difference.

## Tested how?

CI writes note A, takes a backup, writes note B, restores `latest`, and asserts that A is present and B is gone, on every change.
