#!/bin/bash

set -eu -o pipefail

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [sjob] $*" >&2
}

die() {
    log "FATAL: $*"
    exit 1
}

check_kubectl() {
    if [[ -n "${SYMPHONY_KUBECTL_WRAPPER:-}" ]]; then
        [[ -x "${SYMPHONY_KUBECTL_WRAPPER}" ]] || die "kubectl wrapper not executable: ${SYMPHONY_KUBECTL_WRAPPER}"
    else
        command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
    fi
}

check_envsubst() {
    command -v envsubst >/dev/null 2>&1 || die "envsubst not found"
}

kubectl_cmd() {
    if [[ -n "${SYMPHONY_KUBECTL_WRAPPER:-}" ]]; then
        "${SYMPHONY_KUBECTL_WRAPPER}" "$@"
    else
        kubectl "$@"
    fi
}

ensure_dirs() {
    local project_root="$1"
    mkdir -p "${project_root}/home" "${project_root}/config" "${project_root}/workspace" "${project_root}/outputs"
}
