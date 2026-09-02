# Changelog

All notable changes to Louver are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.0.2

### Added

- Louver now speaks Korean — the menu, Settings, and onboarding follow the macOS language, with English everywhere else.

### Changed

- Settings redesigned in the system's grouped style — section headers, rounded boxes, and switches, like Xcode's settings — with the version and build number shown under Check for Updates.

### Fixed

- The speaker icons beside each volume slider vanished in Dark Mode when Louver had been launched in Light Mode (and dimmed the other way round): their tint was frozen at launch instead of following the appearance. They now track it live.

## 1.0.1

- Tightened the gap between the volume sliders and the menu items below them.

## 1.0.0

The first release.

- A volume slider and mute for every app, right in the menu bar — the one control macOS never shipped.
- Built on Core Audio process taps: no drivers, no kernel extensions, nothing to install beyond the app.
- Apps at full volume are untouched — their audio passes straight through the system as if Louver weren't running.
- Chrome- and Electron-style helper processes are grouped under the app you actually see.
- Volumes are remembered per app and reapplied when the app plays again, across relaunches.
- Follows the default output everywhere: switch to AirPods mid-song and the levels come along.
