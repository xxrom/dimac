# Contributing

## Local Setup

1. Use an Apple Silicon Mac running macOS 13 or newer.
2. Install Xcode and select the full Xcode toolchain.
3. Install the helper CLIs:

```sh
brew install m1ddc brightness
```

4. Build the package:

```sh
swift build
```

5. Run the tests:

```sh
zsh ./scripts/test.sh
```

6. Build the app bundle when you need a runnable app:

```sh
zsh ./scripts/build-app.sh
```

## Development Notes

- Intel support is out of scope unless someone is ready to test and maintain it.
- Keep changes focused and easy to review.
- Do not commit `.build`, `DerivedData`, `.DS_Store`, or generated binaries.
- Prefer small pull requests with clear before-and-after behavior.
- Update `README.md`, `PRIVACY.md`, or `CHANGELOG.md` when user-facing behavior changes.

## Pull Requests

- Describe the user-visible change and any hardware assumptions.
- Include manual verification steps.
- Call out behavior that depends on `m1ddc`, `brightness`, or Input Monitoring permission.
- Add or update tests when core dimming behavior changes.

## Coding Style

- Follow the existing Swift style in the repository.
- Keep platform-specific behavior explicit.
- Prefer injecting file paths and command runners instead of hardcoding environment assumptions.
