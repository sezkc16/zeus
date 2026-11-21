import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cloudstream/cloudstream_repository.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../addons/presentation/widgets/addon_manage_view.dart';
import '../../nuvio/presentation/nuvio_plugins_view.dart';
import '../widgets/cloudstream_plugin_section.dart';
import '../widgets/plugin_check_bar.dart';
import '../widgets/plugin_updates_bar.dart';
import '../widgets/skystream_extensions_tab.dart';

/// Settings → Extensions (b121): the four plugin sources as four
/// SEPARATE tabs, one per source — SkyStream, CloudStream, Nuvio,
/// Stremio. The owner asked for them separate, not merged
/// (2026-11-22 ~04:02: "ek jagaha nahi... alag alag ho"): each tab
/// manages ONLY its own source's plugins and repositories, with its own
/// add / remove / refresh and install / uninstall. A plugin installed
/// in one tab never appears in another tab's list.
///
/// The Home plugin section (the Plugins tab) is untouched by this
/// build — it keeps working as-is; this screen is the one place per
/// source the owner asked for because the Home section is troublesome
/// ("bohot dikkat horha").
///
/// Each tab reuses the source's existing management UI, not a rewrite:
/// SkyStream is the .sky extension system ([SkyStreamExtensionsTab]),
/// CloudStream is the .cs3 repository store
/// ([CloudStreamInstalledSection] + [CloudStreamRepositoriesSection]
/// with the owner's TojiX repo in its own [ZeusRepositorySection]),
/// Nuvio is [NuvioPluginsView], Stremio is [AddonManageView].
class SettingsExtensionsScreen extends ConsumerStatefulWidget {
  /// Which tab opens first (0 SkyStream, 1 CloudStream, 2 Nuvio,
  /// 3 Stremio). Defaults to SkyStream.
  final int initialTab;

  const SettingsExtensionsScreen({super.key, this.initialTab = 0});

  @override
  ConsumerState<SettingsExtensionsScreen> createState() =>
      _SettingsExtensionsScreenState();
}

class _SettingsExtensionsScreenState
    extends ConsumerState<SettingsExtensionsScreen>
    with SingleTickerProviderStateMixin {
  static const List<_ExtensionsTab> _tabs = [
    _ExtensionsTab(label: 'SkyStream', icon: Icons.extension_rounded),
    _ExtensionsTab(label: 'CloudStream', icon: Icons.cloud_rounded),
    _ExtensionsTab(label: 'Nuvio', icon: Icons.bolt_rounded),
    _ExtensionsTab(label: 'Stremio', icon: Icons.movie_filter_rounded),
  ];

  late final TabController _tabController = TabController(
    length: _tabs.length,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, _tabs.length - 1),
  );

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              const SettingsRoute().go(context);
            }
          },
        ),
        title: const Text('Extensions'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            for (final tab in _tabs)
              Tab(icon: Icon(tab.icon, size: 20), text: tab.label),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: TabBarView(
            controller: _tabController,
            children: const [
              _KeepAlive(child: SkyStreamExtensionsTab()),
              _KeepAlive(child: _CloudStreamTab()),
              _KeepAlive(child: NuvioPluginsView()),
              _KeepAlive(child: AddonManageView()),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExtensionsTab {
  const _ExtensionsTab({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

/// The CloudStream tab: only the .cs3 store. Installed CloudStream
/// plugins, the owner's Zeus (TojiX) repository in its own section, and
/// every other CloudStream repository — each with its own add / remove /
/// refresh. Pulling the list down refreshes the installed plugins'
/// repositories for newer versions.
class _CloudStreamTab extends ConsumerWidget {
  const _CloudStreamTab();

  Future<void> _refreshInstalled(WidgetRef ref) async {
    try {
      await ref
          .read(cloudStreamRepositoryProvider.notifier)
          .refreshAll(installedOnly: true);
    } catch (_) {
      // The repository records its own failures; nothing to add here.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      notificationPredicate: (notification) => notification.depth == 0,
      onRefresh: () => _refreshInstalled(ref),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          top: LayoutConstants.spacingSm,
          bottom: LayoutConstants.pillFreeBottomContentPadding(context),
        ),
        children: const [
          PluginUpdatesBar(),
          PluginCheckBar(),
          CloudStreamInstalledSection(),
          ZeusRepositorySection(),
          CloudStreamRepositoriesSection(showAddRow: true),
        ],
      ),
    );
  }
}

/// Keeps a tab's scroll position and state while another tab shows —
/// the same keep-alive the Plugins tab uses for its two segments.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
