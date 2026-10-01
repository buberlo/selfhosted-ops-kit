# Runbook: Troubleshooting

Start with the support bundle. Attach it to every escalation:

```bash
./scripts/collect-diagnostics.sh        # → diagnostics-<ts>.tar.gz (no secret values)
```

It contains node and pod state, events, Helm status/history/values, PVCs, NetworkPolicies, quota, and the last 500 log lines of every container, including previous containers.

## Triage order

1. **What changed?** `helm -n ops-demo history notes`, and recent events: `kubectl -n ops-demo get events --sort-by=.lastTimestamp | tail -30`
2. **What is unhealthy?** `kubectl -n ops-demo get pods -o wide`
3. **Why?** `kubectl -n ops-demo describe pod <pod>`, then `kubectl -n ops-demo logs <pod> --all-containers --previous`

## API not ready

| Observation | Meaning | Action |
|---|---|---|
| `Init:0/1` for a long time | `migrate` is waiting for the DB or for the advisory lock | `kubectl logs <pod> -c migrate`; check postgres readiness |
| `Init:CrashLoopBackOff` | Migration fails | Read the migrate logs. Do **not** retry blindly: a half-applied migration needs a decision (restore vs fix forward) |
| Running but `0/1` Ready, `/healthz` ok | `/readyz` fails: DB unreachable or schema missing | Check postgres, NetworkPolicy, Secret; see below |
| `CrashLoopBackOff` on `api` | Process crashes | `kubectl logs <pod> -c api --previous` |
| `ImagePullBackOff` | Wrong tag or registry unreachable | `kubectl describe pod`; for air-gapped sites check `global.imageRegistry` and pull secrets |

Liveness only checks the process. A database outage therefore makes API pods **NotReady**, not restart-looping, which is intentional: restarts would not fix the database and only add load.

## Database connection refused or timing out

```bash
kubectl -n ops-demo get pods -l app.kubernetes.io/component=postgres
kubectl -n ops-demo logs notes-postgres-0 --tail=50
./scripts/netpol-test.sh          # labelled client must reach 5432, unlabelled must not
```
A pod that must talk to PostgreSQL needs the label `selfhosted-ops-kit/db-client: "true"` and the release's `app.kubernetes.io/instance` label. With `networkPolicy.restrictEgress=true`, such a pod can **only** reach PostgreSQL and DNS.

## Release stuck in pending or failed

`helm upgrade` refuses to run while a release is `pending-upgrade` / `pending-rollback` (for example after a killed CI job).

```bash
helm -n ops-demo history notes
helm -n ops-demo rollback notes <last-good-revision> --wait
```
Only if rollback is refused as well: inspect the release Secrets (`kubectl -n ops-demo get secret -l owner=helm,name=notes`). Back them up before you touch them. Deleting the latest pending release Secret is a last resort and needs a second pair of eyes.

## Rollout stalls

- `kubectl -n ops-demo rollout status deploy/notes-api` hangs → new pods are not Ready (see above), or there are not enough nodes for the spread constraints (`values-ha.yaml` uses `DoNotSchedule`): `kubectl describe pod` → `FailedScheduling`.
- Node drain hangs → the PDB is doing its job. Check `kubectl get pdb`; scale up first, or drain one node at a time.

## PVC / storage

- `Pending` PVC → `kubectl describe pvc`: no default StorageClass, quota (`requests.storage`), or the provisioner is down.
- DB volume full → PostgreSQL stops accepting writes. Expand the PVC if the StorageClass allows it (`allowVolumeExpansion`), otherwise restore into a larger volume. The preflight check refuses upgrades above 80 %.

## Pod Security

`violates PodSecurity "restricted:latest"` means a values override or a manually started debug pod lacks `runAsNonRoot`, `seccompProfile`, `allowPrivilegeEscalation: false` or `capabilities.drop: [ALL]`. Debug pods need the same settings, for example:

```bash
kubectl -n ops-demo debug -it notes-postgres-0 --image=busybox:1.37 --profile=restricted -- sh
```

## Backups failing

```bash
kubectl -n ops-demo get jobs -l app.kubernetes.io/component=backup
kubectl -n ops-demo logs job/<job>
```
Typical causes: backup PVC full (lower the retention or enlarge the PVC), DB unreachable, or `activeDeadlineSeconds` too short for the dump size.
