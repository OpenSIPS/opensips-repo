# OpenSIPS Repository Builder

This repository builds and publishes OpenSIPS APT and RPM packages.

GitHub Actions generates a build matrix for the configured OpenSIPS versions
and target distributions, skips packages that already exist in the repository,
and builds only the missing artifacts. The same workflow also regenerates the
static repository website and package indexes.

Manual workflow modes:

- `all` builds release, nightly, devel, CLI/Python packages, indexes, and website.
- `release` builds release packages.
- `nightly` builds nightly packages.
- `devel` builds packages from the OpenSIPS development branch.
- `cli` builds shared CLI/Python packages.
- `www` regenerates only the static website.

Required signing material is provided through GitHub Actions secrets and must
not be committed to this repository.

## Security and licensing

Package signing uses the protected `signing` GitHub Environment.
That environment must be restricted to the `main` branch, require manual
approval, and prevent the person who started a run from approving it.

The package workflow has no `push` or `pull_request` trigger and is guarded so
that public pull-request code cannot run on the persistent self-hosted runner.

The GitHub-side environment and ruleset configuration is documented in
[`docs/GITHUB_SECURITY_SETTINGS.md`](docs/GITHUB_SECURITY_SETTINGS.md).

This repository is licensed under GPL-2.0-or-later. Third-party GPL-covered
files and their retained licensing terms are documented in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
