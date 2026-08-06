#!/usr/bin/env bash

# Trigger Docker and SIPssert builds after their Bullseye package dependency is published.

set -o errexit
set -o nounset
set -o pipefail

MODE="${1:?Usage: $0 MODE VERSION}"
VERSION="${2:?Usage: $0 MODE VERSION}"

: "${DEPENDENT_BUILDS_GITHUB_TOKEN:?DEPENDENT_BUILDS_GITHUB_TOKEN is required}"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

dispatch_workflow() {
    local repository="$1" workflow="$2" ref="$3" inputs="$4" payload

    payload="$(jq -cn --arg ref "$ref" --argjson inputs "$inputs" \
        '{ref: $ref, inputs: $inputs}')"

    printf 'Triggering %s workflow %s on ref %s\n' "$repository" "$workflow" "$ref"
    curl --fail --silent --show-error --connect-timeout 15 --max-time 120 \
        --request POST \
        --header 'Accept: application/vnd.github+json' \
        --header "Authorization: Bearer ${DEPENDENT_BUILDS_GITHUB_TOKEN}" \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --data "$payload" \
        "${GITHUB_API_URL}/repos/${repository}/actions/workflows/${workflow}/dispatches"
}

trigger_docker_build() {
    local tag="$1" component="$2" inputs

    inputs="$(jq -cn --arg tag "$tag" --arg component "$component" \
        '{tag: $tag, component: $component}')"
    dispatch_workflow OpenSIPS/docker-opensips docker-opensips-publish.yml main "$inputs"
}

trigger_sipssert_build() {
    local ref="$1"

    dispatch_workflow OpenSIPS/sipssert-opensips-tests build-and-test.yml "$ref" '{}'
}

require_cmd curl
require_cmd jq

case "$MODE" in
    release)
        trigger_docker_build "$VERSION" "${VERSION}-releases"
        ;;
    nightly)
        trigger_sipssert_build "$VERSION"
        ;;
    devel)
        trigger_docker_build latest devel
        trigger_sipssert_build main
        ;;
    *)
        printf 'Unsupported build mode for dependent workflows: %s\n' "$MODE" >&2
        exit 1
        ;;
esac
