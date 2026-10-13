# Match

Match is a macOS menu-bar app that signs you in to the VIT hostel Wi-Fi automatically. It notices the Pronto Networks captive portal, signs in with the registration number and password you saved once, and keeps the session alive.

This is an early build. Installation instructions, screenshots and release downloads will be added when the first release is published.

## Requirements

- macOS 14 Sonoma or later
- To build from source: Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building from source

```sh
make build      # generate the Xcode project and build
make test       # run the unit tests
make run        # build and launch the app
make install    # copy the build to /Applications and launch it from there
make snapshots  # render every screen to build/snapshots for a look at the layouts
```

Launch at login is only offered when Match runs from an Applications folder, so use `make install` to try it.

To try the app without the hostel network, start the mock portal in one terminal and the app in another:

```sh
make mock
make run-mock
```

`make test-mock` runs the end-to-end tests against the mock portal.

### Signing

Builds are signed with a self-signed certificate named "Match Self-Signed", so that the app keeps the same identity from one build to the next. Create it once:

```sh
tools/make_signing_cert.sh
```

Until that certificate exists, the Makefile signs ad-hoc and prints a warning. The certificate does not avoid the Keychain approval described under "After an update": every build with different code needs it once.

Tests are always signed ad-hoc and built separately (in `build/TestDerivedData`), because macOS will not load a test bundle into an app signed with a self-signed certificate.

## Usage figures

While you are connected, the menu shows the current download and upload speed and the data used since signing in. **Settings → History** lists past sessions. Figures marked "Reported by the portal" come from the portal's own sign-out page; figures marked "Measured by Match" count everything your Mac sent and received over Wi-Fi during the session, so they can differ from what the portal counts. The history holds only times and byte counts, and stays on your Mac.

## After an update

macOS ties a saved password to the exact version of the app that saved it. After each update, Match shows "Match was updated" in its menu with an **Unlock** button. Click it, type your Mac's login password in the macOS dialog, and choose **Always Allow**. This is needed once per update. It happens because Match is not signed with a paid Apple developer certificate.

## Privacy

- Your registration number and password are stored in your Mac's Keychain, and nowhere else.
- They are sent only to the VIT login portal (`phc.prontonetworks.com`, or your Wi-Fi router's address when the portal's name can't be looked up), and only after the network has redirected Match to that portal.
- Match makes two other kinds of request, neither of which carries any personal data: a connectivity check to `clients3.google.com`, and, once per Wi-Fi network, a request for your router's front page to see whether it is a campus router.

**The portal only speaks plain HTTP.** Your password crosses the Wi-Fi unencrypted, exactly as it does when you type it into the portal's login page yourself. Match cannot change that. A hostile network that imitates the VIT portal could therefore capture the password. Match reduces the risk by signing in only when the network redirects to a known VIT portal address, but that check is not proof of the network's identity.

## Credits

Match's portal protocol follows [Latch](https://github.com/vinnovateit/latch) by VinnovateIT (MIT licensed), which supports Android, Windows and Linux. Match is an independent, native macOS implementation.

## License

MIT. See [LICENSE](LICENSE).
