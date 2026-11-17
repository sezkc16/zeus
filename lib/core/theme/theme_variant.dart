import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../storage/settings_repository.dart';
import 'theme_provider.dart';

part 'theme_variant.g.dart';

/// The four named theme variants (Settings → General: Midnight / Arena
/// Gold / Frost / Liquid Glass).
///
/// The variant is the *look*; [ThemeMode] still decides dark / light /
/// system. The three dark variants differ only in surfaces — the accent
/// still drives `primary` in all of them, exactly as it did before this
/// layer existed:
///
/// * [arenaGold] — the theme the app has shipped since the rebrand:
///   obsidian background, gold accent. Still selectable in Settings.
/// * [midnight] — the same structure with backgrounds and surfaces taken
///   to near-black; the gold accent stays.
/// * [frost] — the light theme, unchanged from the one that shipped
///   before. It is the only variant whose brightness is light.
/// * [liquidGlass] — a dark theme with a cooler tint and a glass
///   treatment: the floating pill nav already renders frosted glass
///   (see `CustomBottomNavBar`, built on `liquid_glass_bottom_nav`),
///   and this variant marks the theme glass through
///   [ZoroxThemeExtension] so widgets can key their background
///   treatment off it instead of guessing from the variant name.
///   The fresh-install default: the approved design preview wears the
///   glass pill nav, so a first launch must look like the preview, not
///   the fork's Arena Gold.
enum ZoroxThemeVariant {
  arenaGold(
    'Arena Gold',
    'Dark with the gold accent',
    isDark: true,
  ),
  midnight(
    'Midnight',
    'Purer black dark theme, gold accent kept',
    isDark: true,
  ),
  frost(
    'Frost',
    'The light theme',
    isDark: false,
  ),
  liquidGlass(
    'Liquid Glass',
    'Dark with a glass nav and cooler surfaces',
    isDark: true,
  );

  const ZoroxThemeVariant(this.label, this.detail, {required this.isDark});

  /// Display name shown in Settings.
  final String label;

  /// One line under the name in the picker dialog.
  final String detail;

  /// Whether the variant is a dark theme. Frost is the only light one.
  final bool isDark;

  /// The saved variant name, or Liquid Glass for anything this release
  /// never wrote. Storage outlives downgrades and hand-editing, so an
  /// unrecognised value is reachable; it says no more than an absent one
  /// does, and lands in the same place. Liquid Glass is the fresh-install
  /// default (the approved design preview wears the glass pill nav);
  /// Arena Gold stays selectable in Settings.
  static ZoroxThemeVariant fromName(String? name) {
    if (name == null) return ZoroxThemeVariant.liquidGlass;
    for (final variant in ZoroxThemeVariant.values) {
      if (variant.name == name) return variant;
    }
    return ZoroxThemeVariant.liquidGlass;
  }
}

/// Theme-side marker for the Liquid Glass variant.
///
/// The pill nav's glass comes from the `liquid_glass_bottom_nav` package
/// on every variant; what this carries is the *theme's* answer to "is
/// this the glass variant", so a widget that wants a frosted background
/// reads `Theme.of(context).extension<ZoroxThemeExtension>()?.isGlass`
/// instead of importing the variant enum and comparing names. Every
/// theme the app builds carries it — `false` for the other three
/// variants, so a missing extension and a non-glass theme read the same.
class ZoroxThemeExtension extends ThemeExtension<ZoroxThemeExtension> {
  const ZoroxThemeExtension({required this.isGlass});

  /// True only on the Liquid Glass variant.
  final bool isGlass;

  @override
  ZoroxThemeExtension copyWith({bool? isGlass}) =>
      ZoroxThemeExtension(isGlass: isGlass ?? this.isGlass);

  @override
  ZoroxThemeExtension lerp(
    ThemeExtension<ZoroxThemeExtension>? other,
    double t,
  ) {
    if (other is! ZoroxThemeExtension) return this;
    return ZoroxThemeExtension(isGlass: t < 0.5 ? isGlass : other.isGlass);
  }

  @override
  bool operator ==(Object other) =>
      other is ZoroxThemeExtension && other.isGlass == isGlass;

  @override
  int get hashCode => isGlass.hashCode;
}

/// The user's chosen theme variant, persisted across restarts.
///
/// Everything that wears the variant reads it through the [ThemeData]
/// `AppTheme` builds in `main.dart`, so changing it rebuilds the whole
/// app at once — no restart, no re-login.
@Riverpod(keepAlive: true)
class ThemeVariant extends _$ThemeVariant {
  late SettingsRepository _repository;

  @override
  ZoroxThemeVariant build() {
    _repository = ref.watch(settingsRepositoryProvider);
    return ZoroxThemeVariant.fromName(_repository.getThemeVariant());
  }

  /// Applies the variant live, and flips the theme mode to match its
  /// brightness so the tap is visible at once: picking Frost while the
  /// mode is Dark would otherwise change nothing on screen, because the
  /// dark theme is still the one in force. The App Theme row stays the
  /// override — switching it back to System re-resolves brightness from
  /// the device, and the variant follows per brightness (a dark variant
  /// under a light system, or Frost under a dark one, falls back to the
  /// matching side's palette — see [AppTheme.createDarkTheme] /
  /// [AppTheme.createLightTheme]).
  Future<void> setVariant(ZoroxThemeVariant variant) async {
    state = variant;
    await _repository.saveThemeVariant(variant.name);
    // Remember the last dark variant, so the Dark Mode toggle knows
    // where to return to from Frost.
    if (variant.isDark) {
      await _repository.saveLastDarkThemeVariant(variant.name);
    }
    await ref
        .read(appThemeModeProvider.notifier)
        .setThemeMode(variant.isDark ? ThemeMode.dark : ThemeMode.light);
  }

  /// The Dark Mode toggle (Settings → General, under the variant
  /// picker). The variant stays the single source of truth, so the
  /// toggle and the picker can never fight: picking a dark variant
  /// turns the toggle on (its mode is dark); picking Frost turns it
  /// off. Toggling off from a dark variant switches to the light look
  /// (Frost); toggling on from Frost returns to the last dark variant
  /// (Liquid Glass if none was ever picked).
  Future<void> setDarkMode(bool enabled) async {
    if (enabled) {
      if (state.isDark) return;
      final lastDark = ZoroxThemeVariant.fromName(
        _repository.getLastDarkThemeVariant(),
      );
      await setVariant(
        lastDark.isDark ? lastDark : ZoroxThemeVariant.liquidGlass,
      );
    } else {
      if (!state.isDark) return;
      await setVariant(ZoroxThemeVariant.frost);
    }
  }
}
