# Contributing

Thanks for wanting to help with MAtCh. Bug reports, fixes and improvements are all welcome.

## Reporting a bug

Open an issue with the **Bug report** form. The most useful thing you can include is the text from **Settings → Advanced → Copy diagnostics**, which has your registration number removed. Please never paste your password anywhere.

For security problems, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Building and testing

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The README's "Building from source" section lists every `make` target. The ones you'll use most:

```sh
make test          # unit tests, plus the name check
make run           # build and launch the app
make mock          # a pretend login portal on this Mac...
make run-mock      # ...and the app pointed at it
```

Before opening a pull request, please make sure these pass:

```sh
make test
make test-mock
make test-install
make lint          # needs ShellCheck: brew install shellcheck
```

## Ground rules

These keep MAtCh safe to trust with a password:

- **The password goes only to the VIT login portal**, and only after the network has redirected MAtCh there. It must never be logged, written to a file, shown in a notification or sent anywhere else.
- **Never automatically resend credentials the portal rejected.**
- **No third-party dependencies.**
- **Don't rebuild or re-sign the vault** (`Vault/MatchVault.xpc`) unless the vault itself must change. Every rebuild makes everyone who updates approve Keychain access again. The README's "The vault" section explains why.
- **Builds have zero warnings** under Swift 6 strict concurrency, and `make check-names` must pass.

## Pull requests

Keep each pull request to one change, describe what it changes and why, and add or update tests for anything the app does differently. Changes people will notice also get a line in [CHANGELOG.md](CHANGELOG.md).
