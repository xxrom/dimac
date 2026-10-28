# Releasing

## Before The First Public Release

- confirm the bundle identifier and copyright owner
- enable private vulnerability reporting on GitHub if you want private security intake
- confirm `README.md` and `INSTALL.md` match the actual helper-tool requirements
- decide whether you will distribute unsigned dev builds only, or signed and notarized release artifacts

## Release Checklist

Releases are published by [`.github/workflows/release.yml`](.github/workflows/release.yml) when a `vX.Y.Z` tag is pushed. It checks the tag matches `Info.plist`, runs the tests, builds the app, and publishes `Dimac-X.Y.Z-macOS-arm64.zip` with notes taken from `CHANGELOG.md` and its SHA-256.

1. Add your changes under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md) as you go.
2. Smoke-test dim/restore locally (`zsh ./scripts/build-app.sh`), including external displays with `m1ddc` if the release touches them.
3. On a clean `master`, run:

   ```sh
   zsh ./scripts/release.sh patch --push   # or minor, major, or an explicit X.Y.Z
   ```

   This bumps `CFBundleShortVersionString` and `CFBundleVersion`, moves the Unreleased notes under the new version, commits `Release X.Y.Z`, tags `vX.Y.Z`, and pushes both. Leave off `--push` to review first.
4. Watch the Release workflow in the Actions tab. If it fails, fix on `master`, delete the tag (`git push --delete origin vX.Y.Z && git tag -d vX.Y.Z`), and release the next patch version instead of reusing the tag.
5. If you plan a signed public binary release, sign and notarize the artifact with your real Apple Developer identity.
