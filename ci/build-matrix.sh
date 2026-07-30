#!/usr/bin/env bash

# Generate the GitHub Actions build matrix from workflow inputs and config defaults.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib.sh"

require_cmd git
require_cmd jq
require_cmd flock

MODE="${INPUT_MODE:-all}"
[[ "$MODE" == "both" ]] && MODE="all"
TAG="${INPUT_TAG:-}"
BUILD_WHAT="${INPUT_BUILD_WHAT:-$BUILD_WHAT}"
BUILD_FOR="${INPUT_BUILD_FOR:-$BUILD_FOR}"
REL=1

if [[ "${GITHUB_EVENT_NAME:-}" == "schedule" ]]; then
    MODE="nightly"
fi

if [[ "$MODE" == "www" ]]; then
    jq -cn '{include: []}'
    exit 0
fi

record_matrix_skip() {
    local label="$1" tag="$2" package_path="$3"
    local display_path="$package_path"
    [[ -n "$tag" ]] && label="$label / $tag"
    if [[ "$display_path" == "$FREIGHT_LIB/"* ]]; then
        display_path="${display_path#"$FREIGHT_LIB/"}"
    elif [[ "$display_path" == "$WWW_DIR/"* ]]; then
        display_path="${display_path#"$WWW_DIR/"}"
    fi
    printf 'Skipping %s: package already exists: %s\n' "$label" "$display_path" >&2
    if [[ -n "${BUILD_MATRIX_SKIPPED_FILE:-}" ]]; then
        printf '%s\n' "- $label: already exists: \`$display_path\`" >>"$BUILD_MATRIX_SKIPPED_FILE"
    fi
}

resolve_opensips_matrix_entry() {
    local mode="$1" version="$2" tag="$3"
    local repo real_ref git_release git_date git_release_version last_tag last_tag_rpm resolved_tag

    MATRIX_TYPE=""
    MATRIX_MODE="$mode"
    MATRIX_TAG=""
    MATRIX_VERSION="$version"
    MATRIX_PROD_DEB=""
    MATRIX_PROD_RPM=""

    case "$mode" in
        release)
            MATRIX_TYPE="releases"
            if [[ -n "$tag" ]]; then
                resolved_tag="$tag"
            else
                if is_devel_build "$version"; then
                    printf 'Skipping release / opensips / devel: devel has no release packages\n' >&2
                    return 1
                fi
                real_ref="master"
                repo="$SOURCE_DIR/opensips-${version}.git"
                prepare_git_repo opensips "$OPENSIPS_SOURCE_URL" "$real_ref" "$repo" >&2
                resolved_tag="$(latest_tag_for_version "$repo" "$version" || true)"
                if [[ -z "$resolved_tag" ]]; then
                    printf 'Skipping release / opensips / %s: no tags found\n' "$version" >&2
                    return 1
                fi
            fi
            MATRIX_TAG="$resolved_tag"
            MATRIX_PROD_DEB="$(package_version_from_tag "$resolved_tag")"
            MATRIX_PROD_RPM="$MATRIX_PROD_DEB"
            ;;
        nightly)
            if is_devel_build "$version"; then
                resolve_opensips_matrix_entry devel "$version" "$tag"
                return $?
            fi
            MATRIX_TYPE="nightly"
            real_ref="$version"
            repo="$SOURCE_DIR/opensips-${version}.git"
            prepare_git_repo opensips "$OPENSIPS_SOURCE_URL" "$real_ref" "$repo" >&2
            git_release="$(git_short_sha "$repo")"
            git_date="$(git_commit_date "$repo")"
            last_tag="$(latest_tag_for_version "$repo" "$version" || true)"
            [[ -n "$last_tag" ]] || last_tag="${version}.0"
            last_tag="$(package_version_from_tag "$last_tag")"
            last_tag_rpm="$last_tag"
            MATRIX_PROD_DEB="${last_tag}~${git_date}~${git_release}"
            MATRIX_PROD_RPM="${last_tag_rpm}.${git_date}.${git_release}"
            ;;
        devel)
            MATRIX_TYPE="devel"
            MATRIX_MODE="devel"
            real_ref="master"
            repo="$SOURCE_DIR/opensips-devel.git"
            prepare_git_repo opensips "$OPENSIPS_SOURCE_URL" "$real_ref" "$repo" >&2
            git_release="$(git_short_sha "$repo")"
            git_date="$(git_commit_date "$repo")"
            git_release_version="$(opensips_makefile_version "$repo")"
            MATRIX_VERSION="$(major_from_product_version "$git_release_version")"
            MATRIX_PROD_DEB="${git_release_version}~${git_date}~${git_release}"
            MATRIX_PROD_RPM="${git_release_version}.${git_date}.${git_release}"
            ;;
        *)
            fail "Unknown matrix mode: $mode"
            ;;
    esac
}

resolve_aux_matrix_entry() {
    local mode="$1" project="$2"
    local repo_name source_url default_ref repo git_release git_date last_tag resolved_tag

    MATRIX_TYPE=""
    MATRIX_TAG=""
    MATRIX_PROD_DEB=""
    MATRIX_PROD_RPM=""

    aux_project_package_name "$project" >/dev/null || fail "Unknown matrix project: $project"
    repo_name="$(aux_project_repo_name "$project")"
    source_url="$(aux_project_source_url "$project")"
    default_ref="$(aux_project_default_ref "$project")"
    repo="$SOURCE_DIR/${repo_name}.git"

    case "$mode" in
        release)
            MATRIX_TYPE="releases"
            prepare_git_repo "$repo_name" "$source_url" "$default_ref" "$repo" >&2
            resolved_tag="$(latest_tag "$repo" || true)"
            if [[ -z "$resolved_tag" ]]; then
                printf 'Skipping release / %s: no tags found\n' "$project" >&2
                return 1
            fi
            MATRIX_TAG="$resolved_tag"
            MATRIX_PROD_DEB="$resolved_tag"
            MATRIX_PROD_RPM="${resolved_tag//-/.}"
            ;;
        nightly|devel)
            MATRIX_TYPE="$mode"
            prepare_git_repo "$repo_name" "$source_url" "$default_ref" "$repo" >&2
            git_release="$(git_short_sha "$repo")"
            git_date="$(git_commit_date "$repo")"
            last_tag="$(latest_tag "$repo" || true)"
            [[ -n "$last_tag" ]] || last_tag="0.0.0"
            MATRIX_PROD_DEB="${last_tag}~${git_date}~${git_release}"
            MATRIX_PROD_RPM="${last_tag//-/.}.${git_date}.${git_release}"
            ;;
        *)
            fail "Unknown matrix mode: $mode"
            ;;
    esac
}

case "$MODE" in
    all)
        MODES="release nightly"
        MATRIX_PROJECTS="opensips python cli"
        ;;
    release|nightly)
        MODES="$MODE"
        MATRIX_PROJECTS="opensips python cli"
        ;;
    devel)
        MODES="devel"
        MATRIX_PROJECTS="opensips python cli"
        ;;
    cli)
        MODES="release nightly devel"
        MATRIX_PROJECTS="python cli"
        ;;
    *)
        fail "Unknown matrix mode: $MODE"
        ;;
esac

TAG_MAJOR=""
if [[ -n "$TAG" && " $MODES " == *" release "* && " $MATRIX_PROJECTS " == *" opensips "* ]]; then
    TAG_MAJOR="$(version_from_tag "$TAG")" || fail "Cannot infer major version from tag: $TAG"
fi

entries=()
for mode in $MODES; do
    versions="$BUILD_WHAT"
    entry_tag=""
    if [[ "$mode" == "devel" ]]; then
        versions="devel"
    fi
    if [[ "$mode" == "release" && -n "$TAG" && " $MATRIX_PROJECTS " == *" opensips "* ]]; then
        versions="$TAG_MAJOR"
        entry_tag="$TAG"
        if ! contains_word_in_string "$TAG_MAJOR" "$BUILD_WHAT"; then
            printf 'WARNING: Tag %s belongs to %s, which is not in BUILD_WHAT=[%s]; building it anyway because explicit tag was requested\n' "$TAG" "$TAG_MAJOR" "$BUILD_WHAT" >&2
        fi
    fi

    if contains_word_in_string opensips "$MATRIX_PROJECTS"; then
        for version in $versions; do
            if ! resolve_opensips_matrix_entry "$mode" "$version" "$entry_tag"; then
                continue
            fi
            for target in $BUILD_FOR; do
                package_path=""
                if package_path="$(repo_package_path_for_target "$MATRIX_TYPE" opensips "$MATRIX_PROD_DEB" "$MATRIX_PROD_RPM" "$MATRIX_VERSION" "$target" "$REL")"; then
                    if [[ -f "$package_path" ]]; then
                        parse_distro "$target"
                        if is_rpm_distro "$DISTR_NAME"; then
                            repo_package_path="$(rpm_repository_package_path "$MATRIX_TYPE" opensips "$MATRIX_VERSION" "$target")"
                            if [[ ! -f "$repo_package_path" ]]; then
                                entries+=("$(jq -cn \
                                    --arg mode "$MATRIX_MODE" \
                                    --arg project "opensips" \
                                    --arg version "$MATRIX_VERSION" \
                                    --arg target "$target" \
                                    --arg tag "$MATRIX_TAG" \
                                    --arg display "$MATRIX_MODE / opensips / $MATRIX_VERSION / $target" \
                                    '{mode: $mode, project: $project, version: $version, target: $target, tag: $tag, display: $display}')")
                                continue
                            fi
                        fi
                        record_matrix_skip "$MATRIX_MODE / opensips / $MATRIX_VERSION / $target" "$MATRIX_TAG" "$package_path"
                        continue
                    fi
                fi
                entries+=("$(jq -cn \
                    --arg mode "$MATRIX_MODE" \
                    --arg project "opensips" \
                    --arg version "$MATRIX_VERSION" \
                    --arg target "$target" \
                    --arg tag "$MATRIX_TAG" \
                    --arg display "$MATRIX_MODE / opensips / $MATRIX_VERSION / $target" \
                    '{mode: $mode, project: $project, version: $version, target: $target, tag: $tag, display: $display}')")
            done
        done
    fi

    for project in python cli; do
        contains_word_in_string "$project" "$MATRIX_PROJECTS" || continue
        if ! resolve_aux_matrix_entry "$mode" "$project"; then
            continue
        fi
        aux_versions="$versions"
        if [[ "$mode" == "release" ]]; then
            aux_versions="$(without_devel_versions "$versions")"
            [[ -n "$aux_versions" ]] || continue
        elif [[ "$mode" == "devel" ]]; then
            aux_versions="devel"
        fi
        package_name="$(aux_project_package_name "$project")"
        for target in $BUILD_FOR; do
            parse_distro "$target"
            is_deb_distro "$DISTR_NAME" || continue
            mapfile -t components < <(shared_deb_components "$MATRIX_TYPE" "$aux_versions")
            package_missing=0
            package_path=""
            for component in "${components[@]}"; do
                component_path="$(deb_repo_package_path_for_component "$DISTR_VER" "$component" "$package_name" "$MATRIX_PROD_DEB" "$REL" all)"
                [[ -n "$package_path" ]] || package_path="$component_path"
                [[ -f "$component_path" ]] || package_missing=1
            done
            if [[ "$package_missing" -eq 0 ]]; then
                record_matrix_skip "$mode / $project / $target" "$MATRIX_TAG" "$package_path"
                continue
            fi
            entries+=("$(jq -cn \
                --arg mode "$mode" \
                --arg project "$project" \
                --arg version "$aux_versions" \
                --arg target "$target" \
                --arg tag "$MATRIX_TAG" \
                --arg display "$mode / $project / $target" \
                '{mode: $mode, project: $project, version: $version, target: $target, tag: $tag, display: $display}')")
        done
    done
done

if [[ "${#entries[@]}" -eq 0 ]]; then
    jq -cn '{include: []}'
else
    printf '%s\n' "${entries[@]}" | jq -cs '{include: .}'
fi
