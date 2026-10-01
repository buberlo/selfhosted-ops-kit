#!/usr/bin/env bash
# Build the demo API image in the versions used by the upgrade/rollback flow.
# The versions share source code; only APP_VERSION differs. See README "Scope".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require docker

VERSIONS="${VERSIONS:-1.0.0 1.1.0}"
for v in ${VERSIONS}; do
  step "Building ${IMAGE_REPO}:${v}"
  run docker build --quiet --build-arg APP_VERSION="${v}" -t "${IMAGE_REPO}:${v}" "${REPO_ROOT}/app"
done
