# Zeus

Zeus is a media streaming app for iOS and Android: browse and play movies
and TV through plugins and add-ons you install yourself (CloudStream `.cs3`
plugins run through the bundled `packages/cs3_engine`; Stremio add-ons and
Nuvio plugins are supported too). The app ships with no content of its own.

**Based on SkyStream.** Zeus is built on the open-source
[SkyStream](https://github.com/akashdh11/skystream) project (GPL-3.0): the
streaming engine, player, downloads and plugin support descend from it.
Zeus adds its own design, branding and features on top. See `LICENSE` and
`NOTICE.md`; the app credits SkyStream in Settings → About.

## Identity

- App name: Zeus
- iOS bundle id: `com.legion.zeus`
- Android applicationId: `com.legion.zeus` (set on the `android-v1` branch)
- In-app update checks read the latest release of `github.com/sezkc16/zeus`
  (`lib/core/services/update_service.dart`). A release tag such as `v2` is
  read as 2.0.0; the Android updater needs an APK asset whose name contains
  `android`.

The Dart package is still named `zorox` and some internal identifiers
(method channels, the Android namespace, the `zorox_mpv_pip` package) keep
that name. They are internal only and are not shown to users.

## Layout

- `lib/` — the Flutter app.
- `packages/cs3_engine/` — the CloudStream plugin engine (on iOS it runs
  plugins on the embedded OpenJDK Zero VM — see
  `packages/cs3_engine/README.md`).
- `packages/` — other local packages the app depends on
  (`challenge_browser`, `flutter_js_ng`, `flutter_torrent_server`,
  `media_kit_video`, `vlc_player`, `zorox_mpv_pip`).
- `android/`, `ios/` — platform shells.
- `assets/`, `test/` — bundled assets and tests.

## Build

- **iOS:** every push to `master` builds an unsigned IPA on GitHub Actions
  (`.github/workflows/ios.yml`) for sideloading.
- **Android:** built locally from the `android-v1` branch
  (`flutter build apk --release --target-platform android-arm64`), signed
  with the project's own release key.

To verify locally:

```sh
flutter pub get
dart analyze
flutter test
```
