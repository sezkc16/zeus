import 'package:flutter/widgets.dart';

/// Centralized spacing and layout values for consistent UI.
/// Use from details_screen, explore_carousel, and other layout code.
class LayoutConstants {
  LayoutConstants._();

  // Spacing
  static const double spacingXs = 8;
  static const double spacingSm = 12;
  static const double spacingMd = 16;
  static const double spacingLg = 24;

  // Details screen SliverAppBar
  static const double detailsExpandedHeightMobile = 400;
  static const double detailsExpandedHeightDesktop = 300;

  // Explore carousel: use same breakpoint as [ResponsiveBreakpoints.desktopBreakpoint]
  static const double exploreCarouselDesktopBreakpoint = 900;

  // Carousel hero aspect ratio (e.g. 16/9)
  static const double carouselHeroAspectRatio = 16 / 9;

  // Border Radius
  static const double radiusSm = 4;
  static const double radiusMd = 8;
  static const double radiusLg = 12;
  static const double radiusXl = 16;
  static const double radiusXxl = 24;
  static const double radiusPill = 50;

  // Home poster rows (build 110, user 2026-11-21 01:46): SkyStream-like
  // portrait cards on phones — 130 pt wide, ~150 pt tall. Measured
  // from the user's SkyStream shot with pixel detection: SkyStream's
  // Home posters are NOT 2:3 (~130x150, ratio ~1:1.15), so matching
  // them means leaving the 2:3 ratio behind on phone rows. Desktop /
  // widescreen rows keep the 2:3 poster ratio.
  static const double homePosterCardWidth = 130.0;
  static const double homePosterImageHeight = 150.0;

  // Content constraints
  static const double contentMaxWidth = 800;

  // Dashboard layout (widescreen)
  static const double sidebarWidthExpanded = 230;
  static const double sidebarWidthCompact = 80;
  static const double contentCardRadius = 24;
  static const double dashboardHeaderHeight = 56;
  static const double dashboardContentPadding = 24;

  /// Bottom padding so list content clears the floating bottom nav.
  ///
  /// Prefer [MediaQuery.padding.bottom] when [AppScaffold] has already inflated
  /// it for the shell; fall back to a safe minimum when it has not (e.g. a
  /// screen opened outside the shell).
  static double shellBottomContentPadding(
    BuildContext context, {
    double minimum = 100,
  }) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return bottom > minimum ? bottom : minimum;
  }

  /// What the shell adds to the media padding while the floating nav pill is
  /// on screen. Mirrors `CustomBottomNavBar.contentClearance` (a test keeps
  /// the two equal); kept here so this file stays free of widget imports.
  static const double navPillClearance = 88;

  /// Extra space under the last row of a screen that has no nav pill over
  /// it, on top of the safe-area inset. Zero since 1.0.1 build 67 (was 16):
  /// the last row's own padding plus the home-indicator inset already read
  /// as a gap ("isme avivi thoda gap hein").
  static const double pillFreeEndPadding = 0;

  /// The least the list may end with when the device has no bottom inset at
  /// all, so the last card never touches the screen edge.
  static const double pillFreeMinEndPadding = 8;

  /// Bottom padding for screens the shell shows WITHOUT the nav pill: the
  /// Settings branch (Settings and everything under it) on a phone.
  ///
  /// With no pill there is nothing to clear, so the list ends with the real
  /// safe-area inset plus [pillFreeEndPadding] instead of the 100 px floor of
  /// [shellBottomContentPadding], which left a blank block under the last row.
  ///
  /// If the pill IS on screen (the shell has inflated the media padding to at
  /// least [navPillClearance]) this returns exactly what
  /// [shellBottomContentPadding] returns, so the same screen stays safe if it
  /// is ever hosted on a tab branch.
  static double pillFreeBottomContentPadding(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    if (bottom >= navPillClearance) return shellBottomContentPadding(context);
    final end = bottom + pillFreeEndPadding;
    return end < pillFreeMinEndPadding ? pillFreeMinEndPadding : end;
  }
}
