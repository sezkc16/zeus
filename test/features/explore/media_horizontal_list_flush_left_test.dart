/// Home rows start at the left screen edge (build 112): a
/// MediaHorizontalList with flushLeft renders the first poster and the
/// section heading at x = 0; without it both keep the 16pt inset. The
/// right inset stays 16 either way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/features/explore/presentation/view_all_screen.dart';
import 'package:zorox/features/explore/presentation/widgets/media_horizontal_list.dart';
import 'package:zorox/features/settings/presentation/general_settings_provider.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';
import 'package:zorox/shared/widgets/multimedia_card.dart';

/// MultimediaCard reads the title-position setting; the harness has no
/// StorageService, so the settings notifier is faked with defaults.
class _FakeGeneralSettings extends GeneralSettingsNotifier {
  @override
  GeneralSettings build() => const GeneralSettings();
}

const _kPhone = Size(430, 932);

List<MultimediaItem> _items() => <MultimediaItem>[
  MultimediaItem(title: 'Film One', url: 'u/one', posterUrl: ''),
  MultimediaItem(title: 'Film Two', url: 'u/two', posterUrl: ''),
];

Future<void> _pumpList(WidgetTester tester, {required bool flushLeft}) async {
  tester.view.physicalSize = _kPhone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        generalSettingsProvider.overrideWith(_FakeGeneralSettings.new),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MediaHorizontalList(
            title: 'IMDB Top',
            mediaList: _items(),
            category: ViewAllCategory.providerContent,
            flushLeft: flushLeft,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('flushLeft: first poster and heading start at the left edge', (
    tester,
  ) async {
    await _pumpList(tester, flushLeft: true);

    expect(
      tester.getTopLeft(find.byType(MultimediaCard).first).dx,
      0.0,
    );
    // The heading text sits after the 3pt gold bar + 10pt gap, so its x
    // is the inset + 13 — the bar itself is at the left edge.
    expect(tester.getTopLeft(find.text('IMDB TOP')).dx, 13.0);
    // The second card sits one card + spacing after the first, so the
    // rail itself did not shift — only the left inset is gone.
    expect(
      tester.getTopLeft(find.byType(MultimediaCard).at(1)).dx,
      130.0 + 12.0,
    );
  });

  testWidgets('default: first poster and heading keep the 16pt inset', (
    tester,
  ) async {
    await _pumpList(tester, flushLeft: false);

    expect(
      tester.getTopLeft(find.byType(MultimediaCard).first).dx,
      16.0,
    );
    expect(tester.getTopLeft(find.text('IMDB TOP')).dx, 16.0 + 13.0);
  });
}
