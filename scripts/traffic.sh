#!/usr/bin/env bash
# Synthetic client traffic during a change: start | stop.
# Runs in-cluster through the API Service and reports failed requests,
# so "zero-downtime upgrade" is measured rather than claimed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require kubectl

POD="${RELEASE}-traffic"
case "${1:-}" in
  start)
    IMAGE="$(kc get deploy "${RELEASE}-api" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    kc delete pod "${POD}" --ignore-not-found --wait > /dev/null
    kc apply -f - > /dev/null << YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app.kubernetes.io/instance: "${RELEASE}", app.kubernetes.io/component: traffic }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: traffic
      image: ${IMAGE}
      command:
        - python
        - -uc
        - |
          import time, urllib.request, collections
          url = "http://${RELEASE}-api:8080/readyz"
          stats = collections.Counter()
          while True:
              try:
                  with urllib.request.urlopen(url, timeout=2) as r:
                      stats[r.status] += 1
              except Exception as e:
                  stats["error"] += 1
                  print(time.strftime("%H:%M:%S"), "request failed:", e, flush=True)
              if sum(stats.values()) % 20 == 0:
                  print("STATS", dict(stats), flush=True)
              time.sleep(0.25)
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { memory: 64Mi } }
YAML
    kc wait --for=condition=Ready pod/"${POD}" --timeout=60s > /dev/null
    sleep 2
    ok "synthetic traffic started (pod ${POD}, 4 req/s against the Service)"
    ;;
  stop)
    sleep 3
    last="$(kc logs "${POD}" | grep '^STATS' | tail -n 1)"
    failures="$(kc logs "${POD}" | grep -c 'request failed' || true)"
    kc delete pod "${POD}" --wait=false > /dev/null
    info "traffic result: ${last#STATS } / failed requests: ${failures}"
    [[ "${failures}" -le "${MAX_FAILED_REQUESTS:-0}" ]] || die "${failures} failed requests during the change"
    ok "no client-visible errors during the change"
    ;;
  *) die "usage: traffic.sh start|stop" ;;
esac
