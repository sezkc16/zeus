import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/providers/device_info_provider.dart';
import 'package:zorox/core/storage/history_repository.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/details/presentation/details_controller.dart';
import 'package:zorox/features/details/presentation/details_screen.dart';
import 'package:zorox/features/details/presentation/downloaded_file_provider.dart';
import 'package:zorox/features/details/presentation/widgets/hero_details_widgets.dart';
import 'package:zorox/features/library/presentation/library_provider.dart';
import 'package:zorox/features/library/presentation/library_state.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

const String _kUrl = 'https://fake.test/title';
const String _kBanner = 'https://fake.test/banner.jpg';

/// A large phone in portrait: 590x1200 logical at a raster scale of 3, which
/// is the mobile branch (`isTabletOrLarger` is false below 600 dp) with enough
/// room that the test font's wide glyphs do not overflow the metadata row.
/// The mobile banner is the one this screen paints — a television
/// is `isTabletOrLarger` and takes the desktop hero instead.
const double _phoneDevicePixelRatio = 3.0;
const double _phoneLogicalWidth = 590;
const Size _phonePhysicalSize = Size(1770, 3600);

/// Every history getter goes through Hive-backed [StorageService]; answer
/// "never watched" and skip the boxes entirely.
class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  int getPosition(String url) => 0;
  @override
  int getDuration(String url) => 0;
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

/// The real notifier hits path_provider through DownloadService on the
/// post-frame check; keep the map and drop the disk probe.
class _FakeDownloadedFiles extends DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};

  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
}

/// The screen's own post-frame `loadDetails` would go to the network; the
/// state is handed to it already resolved instead.
class _FakeDetailsController extends DetailsController {
  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncValue.data(_item()),
    isMovie: true,
    item: _item(),
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
    bool forceRefresh = false,
  }) async {}
}

/// The bookmark row, without Hive underneath it.
class _FakeLibrary extends Library {
  @override
  LibraryState build() => const LibraryEmpty();
}

MultimediaItem _item() => MultimediaItem(
  title: 'A Title',
  url: _kUrl,
  posterUrl: '',
  bannerUrl: _kBanner,
  contentType: MultimediaContentType.movie,
);

/// Stands in for any MediaQuery shim installed above this screen. `main.dart`
/// ships one: on television it rebuilds the whole app under
/// `devicePixelRatio: 1.0`. It cannot change the raster scale — that is read
/// off the FlutterView — so a decode sized from MediaQuery asks for a
/// fraction of the pixels the panel paints and is upscaled to fill.
class _DensityClamp extends StatelessWidget {
  const _DensityClamp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(devicePixelRatio: 1.0),
      child: child,
    );
  }
}

Future<void> _pumpDetails(
  WidgetTester tester, {
  bool clampDensity = false,
}) async {
  tester.view.devicePixelRatio = _phoneDevicePixelRatio;
  tester.view.physicalSize = _phonePhysicalSize;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      historyRepositoryProvider.overrideWithValue(_NoHistory()),
      downloadedFilesProvider.overrideWith(_FakeDownloadedFiles.new),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
      detailsControllerProvider.overrideWith2((_) => _FakeDetailsController()),
      libraryProvider.overrideWith(_FakeLibrary.new),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: clampDensity
            ? (context, child) => _DensityClamp(child: child!)
            : null,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DetailsScreen(item: _item()),
      ),
    ),
  );
  // Never settle: the artwork placeholders never resolve under test.
  await tester.pump();
}

CachedNetworkImage _hero(WidgetTester tester) =>
    tester.widget<CachedNetworkImage>(
      find.byWidgetPredicate(
        (w) => w is CachedNetworkImage && w.imageUrl == _kBanner,
      ),
    );

void main() {
  group('the details hero bounds its decode to what cover paints', () {
    testWidgets('at the banner box, not at the window width', (tester) async {
      await _pumpDetails(tester);

      // A 16:9 backdrop behind the 590x440 dp banner is scaled by the HEIGHT
      // and cropped at the sides, so 590 dp of window width is not the width
      // that has to be sharp: 440 * 16/9 = 782.2 dp is, and at 3x that is
      // 2347 px.
      const boxWidth = _phoneLogicalWidth;
      final boxHeight = detailsHeroBannerHeight(const Size(590, 1200));
      const expected = 2347; // (440 * 16 / 9 * 3).round()

      expect(tester.getSize(find.byType(DetailsScreen)).width, boxWidth);
      expect(boxHeight, 440);
      expect(
        tester.getSize(find.byKey(const ValueKey('details-hero-banner'))).height,
        // A movie's page has the round Play button hanging off the banner.
        boxHeight + kDetailsPlayFabOverhang,
      );
      expect(_hero(tester).memCacheWidth, expected);
      expect(
        _hero(tester).memCacheWidth,
        isNot((boxWidth * _phoneDevicePixelRatio).round()),
        reason: 'bounded to the window width, which cover crops away',
      );
    });

    testWidgets('at the raster scale, immune to a MediaQuery density shim', (
      tester,
    ) async {
      await _pumpDetails(tester, clampDensity: true);

      expect(_hero(tester).memCacheWidth, 2347);
      expect(
        _hero(tester).memCacheWidth,
        isNot(782),
        reason: 'took the shimmed devicePixelRatio of 1.0 off MediaQuery',
      );
    });
  });
}
