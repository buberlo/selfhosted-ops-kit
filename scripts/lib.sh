#!/usr/bin/env bash
# Shared settings and helpers. Sourced by the other scripts, not run directly.
# Every setting can be overridden from the environment.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# Work from the repo root so printed commands use short, copy-pasteable paths.
cd "${REPO_ROOT}"

CLUSTER_NAME="${CLUSTER_NAME:-ops-kit}"
NAMESPACE="${NAMESPACE:-ops-demo}"
RELEASE="${RELEASE:-notes}"
CHART_DIR="${CHART_DIR:-charts/notes}"
# Values profile used for install and every upgrade (keep them identical).
VALUES_FILE="${VALUES_FILE:-${CHART_DIR}/values-ha.yaml}"
IMAGE_REPO="${IMAGE_REPO:-selfhosted-ops-kit/notes-api}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"

kc() { kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" "$@"; }
hm() { helm --kube-context "${KUBE_CONTEXT}" -n "${NAMESPACE}" "$@"; }

_ts() { date -u +%H:%M:%SZ; }
if [[ -t 1 || -n "${FORCE_COLOR:-}" ]]; then
  C_STEP=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_FAIL=$'\e[1;31m'; C_WARN=$'\e[1;33m'; C_OFF=$'\e[0m'
else
  C_STEP=""; C_OK=""; C_FAIL=""; C_WARN=""; C_OFF=""
fi
step() { printf '\n%s[%s] ==> %s%s\n' "${C_STEP}" "$(_ts)" "$*" "${C_OFF}"; }
info() { printf '[%s]     %s\n' "$(_ts)" "$*"; }
ok()   { printf '%s[%s]  OK %s%s\n' "${C_OK}" "$(_ts)" "$*" "${C_OFF}"; }
warn() { printf '%s[%s] WARN %s%s\n' "${C_WARN}" "$(_ts)" "$*" "${C_OFF}" >&2; }
die()  { printf '%s[%s] FAIL %s%s\n' "${C_FAIL}" "$(_ts)" "$*" "${C_OFF}" >&2; exit 1; }

# Print a command, then run it (makes logs and recordings self-explanatory).
run() { printf '%s$ %s%s\n' "${C_STEP}" "$*" "${C_OFF}"; "$@"; }

require() {
  local missing=()
  for bin in "$@"; do command -v "${bin}" > /dev/null 2>&1 || missing+=("${bin}"); done
  ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]} (see README 'Prerequisites')"
}

# Call the API from inside an API pod (no port-forward, works with NetworkPolicies on).
api() {
  local method="$1" path="$2" data="${3:-}"
  kc exec deploy/"${RELEASE}"-api -c api -- python -c '
import sys, urllib.request
method, url, data = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(url, data=data.encode() if data else None, method=method)
with urllib.request.urlopen(req, timeout=5) as r:
    print(r.read().decode())
' "${method}" "http://127.0.0.1:8080${path}" "${data}"
}

api_version() { api GET /version | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'; }

release_status() { hm status "${RELEASE}" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])'; }
release_revision() { hm status "${RELEASE}" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'; }

wait_api_ready() {
  kc rollout status deploy/"${RELEASE}"-api --timeout=180s
}

# Pre-change gate: the abort criteria from docs/runbooks/upgrade.md, checked automatically.
preflight() {
  step "Preflight checks (abort if any fails)"
  local status
  status="$(release_status)"
  [[ "${status}" == "deployed" ]] || die "release status is '${status}', expected 'deployed' - resolve first (runbooks/troubleshooting.md)"
  ok "release ${RELEASE} is deployed (revision $(release_revision))"

  local desired ready
  desired="$(kc get deploy "${RELEASE}-api" -o jsonpath='{.spec.replicas}')"
  ready="$(kc get deploy "${RELEASE}-api" -o jsonpath='{.status.readyReplicas}')"
  [[ "${ready:-0}" == "${desired}" ]] || die "API ready replicas ${ready:-0}/${desired}"
  ok "API ready replicas ${ready}/${desired}"

  kc get sts "${RELEASE}-postgres" -o jsonpath='{.status.readyReplicas}' | grep -qx 1 || die "PostgreSQL is not ready"
  ok "PostgreSQL ready"

  local allowed
  allowed="$(kc get pdb "${RELEASE}-api" -o jsonpath='{.status.disruptionsAllowed}' 2> /dev/null || echo "n/a")"
  if [[ "${allowed}" == "0" ]]; then die "PDB ${RELEASE}-api allows 0 disruptions"; fi
  ok "PDB disruptions allowed: ${allowed}"

  local usage
  usage="$(kc exec "${RELEASE}-postgres-0" -c postgres -- df -P /var/lib/postgresql/data | awk 'NR==2 {print $5}' | tr -d '%')"
  ((usage < 80)) || die "PostgreSQL volume ${usage}% full (threshold 80%)"
  ok "PostgreSQL volume usage ${usage}%"
}
