# Contributing to Noctis

This guide covers building Noctis from source and submitting changes.

> [!NOTE]
> Noctis is in pre-alpha and under heavy development. The build process, patch layout and commands may change without notice.

## Before you start

- Search [existing issues](https://github.com/nostacks/noctis/issues) before opening a new one.
- For large changes, open an issue to discuss the approach first.
- Report security vulnerabilities privately through the [security contact](#), not in public issues.

## How Noctis is built

Noctis is not a Chromium fork. Each build starts from the official Chromium source release and applies three patch layers in order:

1. `upstream/ungoogled-chromium`: removes Google services, telemetry and prebuilt binaries
2. `platform/<os>/patches`: platform build fixes, such as [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos) for macOS
3. `patches`: Noctis branding and features

GN args follow the same order: `upstream/ungoogled-chromium/flags.gn`, `platform/<os>/flags.gn`, then `flags.gn`. Later values take precedence.

## Requirements

Building is currently supported on macOS. Windows and Linux support is coming soon.

- Apple silicon or Intel Mac
- Full Xcode with the Metal toolchain
- Python 3.11 to 3.13
- ninja
- 120 GB of free disk space

`ccache` or `sccache` is used automatically if installed.

## Building

```sh
git clone --recurse-submodules https://github.com/nostacks/noctis.git
cd noctis
./noctis doctor
./noctis setup --dev
./noctis build --dev
./noctis run --dev
```

If you cloned without submodules, run `./noctis init` first.

`--dev` produces a component build in `out/Dev`, which links much faster. Omit it for a release build in `out/Release`, which takes several hours.

Setup stages resume where they stopped. If patching fails partway, run `./noctis reset` and start again.

Set `NOCTIS_PYTHON` to choose a Python interpreter, or `NOCTIS_ARCH` to target `arm64` or `x86_64`.

## Commands

| Command | Description |
| --- | --- |
| `doctor` | Check prerequisites |
| `init` | Check out the ungoogled-chromium submodule |
| `setup [--clone] [--dev]` | Run fetch, prepare and configure |
| `fetch [--clone]` | Download the Chromium source |
| `prepare` | Prune binaries, fetch the toolchain, apply patches, substitute domains |
| `configure [--dev]` | Write `args.gn` and run `gn gen` |
| `build [--dev] [targets...]` | Build with ninja (default: `chrome`) |
| `run [--dev] [flags...]` | Launch Noctis with a separate profile |
| `status` | Show pinned versions and completed stages |
| `reset` | Delete the source tree and stage markers |

## Writing patches

Patches apply with `patch -p1` in `series` order, before domain substitution.

1. Write the patch against an unsubstituted Chromium tree.
2. Save it as `patches/noctis/<area>/<name>.patch`.
3. Add its path to `patches/series`.
4. Run `./noctis reset` and `./noctis setup --dev` to confirm it applies cleanly.

Keep each patch focused on a single change. Branding is defined in `patches/noctis/branding/product-name.patch`.

## Updating Chromium

Move the `upstream/ungoogled-chromium` submodule to a newer release tag, then run `./noctis reset` and rebuild. Refresh any patches that no longer apply.

## Pull requests

- Keep each pull request focused on one change.
- Describe what changed and why.
- Confirm Noctis builds and launches with your change.
- Note the platform you tested on.
