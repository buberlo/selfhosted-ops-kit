#!/usr/bin/env bash
# Offline / air-gapped support. See docs/runbooks/offline-install.md.
#   mirror-images.sh list                 images the chart will run (rendered with VALUES_FILE)
#   mirror-images.sh save  images.tar     pull + save all images into one tarball (connected side)
#   mirror-images.sh load  images.tar     docker load the tarball (disconnected side)
#   mirror-images.sh push  REGISTRY       retag + push to an internal registry (disconnected side)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require helm

images() {
  helm template "${RELEASE}" "${CHART_DIR}" -f "${VALUES_FILE}" |
    awk '$1 == "image:" || $1 == "-" && $2 == "image:" { print $NF }' | tr -d '"' | sort -u
}
# docker.io is implicit for un-prefixed references.
normalise() { case "$1" in */*.*/* | *.*/* | *:*/*) echo "$1" ;; *) echo "docker.io/$1" ;; esac; }

cmd="${1:-list}"
case "${cmd}" in
  list)
    images
    ;;
  save)
    require docker
    out="${2:?usage: mirror-images.sh save <file.tar>}"
    mapfile -t list < <(images)
    for img in "${list[@]}"; do
      if [[ "${img}" == "${IMAGE_REPO}:"* ]] && docker image inspect "${img}" > /dev/null 2>&1; then
        info "local build ${img}"
      else
        run docker pull "${img}"
      fi
    done
    run docker save -o "${out}" "${list[@]}"
    sha256sum "${out}" | tee "${out}.sha256"
    ;;
  load)
    require docker
    in="${2:?usage: mirror-images.sh load <file.tar>}"
    [[ -f "${in}.sha256" ]] && sha256sum -c "${in}.sha256"
    run docker load -i "${in}"
    ;;
  push)
    require docker
    reg="${2:?usage: mirror-images.sh push <registry[:port]>}"
    for img in $(images); do
      full="$(normalise "${img}")"
      target="${reg}/${full#*/}"
      run docker tag "${img}" "${target}"
      run docker push "${target}"
    done
    cat << MSG

Install against the mirror with:
  --set global.imageRegistry=${reg}
MSG
    ;;
  *) die "unknown command: ${cmd}" ;;
esac
