# RPM source overrides

To replace the image-provided RPM repositories for a build, add a
`<distribution>-<version>.repo` file to this directory. The name must match the
build target before its architecture suffix; for example, `el-7/x86_64` uses
`el-7.repo`.

The override must contain the complete repository set required by the build.
When it is present, `rpm-build-env.sh` removes the image-provided `.repo` files
and installs the override as `/etc/yum.repos.d/opensips-build.repo`.
