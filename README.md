# mactop

mactop shows CPU, RAM, GPU, power, and network activity in the macOS menu bar, with charts for the last five minutes.

## Install and run

The package requires macOS 27 or later. Binary releases target Apple Silicon.

Download `mactop-aarch64-apple-darwin.zip` from [Releases](https://github.com/joshuarli/mactop/releases), unzip it, and install the executable:

```sh
mkdir -p ~/.local/bin
install -m 755 ~/Downloads/mactop-aarch64-apple-darwin ~/.local/bin/mactop
~/.local/bin/mactop
```

The app runs in the menu bar without a Dock icon. Click a metric to open its popup. Click outside the popup to close it.
Use the popup's pause button to stop collection and clear displayed data. Use its quit button to exit.

CPU, RAM, and GPU show percentages. Network shows upload above download in bytes per second. PWR shows watts.
Power separates system consumption from the modeled component subtotal. Adapter watts describe the adapter maximum, not live consumption.
Some metrics depend on undocumented Apple interfaces and may be unavailable on a particular Mac or OS version.

## Configure the update interval

The default interval is one second. Set a different interval in seconds, then restart mactop:

```sh
defaults write com.mactop UpdateInterval -float 2
```

Values are clamped to 1–3600 seconds. Remove the override to restore the default:

```sh
defaults delete com.mactop UpdateInterval
```

## Help and license

Report problems through [GitHub issues](https://github.com/joshuarli/mactop/issues).
The repository does not currently include a license.
