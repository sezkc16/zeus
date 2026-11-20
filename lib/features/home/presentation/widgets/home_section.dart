import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:zorox/core/utils/responsive_breakpoints.dart';
import 'package:zorox/core/router/app_router.dart';
import 'package:zorox/core/utils/image_fallbacks.dart';
import 'package:zorox/core/utils/layout_constants.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../shared/widgets/desktop_scroll_wrapper.dart';
import '../../../../shared/widgets/multimedia_card.dart';

class HomeSection extends ConsumerStatefulWidget {
  final String title;
  final List<MultimediaItem> items;
  const HomeSection({super.key, required this.title, required this.items});

  @override
  ConsumerState<HomeSection> createState() => _HomeSectionState();
}

class _HomeSectionState extends ConsumerState<HomeSection> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final isLarge = context.isTabletOrLarger;

    // Phones: the SkyStream-like 130x~150 poster card (build 110) —
    // image 150 + title block 40. Widescreen keeps its 2:3 cards.
    final double totalHeight = isLarge
        ? 350.0
        : LayoutConstants.homePosterImageHeight + 40.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // Build 112: left inset 0 (rows start at the left screen
          // edge), right stays 16. Matches MediaHorizontalList's
          // flushLeft on Home; this widget is currently unused.
          padding: const EdgeInsets.only(
            left: 0,
            right: 16,
            top: 8,
            bottom: 8,
          ),
          child: Text(
            widget.title,
            style: isLarge
                ? Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold)
                : Theme.of(context).textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(
          height: totalHeight,
          child: DesktopScrollWrapper(
            controller: _scrollController,
            showButtons: isLarge, // Show nav buttons on both desktop and TV
            child: Builder(
              builder: (context) {
                final double cardWidth = isLarge ? 200.0 : 130.0;
                final double spacing = isLarge
                    ? LayoutConstants.spacingLg
                    : LayoutConstants.spacingSm;

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(
                    left: 0,
                    right: LayoutConstants.spacingMd,
                    top: LayoutConstants.spacingXs,
                    bottom: LayoutConstants.spacingXs,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.items.length,
                  itemExtent: cardWidth + spacing,
                  itemBuilder: (context, index) {
                    final item = widget.items[index];
                    return Padding(
                      padding: EdgeInsets.only(right: spacing),
                      child: MultimediaCard(
                        key: ValueKey(item.url),
                        imageUrl:
                            AppImageFallbacks.poster(
                              item.posterUrl,
                              label: item.title,
                            ) ??
                            '',
                        title: item.title,
                        heroTag: 'home_${item.url}_$index',
                        onTap: () =>
                            DetailsRoute($extra: DetailsRouteExtra(item: item))
                                .push<void>(context),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
