#!/usr/bin/env python3

"""Generate static websites for the OpenSIPS package repositories"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable
from urllib.parse import quote

try:
    from jinja2 import Environment, FileSystemLoader, select_autoescape
except ModuleNotFoundError:
    print(
        "ERROR: missing Python module 'jinja2'. Install python3-jinja2 or Jinja2 "
        "on the self-hosted runner.",
        file=sys.stderr,
    )
    sys.exit(1)


SCRIPT_DIR = Path(__file__).resolve().parent
WWW_DIR = SCRIPT_DIR / "www"
ASSETS_DIR = WWW_DIR / "assets"
KEYS_DIR = WWW_DIR / "keys"
TEMPLATES_DIR = WWW_DIR / "templates"
CONFIG_SH = SCRIPT_DIR / "config.sh"
PUBLIC_KEY_SOURCE = KEYS_DIR / "opensips-org.asc"

CONFIG_EXPORTS = (
    "BUILD_WHAT",
    "BUILD_FOR",
    "MASTER_VER",
    "DEB_DIR",
    "RPM_DIR",
    "ARCHIVE_DIR",
    "OPENSIPS_SITE_URL",
    "APT_REPO_URL",
    "RPM_REPO_URL",
    "DOWNLOAD_REPO_URL",
    "RPM_REPO_PACKAGE_RELEASE",
)

GENERATED_ROOT_FILES = {
    "index.html",
    "packages.html",
    "browse.html",
    "head.php",
    "bottom.php",
    "index.php",
    "packages.php",
    "howto.php",
    "browse.php",
}
OBSOLETE_ROOT_FILES = {
    "howto.html",
}
ASSET_FILES = {
    "opensips.css",
    "opensips-logo.png",
    "favicon.png",
    "opensips-org.gpg",
}
LEGACY_ASSET_FILES = {
    "logo2.jpg",
    "motto.jpg",
    "wsplus.css",
}
SKIP_DIRS = {".git", "scripts", "__pycache__"}
APT_SNAPSHOT_DIR_RE = re.compile(r"^(.+)-\d{8,}$")


@dataclass(frozen=True)
class Target:
    raw: str
    distro_name: str
    arch: str
    distro_id: str
    distro_ver: str
    distro_pure: str

    @property
    def is_deb(self) -> bool:
        return self.distro_id in {"debian", "ubuntu"}

    @property
    def is_rpm(self) -> bool:
        return self.distro_id in {"el", "st", "fc"}


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def load_shell_config() -> None:
    shell_env = os.environ.copy()
    shell_env["CONFIG_EXPORTS"] = " ".join(CONFIG_EXPORTS)
    script = r'''
set -o errexit
set -o nounset
set -o pipefail
source "$1"
for name in $CONFIG_EXPORTS; do
    printf '%s=%s\0' "$name" "${!name-}"
done
'''
    result = subprocess.run(
        ["bash", "-c", script, "bash", str(CONFIG_SH)],
        env=shell_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode("utf-8", errors="replace"))
        sys.exit(result.returncode)
    for item in result.stdout.split(b"\0"):
        if not item:
            continue
        name, value = item.split(b"=", 1)
        os.environ[name.decode()] = value.decode()


def words(value: str) -> list[str]:
    return [item for item in value.split() if item]


def unique(items: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def parse_target(raw: str) -> Target | None:
    if "/" not in raw:
        return None
    distro_name, arch = raw.split("/", 1)
    if "-" not in distro_name:
        return None
    distro_id, distro_ver = distro_name.split("-", 1)
    distro_pure = distro_name.replace("-", "")
    if distro_id == "st":
        distro_pure = distro_pure.replace("st", "el", 1)
    return Target(raw, distro_name, arch, distro_id, distro_ver, distro_pure)


def title_word(value: str) -> str:
    return value.replace("_", " ").replace("-", " ").title()


def deb_target_label(target: Target) -> str:
    family = {"debian": "Debian", "ubuntu": "Ubuntu"}.get(target.distro_id, target.distro_id)
    return f"{family} {title_word(target.distro_ver)}"


def rpm_target_label(target: Target) -> str:
    if target.distro_id == "el":
        return f"Red Hat Enterprise Linux {target.distro_ver}"
    if target.distro_id == "st":
        return f"CentOS Stream {target.distro_ver}"
    if target.distro_id == "fc":
        return f"Fedora {target.distro_ver}"
    return f"{target.distro_id.upper()} {target.distro_ver}"


def target_path_value(target: Target) -> str:
    return f"{target.distro_id}/{target.distro_ver}"


def build_site_data() -> dict:
    versions = words(env("BUILD_WHAT"))
    targets = [target for item in words(env("BUILD_FOR")) if (target := parse_target(item))]
    master_ver = env("MASTER_VER")

    deb_targets: list[dict] = []
    seen_deb_suites: set[str] = set()
    for target in targets:
        if not target.is_deb or target.distro_ver in seen_deb_suites:
            continue
        seen_deb_suites.add(target.distro_ver)
        deb_targets.append(
            {
                "suite": target.distro_ver,
                "label": deb_target_label(target),
            }
        )

    rpm_targets: list[dict] = []
    seen_rpm_distros: set[str] = set()
    for target in targets:
        value = target_path_value(target)
        if not target.is_rpm or value in seen_rpm_distros:
            continue
        seen_rpm_distros.add(value)
        rpm_targets.append(
            {
                "value": value,
                "label": rpm_target_label(target),
                "id": target.distro_id,
                "version": target.distro_ver,
                "pure": target.distro_pure,
            }
        )

    return {
        "versions": [
            {
                "value": version,
                "label": f"OpenSIPS {version}",
                "is_master": version == master_ver,
            }
            for version in versions
        ],
        "deb_targets": deb_targets,
        "deb_arches": unique(target.arch for target in targets if target.is_deb),
        "rpm_targets": rpm_targets,
        "rpm_arches": unique(target.arch for target in targets if target.is_rpm),
        "master_ver": master_ver,
        "opensips_site_url": env("OPENSIPS_SITE_URL", "https://www.opensips.org").rstrip("/"),
        "apt_repo_url": env("APT_REPO_URL", "https://apt.opensips.org").rstrip("/"),
        "rpm_repo_url": env("RPM_REPO_URL", "https://rpm.opensips.org").rstrip("/"),
        "download_repo_url": env("DOWNLOAD_REPO_URL", "https://download.opensips.org").rstrip("/"),
        "rpm_repo_package_release": env("RPM_REPO_PACKAGE_RELEASE", "7"),
    }


def make_environment() -> Environment:
    return Environment(
        loader=FileSystemLoader(TEMPLATES_DIR),
        autoescape=select_autoescape(("html", "j2")),
        trim_blocks=True,
        lstrip_blocks=True,
    )


def write_rendered(env_obj: Environment, template: str, path: Path, **context: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(env_obj.get_template(template).render(**context), encoding="utf-8")


def active_nav(nav: list[dict], active_href: str) -> list[dict]:
    return [
        {
            **item,
            "active": item.get("href") == active_href,
        }
        for item in nav
    ]


def write_public_key(root: Path, key_format: str) -> None:
    output = root / "opensips-org.gpg"
    if key_format == "ascii":
        shutil.copy2(PUBLIC_KEY_SOURCE, output)
        return
    if key_format == "binary":
        tmp_output = output.with_suffix(".gpg.tmp")
        result = subprocess.run(
            [
                "gpg",
                "--batch",
                "--yes",
                "--dearmor",
                "--output",
                str(tmp_output),
                str(PUBLIC_KEY_SOURCE),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            sys.stderr.write(result.stderr.decode("utf-8", errors="replace"))
            sys.exit(result.returncode)
        tmp_output.replace(output)
        return
    raise ValueError(f"Unknown public key format: {key_format}")


def copy_common_files(root: Path, gpg_key_format: str | None = None) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for source in ASSETS_DIR.iterdir():
        if source.is_file() and source.name not in LEGACY_ASSET_FILES:
            shutil.copy2(source, root / source.name)
    if gpg_key_format:
        write_public_key(root, gpg_key_format)


def remove_legacy_php(root: Path) -> None:
    for name in GENERATED_ROOT_FILES:
        if name.endswith(".php"):
            candidate = root / name
            if candidate.exists() or candidate.is_symlink():
                candidate.unlink()


def remove_legacy_assets(root: Path) -> None:
    for name in LEGACY_ASSET_FILES:
        candidate = root / name
        if candidate.exists() or candidate.is_symlink():
            candidate.unlink()


def remove_root_files(root: Path, names: Iterable[str]) -> None:
    for name in names:
        candidate = root / name
        if candidate.exists() or candidate.is_symlink():
            candidate.unlink()


def quote_relative(path: Path) -> str:
    return "/".join(quote(part) for part in path.parts)


def format_size(size: int) -> str:
    units = ["B", "K", "MB", "GB", "TB", "PB"]
    value = float(size)
    unit = units[0]
    for unit in units:
        if value < 1000 or unit == units[-1]:
            break
        value /= 1000
    return f"{value:0.2f} {unit}"


def should_skip_entry(path: Path) -> bool:
    name = path.name
    if name.startswith("."):
        return True
    if path.is_dir() and name in SKIP_DIRS:
        return True
    if name in GENERATED_ROOT_FILES or name in ASSET_FILES:
        return True
    if name.endswith((".php", ".html", ".css", ".png", ".jpg", ".jpeg")):
        return True
    return False


def should_skip_apt_entry(root: Path, rel_dir: Path, path: Path) -> bool:
    if rel_dir != Path("dists") or not path.is_dir():
        return False

    match = APT_SNAPSHOT_DIR_RE.match(path.name)
    if not match:
        return False

    public_suite = root / "dists" / match.group(1)
    if not public_suite.is_symlink():
        return False

    return public_suite.resolve(strict=False) == path.resolve(strict=False)


def directory_entries(root: Path, rel_dir: Path) -> list[dict]:
    current = root / rel_dir
    entries: list[dict] = []
    for child in sorted(current.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower())):
        if should_skip_entry(child) or should_skip_apt_entry(root, rel_dir, child):
            continue
        is_dir = child.is_dir()
        href = quote(child.name)
        if is_dir:
            href = f"{href}/"
        stat = child.stat()
        entries.append(
            {
                "name": f"{child.name}/" if is_dir else child.name,
                "href": href,
                "kind": "Directory" if is_dir else "File",
                "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%d-%b-%Y %H:%M"),
                "size": "-------" if is_dir else format_size(stat.st_size),
            }
        )
    return entries


def parent_href(rel_dir: Path, root_listing_name: str) -> str | None:
    if rel_dir == Path("."):
        return None
    if len(rel_dir.parts) == 1:
        return "../" if root_listing_name == "index.html" else f"../{root_listing_name}"
    return "../"


def render_directory_index(
    env_obj: Environment,
    root: Path,
    rel_dir: Path,
    output: Path,
    *,
    site_title: str,
    root_listing_name: str,
    nav: list[dict],
) -> None:
    display_path = "/" if rel_dir == Path(".") else f"/{quote_relative(rel_dir)}/"
    write_rendered(
        env_obj,
        "directory_index.html.j2",
        output,
        page_title=f"{site_title} | Index of {display_path}",
        site_title=site_title,
        nav=nav,
        display_path=display_path,
        entries=directory_entries(root, rel_dir),
        parent_href=parent_href(rel_dir, root_listing_name),
    )


def render_recursive_indexes(
    env_obj: Environment,
    root: Path,
    *,
    site_title: str,
    root_listing_name: str,
    nav: list[dict],
) -> None:
    for current, dirnames, _filenames in os.walk(root, followlinks=False):
        current_path = Path(current)
        dirnames[:] = [
            name
            for name in dirnames
            if not should_skip_entry(current_path / name)
        ]
        rel_dir = current_path.relative_to(root)
        if rel_dir == Path("."):
            continue
        render_directory_index(
            env_obj,
            root,
            rel_dir,
            current_path / "index.html",
            site_title=site_title,
            root_listing_name=root_listing_name,
            nav=nav,
        )


def render_site() -> None:
    load_shell_config()
    env_obj = make_environment()
    data = build_site_data()
    env_obj.globals["opensips_site_url"] = data["opensips_site_url"]

    apt_root = Path(env("DEB_DIR"))
    rpm_root = Path(env("RPM_DIR"))
    download_root = Path(env("ARCHIVE_DIR"))

    apt_nav = [
        {"href": "/", "title": "Home", "label": "Home"},
        {"href": "/packages.html", "title": "Repository DEBs", "label": "Repository DEBs"},
        {"href": "/browse.html", "title": "Browse Repository", "label": "Browse Repository"},
        {"href": data["rpm_repo_url"], "title": "Go to RPM Repository", "label": "Go to RPM Repository"},
    ]
    rpm_nav = [
        {"href": "/", "title": "Home", "label": "Home"},
        {"href": "/packages.html", "title": "Repository RPMs", "label": "Repository RPMs"},
        {"href": "/browse.html", "title": "Browse Repository", "label": "Browse Repository"},
        {"href": data["apt_repo_url"], "title": "Go to APT Repository", "label": "Go to APT Repository"},
    ]
    download_nav = [
        {"href": "/", "title": "Source Tarballs", "label": "Source Tarballs"},
        {"href": data["apt_repo_url"], "title": "Go to APT Repository", "label": "Go to APT Repository"},
        {"href": data["rpm_repo_url"], "title": "Go to RPM Repository", "label": "Go to RPM Repository"},
    ]

    for root, gpg_key_format in (
        (apt_root, "binary"),
        (rpm_root, "ascii"),
        (download_root, None),
    ):
        copy_common_files(root, gpg_key_format)
        remove_legacy_php(root)
        remove_legacy_assets(root)
        remove_root_files(root, OBSOLETE_ROOT_FILES)

    write_rendered(
        env_obj,
        "repo_home.html.j2",
        apt_root / "index.html",
        page_title="OpenSIPS | APT Repository",
        site_title="OpenSIPS | APT Repository",
        nav=active_nav(apt_nav, "/"),
        repo_kind="apt",
        package_name="DEBs",
        description="OpenSIPS Project official APT repository for Debian and Ubuntu packages.",
        versions=data["versions"],
        targets=data["deb_targets"],
        arches=data["deb_arches"],
    )
    write_rendered(
        env_obj,
        "apt_packages.html.j2",
        apt_root / "packages.html",
        page_title="OpenSIPS | Repository DEBs",
        site_title="OpenSIPS | APT Repository",
        nav=active_nav(apt_nav, "/packages.html"),
        data=data,
    )
    render_directory_index(
        env_obj,
        apt_root,
        Path("."),
        apt_root / "browse.html",
        site_title="OpenSIPS | APT Repository",
        root_listing_name="browse.html",
        nav=active_nav(apt_nav, "/browse.html"),
    )
    render_recursive_indexes(
        env_obj,
        apt_root,
        site_title="OpenSIPS | APT Repository",
        root_listing_name="browse.html",
        nav=active_nav(apt_nav, "/browse.html"),
    )

    write_rendered(
        env_obj,
        "repo_home.html.j2",
        rpm_root / "index.html",
        page_title="OpenSIPS | RPM Repository",
        site_title="OpenSIPS | RPM Repository",
        nav=active_nav(rpm_nav, "/"),
        repo_kind="rpm",
        package_name="RPMs",
        description="OpenSIPS Project official DNF repository for Red Hat compatible and Fedora packages.",
        versions=data["versions"],
        targets=data["rpm_targets"],
        arches=data["rpm_arches"],
    )
    write_rendered(
        env_obj,
        "rpm_packages.html.j2",
        rpm_root / "packages.html",
        page_title="OpenSIPS | Repository RPMs",
        site_title="OpenSIPS | RPM Repository",
        nav=active_nav(rpm_nav, "/packages.html"),
        data=data,
    )
    render_directory_index(
        env_obj,
        rpm_root,
        Path("."),
        rpm_root / "browse.html",
        site_title="OpenSIPS | RPM Repository",
        root_listing_name="browse.html",
        nav=active_nav(rpm_nav, "/browse.html"),
    )
    render_recursive_indexes(
        env_obj,
        rpm_root,
        site_title="OpenSIPS | RPM Repository",
        root_listing_name="browse.html",
        nav=active_nav(rpm_nav, "/browse.html"),
    )

    render_directory_index(
        env_obj,
        download_root,
        Path("."),
        download_root / "index.html",
        site_title="OpenSIPS | Source Tarballs",
        root_listing_name="index.html",
        nav=active_nav(download_nav, "/"),
    )
    render_recursive_indexes(
        env_obj,
        download_root,
        site_title="OpenSIPS | Source Tarballs",
        root_listing_name="index.html",
        nav=active_nav(download_nav, "/"),
    )

    print(f"Generated APT website: {apt_root}")
    print(f"Generated RPM website: {rpm_root}")
    print(f"Generated source website: {download_root}")


if __name__ == "__main__":
    render_site()
