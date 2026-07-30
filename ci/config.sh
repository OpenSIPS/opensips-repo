#!/usr/bin/env bash

# Configuration

set -o nounset
set -o pipefail

BUILD_WHAT="${BUILD_WHAT:-4.0 3.6 devel}"
BUILD_FOR="${BUILD_FOR:-ubuntu-resolute/amd64 ubuntu-noble/amd64 ubuntu-jammy/amd64 \
                        debian-trixie/amd64 debian-bookworm/amd64 debian-bullseye/amd64 \
                        el-9/x86_64 st-9/x86_64}"
KEEP_DAYS=90

BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.opensips-build"
SOURCE_DIR="${BUILD_ROOT}/SOURCES"
WORK_DIR="${BUILD_ROOT}/work"
LOCK_DIR="${BUILD_ROOT}/locks"

WWW_DIR="${WWW_DIR:-/var/www}"
DEB_DIR="${DEB_DIR:-${WWW_DIR}/apt}"
RPM_DIR="${RPM_DIR:-${WWW_DIR}/rpm}"
ARCHIVE_DIR="${ARCHIVE_DIR:-${WWW_DIR}/download}"

OPENSIPS_SITE_URL="${OPENSIPS_SITE_URL:-https://www.opensips.org}"
APT_REPO_URL="${APT_REPO_URL:-https://apt.opensips.org}"
RPM_REPO_URL="${RPM_REPO_URL:-https://yum.opensips.org}"
DOWNLOAD_REPO_URL="${DOWNLOAD_REPO_URL:-https://download.opensips.org}"
RPM_REPO_PACKAGE_RELEASE="${RPM_REPO_PACKAGE_RELEASE:-7}"

# Persistent state that must survive workspace cleanup: GPG home and Freight library.
STATE_DIR="/var/cache/github-runner"
GIT_CACHE_DIR="${STATE_DIR}/git"
if [[ -n "${RUNNER_TEMP:-}" ]]; then
    GNUPGHOME="${GNUPGHOME:-${RUNNER_TEMP}/opensips-apt-gnupg}"
    APT_GPG_PASSPHRASE_FILE="${APT_GPG_PASSPHRASE_FILE:-${RUNNER_TEMP}/opensips-apt-gpg-passphrase}"
else
    GNUPGHOME="${GNUPGHOME:-${STATE_DIR}/gnupg}"
    APT_GPG_PASSPHRASE_FILE="${APT_GPG_PASSPHRASE_FILE:-${STATE_DIR}/apt-gpg-passphrase}"
fi
FREIGHT_LIB="${STATE_DIR}/freight"
FREIGHT_DIR="${FREIGHT_LIB}/apt"
FREIGHT_CONF="${STATE_DIR}/freight.conf"

GPG_KEY_NAME="info@opensips.org"

OPENSIPS_SOURCE_URL="https://github.com/OpenSIPS/opensips.git"
PYTHON_OPENSIPS_SOURCE_URL="${PYTHON_OPENSIPS_SOURCE_URL:-https://github.com/OpenSIPS/python-opensips.git}"
OPENSIPS_CLI_SOURCE_URL="${OPENSIPS_CLI_SOURCE_URL:-https://github.com/OpenSIPS/opensips-cli.git}"

export GNUPGHOME
