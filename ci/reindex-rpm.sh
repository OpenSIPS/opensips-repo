#!/usr/bin/env bash

# Rebuild RPM repository metadata

set -o errexit
set -o nounset
set -o pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

repo_dir="${1:?Usage: reindex-rpm.sh <repo-dir>}"
cache_dir="${WORK_DIR}/cache"

require_cmd createrepo_c

if [[ ! -d "$repo_dir" ]]; then
    warn "RPM repo directory does not exist: $repo_dir"
    exit 0
fi

log "Reindexing RPM repo $repo_dir"
mkdir -p "$cache_dir/createrepo"
createrepo_c --quiet --update --cachedir="$cache_dir/createrepo" "$repo_dir"
refresh_repository_website
