#!/usr/bin/env bash

# Publish .deb files

set -o errexit
set -o nounset
set -o pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

suite="${1:?Usage: publish-deb-freight.sh <suite> <component> <deb...>}"
component="${2:?Usage: publish-deb-freight.sh <suite> <component> <deb...>}"
shift 2

require_cmd freight
require_cmd freight-cache
require_cmd gpg
setup_apt_signing_key
make_freight_conf

mkdir -p "$FREIGHT_DIR/$suite/$component"
for deb in "$@"; do
  [[ -f "$deb" ]] || continue
  log "freight add $(basename "$deb") apt/$suite/$component"
  freight-add -c "$FREIGHT_CONF" "$deb" "apt/${suite}/${component}"
done

# Cleanup old nightly/devel files before reindexing. Release packages are never matched here.
find "$FREIGHT_DIR" -name '*.deb' \( -path '*nightly*' -o -path '*devel*' \) -mtime +"$KEEP_DAYS" -type f -delete || true
find "$FREIGHT_DIR" -name '*.deb-control' \( -path '*nightly*' -o -path '*devel*' \) -mtime +"$KEEP_DAYS" -type f -delete || true

log "Reindexing APT suite $suite"
freight-cache -c "$FREIGHT_CONF" "apt/${suite}"
refresh_repository_website
