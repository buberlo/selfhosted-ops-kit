#!/usr/bin/env bash
# Restore PostgreSQL from a dump on the backup volume.
#   restore.sh latest                 newest dump
#   restore.sh notes-20261001T020000Z.dump
# Procedure and decision points: docs/runbooks/backup-restore.md
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

DUMP="${1:-latest}"
[[ "${DUMP}" == "latest" || "${DUMP}" =~ ^[A-Za-z0-9._-]+\.dump$ ]] || die "invalid dump name: ${DUMP}"
CONFIRM="${CONFIRM:-}"
if [[ "${CONFIRM}" != "yes" ]]; then
  [[ -t 0 ]] || die "set CONFIRM=yes to restore non-interactively (this overwrites the database)"
  read -r -p "Restore '${DUMP}' into ${NAMESPACE}/${RELEASE}? This OVERWRITES current data. Type 'yes': " CONFIRM
  [[ "${CONFIRM}" == "yes" ]] || die "aborted by operator"
fi

PG_IMAGE="$(kc get sts "${RELEASE}-postgres" -o jsonpath='{.spec.template.spec.containers[0].image}')"
PG_SECRET="$(kc get sts "${RELEASE}-postgres" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_PASSWORD")].valueFrom.secretKeyRef.name}')"
DB="$(kc get sts "${RELEASE}-postgres" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_DB")].value}')"
USER_NAME="$(kc get sts "${RELEASE}-postgres" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_USER")].value}')"
REPLICAS="$(kc get deploy "${RELEASE}-api" -o jsonpath='{.spec.replicas}')"
JOB="${RELEASE}-restore-$(date +%s)"

step "1/4 Stop writers: scale ${RELEASE}-api ${REPLICAS} -> 0"
run kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" scale deploy/"${RELEASE}"-api --replicas=0
kc wait --for=delete pod -l app.kubernetes.io/instance="${RELEASE}",app.kubernetes.io/component=api --timeout=120s

step "2/4 Restore job ${JOB} (${DUMP})"
kc apply -f - << YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  labels:
    app.kubernetes.io/instance: ${RELEASE}
    app.kubernetes.io/component: restore
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: ${RELEASE}
        app.kubernetes.io/component: restore
        selfhosted-ops-kit/db-client: "true"
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      affinity: # backup PVC is RWO and mounted by the postgres pod
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app.kubernetes.io/instance: ${RELEASE}
                  app.kubernetes.io/component: postgres
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: pg-restore
          image: ${PG_IMAGE}
          env:
            - { name: PGHOST, value: ${RELEASE}-postgres }
            - { name: PGDATABASE, value: "${DB}" }
            - { name: PGUSER, value: "${USER_NAME}" }
            - name: PGPASSWORD
              valueFrom: { secretKeyRef: { name: ${PG_SECRET}, key: password } }
            - { name: DUMP, value: "${DUMP}" }
          command:
            - /bin/sh
            - -ec
            - |
              if [ "\$DUMP" = latest ]; then f="\$(ls -1t /backups/*.dump | head -n 1)"; else f="/backups/\$DUMP"; fi
              [ -f "\$f" ] || { echo "dump not found: \$f"; ls -l /backups; exit 1; }
              echo "restoring \$f"
              pg_restore --list "\$f" > /dev/null
              pg_restore --clean --if-exists --no-owner --single-transaction --exit-on-error -d "\$PGDATABASE" "\$f"
              echo "restore ok: \$(psql -Atc 'select count(*) from notes') notes, schema \$(psql -Atc 'select max(version) from schema_version')"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 256Mi }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: backups
          persistentVolumeClaim: { claimName: ${RELEASE}-backups }
        - name: tmp
          emptyDir: {}
YAML

if ! kc wait --for=condition=complete job/"${JOB}" --timeout=600s; then
  kc logs job/"${JOB}" || true
  die "restore job failed - database state unknown, do NOT resume traffic blindly (see runbook)"
fi
step "3/4 Restore log"
kc logs job/"${JOB}"
ok "restore completed"

# Writers stay stopped if anything above failed: a half-restored database must
# be inspected before traffic resumes (runbook step "Restore failed").
step "4/4 Start writers again: scale ${RELEASE}-api -> ${REPLICAS}"
run kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" scale deploy/"${RELEASE}"-api --replicas="${REPLICAS}"
wait_api_ready
ok "API back at ${REPLICAS} replicas"
