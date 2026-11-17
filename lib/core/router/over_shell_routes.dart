import 'package:flutter/material.dart';

import '../../features/addons/presentation/addons_screen.dart';
import '../../features/nuvio/presentation/nuvio_plugins_screen.dart';

/// Opens the Nuvio Plugins / Stremio Add-ons screens OVER the tab the user
/// is on, instead of going to their `/settings/...` routes.
///
/// Those routes are children of Settings, so going to them switched to the
/// Settings branch and Back landed on the Settings screen (1.0.1 phone
/// report: Plugins → Nuvio Plugins → back = Settings). Pushed on the root
/// navigator, Back — the arrow, the iOS edge swipe and Android's back —
/// returns to wherever the screen was opened from. The `/settings/...`
/// routes stay registered for anything that still links to them.
Future<void> openNuvioPlugins(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'nuvio-plugins'),
      builder: (_) => const NuvioPluginsScreen(),
    ),
  );
}

/// See [openNuvioPlugins]. [discover] opens on the Discover tab.
Future<void> openStremioAddons(BuildContext context, {bool discover = false}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'stremio-addons'),
      builder: (_) => AddonsScreen(initialTab: discover ? 1 : 0),
    ),
  );
}
