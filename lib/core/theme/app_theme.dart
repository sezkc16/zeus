import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../shared/focus/app_focus.dart';
import 'theme_variant.dart';

/// The surfaces a dark variant paints on.
///
/// Arena Gold is the palette the app has shipped since the rebrand
/// (obsidian scaffold, #161618 cards). Midnight takes the same structure
/// to near-black; Liquid Glass keeps the structure with a cooler tint,
/// its glass-ness carried by [ZoroxThemeExtension] rather than by these
/// colours. Text and accent colours are identical across all three —
/// only surfaces move.
class _DarkPalette {
  const _DarkPalette({
    required this.scaffold,
    required this.surface,
    required this.dialog,
    required this.card,
    required this.inputFill,
    required this.divider,
    required this.appBar,
  });

  final Color scaffold;
  final Color surface;
  final Color dialog;
  final Color card;
  final Color inputFill;
  final Color divider;
  final Color appBar;
}

const _arenaGoldPalette = _DarkPalette(
  scaffold: Color(0xFF0A0A0B),
  surface: Color(0xFF161618),
  dialog: Color(0xFF17171A),
  card: Color(0xFF161618),
  inputFill: Color(0xFF17171A),
  divider: Color(0xFF1E1E21),
  appBar: Color(0xFF0A0A0B),
);

const _midnightPalette = _DarkPalette(
  scaffold: Color(0xFF000000),
  surface: Color(0xFF0A0A0A),
  dialog: Color(0xFF0A0A0A),
  card: Color(0xFF0A0A0A),
  inputFill: Color(0xFF111113),
  divider: Color(0xFF1C1C1E),
  appBar: Color(0xFF000000),
);

const _liquidGlassPalette = _DarkPalette(
  scaffold: Color(0xFF0B0D12),
  surface: Color(0xFF15181F),
  dialog: Color(0xFF171B23),
  card: Color(0xFF15181F),
  inputFill: Color(0xFF171B23),
  divider: Color(0xFF1F2430),
  appBar: Color(0xFF0B0D12),
);

/// Olympus Noir (build 102) — cinematic gold on obsidian: the deepest
/// of the dark variants, with #090B10 backgrounds and #15171E surfaces.
const _obsidianPalette = _DarkPalette(
  scaffold: Color(0xFF090B10),
  surface: Color(0xFF15171E),
  dialog: Color(0xFF171A21),
  card: Color(0xFF15171E),
  inputFill: Color(0xFF171A21),
  divider: Color(0xFF20242E),
  appBar: Color(0xFF090B10),
);

class AppTheme {
  /// The bundled application type family.
  ///
  /// The whole ramp used to come from the google_fonts package, which
  /// downloads the .ttf from fonts.gstatic.com on first launch: with no
  /// network the app rendered in a fallback face, and every first launch
  /// reached out to a third-party server before the user had done anything.
  /// The six weights the app uses are now declared in pubspec.yaml under
  /// `fonts:`.
  static const String fontFamily = 'Outfit';

  /// Fonts that ship as bundle assets are not registered with Flutter's
  /// licence registry the way a package's LICENSE file is, so the SIL Open
  /// Font License text that travels with Outfit is registered here. The
  /// package it replaced did the equivalent at runtime; the in-app licence
  /// page keeps showing the entry without it.
  ///
  /// The app's own licence is registered here too, for the same reason:
  /// Flutter lists only what dependencies declare. ZoroX is GPL-3.0, which
  /// asks an interactive program to show where its licence is.
  static bool _fontLicenceRegistered = false;

  static void _registerFontLicence() {
    if (_fontLicenceRegistered) return;
    _fontLicenceRegistered = true;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const <String>[
        fontFamily,
      ], await rootBundle.loadString('assets/fonts/OFL.txt'));
      yield LicenseEntryWithLineBreaks(const <String>[
        'Zeus',
      ], await rootBundle.loadString('LICENSE'));
    });
  }

  // Premium Colors — ZoroX Gold & Black (see ZOROX_DESIGN_SPEC.md).
  static const Color background = Color(0xFF0A0A0B); // Obsidian
  static const Color surface = Color(0xFF161618); // Cards
  static const Color surfaceHighlight = Color(0xFF26262A);
  static const Color primary = Color(0xFFD4AF37); // Gold Accent
  static const Color primaryVariant = Color(0xFFB8860B); // Gold Accent Darker
  static const Color secondary = Color(0xFF10B981); // Emerald
  static const Color error = Color(0xFFEF4444);
  static const Color onSurface = Color(0xFFF5F2EA); // Warm White
  static const Color textSecondary = Color(0xFFA7A49B); // Muted

  // Light Theme Colors
  static const Color lightBackground = Color(0xFFF5F1EC); // primary surface
  static const Color lightSurface = Color(0xFFFAF8F5); // surfaceContainerLowest
  static const Color lightSurfaceHighlight = Color(
    0xFFE8E2D8,
  ); // surfaceContainerHigh
  static const Color lightTextPrimary = Color(0xFF2C2521); // onSurface
  static const Color lightTextSecondary = Color(0xFF5C5C5C); // onSurfaceVariant
  static const Color lightCoral = Color(0xFFC63523); // Coral Accent

  /// Page background of Liquid Glass with Dark Mode off.
  static const Color liquidGlassLightBackground = Color(0xFFEEF1F6);

  /// The variant's surface, when the caller builds a dark theme whose
  /// surface is not Arena Gold's (Midnight, Liquid Glass). Defaults to
  /// [surface] — the existing behaviour for every caller that does not
  /// pass one.
  static SnackBarThemeData snackBarThemeFor(
    ColorScheme colorScheme, {
    Color? surfaceColor,
  }) {
    final isDark = colorScheme.brightness == Brightness.dark;
    return SnackBarThemeData(
      backgroundColor: isDark
          ? (surfaceColor ?? surface)
          : colorScheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(
        color: isDark ? onSurface : colorScheme.onSurface,
      ),
      actionTextColor: colorScheme.primary,
      // Floating pill above the bottom nav, not a full-width black bar at
      // the very bottom covering the liquid-glass nav pill: floating
      // behaviour + rounded shape to match the M3 toasts. (SnackBarTheme
      // has no margin slot — the margin that lifts the pill above the nav
      // lives in [appSnackBar], which every SnackBar in the app is built
      // with; see lib/core/widgets/app_snack_bar.dart.)
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      elevation: 6,
    );
  }

  /// Every Material control's focus indicator, in one place.
  ///
  /// Before this existed, a [FilledButton] in this app had no focus state that
  /// could be seen at all: Material 3 answers focus with an overlay of about
  /// a tenth of the foreground colour, which on an accent-filled pill is
  /// invisible on a phone and simply not there from a sofa. On a television
  /// that is not a cosmetic problem - a fresh install sends the viewer to
  /// Extensions -> Repositories -> Add Repository, and with nothing on screen
  /// telling them which button the remote is pointing at, the app reads as
  /// locked. This is the fix for that, and because it is a theme every button,
  /// tab and list row in the app gets it without being touched.
  ///
  /// Material reports [WidgetState.focused] for any button that holds focus,
  /// and a button can hold it under a thumb - autofocused for a remote, or
  /// handed focus back as a dialog closes - so the ring also asks
  /// [FocusVisibility], the one rule every focus indicator in the app follows.
  /// See `shared/focus/app_focus.dart`.
  static FilledButtonThemeData _filledButtonTheme(ColorScheme cs) =>
      FilledButtonThemeData(style: ButtonStyle(side: AppFocus.buttonSide(cs)));

  static ElevatedButtonThemeData _elevatedButtonTheme(ColorScheme cs) =>
      ElevatedButtonThemeData(
        style: ButtonStyle(side: AppFocus.buttonSide(cs)),
      );

  static TextButtonThemeData _textButtonTheme(ColorScheme cs) =>
      TextButtonThemeData(style: ButtonStyle(side: AppFocus.buttonSide(cs)));

  /// An outlined button already wears a border, so its resolver has to hand
  /// back that border in every state but focused.
  static OutlinedButtonThemeData _outlinedButtonTheme(ColorScheme cs) =>
      OutlinedButtonThemeData(
        style: ButtonStyle(
          side: AppFocus.buttonSide(
            cs,
            unfocused: BorderSide(color: cs.outline),
          ),
        ),
      );

  static IconButtonThemeData _iconButtonTheme(ColorScheme cs) =>
      IconButtonThemeData(style: ButtonStyle(side: AppFocus.buttonSide(cs)));

  /// Tabs and segmented buttons are ink responses rather than shaped buttons,
  /// so they take the wash instead of the ring.
  static TabBarThemeData _tabBarTheme(ColorScheme cs) =>
      TabBarThemeData(overlayColor: AppFocus.overlay(cs));

  /// Builds the dark theme for [variant].
  ///
  /// Arena Gold is the palette this method has always built (the
  /// default, so existing callers are unchanged). Midnight and Liquid
  /// Glass swap the surfaces only — the seed/accent handling, text
  /// colours and every sub-theme below are identical. Frost is the
  /// light variant and has no dark palette: a dark theme asked for
  /// Frost falls back to Arena Gold rather than inventing one (the
  /// variant picker also flips the mode to light when Frost is picked,
  /// so this is only reached when the mode is later switched back).
  static ThemeData createDarkTheme(
    ColorScheme? dynamicScheme, {
    Color seedColor = const Color(0xFF66BB6A),
    ZoroxThemeVariant variant = ZoroxThemeVariant.arenaGold,
  }) {
    _registerFontLicence();
    final palette = switch (variant) {
      ZoroxThemeVariant.midnight => _midnightPalette,
      ZoroxThemeVariant.liquidGlass => _liquidGlassPalette,
      ZoroxThemeVariant.obsidian => _obsidianPalette,
      // Arena Gold, and Frost (light-only — see above).
      _ => _arenaGoldPalette,
    };
    var colorScheme =
        dynamicScheme ??
        ColorScheme.fromSeed(
          seedColor: seedColor, // Accent seed (Green by default, v4)
          brightness: Brightness.dark,
          surface: palette.surface, // Cards
        );

    // Cards / list items in the design's surface colour.
    colorScheme = colorScheme.copyWith(surface: palette.surface);

    // Achromatic accents (White/Black v20+37, Silver v3):
    // ColorScheme.fromSeed builds a tonal palette from the seed and the
    // seed itself never becomes `primary` — for achromatic seeds the
    // palette is the same neutral ramp, so White and Black collapse to
    // the identical light-grey primary and Silver collapses to the same
    // light blue as Blue (0xFF9ECAFC vs 0xFF9DCBFB), and neither looks
    // like the swatch that was tapped (the picker checkmark moves, the
    // app does not recolor). Pin the primary family to the literal
    // accent for seeds with almost no saturation; the chromatic presets
    // keep the tonal scheme untouched. Silver's 0xFFE8E8EC reads as
    // saturation ~0.095 (its blue channel is 4 steps above red/green),
    // so the threshold sits at 0.15 — every chromatic preset is above
    // 0.5. onPrimary follows the same
    // luminance guard the light theme already uses (dark text on a
    // light accent, white text on a dark one), so White and Black keep
    // exactly the behaviour they had under the old exact match.
    final seedSaturation = HSLColor.fromColor(seedColor).saturation;
    if (seedSaturation < 0.15) {
      final isLight = seedColor.computeLuminance() > 0.6;
      final onAccent = isLight ? const Color(0xFF1A1A1A) : Colors.white;
      final container = isLight
          ? const Color(0xFF2E2E33)
          : const Color(0xFF1C1C1F);
      colorScheme = colorScheme.copyWith(
        primary: seedColor,
        onPrimary: onAccent,
        primaryContainer: container,
        onPrimaryContainer: Colors.white,
        tertiary: seedColor,
        onTertiary: onAccent,
        tertiaryContainer: container,
        onTertiaryContainer: Colors.white,
        surfaceTint: seedColor,
      );
    }

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: palette.scaffold,
      // Obsidian Background for Screens
      // Dialog Theme (Premium Grey)
      dialogTheme: DialogThemeData(
        backgroundColor: palette.dialog,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Color(0xFFF5F2EA),
        ),
      ),

      // Bottom Sheet Theme (Premium Grey)
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.dialog,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: palette.dialog,
      ),

      // Card Theme (Surface for List Items)
      cardTheme: CardThemeData(
        color: palette.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),

      // Material 3 Color Scheme
      colorScheme: colorScheme,

      // Typography
      textTheme: ThemeData.dark().textTheme
          .apply(fontFamily: fontFamily)
          .copyWith(
            displayLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF5F2EA),
            ),
            displayMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF5F2EA),
            ),
            displaySmall: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFFF5F2EA),
            ),
            headlineMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF5F2EA),
            ),
            titleLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF5F2EA),
            ),
            titleMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF5F2EA),
            ),
            bodyLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 16,
              color: Color(0xFFF5F2EA),
            ),
            bodyMedium: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              color: Color(0xFFA7A49B),
            ),
            // WCAG AA (4.5:1) for 12 sp body text, which is the settings
            // subtitle stating the current value of every setting. The old
            // 0xFF6B7280 measured 4.34:1 on the pure-black scaffold and only
            // 3.65:1 on the 0xFF17171A dialog and bottom sheet; this is the
            // same slate lifted 15% and clears both (5.51:1 and 4.63:1).
            bodySmall: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 12,
              color: Color(0xFFA7A49B),
            ),
            labelLarge: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
              color: Color(0xFFF5F2EA),
            ),
          ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: palette.appBar,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: palette.scaffold,
        // Pure Black matches background
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showSelectedLabels: false,
        showUnselectedLabels: false,
        landscapeLayout: BottomNavigationBarLandscapeLayout.spread,
      ),

      // Keep SnackBars visually consistent with the dark application instead
      // of Material's default inverse (light) surface.
      snackBarTheme: snackBarThemeFor(
        colorScheme,
        surfaceColor: palette.surface,
      ),

      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.inputFill, // Slightly lighter grey for fields
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
      ),

      dividerColor: palette.divider,
      dividerTheme: DividerThemeData(
        thickness: 1,
        space: 1,
        color: palette.divider,
      ),

      // One focus indicator for every Material control. See
      // [_filledButtonTheme] for why this is a theme and not a widget.
      filledButtonTheme: _filledButtonTheme(colorScheme),
      elevatedButtonTheme: _elevatedButtonTheme(colorScheme),
      textButtonTheme: _textButtonTheme(colorScheme),
      outlinedButtonTheme: _outlinedButtonTheme(colorScheme),
      iconButtonTheme: _iconButtonTheme(colorScheme),
      tabBarTheme: _tabBarTheme(colorScheme),
      // Every bare [InkWell] and [ListTile] in the app reads this one, so a
      // row that is not a button still shows where the remote is.
      focusColor: colorScheme.onSurface.withValues(alpha: 0.16),

      // Switch Theme
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
          if ((states.contains(WidgetState.focused) &&
                  FocusVisibility.visible) ||
              states.contains(WidgetState.hovered)) {
            if (states.contains(WidgetState.selected)) {
              return const Icon(Icons.check_rounded, size: 14);
            } else {
              return const Icon(Icons.close_rounded, size: 14);
            }
          }
          return null;
        }),
      ),

      // Which variant this theme is, for widgets that key a treatment
      // off it (the glass nav reads `isGlass`). Every variant carries
      // the extension; only Liquid Glass sets it.
      extensions: <ThemeExtension<dynamic>>[
        ZoroxThemeExtension(isGlass: variant == ZoroxThemeVariant.liquidGlass),
      ],
    );
  }

  /// Builds the light theme.
  ///
  /// Frost is the warm light palette, and Arena Gold / Midnight (dark
  /// only) get the same one if a light theme is ever asked of them.
  /// Liquid Glass has its own cool light palette and carries the glass
  /// flag in both modes.
  static ThemeData createLightTheme(
    ColorScheme? dynamicScheme, {
    Color? accent,
    ZoroxThemeVariant variant = ZoroxThemeVariant.arenaGold,
  }) {
    _registerFontLicence();
    var colorScheme = const ColorScheme.light(
      primary: lightCoral,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFFFDAD4),
      onPrimaryContainer: Color(0xFF410001),
      secondary: Color(0xFF775651),
      onSecondary: Colors.white,
      secondaryContainer: lightSurfaceHighlight,
      onSecondaryContainer: Color(0xFF2C1512),
      tertiary: lightCoral,
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFFFDAD4),
      onTertiaryContainer: Color(0xFF410001),
      surface: lightBackground,
      onSurface: lightTextPrimary,
      onSurfaceVariant: lightTextSecondary,
      outline: Color(0xFFC9BBA6), // Warm sand outline
      outlineVariant: Color(0xFFD9C9AE), // Soft warm tan outlineVariant
      error: Color(0xFFBA1A1A),
      onError: Colors.white,
      surfaceContainerLowest: lightSurface,
      surfaceContainerLow: Color(0xFFF7F3EE),
      surfaceContainer: Color(0xFFEFEAE2),
      surfaceContainerHigh: lightSurfaceHighlight,
      surfaceContainerHighest: Color(0xFFE4D9C8),
    );

    // Liquid Glass with Dark Mode off: the same structure on cool,
    // blue-grey paper instead of Frost's warm sand - the light
    // counterpart of the cool dark Liquid Glass surfaces. Every colour
    // is opaque, like the other variants.
    if (variant == ZoroxThemeVariant.liquidGlass) {
      colorScheme = colorScheme.copyWith(
        surface: liquidGlassLightBackground,
        onSurface: const Color(0xFF141821),
        onSurfaceVariant: const Color(0xFF4A5261),
        outline: const Color(0xFFB4BCCB),
        outlineVariant: const Color(0xFFCBD2DE),
        secondary: const Color(0xFF4F5B70),
        secondaryContainer: const Color(0xFFDDE2EB),
        onSecondaryContainer: const Color(0xFF141821),
        surfaceContainerLowest: const Color(0xFFF8FAFD),
        surfaceContainerLow: const Color(0xFFF3F5F9),
        surfaceContainer: const Color(0xFFE6EAF1),
        surfaceContainerHigh: const Color(0xFFDDE2EB),
        surfaceContainerHighest: const Color(0xFFD3D9E4),
      );
    }

    // The accent drives the light theme's primary too, so the picker works
    // in both themes. Containers are a light tint of the accent; their "on"
    // colour is the accent darkened, so text stays readable on them.
    //
    // A near-white accent (White, M M 2026-11-14) would make `onPrimary`
    // white-on-white — invisible. Very light accents get dark `onPrimary`
    // text instead, so a white button still reads.
    if (accent != null) {
      final hsl = HSLColor.fromColor(accent);
      final darkAccent = hsl
          .withLightness((hsl.lightness - 0.35).clamp(0.0, 1.0))
          .toColor();
      final onPrimary = accent.computeLuminance() > 0.6
          ? const Color(0xFF1A1A1A)
          : Colors.white;
      colorScheme = colorScheme.copyWith(
        primary: accent,
        onPrimary: onPrimary,
        primaryContainer: accent.withValues(alpha: 0.18),
        onPrimaryContainer: darkAccent,
        tertiary: accent,
        onTertiary: onPrimary,
        tertiaryContainer: accent.withValues(alpha: 0.18),
        onTertiaryContainer: darkAccent,
      );
    }

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: colorScheme.surface,

      // Dialog Theme
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),

      // Bottom Sheet Theme
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: colorScheme.surface,
      ),

      // Card Theme
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),

      // Material 3 Color Scheme
      colorScheme: colorScheme,

      // Typography
      textTheme: ThemeData.light().textTheme
          .apply(fontFamily: fontFamily)
          .copyWith(
            displayLarge: TextStyle(
              fontFamily: fontFamily,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
            headlineMedium: TextStyle(
              fontFamily: fontFamily,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
            titleLarge: TextStyle(
              fontFamily: fontFamily,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
            bodyLarge: TextStyle(
              fontFamily: fontFamily,
              fontSize: 16,
              color: colorScheme.onSurface,
            ),
            bodyMedium: TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
            // Full-strength onSurfaceVariant, not 80% of it: the alpha
            // blended 0xFF5C5C5C down to 0xFF7B7A79 on the 0xFFF5F1EC
            // scaffold, which is 3.81:1 and fails WCAG AA. Undimmed it is
            // 5.95:1 on the scaffold and 4.80:1 on the darkest container.
            bodySmall: TextStyle(
              fontFamily: fontFamily,
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamily: fontFamily,
        ),
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        showSelectedLabels: false,
        showUnselectedLabels: false,
      ),

      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),

      // Chip Theme
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        disabledColor: colorScheme.onSurface.withValues(alpha: 0.12),
        selectedColor: colorScheme.primary.withValues(alpha: 0.15),
        secondarySelectedColor: colorScheme.primary.withValues(alpha: 0.15),
        labelStyle: TextStyle(color: colorScheme.onSurface),
        secondaryLabelStyle: TextStyle(color: colorScheme.primary),
        checkmarkColor: colorScheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide.none,
        ),
      ),

      // Switch Theme
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
          if ((states.contains(WidgetState.focused) &&
                  FocusVisibility.visible) ||
              states.contains(WidgetState.hovered)) {
            if (states.contains(WidgetState.selected)) {
              return const Icon(Icons.check_rounded, size: 14);
            } else {
              return const Icon(Icons.close_rounded, size: 14);
            }
          }
          return null;
        }),
      ),

      // Slider Theme
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.primary.withValues(alpha: 0.24),
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
      ),

      // Floating Action Button Theme
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),

      // SnackBar Theme
      snackBarTheme: snackBarThemeFor(colorScheme),

      // Ripple / Splash / Highlights
      splashColor: colorScheme.primary.withValues(alpha: 0.1),
      hoverColor: colorScheme.primary.withValues(alpha: 0.04),
      highlightColor: colorScheme.primary.withValues(alpha: 0.05),

      // Selection Text Theme
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.3),
        selectionHandleColor: colorScheme.primary,
      ),

      dividerColor: colorScheme.outlineVariant,
      dividerTheme: DividerThemeData(
        thickness: 1,
        space: 1,
        color: colorScheme.outlineVariant,
      ),

      // The same focus indicator as the dark theme; the ring colour comes
      // from the scheme, so it is near-black here and near-white there.
      filledButtonTheme: _filledButtonTheme(colorScheme),
      elevatedButtonTheme: _elevatedButtonTheme(colorScheme),
      textButtonTheme: _textButtonTheme(colorScheme),
      outlinedButtonTheme: _outlinedButtonTheme(colorScheme),
      iconButtonTheme: _iconButtonTheme(colorScheme),
      tabBarTheme: _tabBarTheme(colorScheme),
      // Every bare [InkWell] and [ListTile] in the app reads this one, so a
      // row that is not a button still shows where the remote is.
      focusColor: colorScheme.onSurface.withValues(alpha: 0.16),

      // Which variant this theme is — see [createDarkTheme]. The palette
      // here is always Frost; only the glass flag follows the variant.
      extensions: <ThemeExtension<dynamic>>[
        ZoroxThemeExtension(isGlass: variant == ZoroxThemeVariant.liquidGlass),
      ],
    );
  }
}
