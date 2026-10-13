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
```

To try the app without the hostel network, start the mock portal in one terminal and the app in another:

```sh
make mock
make run-mock
```

`make test-mock` runs the end-to-end tests against the mock portal.

### Signing

Builds are signed with a self-signed certificate named "Match Self-Signed", so that macOS keeps trusting the app's Keychain item from one build to the next. Create it once:

```sh
tools/make_signing_cert.sh
```

Until that certificate exists, the Makefile signs ad-hoc and prints a warning. An ad-hoc build works, but macOS asks for Keychain access again after every rebuild.

## Privacy

- Your registration number and password are stored in your Mac's Keychain, and nowhere else.
- They are sent only to the VIT login portal (`phc.prontonetworks.com`, or your Wi-Fi router's address when the portal's name can't be looked up), and only after the network has redirected Match to that portal.
- Match makes no other network calls, apart from a connectivity check to `clients3.google.com` that carries no personal data.

**The portal only speaks plain HTTP.** Your password crosses the Wi-Fi unencrypted, exactly as it does when you type it into the portal's login page yourself. Match cannot change that. A hostile network that imitates the VIT portal could therefore capture the password. Match reduces the risk by signing in only when the network redirects to a known VIT portal address, but that check is not proof of the network's identity.

## Credits

Match's portal protocol follows [Latch](https://github.com/vinnovateit/latch) by VinnovateIT (MIT licensed), which supports Android, Windows and Linux. Match is an independent, native macOS implementation.

## License

MIT. See [LICENSE](LICENSE).
