#!/usr/bin/env bash

# Create opensips-repo repository RPM

set -o errexit
set -o nounset
set -o pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

project_name="${1:?Usage: create-rpm-repo-package.sh <project> <major> <type> <local-rpm-dir>}"
major="${2:?Usage: create-rpm-repo-package.sh <project> <major> <type> <local-rpm-dir>}"
type="${3:?Usage: create-rpm-repo-package.sh <project> <major> <type> <local-rpm-dir>}"
local_rpm_dir="${4:?Usage: create-rpm-repo-package.sh <project> <major> <type> <local-rpm-dir>}"

[[ "$project_name" == "${PROJECT:-opensips}" ]] || exit 0
[[ -n "${DISTR_ID:-}" && -n "${DISTR_VER:-}" && -n "${DISTR_NAME_PURE:-}" ]] || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_dir="$script_dir/rpm-repo"
build_dir="${WORK_DIR}/rpmbuild-host"
spec_dir="${build_dir}/SPECS"
source_dir="$build_dir/SOURCES"
rpm_build_dir="$build_dir/RPMS"

spec_template="${template_dir}/opensips-repo.spec.m4"
repo_template="${template_dir}/opensips.repo.m4"
gpg_pub="${script_dir}/www/keys/opensips-org.asc"

if [[ ! -f "$spec_template" || ! -f "$repo_template" || ! -f "$gpg_pub" ]]; then
    fail "RPM repo-package templates or public key are missing"
fi

require_cmd m4
require_cmd rpmbuild

status=0
rpm_repo_part="$(rpm_repo_dir_part "$type" "$major")"
rpm_yum_type_value="$(rpm_yum_type "$type" "$major")"
rpm_yum_value="$(rpm_yum_name "$type" "$major")"
rpm_base_url="${RPM_REPO_URL%/}/${rpm_repo_part}/${DISTR_ID}/${DISTR_VER}/\$basearch"
yum_rpm="${project_name}-repo-${rpm_yum_value}-${RPM_REPO_PACKAGE_RELEASE}.${DISTR_NAME_PURE}.noarch"
yum_rpm_name="${yum_rpm}.rpm"

if [[ -f "$local_rpm_dir/$yum_rpm_name" ]]; then
    ln -sfn "$yum_rpm_name" "$local_rpm_dir/repository.rpm"
    exit 0
fi

buildroot="$build_dir/BUILDROOT/$yum_rpm"
mkdir -p "$spec_dir" "$source_dir" "$rpm_build_dir/noarch"
cp "$gpg_pub" "$source_dir/RPM-GPG-KEY-OPENSIPS"

m4vars=(
    -D "_MVERSION_=$major"
    -D "_TYPE_=$rpm_yum_type_value"
    -D "_YUM_NAME_=$rpm_yum_value"
    -D "_BASEURL_=$rpm_base_url"
    -D "_RELEASE_=$RPM_REPO_PACKAGE_RELEASE"
)

m4 "${m4vars[@]}" "$spec_template" >"$spec_dir/${project_name}-repo.spec"
m4 "${m4vars[@]}" "$repo_template" >"$source_dir/opensips.repo"

macro_rhel=0
macro_fedora=0
if [[ "$DISTR_ID" == "el" || "$DISTR_ID" == "st" ]]; then
    macro_rhel="$DISTR_VER"
elif [[ "$DISTR_ID" == "fc" ]]; then
    macro_fedora="$DISTR_VER"
fi

if rpmbuild -bb --target=noarch \
    --define="_topdir ${build_dir}" \
    --define="dist .${DISTR_NAME_PURE}" \
    --define="${DISTR_ID}${DISTR_VER} 1" \
    --define="rhel ${macro_rhel}" \
    --define="fedora ${macro_fedora}" \
    "$spec_dir/${project_name}-repo.spec"; then
    if [[ -f "$rpm_build_dir/noarch/$yum_rpm_name" ]]; then
        mv -f "$rpm_build_dir/noarch/$yum_rpm_name" "$local_rpm_dir/"
        ln -sfn "$yum_rpm_name" "$local_rpm_dir/repository.rpm"
    else
        warn "rpmbuild succeeded, but $yum_rpm_name was not found"
        status=1
    fi
else
    warn "Cannot create yum-repo rpm $yum_rpm_name"
    status=1
fi

rm -rf "$rpm_build_dir/noarch" "$buildroot" "$spec_dir/${project_name}-repo.spec" \
    "$source_dir/opensips.repo" "$source_dir/RPM-GPG-KEY-OPENSIPS"
exit "$status"
