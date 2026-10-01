# Runbook: Offline / air-gapped install

Self-hosted customers often run clusters with **no internet egress**: images must come from an internal registry, nothing may phone home, and every artifact must be reviewable before it crosses the boundary. This kit is built so that is possible.

## What the chart does and does not need

- Exactly two images: `notes-api` and `postgres` (`./scripts/mirror-images.sh list`).
- **No** runtime downloads, no telemetry, no external endpoints. With `restrictEgress=true`, the API and backup pods cannot reach anything except PostgreSQL and DNS.
- No subcharts and no chart repositories: the chart directory (or a `helm package` .tgz) is the whole artifact.
- All images can be redirected with `global.imageRegistry` and pinned by digest (`*.image.digest`).

## Procedure

### On the connected side

```bash
make images                                   # or pull the released images
./scripts/mirror-images.sh list               # review the exact image list
./scripts/mirror-images.sh save notes-images.tar   # docker save + .sha256
helm package charts/notes                     # notes-<version>.tgz
sha256sum notes-*.tgz > chart.sha256
```

Transfer `notes-images.tar`, `notes-images.tar.sha256`, the chart `.tgz` and `chart.sha256` through the customer's approved transfer path (data diode, scanned media, artifact gateway). Many sites scan the files at the boundary; the checksums let both sides prove the files are the same.

### On the disconnected side

```bash
sha256sum -c chart.sha256
./scripts/mirror-images.sh load notes-images.tar          # verifies the checksum, docker load
./scripts/mirror-images.sh push registry.internal:5000    # retag + push, keeps repo paths
```

Install against the mirror:

```bash
helm upgrade --install notes notes-0.1.0.tgz -n ops-demo \
  -f values-ha.yaml \
  --set global.imageRegistry=registry.internal:5000 \
  --set 'global.imagePullSecrets={regcred}' \
  --set api.image.tag=1.0.0 \
  --wait --timeout 10m
```

For full reproducibility, pin digests instead of tags (`--set api.image.digest=sha256:...`, `--set postgres.image.digest=sha256:...`). Take the digests from `docker inspect --format '{{index .RepoDigests 0}}'` after the push.

### Cluster-level mirroring (alternative)

Instead of rewriting image names, the container runtime can be pointed at a mirror. The Terraform module supports this for kind:

```bash
terraform -chdir=terraform/kind apply -var registry_mirror=http://registry.internal:5000
```
On real clusters this is the containerd `hosts.toml` / registry mirror configuration of the node OS (or the distribution's equivalent).

## Verify that no egress is needed

1. Install with `networkPolicy.restrictEgress=true` (the default).
2. Run `helm test` and `./scripts/netpol-test.sh`.
3. Optionally block egress at the node or cluster level and repeat. CI runs with internet access, so this step is **not** automated here.

## Checklist for the change ticket

- [ ] Image list and digests recorded
- [ ] Checksums verified on both sides
- [ ] Pull secret created in the namespace (if the registry needs auth)
- [ ] `global.imageRegistry` set; `helm template ... | grep image:` shows only internal references
- [ ] No `latest` tags
