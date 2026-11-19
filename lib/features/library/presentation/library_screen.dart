import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'widgets/bookmarks_tab.dart';
import 'widgets/downloads_tab.dart';
import 'widgets/watch_status_tab.dart';
import '../../../shared/focus/app_focus.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  /// 0 = My List, 1 = Watching, 2 = Completed, 3 = Downloads — the design
  /// preview's Library chips, in order. Settings opens the screen on a
  /// given tab now that Library is no longer a navigation destination.
  final int initialTab;

  const LibraryScreen({super.key, this.initialTab = 0});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late PageController _pageController;

  /// The tabs, in the design preview's order: My List (bookmarks), Watching
  /// and Completed (two views over the watch history), Downloads. 'My List'
  /// is a plain literal — there is no l10n key for it — the rest are the
  /// localised words the app already used for the same things.
  List<({String label, IconData icon})> _tabDefs(AppLocalizations l10n) => [
    (label: 'My List', icon: Icons.bookmark_rounded),
    (label: l10n.watching, icon: Icons.play_circle_outline_rounded),
    (label: l10n.completed, icon: Icons.check_circle_outline_rounded),
    (label: l10n.downloads, icon: Icons.download_for_offline_rounded),
  ];

  static const int _tabCount = 4;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTab.clamp(0, _tabCount - 1);
    _tabController = TabController(
      length: _tabCount,
      vsync: this,
      initialIndex: initial,
    );
    _pageController = PageController(initialPage: initial);

    // Sync TabBar -> PageView
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        _pageController.animateToPage(
          _tabController.index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.ease,
        );
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Widescreen is a size question, so it is asked of the size. A
    // television is 960 dp wide and clears the tablet breakpoint like any
    // other big window; it needs no device clause of its own.
    final isWidescreen = context.isTabletOrLarger;

    if (isWidescreen) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            // Inline header matching other widescreen screens
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                height: LayoutConstants.dashboardHeaderHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.dashboardContentPadding,
                ),
                child: Row(
                  children: [
                    Text(
                      AppLocalizations.of(context)!.library,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    // Tab chips
                    _buildTabChips(context),
                  ],
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (index) {
                  // Ignore page changes the chip tap itself caused: during
                  // a multi-page animated jump PageView reports every
                  // intermediate page, and feeding those back into the
                  // TabController would hijack the animation back to the
                  // intermediate tab. Swipes still sync — a swipe never
                  // sets indexIsChanging.
                  if (!_tabController.indexIsChanging) {
                    _tabController.animateTo(index);
                  }
                },
                physics: const BouncingScrollPhysics(),
                itemCount: _tabCount,
                itemBuilder: (_, i) => _tabPage(i),
              ),
            ),
          ],
        ),
      );
    }

    // Mobile layout: the preview's in-body header — big title, subtitle,
    // then the chips — instead of an AppBar with a TabBar. The chips are
    // the same _TabChip row the widescreen header uses, so the two can
    // never disagree about the order or the labels.
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(
              left: LayoutConstants.spacingMd,
              right: LayoutConstants.spacingMd,
              top: MediaQuery.paddingOf(context).top + 8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.library,
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.librarySubtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _buildTabChips(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (index) {
                // Same guard as the widescreen PageView above: ignore page
                // changes the chip tap itself caused.
                if (!_tabController.indexIsChanging) {
                  _tabController.animateTo(index);
                }
              },
              physics: const BouncingScrollPhysics(),
              children: [
                for (var i = 0; i < _tabCount; i++) _tabPage(i),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The page behind tab [index], shared by the mobile PageView and the
  /// widescreen one so the two can never disagree about the order.
  Widget _tabPage(int index) => switch (index) {
    0 => const BookmarksTab(),
    1 => const WatchStatusTab(filter: LibraryWatchFilter.watching),
    2 => const WatchStatusTab(filter: LibraryWatchFilter.completed),
    _ => const DownloadsTab(),
  };

  Widget _buildTabChips(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final tabs = _tabDefs(l10n);

    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _TabChip(
                label: tabs[i].label,
                icon: tabs[i].icon,
                selected: _tabController.index == i,
                onTap: () => _tabController.animateTo(i),
                theme: theme,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _TabChip extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final ThemeData theme;

  const _TabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.theme,
  });

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    // Read through [FocusVisibility] rather than [FocusManager] directly: the
    // highlight mode alone does not rebuild this widget when it changes, and
    // it calls a mouse click keyboard navigation.
    final showHighlight = showFocusIndicator(context, _isFocused);
    final scale = showHighlight ? 1.04 : 1.0;

    return Focus(
      onFocusChange: (f) {
        if (mounted) setState(() => _isFocused = f);
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: widget.selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.15)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.3,
                    ),
              borderRadius: BorderRadius.circular(LayoutConstants.radiusPill),
              border: showHighlight
                  ? AppFocus.border(context, focused: true)
                  : (widget.selected
                        ? Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.3,
                            ),
                          )
                        : Border.all(color: Colors.transparent, width: 1)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: widget.selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: widget.selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
