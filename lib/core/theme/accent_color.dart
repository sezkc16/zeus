import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../storage/settings_repository.dart';

part 'accent_color.g.dart';

/// The 9 accent presets — the design preview's swatch row (v3, 2.9.19+59).
/// Green is the default (user 2026-11-17: fresh installs open green) —
/// Gold stays a preset. The shades are picked to stay readable on the
/// obsidian background (#0A0A0B): saturated enough to read as an accent,
/// light enough that the active nav icon, section underlines and buttons
/// stay legible. Only the accent changes; the background stays black and
/// the layout is untouched.
///
/// White is a preset again (user 2026-11-23: the player must follow the
/// Settings accent, and White must be pickable so the player can be
/// white). Black / Cyan were presets in earlier releases (Black for the
/// light theme, M M 2026-11-14); the approved design preview shows the
/// 8 others, so those two stay gone: a saved Black / Cyan falls back to
/// Green through [fromName], which is the same landing as an absent
/// value.
enum ZoroxAccent {
  gold('Gold', Color(0xFFD4AF37)),
  red('Red', Color(0xFFE53935)),
  orange('Orange', Color(0xFFFF9800)),
  green('Green', Color(0xFF66BB6A)),
  blue('Blue', Color(0xFF42A5F5)),
  violet('Violet', Color(0xFFAB47BC)),
  pink('Pink', Color(0xFFEC407A)),
  silver('Silver', Color(0xFFE8E8EC)),
  white('White', Color(0xFFFFFFFF));

  const ZoroxAccent(this.label, this.color);

  /// Display name shown under the swatches in Settings.
  final String label;

  /// The accent color itself.
  final Color color;

  /// The saved preset name, or Green for anything this release never wrote.
  /// Storage outlives downgrades and hand-editing, so an unrecognised value
  /// is reachable; it says no more than an absent one does, and lands in
  /// the same place.
  static ZoroxAccent fromName(String? name) {
    if (name == null) return ZoroxAccent.green;
    for (final accent in ZoroxAccent.values) {
      if (accent.name == name) return accent;
    }
    return ZoroxAccent.green;
  }
}

/// The user's chosen accent color, persisted across restarts.
///
/// Everything that wears the accent reads it through
/// `Theme.of(context).colorScheme.primary`, which is seeded from this
/// value in `AppTheme`, so changing it rebuilds the whole app at once —
/// no restart, no re-login.
@Riverpod(keepAlive: true)
class AccentColor extends _$AccentColor {
  late SettingsRepository _repository;

  @override
  ZoroxAccent build() {
    _repository = ref.watch(settingsRepositoryProvider);
    return ZoroxAccent.fromName(_repository.getAccentColor());
  }

  /// Whether the user has ever picked an accent in Settings (any preset,
  /// Green included). Until then the saved value is absent — and on Android
  /// the OS dynamic colour is used instead, so Material You keeps working.
  /// Picking Green explicitly IS a choice, not the default: Green is both
  /// the fallback and a preset, so the accent state alone cannot tell
  /// "never chose" from "chose Green" — only the stored value can.
  bool get hasExplicitChoice => _repository.getAccentColor() != null;

  Future<void> setAccent(ZoroxAccent accent) async {
    if (state == accent) return;
    state = accent;
    await _repository.saveAccentColor(accent.name);
  }
}
