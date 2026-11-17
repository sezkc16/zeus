import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../l10n/generated/app_localizations.dart';

/// One source's search results (v5, design A "Rows"): a header — the
/// source's icon, its name and how many results it returned, with
/// "View All" on the right — over a horizontally scrolling row of
/// portrait posters, each with its title beneath.
class SearchSourceRow extends StatelessWidget {
  const SearchSourceRow({
    super.key,
    required this.sourceId,
    required this.name,
    required this.results,
    required this.onOpen,
    required this.onViewAll,
    this.iconUrl,
    this.firstCardFocusNode,
  });

  final String sourceId;

  /// The source's clean name ("Anikoto").
  final String name;

  /// The plugin's own icon; a neutral placeholder shows without one.
  final String? iconUrl;
  final List<MultimediaItem> results;
  final void Function(MultimediaItem item) onOpen;
  final VoidCallback onViewAll;
  final FocusNode? firstCardFocusNode;

  /// About four posters show at once on a phone.
  static const double posterWidth = 84;
  static const double posterHeight = 124;
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 6),
          child: Row(
            children: [
              _SourceIcon(url: iconUrl),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$name · ${results.length}',
                  key: ValueKey('search-source-header-$sourceId'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
              TextButton(
                key: ValueKey('search-source-view-all-$sourceId'),
                onPressed: onViewAll,
                style: TextButton.styleFrom(
                  foregroundColor: cs.primary,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  l10n.viewAll,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: posterHeight + 24,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: results.length,
            separatorBuilder: (_, _) => const SizedBox(width: _gap),
            itemBuilder: (context, index) {
              final item = results[index];
              return SearchPosterTile(
                key: ValueKey('search-poster-$sourceId-${item.url}'),
                item: item,
                focusNode: index == 0 ? firstCardFocusNode : null,
                onTap: () => onOpen(item),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The source's icon in a small rounded square; a neutral puzzle piece
/// when the source has none or it fails to load.
class _SourceIcon extends StatelessWidget {
  const _SourceIcon({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: 22,
      height: 22,
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.extension_rounded,
        size: 14,
        color: cs.onSurfaceVariant,
      ),
    );
    final link = url?.trim() ?? '';
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: link.startsWith('http')
          ? CachedNetworkImage(
              imageUrl: link,
              width: 22,
              height: 22,
              fit: BoxFit.cover,
              placeholder: (_, _) => placeholder,
              errorWidget: (_, _, _) => placeholder,
            )
          : placeholder,
    );
  }
}

/// A portrait poster with its title on one line beneath.
class SearchPosterTile extends StatelessWidget {
  const SearchPosterTile({
    super.key,
    required this.item,
    required this.onTap,
    this.focusNode,
    this.width = SearchSourceRow.posterWidth,
    this.height = SearchSourceRow.posterHeight,
  });

  final MultimediaItem item;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final poster = AppImageFallbacks.poster(item.posterUrl, label: item.title);
    final blank = Container(
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.movie_outlined, color: cs.onSurfaceVariant, size: 22),
    );
    return SizedBox(
      width: width,
      child: InkWell(
        focusNode: focusNode,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: width,
                height: height,
                child: poster == null
                    ? blank
                    : CachedNetworkImage(
                        imageUrl: poster,
                        httpHeaders: item.headers,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => blank,
                        errorWidget: (_, _, _) => blank,
                      ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
