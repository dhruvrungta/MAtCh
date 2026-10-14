# Changelog

What changed in each version of MAtCh. The newest is at the top.

## [0.2.3] - 2026-10-15

### Changed
- The app is now called MAtCh. It shows under that name in the menu, its windows and notifications, Finder and Spotlight. Nothing else changes: your saved sign-in and settings carry over, and updating doesn't ask for your Mac password.

## [0.2.2] - 2026-10-14

### Added
- An app icon: a matchstick whose flame is the Wi-Fi signal. It appears in Finder, in Settings → About, and on the project page.

## [0.2.1] - 2026-10-14

### Fixed
- The installer no longer tells everyone to click Unlock after installing. It now asks only people updating from a version before 0.2.0, the only ones who need it.
- The installer now checks that MAtCh actually started after installing, and tries again if it didn't.
- The note shown in MAtCh's "update available" message is now the release's own description.

## [0.2.0] - 2026-10-14

The first public release.

### Added
- Signs you in to the VIT hostel Wi-Fi automatically when the login page appears, and again when your session runs out.
- Shows at a glance in the menu bar whether you're connected, and explains in plain words when something goes wrong.
- A welcome window, a Settings window, notifications, and an option to open MAtCh when you log in to your Mac.
- The current download and upload speed, the data used this session, and a history of past sessions.
- A daily check for new versions, which never downloads or installs anything by itself.
- Your password is kept in the Keychain by a small helper that never changes between versions, so updating MAtCh doesn't ask for your Mac password.
- Requests to the login page go over Wi-Fi even when the Mac is also connected another way.

[0.2.3]: https://github.com/dhruvrungta/match/releases/tag/v0.2.3
[0.2.2]: https://github.com/dhruvrungta/match/releases/tag/v0.2.2
[0.2.1]: https://github.com/dhruvrungta/match/releases/tag/v0.2.1
[0.2.0]: https://github.com/dhruvrungta/match/releases/tag/v0.2.0
