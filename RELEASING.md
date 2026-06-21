# Releasing

## Before The First Public Release

- confirm the bundle identifier and copyright owner
- enable private vulnerability reporting on GitHub if you want private security intake
- confirm `README.md` and `INSTALL.md` match the actual helper-tool requirements
- decide whether you will distribute unsigned dev builds only, or signed and notarized release artifacts

## Release Checklist

1. Run `swift build`.
2. Run `zsh ./scripts/test.sh`.
3. Build the app bundle with `zsh ./scripts/build-app.sh`.
4. Smoke-test built-in dim/restore with `brightness` installed.
5. Smoke-test external display control with `m1ddc` installed, if you claim external support in the release notes.
6. If Input Monitoring is already granted on the test machine, verify the optional faster wake path still behaves correctly.
7. Update [CHANGELOG.md](CHANGELOG.md).
8. Tag the release and attach the built `.app` if you distribute binaries.
9. If you plan a public binary release, sign and notarize the artifact with your real Apple Developer identity.
