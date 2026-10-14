# Build and maintain mactop

Use Swift 6.4 and the macOS 27 SDK. The package deployment target is macOS 27.
Run commands from the repository root.

## Build and check

```sh
make build
make dev
swift test --filter PowerReadingValidationTests
```

`make build` builds debug products and signs the debug mactop executable ad hoc. `make dev` also launches it.
For another focused test, select its XCTest class from [ProcessReadersTests.swift](../Tests/mactopTests/ProcessReadersTests.swift).
Those tests cover ranking, CPU deltas, power validation, ps parsing, and network counter rates.
They do not exercise live readers, private callbacks, the coordinator, or AppKit views.

`make lint` points to a removed package and fails. `make fmtlint` formats source before reaching that failure. Do not run it.

## Install from source

```sh
make install
```

The [Makefile](../Makefile) builds release products, creates and signs an app bundle, installs `/Applications/mactop.app`, and installs `~/.local/bin/mactop`.
It also registers `~/Library/LaunchAgents/com.mactop.plist` and starts mactop.
Set `PREFIX` to change the binary's installation prefix. The app and LaunchAgent locations remain fixed.
Installation replaces an existing app at that path.

```sh
make uninstall
make clean
```

`make uninstall` removes the binary, app, and LaunchAgent. Use the same `PREFIX` used for installation.
`make clean` cleans Swift package artifacts and generated app/icon files.

## Release

The [release workflow](../.github/workflows/release.yml) runs manually through `workflow_dispatch`.
It builds the release mactop product on the `xcode-27` runner and publishes a ZIP as a GitHub pre-release tagged `release-<commit>`.
The workflow packages a bare executable, not the app bundle or LaunchAgent created by `make install`.
It does not run tests or lint, sign the binary, or notarize it.
