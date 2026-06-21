# Install

Dimac is currently a source-built macOS app for Apple Silicon Macs.

## What Dimac Depends On

Dimac does not bundle or compile its helper tools itself.

It expects these executables to already exist on disk:

- `brightness`
- `m1ddc`

By default, Dimac looks in:

- `/opt/homebrew/bin`
- `/usr/local/bin`

You can override both paths in `Advanced` settings.

## What Works With Each Helper

- `brightness`: required for built-in display dim/restore in the current implementation, and also used for display discovery and some fallback hardware control paths.
- `m1ddc`: required for DDC-capable external display brightness control.

If you launch Dimac without these helpers installed, the app may still open, but built-in or external brightness control will be limited or fail depending on which helper is missing.

## Recommended Install Path

Recommended setup:

```sh
brew install m1ddc

git clone https://github.com/nriley/brightness.git
cd brightness
make
sudo make install
```

Then build Dimac:

```sh
zsh ./scripts/build-app.sh
```

Open the app bundle:

```text
.build/release/Dimac.app
```

## If You Build Helpers From Source

That is supported too, but you must do it outside Dimac.

1. Build `brightness` from the upstream [`nriley/brightness`](https://github.com/nriley/brightness) repository.
2. Build `m1ddc` yourself if you do not want the Homebrew package.
3. Open Dimac and set the binary paths in `Advanced` settings if they are not auto-detected.

Dimac only needs executable paths. It does not care whether those binaries came from Homebrew or from your own source builds.

## Permissions

Input Monitoring is optional. If it is already granted, Dimac can restore brightness a bit faster. Without it, the app still restores brightness through its normal idle polling path.
