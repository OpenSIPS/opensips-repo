#!/usr/bin/env bash

# Build Debian/Ubuntu binary packages inside a disposable target OS container

set -o errexit
set -o nounset
set -o pipefail

: "${PROJECT:?PROJECT is required}"
: "${PROD_VER:?PROD_VER is required}"
: "${REL:?REL is required}"
: "${DISTR_ID:?DISTR_ID is required}"
: "${DISTR_VER:?DISTR_VER is required}"
: "${DISTR_ARCH:?DISTR_ARCH is required}"
: "${REAL_ARCH:?REAL_ARCH is required}"
: "${DEB_BUILD_PROFILES:=}"
: "${DEB_EXTRA_LOCAL_DEBS:=}"
: "${HOST_UID:=}"
: "${HOST_GID:=}"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

restore_output_owner() {
    if [[ "$HOST_UID" =~ ^[0-9]+$ && "$HOST_GID" =~ ^[0-9]+$ && -d /out ]]; then
        chown -R "$HOST_UID:$HOST_GID" /out || true
    fi
}

trap restore_output_owner EXIT

configure_apt_sources() {
    if [[ "$DISTR_ID" == "debian" && "$DISTR_VER" == "buster" ]]; then
        cat >/etc/apt/sources.list <<'EOF'
deb http://archive.debian.org/debian buster main contrib non-free
deb http://archive.debian.org/debian-security buster/updates main contrib non-free
EOF
        echo 'Acquire::Check-Valid-Until "false";' >/etc/apt/apt.conf.d/99no-check-valid-until
    fi
}

install_build_tools() {
    configure_apt_sources
    apt-get update

    apt-get install -y --no-install-recommends \
        apt-utils ca-certificates devscripts equivs fakeroot build-essential debconf \
        dpkg-dev debhelper git tar gzip xz-utils sed patch python3 python3-setuptools \
        pkg-config lintian

    if [[ "$PROJECT" == "opensips" && "${MAJOR:-}" == "4.0" && "$DISTR_VER" == "bullseye" ]]; then
        apt-get install -y --no-install-recommends python3-dev
    fi
}

prepare_debian_packaging() {
    rm -rf debian
    if [[ -d packaging/debian ]]; then
        cp -a packaging/debian debian
    else
        echo "No Debian packaging directory found in source tree" >&2
        exit 1
    fi

    sed -i "1 s/(.*)/(${PROD_VER}-${REL})/" debian/changelog
}

install_build_deps() {
    local local_debs=()
    if [[ -n "$DEB_EXTRA_LOCAL_DEBS" ]]; then
        read -r -a local_debs <<<"$DEB_EXTRA_LOCAL_DEBS"
        apt-get install -y --no-install-recommends "${local_debs[@]}"
    fi
    /ci/pbuilder/pbuilder-satisfydepends-experimental --control debian/control --binary-all
}

build_package() {
    local build_root="/build"
    local src_name="${PROJECT}-${PROD_VER}"
    rm -rf "$build_root"
    mkdir -p "$build_root"
    cp -a /src "$build_root/$src_name"

    cd "$build_root/$src_name"
    prepare_debian_packaging

    cd "$build_root"
    tar --exclude="${src_name}/.git" --exclude="${src_name}/debian" -czf "${PROJECT}_${PROD_VER}.orig.tar.gz" "$src_name"

    cd "$build_root/$src_name"
    install_build_deps

    if [[ -n "$DEB_BUILD_PROFILES" ]]; then
        echo "Using DEB_BUILD_PROFILES=$DEB_BUILD_PROFILES"
    fi

    dpkg-buildpackage -us -uc -b
    mkdir -p /out
    cp -a "$build_root"/*.deb /out/
    cp -a "$build_root"/*.changes "$build_root"/*.buildinfo /out/ 2>/dev/null || true
}

install_build_tools
build_package
