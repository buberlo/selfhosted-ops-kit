# Runbook: Install

| | |
|---|---|
| **Purpose** | First installation of the `notes` release into a prepared namespace |
| **Duration** | ~3 min (images local), plus image pull time |
| **Risk** | Low: no existing data |
| **Automation** | `scripts/install.sh` (called by `make up`) |

## Preconditions

- [ ] `kubectl auth can-i create deployments -n ops-demo` → `yes`
- [ ] The namespace exists with Pod Security `restricted` (created by Terraform here; in a customer cluster the platform team usually provides it).
- [ ] A default StorageClass exists: `kubectl get storageclass` shows one marked `(default)`, or you set `postgres.persistence.storageClass` and `backup.persistence.storageClass`.
- [ ] Images can be pulled, or are already mirrored for air-gapped sites ([offline-install.md](offline-install.md)).
- [ ] The values profile is chosen and stored in version control. Every later upgrade must use the same file.

## Steps

1. **Render and review** before touching the cluster:
   ```bash
   helm template notes charts/notes -n ops-demo -f charts/notes/values-ha.yaml | less
   ```
2. **Install**:
   ```bash
   helm upgrade --install notes charts/notes -n ops-demo \
     -f charts/notes/values-ha.yaml --set api.image.tag=1.0.0 \
     --wait --timeout 5m
   ```
3. **Verify**:
   ```bash
   kubectl -n ops-demo get pods -o wide        # 3x api (spread over nodes), 1x postgres, all Ready
   helm -n ops-demo test notes --logs          # write + read-back through the Service
   kubectl -n ops-demo get pdb,networkpolicy,cronjob
   ```
4. **Take a first backup** so a restore point exists before real data arrives:
   ```bash
   ./scripts/backup-now.sh
   ```

## Expected result

`helm status notes` shows `deployed`, `helm test` passes, and the backup job is `Complete`.

## If it fails

| Symptom | Likely cause | Next step |
|---|---|---|
| `violates PodSecurity "restricted"` | A values override broke the security context | Revert the override and read [troubleshooting.md](troubleshooting.md#pod-security) |
| postgres `Pending` | No default StorageClass, or quota exceeded | `kubectl describe pvc`, `kubectl describe resourcequota` |
| api `Init:CrashLoopBackOff` | Migration cannot reach the DB | [troubleshooting.md](troubleshooting.md#api-not-ready) |
| `exceeded quota` | Requests are above the namespace quota | Lower the resources or ask the platform team to raise the quota |
