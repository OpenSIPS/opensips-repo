# Security policy

## Reporting a vulnerability

Please do not report suspected vulnerabilities, signing-key issues, or
credential exposure in a public issue. Contact the OpenSIPS repository
maintainers privately through the security contact configured for this
repository.

Do not include private signing material in issues, pull requests, workflow
logs, or repository files. Rotate any credential that may have been exposed.

## GitHub Actions boundary

The package publishing workflow is intentionally limited to scheduled and
manual dispatch events. It runs on a persistent self-hosted runner and must
not be changed to execute code from public pull requests on that runner.
Untrusted pull-request checks, if added later, must use GitHub-hosted runners
and must not receive signing secrets.
