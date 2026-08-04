#!/usr/bin/env bash


### DONT FORGET TO GENERATE opensips-repo- package with repository



# Build RPM/SRPM packages inside a disposable target OS container.

set -o errexit
set -o nounset
set -o pipefail

: "${PROJECT:?PROJECT is required}"
: "${PROD_VER:?PROD_VER is required}"
: "${REL:?REL is required}"
: "${DISTR_ID:?DISTR_ID is required}"
: "${DISTR_VER:?DISTR_VER is required}"
: "${DISTR_NAME_PURE:?DISTR_NAME_PURE is required}"
: "${DISTR_ARCH:?DISTR_ARCH is required}"
: "${REAL_ARCH:?REAL_ARCH is required}"
: "${HOST_UID:=}"
: "${HOST_GID:=}"
: "${RPM_EXTRA_LOCAL_RPMS:=}"

restore_output_owner() {
    if [[ "$HOST_UID" =~ ^[0-9]+$ && "$HOST_GID" =~ ^[0-9]+$ && -d /out ]]; then
        chown -R "$HOST_UID:$HOST_GID" /out || true
    fi
}

trap restore_output_owner EXIT

install_build_tools() {
    if command -v dnf >/dev/null 2>&1; then
        dnf -y install dnf-plugins-core || true
        if [[ "$DISTR_ID" == "el" || "$DISTR_ID" == "st" ]]; then
            if [[ "$DISTR_VER" == "8" ]]; then
                dnf -y config-manager --set-enabled powertools || true
            else
                dnf -y config-manager --set-enabled crb || true
            fi
        fi
        dnf -y install epel-release || true
        dnf -y install rpm-build rpm-sign redhat-rpm-config make gcc gcc-c++ git tar gzip sed m4 which findutils python3 python3-setuptools ca-certificates perl-devel perl-generators
    else
        echo "DNF not found" >&2
        exit 1
    fi
}

prepare_spec() {
    local spec_source="" spec="/root/rpmbuild/SPECS/${PROJECT}.spec"
    if [[ -f "/src/packaging/redhat_fedora/${PROJECT}.spec" ]]; then
        spec_source="/src/packaging/redhat_fedora/${PROJECT}.spec"
    elif [[ -f "/src/packaging/fedora/${PROJECT}.spec" ]]; then
        spec_source="/src/packaging/fedora/${PROJECT}.spec"
    elif [[ -f "/src/packaging/rpm/${PROJECT}.spec" ]]; then
        spec_source="/src/packaging/rpm/${PROJECT}.spec"
    else
        echo "No RPM spec found for ${PROJECT}" >&2
        exit 1
    fi

    cp -f "$spec_source" "$spec"
    sed -i "s/^Version:.*/Version:  ${PROD_VER}/" "$spec"
    sed -i "s/^Release:.*/Release:  ${REL}%{?dist}/" "$spec"

    # Fallback for el/st <10
    if [[ "$(rpm --eval '%{bash_completions_dir}')" == "%{bash_completions_dir}" ]] \
        && ! grep -Eq '^[[:space:]]*%(global|define)[[:space:]]+bash_completions_dir\b' "$spec"; then
        sed -i '1i%global bash_completions_dir %{_datadir}/bash-completion/completions' "$spec"
    fi
}

install_build_deps() {
    local spec="/root/rpmbuild/SPECS/${PROJECT}.spec"
    local local_rpms=()
    if [[ -n "$RPM_EXTRA_LOCAL_RPMS" ]]; then
        read -r -a local_rpms <<<"$RPM_EXTRA_LOCAL_RPMS"
        dnf -y install --nogpgcheck "${local_rpms[@]}"
    fi
    dnf -y builddep "$spec"
}

build_package() {
    local top="/root/rpmbuild"
    local src_name="${PROJECT}-${PROD_VER}"
    mkdir -p "$top/BUILD" "$top/BUILDROOT" "$top/RPMS" "$top/SOURCES" "$top/SPECS" "$top/SRPMS"
    rm -rf "/tmp/${src_name}"
    cp -a /src "/tmp/${src_name}"
    tar --exclude="${src_name}/.git" -czf "$top/SOURCES/${src_name}.tar.gz" -C /tmp "$src_name"

    prepare_spec
    install_build_deps

    local macro_rhel="0"
    local macro_fedora="0"
    if [[ "$DISTR_ID" == "el" || "$DISTR_ID" == "st" ]]; then
        macro_rhel="$DISTR_VER"
    elif [[ "$DISTR_ID" == "fc" ]]; then
        macro_fedora="$DISTR_VER"
    fi

    rpmbuild -ba \
        --target="$DISTR_ARCH" \
        --define "_topdir ${top}" \
        --define "dist .${DISTR_NAME_PURE}" \
        --define "${DISTR_ID}${DISTR_VER} 1" \
        --define "rhel ${macro_rhel}" \
        --define "fedora ${macro_fedora}" \
        "$top/SPECS/${PROJECT}.spec"

    mkdir -p /out/RPMS /out/SRPMS
    find "$top/RPMS" -type f -name '*.rpm' -exec cp -a {} /out/RPMS/ \;
    find "$top/SRPMS" -type f -name '*.src.rpm' -exec cp -a {} /out/SRPMS/ \;
}

install_build_tools
build_package
