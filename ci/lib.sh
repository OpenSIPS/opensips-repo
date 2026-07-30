#!/usr/bin/env bash

# Common functions

set -o errexit
set -o nounset
set -o pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/config.sh"

log() {
    local msg="$*"
    printf '%s builder %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg"
}

warn() {
    log "WARNING: $*"
}

err() {
    log "ERROR: $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
}

contains_word_in_string() {
    local needle="$1" haystack="$2" item
    for item in $haystack; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

without_devel_versions() {
    local item
    for item in $*; do
        is_devel_build "$item" && continue
        printf '%s\n' "$item"
    done | xargs
}

parse_distro() {
    local target="$1"
    DISTR_NAME="${target%%/*}"
    DISTR_ARCH="${target##*/}"
    DISTR_ID="${DISTR_NAME%%-*}"
    DISTR_VER="${DISTR_NAME#*-}"
    DISTR_NAME_PURE="${DISTR_NAME//-/}"
    if [[ "$DISTR_ID" == "st" ]]; then
        DISTR_NAME_PURE="${DISTR_NAME_PURE/st/el}"
    fi
    export DISTR_NAME DISTR_ARCH DISTR_ID DISTR_VER DISTR_NAME_PURE
}

is_deb_distro() {
    [[ "$1" == debian-* || "$1" == ubuntu-* ]]
}

is_rpm_distro() {
    [[ "$1" == el-* || "$1" == st-* || "$1" == fc-* ]]
}

is_devel_build() {
    [[ "$1" == "devel" ]]
}

deb_component() {
    local type="$1" major="$2"
    if [[ "$type" == "devel" || "$major" == "devel" ]]; then
        printf 'devel\n'
    else
        printf '%s-%s\n' "$major" "$type"
    fi
}

shared_deb_components() {
    local type="$1" versions="$2" major
    for major in $versions; do
        deb_component "$type" "$major"
    done | sort -u
}

rpm_repo_dir_part() {
    local type="$1" major="$2"
    if [[ "$type" == "devel" || "$major" == "devel" ]]; then
        printf 'devel\n'
    else
        printf '%s/%s\n' "$major" "$type"
    fi
}

deb_repo_package_path() {
    local type="$1" project_name="$2" prod_ver="$3" major="$4" target="$5" rel="$6"
    local component real_arch
    parse_distro "$target"
    component="$(deb_component "$type" "$major")"
    real_arch="$DISTR_ARCH"
    if [[ "$project_name" != "opensips" ]]; then
        real_arch="all"
    fi
    printf '%s/%s/%s/%s_%s-%s_%s.deb\n' "$FREIGHT_DIR" "$DISTR_VER" "$component" "$project_name" "$prod_ver" "$rel" "$real_arch"
}

deb_repo_package_path_for_component() {
    local suite="$1" component="$2" project_name="$3" prod_ver="$4" rel="$5" real_arch="$6"
    printf '%s/%s/%s/%s_%s-%s_%s.deb\n' "$FREIGHT_DIR" "$suite" "$component" "$project_name" "$prod_ver" "$rel" "$real_arch"
}

rpm_repo_package_path() {
    local type="$1" project_name="$2" prod_ver="$3" major="$4" target="$5" rel="$6"
    local repo_part local_rpm_dir real_arch
    parse_distro "$target"
    repo_part="$(rpm_repo_dir_part "$type" "$major")"
    local_rpm_dir="$RPM_DIR/$repo_part/$DISTR_ID/$DISTR_VER/$DISTR_ARCH"
    real_arch="$DISTR_ARCH"
    if [[ "$project_name" != "opensips" ]]; then
        real_arch="noarch"
    fi
    [[ "$real_arch" == "i386" ]] && real_arch="i686"
    printf '%s/%s-%s-%s.%s.%s.rpm\n' "$local_rpm_dir" "$project_name" "$prod_ver" "$rel" "$DISTR_NAME_PURE" "$real_arch"
}

rpm_repository_package_path() {
    local type="$1" project_name="$2" major="$3" target="$4"
    local repo_part local_rpm_dir repo_name
    parse_distro "$target"
    repo_part="$(rpm_repo_dir_part "$type" "$major")"
    local_rpm_dir="$RPM_DIR/$repo_part/$DISTR_ID/$DISTR_VER/$DISTR_ARCH"
    repo_name="$(rpm_yum_name "$type" "$major")"
    printf '%s/%s-repo-%s-%s.%s.noarch.rpm\n' \
        "$local_rpm_dir" "$project_name" "$repo_name" "$RPM_REPO_PACKAGE_RELEASE" "$DISTR_NAME_PURE"
}

repo_package_path_for_target() {
    local type="$1" project_name="$2" prod_deb="$3" prod_rpm="$4" major="$5" target="$6" rel="$7"
    parse_distro "$target"
    if is_deb_distro "$DISTR_NAME"; then
        deb_repo_package_path "$type" "$project_name" "$prod_deb" "$major" "$target" "$rel"
    elif is_rpm_distro "$DISTR_NAME"; then
        rpm_repo_package_path "$type" "$project_name" "$prod_rpm" "$major" "$target" "$rel"
    else
        return 1
    fi
}

rpm_yum_type() {
    local type="$1" major="$2"
    if [[ "$type" == "devel" || "$major" == "devel" ]]; then
        printf 'devel\n'
    else
        printf '%s\n' "$type"
    fi
}

rpm_yum_name() {
    local type="$1" major="$2"
    if [[ "$type" == "devel" || "$major" == "devel" ]]; then
        printf 'devel-%s\n' "$major"
    else
        printf '%s-%s\n' "$type" "$major"
    fi
}

docker_image_for_target() {
    local target="$1"
    parse_distro "$target"
    if is_deb_distro "$DISTR_NAME"; then
        printf '%s:%s\n' "$DISTR_ID" "$DISTR_VER"
        return 0
    fi

    case "$DISTR_ID-$DISTR_VER" in
        el-10) printf 'rockylinux/rockylinux:10\n' ;;
        el-9) printf 'rockylinux/rockylinux:9\n' ;;
        st-9) printf 'quay.io/centos/centos:stream9\n' ;;
        fc-*) printf 'fedora:%s\n' "$DISTR_VER" ;;
        *) fail "No Docker image mapping for target $target" ;;
    esac
}

prepare_git_repo() {
    local name="$1" url="$2" ref="$3" dest="$4" git_cache="${GIT_CACHE_DIR}/$1"
    local lock_dir="${STATE_DIR}/locks"
    mkdir -p "$GIT_CACHE_DIR" "$lock_dir"

    (
        flock 200
        prepare_git_repo_locked "$name" "$url" "$ref" "$dest" "$git_cache"
    ) 200>"$lock_dir/git-cache-${name}.lock"
}

prepare_git_repo_locked() {
    local name="$1" url="$2" ref="$3" dest="$4" git_cache="$5"

    if [[ ! -d "${GIT_CACHE_DIR}/$name" ]]; then
        log "Cloning $url into cache"
        git clone "$url" "$git_cache"
    fi

    log "Fetching $name"
    remove_git_index_locks "$git_cache"
    git -C "$git_cache" fetch --all --tags --prune
    git -C "$git_cache" clean -dfx
    git -C "$git_cache" reset --hard
    checkout_git_ref "$git_cache" "$ref"
    update_git_submodules "$git_cache"

    if [[ ! -d "$dest/.git" ]]; then
        log "Copying cached $url into $dest"
        rm -rf "$dest"
        mkdir -p "$SOURCE_DIR"
        cp -rf "$git_cache" "$dest"
    fi

    log "Checkout $name"
    remove_git_index_locks "$dest"
    git -C "$dest" clean -dfx
    git -C "$dest" reset --hard
    checkout_git_ref "$dest" "$ref"
    update_git_submodules "$dest"
}

checkout_git_ref() {
    local repo="$1" ref="$2"
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
        git -C "$repo" checkout -B "$ref" "origin/$ref"
    else
        git -C "$repo" checkout "$ref"
    fi
}

remove_git_index_locks() {
    local repo="$1" max_age_minutes="${2:-10}" lock
    [[ -e "$repo/.git" ]] || return 0
    while IFS= read -r -d '' lock; do
        warn "Removing stale git lock: $lock"
        rm -f "$lock"
    done < <(find "$repo/.git" -type f -name index.lock -mmin +"$max_age_minutes" -print0 2>/dev/null || true)

    while IFS= read -r -d '' lock; do
        warn "Git lock is recent; leaving it in place: $lock"
    done < <(find "$repo/.git" -type f -name index.lock ! -mmin +"$max_age_minutes" -print0 2>/dev/null || true)
}

update_git_submodules() {
    local repo="$1"
    [[ -f "$repo/.gitmodules" ]] || return 0
    git -C "$repo" submodule sync --recursive
    git -C "$repo" submodule update --init --recursive --force
    git -C "$repo" submodule foreach --recursive 'git reset --hard && git clean -dfx'
}

git_short_sha() {
    git -C "$1" log -n 1 --pretty='%h'
}

git_commit_date() {
    local ts
    ts="$(git -C "$1" log -n 1 --pretty='%ct')"
    date -d "@$ts" '+%Y%m%d'
}

version_from_tag() {
    local tag="$1"
    if [[ "$tag" =~ ^([0-9]+\.[0-9]+)\. ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

package_version_from_tag() {
    local tag="$1"
    if [[ "$tag" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-(.+)$ ]]; then
        printf '%s~%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf '%s\n' "$tag"
    fi
}

latest_tag_for_version() {
    local repo="$1" version="$2"
    git -C "$repo" tag -l "${version}.*" \
        | while IFS= read -r tag; do
            printf '%s\t%s\n' "$(package_version_from_tag "$tag")" "$tag"
        done \
        | sort -V -k1,1 \
        | tail -n 1 \
        | cut -f2
}

latest_tag() {
    git -C "$1" tag -l | sort -V | tail -n 1
}

opensips_makefile_version() {
    local repo="$1" defs="$1/Makefile.defs" major="" minor="" subminor=""
    [[ -f "$defs" ]] || fail "Missing Makefile.defs in $repo"
    while IFS='=' read -r key value; do
        key="${key//[[:space:]]/}"
        value="${value//[[:space:]]/}"
        case "$key" in
            VERSION_MAJOR) major="$value" ;;
            VERSION_MINOR) minor="$value" ;;
            VERSION_SUBMINOR) subminor="$value" ;;
        esac
    done <"$defs"
    [[ -n "$major" && -n "$minor" && -n "$subminor" ]] \
        || fail "Cannot read VERSION_MAJOR/MINOR/SUBMINOR from $defs"
    printf '%s.%s.%s\n' "$major" "$minor" "$subminor"
}

major_from_product_version() {
    local version="$1" rest
    rest="${version#*.}"
    printf '%s.%s\n' "${version%%.*}" "${rest%%.*}"
}

aux_project_package_name() {
    case "$1" in
        python) printf 'python3-opensips\n' ;;
        cli) printf 'opensips-cli\n' ;;
        *) return 1 ;;
    esac
}

aux_project_repo_name() {
    case "$1" in
        python) printf 'python-opensips\n' ;;
        cli) printf 'opensips-cli\n' ;;
        *) return 1 ;;
    esac
}

aux_project_source_url() {
    case "$1" in
        python) printf '%s\n' "$PYTHON_OPENSIPS_SOURCE_URL" ;;
        cli) printf '%s\n' "$OPENSIPS_CLI_SOURCE_URL" ;;
        *) return 1 ;;
    esac
}

aux_project_default_ref() {
    case "$1" in
        python) printf 'main\n' ;;
        cli) printf 'master\n' ;;
        *) return 1 ;;
    esac
}

stage_source_tree() {
    local source_repo="$1" git_release="$2" dest="$3"
    rm -rf "$dest"
    mkdir -p "$dest"
    rsync -a --delete --exclude '.git' "$source_repo/" "$dest/"
    printf '%s\n' "$git_release" >"$dest/.gitrevision"
}

sign_rpms() {
    local rpm_file
    if [[ "$#" -eq 0 ]]; then
        return 0
    fi
    if ! command -v rpmsign >/dev/null 2>&1 && ! command -v rpm >/dev/null 2>&1; then
        warn "rpmsign/rpm is not installed on host; RPM files will not be signed"
        return 0
    fi
    if ! gpg --homedir "$GNUPGHOME" --list-secret-keys "$GPG_KEY_NAME" >/dev/null 2>&1; then
        if [[ -n "${APT_GPG_PRIVATE_KEY:-}" ]]; then
            setup_apt_signing_key
        fi
    fi
    if ! gpg --homedir "$GNUPGHOME" --list-secret-keys "$GPG_KEY_NAME" >/dev/null 2>&1; then
        warn "GPG secret key not found in $GNUPGHOME for $GPG_KEY_NAME; RPM files will not be signed"
        return 0
    fi
    for rpm_file in "$@"; do
        [[ -f "$rpm_file" ]] || continue
        log "Signing RPM $(basename "$rpm_file")"
        if command -v rpmsign >/dev/null 2>&1; then
            GNUPGHOME="$GNUPGHOME" rpmsign --addsign \
                --define "_gpg_name ${GPG_KEY_NAME}" \
                --define "_gpg_path ${GNUPGHOME}" \
                "$rpm_file" || warn "Cannot sign $rpm_file"
        else
            GNUPGHOME="$GNUPGHOME" rpm \
                -D "%_gpg_name ${GPG_KEY_NAME}" \
                -D "%_gpg_path ${GNUPGHOME}" \
                --resign "$rpm_file" || warn "Cannot sign $rpm_file"
        fi
    done
}

cleanup_expiring_files() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    find "$root" -type f \( -path '*nightly*' -o -path '*devel*' \) \
        -name '*[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*' \
        -mtime +"$KEEP_DAYS" -delete || true
}

archive_release_tarball() {
    local source_repo="$1" product="$2" version="$3" git_release="$4"
    local tmp="$WORK_DIR/archive-${product}-${version}"
    local tgzdir="${product}-${version}"
    local tgzfile="${tgzdir}.tar.gz"
    local archive_file="$ARCHIVE_DIR/$tgzfile"
    if [[ -f "$archive_file" ]]; then
        log "Release tarball already exists: $archive_file"
        (
            cd "$ARCHIVE_DIR"
            [[ -f "$tgzfile.sha256" ]] || sha256sum "$tgzfile" >"$tgzfile.sha256"
            [[ -f "$tgzfile.md5" ]] || md5sum "$tgzfile" >"$tgzfile.md5"
        )
        return 0
    fi

    rm -rf "$tmp"
    mkdir -p "$tmp"
    stage_source_tree "$source_repo" "$git_release" "$tmp/$tgzdir"
    (cd "$tmp" && tar -czf "$tgzfile" --exclude "${tgzdir}/.git" "$tgzdir")
    mv -f "$tmp/$tgzfile" "$ARCHIVE_DIR/$tgzfile"
    (cd "$ARCHIVE_DIR" && sha256sum "$tgzfile" >"$tgzfile.sha256" && md5sum "$tgzfile" >"$tgzfile.md5")
    rm -rf "$tmp"
}

setup_apt_signing_key() {
    [[ -n "${APT_GPG_PRIVATE_KEY:-}" ]] || fail "APT_GPG_PRIVATE_KEY is required for repository signing"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    export GNUPGHOME

    if ! gpg --batch --homedir "$GNUPGHOME" --list-secret-keys "$GPG_KEY_NAME" >/dev/null 2>&1; then
        log "Importing APT signing key into $GNUPGHOME"
        printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --homedir "$GNUPGHOME" --import
    fi

    local old_umask
    mkdir -p "${APT_GPG_PASSPHRASE_FILE%/*}"
    old_umask="$(umask)"
    umask 077
    printf '%s' "${APT_GPG_PASSPHRASE:-}" >"$APT_GPG_PASSPHRASE_FILE"
    umask "$old_umask"
    export APT_GPG_PASSPHRASE_FILE

    gpg --batch --homedir "$GNUPGHOME" --list-secret-keys "$GPG_KEY_NAME" >/dev/null 2>&1 \
        || fail "APT signing key '$GPG_KEY_NAME' is not available in GNUPGHOME=$GNUPGHOME"
}

make_freight_conf() {
    cat >"$FREIGHT_CONF" <<EOF
VARLIB="$FREIGHT_LIB"
VARCACHE="$DEB_DIR"

ORIGIN="OpenSIPS - Open Source SIP proxy/server"
LABEL="OpenSIPS - Open Source SIP proxy/server"

CACHE="on"

GPG="$GPG_KEY_NAME"
GPG_DIGEST_ALGO="SHA512"
export GNUPGHOME="$GNUPGHOME"
GPG_PASSPHRASE_FILE="$APT_GPG_PASSPHRASE_FILE"

SYMLINKS="off"
EOF
}

refresh_repository_website() {
    local generator="$LIB_DIR/generate-www.py"

    if [[ ! -f "$generator" ]]; then
        warn "Repository website generator is missing: $generator"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 is not installed; repository website indexes will not be refreshed"
        return 0
    fi
    if ! python3 -c 'import jinja2' >/dev/null 2>&1; then
        warn "Python module jinja2 is not installed; repository website indexes will not be refreshed"
        return 0
    fi

    log "Refreshing repository website indexes"
    python3 "$generator" || warn "Cannot refresh repository website indexes"
}
