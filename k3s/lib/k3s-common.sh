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
    command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
}

ensure_dirs() {
    local project_root="$1"
    mkdir -p "${project_root}/home" "${project_root}/config" "${project_root}/workspace" "${project_root}/outputs"
}
