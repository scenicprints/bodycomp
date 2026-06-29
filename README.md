# BodyComp

A personal Android body-recomposition tracker (Flutter), with **over-the-air updates**:
push your work and pull it onto your phone with a button — no flutlab.io, no Play Store.

## How updates work

```
 you edit code  ──►  .\publish.ps1  ──►  git tag pushed  ──►  GitHub Actions
                                                                    │ builds
                                                                    │ signed APK
                                                                    ▼
   phone: Settings ► Check for updates  ◄──────────────  GitHub Release
```

1. **Publish** — run `.\publish.ps1`, give it a version number and a "What's New" note.
   It bumps the version, tags, and pushes. GitHub Actions builds a *signed* release APK
   in the cloud and attaches it to a GitHub Release.
2. **Update** — on the phone, open **Settings → App Updates → Check**. If a newer release
   exists it shows the notes and a **Download & Install** button.

## First-time phone setup

- Install the APK once (download it from the
  [Releases page](https://github.com/scenicprints/bodycomp/releases) and open it).
- When the app first tries to self-update, Android asks to allow
  **"install unknown apps"** for BodyComp — allow it. After that, updates are one tap.

## Signing (why it matters)

All builds are signed with one persistent key so Android allows in-place updates. The key
lives in `android/app/upload-keystore.jks` locally and as encrypted GitHub **secrets**
(`KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`) for CI.

> ⚠️ **Never lose the keystore.** It is `.gitignore`d. Without the exact same key you
> cannot push updates to already-installed copies — they'd have to uninstall first.
> Keep a backup of `android/app/upload-keystore.jks` and its password somewhere safe.

## Building locally (optional)

Local APK builds need the Android SDK installed (not currently set up on this machine).
CI does not — it builds everything in the cloud. To develop the Dart UI, `flutter run`
works against any connected device/emulator once the Android SDK is present.

## Project layout

| Path | What |
|---|---|
| `lib/main.dart` | The app (dashboard, ledger, settings, math engine) |
| `lib/updater.dart` | In-app OTA updater (GitHub Releases → APK install) |
| `.github/workflows/release.yml` | Cloud build + release on `v*` tag |
| `publish.ps1` | One-command release (bump → tag → push) |
