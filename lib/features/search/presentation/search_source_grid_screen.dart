import 'package:flutter/material.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import 'widgets/search_source_row.dart';

/// Every result one source returned for a search, as a 3-column poster
/// grid: what a search row's "View All" opens. A poster opens the title in
/// that same source.
class SearchSourceGridScreen extends StatelessWidget {
  const SearchSourceGridScreen({
    super.key,
    required this.title,
    required this.results,
    required this.onOpen,
  });

  /// The source's name and result count.
  final String title;
  final List<MultimediaItem> results;
  final void Function(BuildContext context, MultimediaItem item) onOpen;

  @override
  Widget build(BuildContext context) {
    final columns = context.isTabletOrLarger ? 5 : 3;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 12.0;
          final width = (constraints.maxWidth - 32 - gap * (columns - 1)) /
              columns;
          final height = width * 1.5;
          return GridView.builder(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              LayoutConstants.shellBottomContentPadding(context),
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: height + 26,
              crossAxisSpacing: gap,
              mainAxisSpacing: gap,
            ),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final item = results[index];
              return SearchPosterTile(
                key: ValueKey('search-grid-${item.url}'),
                item: item,
                width: width,
                height: height,
                onTap: () => onOpen(context, item),
              );
            },
          );
        },
      ),
    );
  }
}
