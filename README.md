<p align="center">
  <img src="Assets/banner.png" alt="Louver: A volume slider for every app" />
</p>

# Louver

Per-app volume control for the Mac. Part of [Domus](https://domus-apps.com).

A louver is a set of angled slats over a window opening, letting you adjust
how much air and light pass through, Louver does the same for each app's
sound. macOS still has one volume for everything; Louver gives every app its
own slider and mute, from the menu bar.

## How it works

Louver uses macOS's Core Audio process taps (no drivers, no kernel
extensions): an app you turn down is muted at the audio HAL and its sound is
played back at the level you set. Apps at full volume are untouched, their
audio passes straight through the system as if Louver weren't running.

This needs the System Audio Recording permission. Nothing is recorded or
stored.

## Development

```sh
./Scripts/dev.sh      # rebuild-and-relaunch loop
./Scripts/test.sh     # unit tests
./Scripts/bundle.sh   # assemble build/Louver.app
```

Requires macOS 26 or later.
