# ZoroX

ZoroX is the user's own media streaming app for Android and iOS: browse and
play movies and TV, run CloudStream (`.cs3`) plugins through the bundled
`packages/cs3_engine`, and keep everything under the `com.toji.zorox`
identity. It was built from scratch as its own project; the streaming and
plugin code descends from the open-source SkyStream project (GPL-3.0, see
`LICENSE` and `NOTICE.md`).

## Layout

- `lib/` — the Flutter app (495 Dart files).
- `packages/cs3_engine/` — the CloudStream plugin engine (upstream code,
  untouched; on iOS it runs plugins on the embedded OpenJDK Zero VM — see
  `packages/cs3_engine/README.md`).
- `packages/` — other local packages the app depends on
  (`challenge_browser`, `flutter_js_ng`, `flutter_torrent_server`,
  `media_kit_video`, `vlc_player`, `zorox_mpv_pip`).
- `android/`, `ios/` — platform shells. Android namespace / applicationId and
  the iOS bundle id are both `com.toji.zorox`.
- `assets/`, `test/` — bundled assets and tests.

## Build

No CI is wired up yet (no GitHub Actions, no Codemagic). To verify locally:

```sh
export PATH="$HOME/workspace/flutter/bin:$PATH"
flutter pub get
dart analyze
flutter test
```

iOS builds need Xcode on a Mac; they cannot run on this Linux VM.

## Identity

- App name: ZoroX
- Android applicationId / namespace: `com.toji.zorox`
- iOS bundle id: `com.toji.zorox`
- In-app update checks point at `github.com/sezkc16/zorox` releases
  (`lib/core/services/update_service.dart`).
