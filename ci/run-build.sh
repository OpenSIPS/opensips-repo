#!/usr/bin/env bash

# Main entrypoint
# Runs all builds sequentially on one self-hosted runner

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Defaults (when started by cron)
MODE="${INPUT_MODE:-all}"
[[ "$MODE" == "both" ]] && MODE="all"
TAG="${INPUT_TAG:-}"
BUILD_WHAT="${INPUT_BUILD_WHAT:-$BUILD_WHAT}"
BUILD_FOR="${INPUT_BUILD_FOR:-$BUILD_FOR}"
BUILD_PROJECT="${BUILD_PROJECT:-all}"

if [[ "$MODE" != "www" ]]; then
    require_cmd docker
    require_cmd flock
    require_cmd git
    require_cmd rsync
    require_cmd tar
    require_cmd sort
    require_cmd find
fi

NICE_CMD="nice -n 5 ionice -c2 -n 5"
DOCKER_RUN_OPTS="--rm --network host"

REL=1
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

STATUS=0

is_build_project() {
    [[ "$BUILD_PROJECT" == "all" || "$BUILD_PROJECT" == "$1" ]]
}

deb_build_profiles() {
    local project_name="$1" major="$2" distro_ver="$3"
    local profiles=""
    if [[ "$project_name" == "opensips" ]]; then
        if [[ "$distro_ver" == "trixie" ]]; then
            profiles="${profiles} opentelemetry"
        elif [[ "$major" == "3.6" && "$distro_ver" != "resolute" ]]; then
            profiles="${profiles} nopcre2"
        fi
    fi
    xargs <<<"$profiles"
}

publish_debs() {
    local suite="$1" component="$2"
    shift 2
    "$SCRIPT_DIR/publish-deb.sh" "$suite" "$component" "$@"
}

first_shared_deb_path() {
    local type="$1" project_name="$2" prod_ver="$3" versions="$4" target="$5"
    local component
    parse_distro "$target"
    component="$(shared_deb_components "$type" "$versions" | head -n 1)"
    deb_repo_package_path_for_component "$DISTR_VER" "$component" "$project_name" "$prod_ver" "$REL" all
}

build_repository_rpm() {
    local type="$1" project_name="$2" major="$3" target="$4" image="$5" local_rpm_dir="$6"

    log "Build repository RPM $project_name $major $type for $target using $image"
    if ${NICE_CMD} docker run ${DOCKER_RUN_OPTS} \
        -e PROJECT="$project_name" \
        -e DISTR_ID="$DISTR_ID" \
        -e DISTR_VER="$DISTR_VER" \
        -e DISTR_NAME_PURE="$DISTR_NAME_PURE" \
        -e RPM_REPO_URL="$RPM_REPO_URL" \
        -e RPM_REPO_PACKAGE_RELEASE="$RPM_REPO_PACKAGE_RELEASE" \
        -e HOST_UID="$HOST_UID" \
        -e HOST_GID="$HOST_GID" \
        -v "$SCRIPT_DIR:/ci:ro" \
        -v "$local_rpm_dir:/repo" \
        "$image" bash -c '
            set -euo pipefail
            source /ci/rpm-build-env.sh
            rpm_init
            rpm_install rpm-build redhat-rpm-config m4 >/dev/null
            /ci/create-rpm-repo-package.sh "$@"
            if [[ "${HOST_UID}" =~ ^[0-9]+$ && "${HOST_GID}" =~ ^[0-9]+$ ]]; then
                chown -R "${HOST_UID}:${HOST_GID}" /repo || true
            fi
        ' bash "$project_name" "$major" "$type" /repo
    then
        return 0
    fi

    warn "Cannot build repository RPM $project_name $major $type for $target"
    return 1
}

run_deb_build() {
    local type="$1" project_name="$2" source_repo="$3" prod_ver="$4" major_or_versions="$5" target="$6" extra_deb="${7:-}"
    parse_distro "$target"

    local build_arch="$DISTR_ARCH"
    local real_arch="$DISTR_ARCH"
    if [[ "$project_name" != "opensips" ]]; then
        if ! is_deb_distro "$DISTR_NAME"; then
            warn "Skipping DEB build for non-DEB target: $target"
            return 0
        fi
        build_arch="amd64"
        real_arch="all"
    fi

    local component package_path missing=0
    local -a components deb_files docker_args
    if [[ "$project_name" == "opensips" ]]; then
        components=("$(deb_component "$type" "$major_or_versions")")
    else
        mapfile -t components < <(shared_deb_components "$type" "$major_or_versions")
    fi

    for component in "${components[@]}"; do
        if [[ "$project_name" == "opensips" ]]; then
            package_path="$(deb_repo_package_path "$type" "$project_name" "$prod_ver" "$major_or_versions" "$target" "$REL")"
        else
            package_path="$(deb_repo_package_path_for_component "$DISTR_VER" "$component" "$project_name" "$prod_ver" "$REL" "$real_arch")"
        fi
        if [[ -f "$package_path" ]]; then
            log "DEB already exists: $DISTR_VER/$component/${package_path##*/}"
        else
            missing=1
        fi
    done
    if [[ "$missing" -eq 0 ]]; then
        return 0
    fi

    local image safe_target staged out dep_mount_path
    image="$(docker_image_for_target "$target")"
    safe_target="${target//\//_}"
    staged="$WORK_DIR/staged/deb/${type}/${project_name}/${prod_ver}/${safe_target}"
    out="$WORK_DIR/out/deb/${type}/${project_name}/${prod_ver}/${safe_target}"
    rm -rf "$out"
    mkdir -p "$out"

    stage_source_tree "$source_repo" "$(git_short_sha "$source_repo")" "$staged"

    log "Build DEB $project_name $prod_ver for $target using $image"
    docker_args=(
        --rm
        --network host
        -e PROJECT="$project_name"
        -e PROD_VER="$prod_ver"
        -e REL="$REL"
        -e MAJOR="$major_or_versions"
        -e DISTR_ID="$DISTR_ID"
        -e DISTR_VER="$DISTR_VER"
        -e DISTR_NAME="$DISTR_NAME"
        -e DISTR_ARCH="$build_arch"
        -e REAL_ARCH="$real_arch"
        -e HOST_UID="$HOST_UID"
        -e HOST_GID="$HOST_GID"
        -e DEB_BUILD_PROFILES="$(deb_build_profiles "$project_name" "$major_or_versions" "$DISTR_VER")"
        -e PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        -v "$staged:/src:ro"
        -v "$out:/out"
        -v "$SCRIPT_DIR:/ci:ro"
    )
    if [[ -n "$extra_deb" ]]; then
        dep_mount_path="/deps/${extra_deb##*/}"
        docker_args+=(
            -e DEB_EXTRA_LOCAL_DEBS="$dep_mount_path"
            -v "$extra_deb:$dep_mount_path:ro"
        )
    fi

    if ${NICE_CMD} docker run "${docker_args[@]}" "$image" bash /ci/build-deb.sh
    then
        mapfile -t deb_files < <(find "$out" -maxdepth 1 -type f -name '*.deb' | sort)
        if [[ "${#deb_files[@]}" -eq 0 ]]; then
            warn "DEB build produced no .deb files for $project_name $prod_ver $target"
            STATUS=1
            return 0
        fi
        for component in "${components[@]}"; do
            publish_debs "$DISTR_VER" "$component" "${deb_files[@]}"
        done
        log "DEB build done: $project_name $prod_ver for $target"
    else
        err "Cannot build DEB $project_name $prod_ver for $target"
        STATUS=1
    fi
}

run_rpm_build() {
    local type="$1" project_name="$2" source_repo="$3" prod_ver="$4" major_or_versions="$5" target="$6" extra_rpm="${7:-}"
    parse_distro "$target"

    if ! is_rpm_distro "$DISTR_NAME"; then
        warn "Skipping RPM build for non-RPM target: $target"
        return 0
    fi

    local build_arch="$DISTR_ARCH"
    local real_arch="$DISTR_ARCH"
    if [[ "$project_name" != "opensips" ]]; then
        build_arch="x86_64"
        real_arch="noarch"
    fi
    [[ "$real_arch" == "i386" ]] && real_arch="i686"

    local image safe_target staged out dep_mount_path package_path missing=0
    local repo_part local_rpm_dir local_srpm_dir repo_rpm_path
    local -a repo_parts rpm_files srpm_files docker_args
    if [[ "$project_name" == "opensips" ]]; then
        repo_parts=("$(rpm_repo_dir_part "$type" "$major_or_versions")")
    else
        mapfile -t repo_parts < <(shared_rpm_repo_parts "$type" "$major_or_versions")
    fi
    [[ "${#repo_parts[@]}" -gt 0 ]] || { warn "No RPM repositories selected for $project_name $prod_ver"; return 0; }

    for repo_part in "${repo_parts[@]}"; do
        local_rpm_dir="$RPM_DIR/$repo_part/$DISTR_ID/$DISTR_VER/$DISTR_ARCH"
        local_srpm_dir="$RPM_DIR/$repo_part/$DISTR_ID/$DISTR_VER/SRPMS"
        mkdir -p "$local_rpm_dir" "$local_srpm_dir"
        package_path="$(rpm_repo_package_path_for_part "$repo_part" "$project_name" "$prod_ver" "$target" "$REL")"
        if [[ -f "$package_path" ]]; then
            log "RPM already exists: $package_path"
        else
            missing=1
        fi
    done

    image="$(docker_image_for_target "$target")"
    if [[ "$missing" -eq 0 ]]; then
        if [[ "$project_name" == "opensips" ]]; then
            repo_part="${repo_parts[0]}"
            local_rpm_dir="$RPM_DIR/$repo_part/$DISTR_ID/$DISTR_VER/$DISTR_ARCH"
            repo_rpm_path="$(rpm_repository_package_path "$type" "$project_name" "$major_or_versions" "$target")"
            if [[ ! -f "$repo_rpm_path" ]]; then
                if ! build_repository_rpm "$type" "$project_name" "$major_or_versions" "$target" "$image" "$local_rpm_dir"; then
                    STATUS=1
                    return 0
                fi
                [[ -f "$repo_rpm_path" ]] || { warn "Repository RPM was not created: $repo_rpm_path"; STATUS=1; return 0; }
                sign_rpms "$repo_rpm_path"
                "$SCRIPT_DIR/reindex-rpm.sh" "$local_rpm_dir"
            else
                log "Repository RPM already exists: $repo_rpm_path"
            fi
        fi
        return 0
    fi

    safe_target="${target//\//_}"
    staged="$WORK_DIR/staged/rpm/${type}/${project_name}/${prod_ver}/${safe_target}"
    out="$WORK_DIR/out/rpm/${type}/${project_name}/${prod_ver}/${safe_target}"
    rm -rf "$out"
    mkdir -p "$out"

    stage_source_tree "$source_repo" "$(git_short_sha "$source_repo")" "$staged"
    apply_rpm_compat_patches "$project_name" "$target" "$staged"

    log "Build RPM $project_name $prod_ver for $target using $image"
    docker_args=(
        --rm
        --network host
        -e PROJECT="$project_name"
        -e PROD_VER="$prod_ver"
        -e REL="$REL"
        -e MAJOR="$major_or_versions"
        -e DISTR_ID="$DISTR_ID"
        -e DISTR_VER="$DISTR_VER"
        -e DISTR_NAME="$DISTR_NAME"
        -e DISTR_NAME_PURE="$DISTR_NAME_PURE"
        -e DISTR_ARCH="$build_arch"
        -e REAL_ARCH="$real_arch"
        -e HOST_UID="$HOST_UID"
        -e HOST_GID="$HOST_GID"
        -v "$staged:/src:ro"
        -v "$SCRIPT_DIR:/ci:ro"
        -v "$out:/out"
    )
    if [[ -n "$extra_rpm" ]]; then
        dep_mount_path="/deps/${extra_rpm##*/}"
        docker_args+=(
            -e RPM_EXTRA_LOCAL_RPMS="$dep_mount_path"
            -v "$extra_rpm:$dep_mount_path:ro"
        )
    fi

    if ${NICE_CMD} docker run "${docker_args[@]}" "$image" bash /ci/build-rpm.sh
    then
        mapfile -t rpm_files < <(find "$out/RPMS" -type f -name '*.rpm' ! -name '*.src.rpm' | sort || true)
        mapfile -t srpm_files < <(find "$out/SRPMS" -type f -name '*.src.rpm' | sort || true)
        if [[ "${#rpm_files[@]}" -eq 0 ]]; then
            warn "RPM build produced no .rpm files for $project_name $prod_ver $target"
            STATUS=1
            return 0
        fi
        sign_rpms "${rpm_files[@]}" "${srpm_files[@]}"
        for repo_part in "${repo_parts[@]}"; do
            local_rpm_dir="$RPM_DIR/$repo_part/$DISTR_ID/$DISTR_VER/$DISTR_ARCH"
            local_srpm_dir="$RPM_DIR/$repo_part/$DISTR_ID/$DISTR_VER/SRPMS"
            mkdir -p "$local_rpm_dir" "$local_srpm_dir"
            for rpm_file in "${rpm_files[@]}"; do
                cp -f "$rpm_file" "$local_rpm_dir/"
            done
            for srpm_file in "${srpm_files[@]}"; do
                cp -f "$srpm_file" "$local_srpm_dir/${project_name}-${prod_ver}.src.rpm"
            done

            if [[ "$project_name" == "opensips" ]]; then
                if ! build_repository_rpm "$type" "$project_name" "$major_or_versions" "$target" "$image" "$local_rpm_dir"; then
                    STATUS=1
                    return 0
                fi
                repo_rpm_path="$(rpm_repository_package_path "$type" "$project_name" "$major_or_versions" "$target")"
                [[ -f "$repo_rpm_path" ]] || { warn "Repository RPM was not created: $repo_rpm_path"; STATUS=1; return 0; }
                sign_rpms "$repo_rpm_path"
                log "Repository RPM done: $repo_rpm_path"
            fi
            "$SCRIPT_DIR/reindex-rpm.sh" "$local_rpm_dir"
            "$SCRIPT_DIR/reindex-rpm.sh" "$local_srpm_dir"
        done
        cleanup_expiring_files "$RPM_DIR"
        log "RPM build done: $project_name $prod_ver for $target"
    else
        warn "Cannot build RPM $project_name $prod_ver for $target"
        STATUS=1
    fi
}

build_opensips() {
    local type="$1" ref="$2" major="$3" prod_deb="$4" prod_rpm="$5"
    local repo="$SOURCE_DIR/opensips-${major}.git"
    prepare_git_repo opensips "$OPENSIPS_SOURCE_URL" "$ref" "$repo"

    if [[ "$type" == "releases" ]]; then
        archive_release_tarball "$repo" opensips "$prod_rpm" "$(git_short_sha "$repo")"
    fi

    local target="$BUILD_FOR"
    parse_distro "$target"
    log "Distribution: $target"
    if is_rpm_distro "$DISTR_NAME"; then
        run_rpm_build "$type" opensips "$repo" "$prod_rpm" "$major" "$target"
    elif is_deb_distro "$DISTR_NAME"; then
        run_deb_build "$type" opensips "$repo" "$prod_deb" "$major" "$target"
    else
        warn "Unknown target family: $target"
    fi
}

build_release_from_tag() {
    local tag="$1"
    [[ -n "$tag" ]] || fail "Release mode requires INPUT_TAG/tag"
    local major prod_ver repo
    major="$(version_from_tag "$tag")" || fail "Cannot infer major version from tag: $tag"
    if ! contains_word_in_string "$major" "$BUILD_WHAT"; then
        warn "Tag $tag belongs to $major, which is not in BUILD_WHAT=[$BUILD_WHAT]; building it anyway because explicit tag was requested"
    fi
    repo="$SOURCE_DIR/opensips-${major}.git"
    prepare_git_repo opensips "$OPENSIPS_SOURCE_URL" "$tag" "$repo"
    prod_ver="$(package_version_from_tag "$tag")"
    log ">>> opensips-$major release tag=$tag"
    build_opensips releases "$tag" "$major" "$prod_ver" "$prod_ver"
}

build_latest_release() {
    local major="$BUILD_WHAT" repo tag prod_ver real_ref
    is_devel_build "$major" && { warn "Skipping release build for devel"; return 0; }
    real_ref="master"
    repo="$SOURCE_DIR/opensips-${major}.git"
    prepare_git_repo opensips "$OPENSIPS_SOURCE_URL" "$real_ref" "$repo"
    tag="$(latest_tag_for_version "$repo" "$major" || true)"
    [[ -n "$tag" ]] || { warn "No tags found for $major"; return 0; }
    prod_ver="$(package_version_from_tag "$tag")"
    log ">>> opensips-$major latest release tag=$tag"
    build_opensips releases "$tag" "$major" "$prod_ver" "$prod_ver"
}

build_opensips_nightly() {
    local major="$BUILD_WHAT" real_ref repo git_release git_date last_tag last_tag_rpm prod_deb prod_rpm
    if is_devel_build "$major"; then
        build_opensips_devel
        return 0
    fi
    log ">>> opensips-$major nightly"
    real_ref="$major"
    repo="$SOURCE_DIR/opensips-${major}.git"
    prepare_git_repo opensips "$OPENSIPS_SOURCE_URL" "$real_ref" "$repo"
    git_release="$(git_short_sha "$repo")"
    git_date="$(git_commit_date "$repo")"
    last_tag="$(latest_tag_for_version "$repo" "$major" || true)"
    [[ -n "$last_tag" ]] || last_tag="${major}.0"
    last_tag="$(package_version_from_tag "$last_tag")"
    last_tag_rpm="$last_tag"
    prod_deb="${last_tag}~${git_date}~${git_release}"
    prod_rpm="${last_tag_rpm}.${git_date}.${git_release}"
    build_opensips nightly "$real_ref" "$major" "$prod_deb" "$prod_rpm"
}

build_opensips_devel() {
    local ref="master" repo git_release git_date base_ver major prod_deb prod_rpm
    repo="$SOURCE_DIR/opensips-devel.git"
    prepare_git_repo opensips "$OPENSIPS_SOURCE_URL" "$ref" "$repo"
    git_release="$(git_short_sha "$repo")"
    git_date="$(git_commit_date "$repo")"
    base_ver="$(opensips_makefile_version "$repo")"
    major="$(major_from_product_version "$base_ver")"
    prod_deb="${base_ver}~${git_date}~${git_release}"
    prod_rpm="${base_ver}.${git_date}.${git_release}"
    log ">>> opensips-$major devel"
    build_opensips devel "$ref" "$major" "$prod_deb" "$prod_rpm"
}

AUX_PACKAGE_DEB_PATH=""
AUX_PACKAGE_RPM_PATH=""
PYTHON_AUX_RELEASE_DEB_PATH=""
PYTHON_AUX_RELEASE_RPM_PATH=""
PYTHON_AUX_NIGHTLY_DEB_PATH=""
PYTHON_AUX_NIGHTLY_RPM_PATH=""
PYTHON_AUX_DEVEL_DEB_PATH=""
PYTHON_AUX_DEVEL_RPM_PATH=""

build_aux_project() {
    local project_key="$1" type="$2" versions="$3" target="$4" extra_deb="${5:-}" extra_rpm="${6:-}"
    local package_name repo_name source_url default_ref repo git_release git_date tag prod_deb prod_rpm

    package_name="$(aux_project_package_name "$project_key")" || fail "Unknown auxiliary project: $project_key"
    repo_name="$(aux_project_repo_name "$project_key")"
    source_url="$(aux_project_source_url "$project_key")"
    default_ref="$(aux_project_default_ref "$project_key")"
    repo="$SOURCE_DIR/${repo_name}.git"

    case "$type" in
        releases)
            prepare_git_repo "$repo_name" "$source_url" "$default_ref" "$repo"
            tag="$(latest_tag "$repo")"
            [[ -n "$tag" ]] || { warn "No tags found for $package_name"; return 0; }
            prepare_git_repo "$repo_name" "$source_url" "$tag" "$repo"
            prod_deb="$tag"
            prod_rpm="${tag//-/.}"
            ;;
        nightly|devel)
            prepare_git_repo "$repo_name" "$source_url" "$default_ref" "$repo"
            git_release="$(git_short_sha "$repo")"
            git_date="$(git_commit_date "$repo")"
            tag="$(latest_tag "$repo")"
            [[ -n "$tag" ]] || tag="0.0.0"
            prod_deb="${tag}~${git_date}~${git_release}"
            prod_rpm="${tag//-/.}.${git_date}.${git_release}"
            ;;
        *)
            fail "Unknown auxiliary build type: $type"
            ;;
    esac

    log ">>> $package_name $type"
    AUX_PACKAGE_DEB_PATH=""
    AUX_PACKAGE_RPM_PATH=""
    parse_distro "$target"
    if is_deb_distro "$DISTR_NAME"; then
        run_deb_build "$type" "$package_name" "$repo" "$prod_deb" "$versions" "$target" "$extra_deb"
        AUX_PACKAGE_DEB_PATH="$(first_shared_deb_path "$type" "$package_name" "$prod_deb" "$versions" "$target")"
    elif is_rpm_distro "$DISTR_NAME"; then
        run_rpm_build "$type" "$package_name" "$repo" "$prod_rpm" "$versions" "$target" "$extra_rpm"
        AUX_PACKAGE_RPM_PATH="$(first_shared_rpm_path "$type" "$package_name" "$prod_rpm" "$versions" "$target" "$REL")"
    else
        warn "Unknown target family: $target"
    fi
}

build_python_aux_release() {
    build_aux_project python releases "$BUILD_WHAT" "$BUILD_FOR"
    PYTHON_AUX_RELEASE_DEB_PATH="$AUX_PACKAGE_DEB_PATH"
    PYTHON_AUX_RELEASE_RPM_PATH="$AUX_PACKAGE_RPM_PATH"
}

build_python_aux_nightly() {
    build_aux_project python nightly "$BUILD_WHAT" "$BUILD_FOR"
    PYTHON_AUX_NIGHTLY_DEB_PATH="$AUX_PACKAGE_DEB_PATH"
    PYTHON_AUX_NIGHTLY_RPM_PATH="$AUX_PACKAGE_RPM_PATH"
}

build_python_aux_devel() {
    build_aux_project python devel devel "$BUILD_FOR"
    PYTHON_AUX_DEVEL_DEB_PATH="$AUX_PACKAGE_DEB_PATH"
    PYTHON_AUX_DEVEL_RPM_PATH="$AUX_PACKAGE_RPM_PATH"
}

build_cli_aux_project() {
    local type="$1" versions="$2" label="$3" python_build_func="$4" deb_var="$5" rpm_var="$6"
    local extra_deb="" extra_rpm="" dep_path=""

    parse_distro "$BUILD_FOR"
    if is_deb_distro "$DISTR_NAME"; then
        dep_path="${!deb_var}"
        if [[ -z "$dep_path" ]]; then
            "$python_build_func"
            dep_path="${!deb_var}"
        fi
        if [[ ! -f "$dep_path" ]]; then
            warn "Cannot build opensips-cli $label without $dep_path"
            STATUS=1
            return 0
        fi
        extra_deb="$dep_path"
    elif is_rpm_distro "$DISTR_NAME"; then
        dep_path="${!rpm_var}"
        if [[ -z "$dep_path" ]]; then
            "$python_build_func"
            dep_path="${!rpm_var}"
        fi
        if [[ ! -f "$dep_path" ]]; then
            warn "Cannot build opensips-cli $label without $dep_path"
            STATUS=1
            return 0
        fi
        extra_rpm="$dep_path"
    else
        warn "Unknown target family: $BUILD_FOR"
        return 0
    fi

    build_aux_project cli "$type" "$versions" "$BUILD_FOR" "$extra_deb" "$extra_rpm"
}

build_cli_aux_release() {
    build_cli_aux_project releases "$BUILD_WHAT" release build_python_aux_release \
        PYTHON_AUX_RELEASE_DEB_PATH PYTHON_AUX_RELEASE_RPM_PATH
}

build_cli_aux_nightly() {
    build_cli_aux_project nightly "$BUILD_WHAT" nightly build_python_aux_nightly \
        PYTHON_AUX_NIGHTLY_DEB_PATH PYTHON_AUX_NIGHTLY_RPM_PATH
}

build_cli_aux_devel() {
    build_cli_aux_project devel devel devel build_python_aux_devel \
        PYTHON_AUX_DEVEL_DEB_PATH PYTHON_AUX_DEVEL_RPM_PATH
}

main() {
    log "Start build job"
    log "Mode=$MODE Versions=[$BUILD_WHAT] Distros=[$BUILD_FOR] Project=[$BUILD_PROJECT]"

    case "$MODE" in
        release)
            if is_build_project opensips; then
                if [[ -n "$TAG" ]]; then
                    build_release_from_tag "$TAG"
                else
                    build_latest_release
                fi
            fi
            is_build_project python && build_python_aux_release
            is_build_project cli && build_cli_aux_release
        ;;
        nightly)
            is_build_project opensips && build_opensips_nightly
            is_build_project python && build_python_aux_nightly
            is_build_project cli && build_cli_aux_nightly
#      is_build_project python && build_python_like_nightly python3-opensips python-opensips "$PYTHON_OPENSIPS_SOURCE_URL" main \
#        "from opensips.version import __version__; print(__version__)"
#      is_build_project cli && build_python_like_nightly opensips-cli opensips-cli "$OPENSIPS_CLI_SOURCE_URL" master \
#        "from opensipscli.version import __version__; print(__version__)"
            ;;
        devel)
            is_build_project opensips && build_opensips_devel
            is_build_project python && build_python_aux_devel
            is_build_project cli && build_cli_aux_devel
            ;;
        all)
            if is_build_project opensips; then
                if [[ -n "$TAG" ]]; then
                    build_release_from_tag "$TAG"
                else
                    build_latest_release
                fi
            fi
            is_build_project opensips && build_opensips_nightly
            is_build_project python && build_python_aux_release
            is_build_project cli && build_cli_aux_release
            is_build_project python && build_python_aux_nightly
            is_build_project cli && build_cli_aux_nightly
#      is_build_project python && build_python_like_nightly python3-opensips python-opensips "$PYTHON_OPENSIPS_SOURCE_URL" main \
#        "from opensips.version import __version__; print(__version__)"
#      is_build_project cli && build_python_like_nightly opensips-cli opensips-cli "$OPENSIPS_CLI_SOURCE_URL" master \
#        "from opensipscli.version import __version__; print(__version__)"
            ;;
        cli)
            build_python_aux_release
            build_cli_aux_release
            build_python_aux_nightly
            build_cli_aux_nightly
            build_python_aux_devel
            build_cli_aux_devel
            ;;
        www)
            log "Website-only mode; package build skipped"
            ;;
        *)
            fail "Unknown mode: $MODE"
            ;;
    esac

    log "Build job done with status=$STATUS"
    exit "$STATUS"
}

if [[ "$MODE" == "www" ]]; then
    main "$@"
fi

mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/build-opensips.lock"
flock 9
main "$@"
