import 'dart:convert';

/// What of the app's settings a Zeus backup carries (v9), and what it
/// never does.
///
/// The backup takes settings from an explicit allow-list — [kSyncedSettingKeys]
/// — never "everything in the settings box". A key that is not on the list
/// is not read into a backup and not written from one, whatever a backup
/// file claims to hold. So nothing below can ever travel:
///
///   * tokens, passwords and API keys (Trakt, Simkl, MAL, AniList, the TMDB
///     key, OpenSubtitles / SubDL / SubSource logins, debrid, plugin logins);
///   * the app-lock switch;
///   * the sync server URL, the session and the last-synced time;
///   * download folder and download tuning;
///   * per-device caches and memories (last source per title, search
///     history, the active plugin, declined update, developer switches).
const Set<String> kSyncedSettingKeys = <String>{
  // Look.
  'theme_mode',
  'theme_variant',
  'last_dark_theme_variant',
  'accent_color',
  // Home and navigation.
  'default_home_screen',
  'title_position',
  'home_row_prefs',
  'search_disabled_sources',
  'episode_sort_ascending',
  // Player.
  'player_engine',
  'player_ios_mpv_pip',
  'player_pip_mode',
  'player_gesture_left',
  'player_gesture_right',
  'player_double_tap',
  'player_swipe_seek',
  'player_seek_duration',
  'player_buffer_override_mb',
  'player_default_resize',
  'player_autoplay_next_episode',
  'player_mobile_data_max_quality',
  'player_wifi_quality',
  'player_mobile_quality',
  'player_quality_filter_mode',
  'player_preferred_source_language',
  'player_auto_skip',
  'player_hw_dec',
  'player_max_volume',
  'player_show_episodes',
  'player_show_pip',
  'player_show_playback_speed',
  'player_show_remaining',
  'player_show_resize',
  'player_show_rotate',
  'player_show_volume',
  // Video panel: the HDR choice and the PICTURE sliders.
  'player_video_output_preset',
  'player_picture_brightness',
  'player_picture_contrast',
  'player_picture_saturation',
  // Subtitles and audio.
  'player_subtitle_default',
  'player_audio_language',
  'player_sub_size',
  'player_sub_color',
  'player_sub_bg',
  'player_sub_bg_opacity',
  'player_sub_outline',
  'player_sub_shadow',
  'player_sub_raise',
  'player_sub_auto_adjust',
  'player_sub_bold',
  'player_sub_font',
  'player_sub_text_opacity',
  'player_sub_encoding',
};

/// Whether [value] is something a backup may carry for a setting: a plain
/// string, number or boolean. Anything else (a list, a map, an object) is
/// left out rather than guessed at.
bool _isPlainSettingValue(Object? value) =>
    value is String || value is bool || (value is num && value.isFinite);

/// The synced settings as they are stored now: each allow-listed key that
/// has a plain value. A key with nothing stored is simply absent (which is
/// how "default" travels).
Map<String, dynamic> collectSyncedSettings(
  Object? Function(String key) read,
) {
  final out = <String, dynamic>{};
  for (final key in kSyncedSettingKeys) {
    final value = read(key);
    if (_isPlainSettingValue(value)) out[key] = value;
  }
  return out;
}

/// Makes the stored settings match [settings] for every allow-listed key:
/// a key the backup carries is written, a key it does not carry is cleared
/// (back to its default). Keys off the allow-list are ignored, both ways —
/// a backup file cannot write a secret or the app-lock switch.
///
/// Returns how many keys actually changed.
Future<int> applySyncedSettings(
  Map<String, dynamic> settings, {
  required Object? Function(String key) read,
  required Future<void> Function(String key, Object? value) write,
}) async {
  var changed = 0;
  for (final key in kSyncedSettingKeys) {
    final incoming = settings[key];
    final current = read(key);
    if (_isPlainSettingValue(incoming)) {
      if (current != incoming) {
        await write(key, incoming);
        changed++;
      }
    } else if (current != null) {
      await write(key, null);
      changed++;
    }
  }
  return changed;
}

/// Whether a Stremio add-on's manifest URL looks like it carries a
/// credential (v9) — a debrid key, an API key, a token, a login.
///
/// Configured add-ons keep their configuration inside the URL, and for
/// many that includes a debrid or API key. A backup must never carry one,
/// so such an add-on is left out of the backup (it stays on this device).
/// This errs on the side of leaving out: anything that names a credential,
/// carries user-info, or holds a long opaque configuration segment that
/// cannot be read as plain settings counts as carrying one.
bool addonUrlCarriesSecret(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url.trim());
  } catch (_) {
    return true;
  }
  if (uri.userInfo.isNotEmpty) return true;
  String decoded;
  try {
    decoded = Uri.decodeFull(url);
  } catch (_) {
    decoded = url;
  }
  if (_namesCredential(decoded)) return true;
  for (final segment in uri.pathSegments) {
    if (segment.isEmpty || segment == 'manifest.json') continue;
    final text = _tryDecodeSegment(segment);
    if (text != null) {
      if (_namesCredential(text)) return true;
      continue;
    }
    // Not readable as text: a long opaque blob may be an encrypted or
    // packed configuration — or a bare key. Leave it out.
    if (segment.length >= 24 && _opaque.hasMatch(segment)) return true;
  }
  for (final value in uri.queryParameters.values) {
    if (value.length >= 24 && _opaque.hasMatch(value)) return true;
  }
  return false;
}

final RegExp _opaque = RegExp(r'^[A-Za-z0-9_\-+/=.~%]+$');

final RegExp _credentialName = RegExp(
  r'(real[-_ ]?debrid|all[-_ ]?debrid|premiumize|torbox|debrid[-_ ]?link|'
  r'easy[-_ ]?debrid|offcloud|put\.?io|pikpak|debrid|'
  r'api[-_ ]?key|apikey|access[-_ ]?token|refresh[-_ ]?token|token|'
  r'secret|passw(or)?d|passwd|auth|bearer|session|cookie|credential|'
  r'username|user[-_ ]?id|login|email)',
  caseSensitive: false,
);

bool _namesCredential(String text) => _credentialName.hasMatch(text);

/// A path segment read as text when it is base64 (plain or URL-safe) of
/// readable text — the usual shape of an add-on's packed configuration —
/// or already readable settings (`a=b|c=d`). Null when it is neither.
String? _tryDecodeSegment(String segment) {
  String raw;
  try {
    raw = Uri.decodeComponent(segment);
  } catch (_) {
    raw = segment;
  }
  // Already readable settings: has separators a key would not.
  if (RegExp(r'[=|,:{}\[\]"]').hasMatch(raw) && !raw.endsWith('=')) {
    return raw;
  }
  if (raw.length < 16) return raw; // Too short to be a packed config.
  try {
    var b64 = raw.replaceAll('-', '+').replaceAll('_', '/');
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    final text = utf8.decode(base64.decode(b64));
    final printable = text.runes.every((r) => r >= 0x20 || r == 0x0a);
    if (printable && RegExp(r'[{=:]').hasMatch(text)) return text;
  } catch (_) {
    // Not base64 text.
  }
  // A plain word-like segment (letters with separators, no long digit/
  // mixed run) is a route, not a blob.
  if (RegExp(r'^[a-z]+([\-_.][a-z0-9]+)*$', caseSensitive: false)
          .hasMatch(raw) &&
      raw.length < 40) {
    return raw;
  }
  return null;
}

/// When the automatic sync may run (v9): on cold start and on return to
/// the foreground, at most once per [minInterval], only while logged in
/// with the switch on, and never over the player.
class AutoSyncGate {
  AutoSyncGate({this.minInterval = const Duration(minutes: 10)});

  final Duration minInterval;
  DateTime? _lastRun;

  /// Whether a run may start at [now]. Does not record anything: call
  /// [markRan] when the run actually starts.
  bool mayRun({
    required DateTime now,
    required bool loggedIn,
    required bool enabled,
    required bool playerOnTop,
    required bool busy,
  }) {
    if (!loggedIn || !enabled || playerOnTop || busy) return false;
    final last = _lastRun;
    if (last != null && now.difference(last) < minInterval) return false;
    return true;
  }

  void markRan(DateTime now) => _lastRun = now;
}
