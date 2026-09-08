# APT source overrides

To replace the image-provided APT repositories for a Debian or Ubuntu build,
add a `<distribution>-<version>.list` file to this directory. The name must
match the build target before its architecture suffix; for example,
`ubuntu-jammy/amd64` uses `ubuntu-jammy.list`.

The override must contain the complete source list required by the build. When
it is present, `build-deb.sh` removes the image-provided `.list` and `.sources`
files, copies the override to `/etc/apt/sources.list`, clears cached indexes,
and then runs `apt-get update`.
