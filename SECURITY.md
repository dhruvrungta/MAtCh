# Security

Match handles your VIT Wi-Fi password, so security problems matter. Thank you for taking the time to report one.

## Reporting a problem

**Please don't open a public issue.** Report it privately instead: on the repository page, open the **Security** tab and click **Report a vulnerability**. Only the maintainer can see the report.

Please include:

- what the problem is and what someone could do with it;
- the steps to reproduce it;
- your Match version (Settings → About) and your macOS version.

You can expect an acknowledgement within a few days. Fixes go out as a new release, and the report is credited in the changelog unless you'd rather not be named.

## What counts

Anything that could expose or misuse a saved sign-in. For example:

- the password leaving the Mac for anywhere other than the VIT login portal;
- the password appearing in logs, files, notifications or "Copy diagnostics";
- another app reading the saved sign-in without the user's approval;
- the installer or the update check fetching something other than this project's own releases.

## Known limits

These are by design, and are described in the README:

- The VIT login portal only accepts plain HTTP, so the password crosses the Wi-Fi unencrypted, exactly as it does when typed into the portal's page.
- A hostile network that imitates the VIT portal convincingly could capture the password. Match signs in only when it is redirected to a known VIT portal address, which reduces the risk but cannot prove a network's identity.
- Match is not notarized by Apple, so macOS warns about it on first launch.

## Supported versions

Only the latest release receives fixes.
