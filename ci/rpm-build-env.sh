#!/usr/bin/env bash

# Package-manager and repository helpers used inside RPM build containers.

rpm_select_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        RPM_PACKAGE_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        RPM_PACKAGE_MANAGER="yum"
    else
        echo "Neither DNF nor YUM was found" >&2
        return 1
    fi
    export RPM_PACKAGE_MANAGER
}

rpm_configure_sources() {
    local source_override="/ci/rpm-sources/${DISTR_ID}-${DISTR_VER}.repo"

    RPM_SOURCES_OVERRIDDEN=0
    if [[ -f "$source_override" ]]; then
        echo "Using RPM sources override: $source_override"
        rm -f /etc/yum.repos.d/*.repo
        cp "$source_override" /etc/yum.repos.d/opensips-build.repo
        RPM_SOURCES_OVERRIDDEN=1
    fi
    export RPM_SOURCES_OVERRIDDEN
}

rpm_limit_file_descriptors() {
    [[ "$DISTR_ID" == "el" && "$DISTR_VER" == "7" ]] || return 0

    # RPM 4.11 scans every possible fd before each scriptlet. Modern containerd
    # can supply a billion-fd limit, turning each package install into minutes.
    local open_files
    open_files="$(ulimit -Sn)"
    if [[ "$open_files" == "unlimited" || "$open_files" -gt 65536 ]]; then
        echo "Limit EL7 RPM scriptlet file descriptors: $open_files -> 65536"
        ulimit -Sn 65536
    fi
}

rpm_init() {
    rpm_limit_file_descriptors
    rpm_select_package_manager
    rpm_configure_sources
}

rpm_install() {
    "$RPM_PACKAGE_MANAGER" -y install "$@"
}

rpm_enable_repository() {
    local repository="$1"
    if [[ "$RPM_PACKAGE_MANAGER" == "dnf" ]]; then
        dnf -y config-manager --set-enabled "$repository"
    else
        yum-config-manager --enable "$repository"
    fi
}

rpm_prepare_build_repositories() {
    if [[ "$RPM_PACKAGE_MANAGER" == "dnf" ]]; then
        rpm_install dnf-plugins-core
    else
        rpm_install yum-utils
    fi

    if [[ "$RPM_SOURCES_OVERRIDDEN" -eq 0 \
        && ( "$DISTR_ID" == "el" || "$DISTR_ID" == "st" ) ]]; then
        if [[ "$DISTR_VER" == "8" ]]; then
            rpm_enable_repository powertools || true
        elif [[ "$DISTR_VER" != "7" ]]; then
            rpm_enable_repository crb || true
        fi
        rpm_install epel-release || true
    fi

    if [[ "$DISTR_ID" == "el" || "$DISTR_ID" == "st" ]]; then
        rpm_install epel-rpm-macros
    fi
}

rpm_install_local() {
    if [[ "$RPM_PACKAGE_MANAGER" == "dnf" ]]; then
        dnf -y install --nogpgcheck "$@"
    else
        yum -y --nogpgcheck localinstall "$@"
    fi
}

rpm_builddep() {
    local spec="$1"
    if [[ "$RPM_PACKAGE_MANAGER" == "dnf" ]]; then
        dnf -y builddep "$spec"
    else
        yum-builddep -y "$spec"
    fi
}
