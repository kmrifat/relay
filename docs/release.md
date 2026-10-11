# Releasing Relay

**Build model.** The Mac app is a Developer ID build: signed, notarized, delivered as a DMG, and updated in place by Sparkle. It is not sandboxed and not in the Mac App Store, because relayd runs agent CLIs and git (ADR-0001). The iPhone app goes through TestFlight, then the App Store.

**Scripts.** Adapted from DevVault's `tool/release/`, they live in `tool/release/` and run from `apps/relay`. `.github/workflows/release.yml` runs them when a `v*` tag is pushed. Each job skips itself if its secrets aren't set.

## 1. Version

Three places must agree, and `tool/release/check_version.sh v0.2.0` checks them:

- the tag, `v<version>`;
- `apps/relay/pubspec.yaml`, as `version: <version>+<build>`. The build number must grow every release, because Sparkle compares it;
- `relayVersion` in `packages/relay_daemon/lib/src/server.dart`.

## 2. macOS: sign, notarize, staple (M9-03)

Repository secrets:

| Secret | What |
|---|---|
| `MACOS_CERT_P12_BASE64` | *Developer ID Application* certificate + private key, exported as .p12, then `base64 -i cert.p12` |
| `MACOS_CERT_PASSWORD` | the .p12 password |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_ID` | the Apple ID used for notarization |
| `APPLE_APP_PASSWORD` | an app-specific password for that Apple ID (appleid.apple.com) |

`macos_sign_notarize.sh` signs from the inside out (Sparkle's helpers, frameworks and dylibs, `relay` and `relay-pty` with `Helper.entitlements`, then the app). It then makes `Relay-macos.dmg`, notarizes it, staples it and checks it with `spctl`.

The LaunchAgent plist (`Contents/Library/LaunchAgents`) is covered by the app's seal.

To do it locally with your own keychain identity, export the same variables and run `../../tool/release/macos_sign_notarize.sh` from `apps/relay`.

## 3. Sparkle updates (M9-03)

Relay is open source (decision 4), so releases and `appcast.xml` live on GitHub. `SPARKLE_FEED_URL` already points at `…/releases/latest/download/appcast.xml`, and `RELEASE_BASE_URL` defaults to this repo's releases.

Updates stay off until:

- the repository is public, because the app can't fetch private release assets;
- the update key is set (steps 1 and 3 below).

To turn them on:

1. Make an update key with Sparkle's `generate_keys` (Sparkle 2.9.6, the version pinned in `macos/Podfile`).
   - Store the private half, exported with `generate_keys -x`, as the secret `SPARKLE_ED_PRIVATE_KEY`.
   - Put the public half in `macos/Runner/Configs/AppInfo.xcconfig` as `SPARKLE_PUBLIC_ED_KEY`.
2. (Only when releases are hosted somewhere else.) Change `SPARKLE_FEED_URL`, and set the repository variable `RELEASE_BASE_URL` (`<base>/v<version>/Relay-macos.dmg`).
3. Make the repository public.

`macos_appcast.sh` writes `appcast.xml` with the DMG's EdDSA signature. Sparkle runs only when the person chooses **Check for Updates…** (Settings → This Mac). It checks the signature and the Developer ID team before it installs anything.

## 4. iPhone: TestFlight (M9-04)

| Secret | What |
|---|---|
| `APPLE_TEAM_ID` | as above |
| `IOS_DIST_CERT_P12_BASE64` / `IOS_DIST_CERT_PASSWORD` | *Apple Distribution* certificate + key |
| `APP_STORE_CONNECT_KEY_ID` / `APP_STORE_CONNECT_ISSUER_ID` | an App Store Connect API key (App Manager or higher) |
| `APP_STORE_CONNECT_KEY_P8_BASE64` | its `AuthKey_<id>.p8`, base64 |

Once, in App Store Connect:

1. Create the app with bundle ID `com.binarycastle.relay`.
2. Enable **Push Notifications** for that App ID; Relay registers for APNs (M8-04).

`ios_testflight.sh` archives with automatic signing through the API key, exports for App Store Connect, and uploads. The build shows in TestFlight once Apple has processed it.

**Export compliance:** Relay encrypts team data (XChaCha20-Poly1305, X25519). App Store Connect asks about encryption on each build. Answer it, or set `ITSAppUsesNonExemptEncryption` once you've decided.

**Push in production:** the entitlement says `development`, and Xcode switches it to production for App Store builds. The team's APNs key itself is set in the Mac app (Settings → Team → iPhone push).

## 5. Windows and Linux (M10)

The `release.yml` jobs build them on every tag:

- **Windows:** `relay-windows-x64-setup.exe` (Inno Setup, per-user) and a portable `relay-windows-x64.zip`. The app is in the root; relayd, `relay-pty.exe` and `sqlite3.dll` are in `helpers\`.
- **Linux:** `relay-linux-x64.AppImage` with its `.zsync` (AppImageUpdate), and a `relay-linux-x64.tar.gz` bundle.

Neither is code-signed yet. On Windows, SmartScreen warns until a signing certificate is added (a decision for the owner). The installer script is `tool/release/windows_installer.iss`; the AppImage script is `tool/release/linux_appimage.sh`.

## 6. Release checklist

1. Run all the tests (CI's `checks` workflow, or locally as in the README).
2. Bump the three versions and the build number, then commit and merge to `main` through a PR.
3. `git tag v<version> && git push origin v<version>`.
4. Check the GitHub release (DMG, and `appcast.xml` once Sparkle is on) and the TestFlight build.
5. Install the DMG on a clean Mac:
   - Gatekeeper opens it without a warning;
   - Settings → This Mac → Start at login works;
   - the menu bar item shows.
