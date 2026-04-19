# OpenSIPS Repository Builder

This repository builds and publishes OpenSIPS APT and RPM packages.

GitHub Actions generates a build matrix for the configured OpenSIPS versions
and target distributions, skips packages that already exist in the repository,
and builds only the missing artifacts. The same workflow also regenerates the
static repository website and package indexes.

Manual workflow modes:

- `all` builds release, nightly, CLI/Python packages, indexes, and website.
- `release` builds release packages.
- `nightly` builds nightly packages.
- `cli` builds shared CLI/Python packages.
- `www` regenerates only the static website.

Required signing material is provided through GitHub Actions secrets and must
not be committed to this repository.
