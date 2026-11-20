// Profiles Build 1: the storage choke point — per-profile history and
// library boxes, switched by setActiveZeusProfile, with the migration
// copy and the legacy clear.
//
// Real Hive I/O against a temp directory (the path_provider channel is
// mocked, as in test/app_boot_test.dart). Plain `test`, not
// `testWidgets`: Hive I/O cannot complete inside testWidgets' fake-async
// zone.
//
// NOTE: written but NOT run yet — the b107 agent is running flutter on
// this VM and two flutter processes OOM it. Run after b107 lands:
// `flutter test test/features/profiles/`.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/storage/storage_service.dart';

MultimediaItem _item(String title, {String type = 'movie'}) =>
    MultimediaItem(
      title: title,
      url: 'https://example.test/$title',
      posterUrl: '',
      contentType: type == 'series'
          ? MultimediaContentType.series
          : MultimediaContentType.movie,
    );

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('zeus_profiles_storage');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => dir.path,
    );
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('history and library are per profile, switched at the choke point', () async {
    final legacy = _item('Legacy Film');
    await storage.saveProgress(legacy, 1000, 60000);
    await storage.addToLibrary(legacy);
    expect(storage.getWatchHistory(), hasLength(1));
    expect(storage.getLibraryItems(), hasLength(1));

    // A profile starts empty.
    await storage.setActiveZeusProfile('p_aaaa000000000001');
    expect(storage.activeZeusProfileId, 'p_aaaa000000000001');
    expect(storage.getWatchHistory(), isEmpty);
    expect(storage.getLibraryItems(), isEmpty);
    expect(storage.getPosition(legacy.url), 0);

    // The profile's own data stays in its own boxes.
    final profileFilm = _item('Profile Film');
    await storage.saveProgress(profileFilm, 5000, 60000);
    await storage.addToLibrary(profileFilm);
    expect(
      storage.getWatchHistory().map((e) => e['title']),
      ['Profile Film'],
    );
    expect(
      storage.getLibraryItems().map((e) => e.title),
      ['Profile Film'],
    );

    // Back to the legacy boxes: the old data is untouched.
    await storage.setActiveZeusProfile(null);
    expect(storage.activeZeusProfileId, isNull);
    expect(
      storage.getWatchHistory().map((e) => e['title']),
      ['Legacy Film'],
    );
    expect(
      storage.getLibraryItems().map((e) => e.title),
      ['Legacy Film'],
    );
    expect(storage.getPosition(legacy.url), 1000);

    // A second profile is separate from the first.
    await storage.setActiveZeusProfile('p_aaaa000000000001');
    expect(
      storage.getWatchHistory().map((e) => e['title']),
      ['Profile Film'],
    );
    await storage.setActiveZeusProfile('p_bbbb000000000002');
    expect(storage.getWatchHistory(), isEmpty);
  });

  test('per-episode positions are per profile too', () async {
    final series = _item('Series', type: 'series');
    const episodeUrl = 'https://example.test/Series/s1e1';
    await storage.saveProgress(
      series,
      1000,
      60000,
      lastEpisodeUrl: episodeUrl,
      season: 1,
      episode: 1,
    );
    expect(storage.getEpisodePosition(episodeUrl), 1000);

    await storage.setActiveZeusProfile('p_aaaa000000000001');
    expect(storage.getEpisodePosition(episodeUrl), 0);
    await storage.saveProgress(
      series,
      7000,
      60000,
      lastEpisodeUrl: episodeUrl,
      season: 1,
      episode: 1,
    );
    expect(storage.getEpisodePosition(episodeUrl), 7000);

    await storage.setActiveZeusProfile(null);
    expect(storage.getEpisodePosition(episodeUrl), 1000);
  });

  test('clearAllHistory clears only the active profile', () async {
    await storage.saveProgress(_item('Legacy Film'), 1000, 60000);
    await storage.setActiveZeusProfile('p_aaaa000000000001');
    await storage.saveProgress(_item('Profile Film'), 5000, 60000);
    await storage.clearAllHistory();
    expect(storage.getWatchHistory(), isEmpty);

    await storage.setActiveZeusProfile(null);
    expect(storage.getWatchHistory(), hasLength(1));
  });

  test('migration copies the legacy data into the first profile', () async {
    final legacy = _item('Legacy Film');
    await storage.saveProgress(legacy, 1000, 60000);
    await storage.addToLibrary(legacy);
    expect(storage.legacyHistoryOrLibraryNonEmpty, isTrue);

    await storage.copyLegacyHistoryAndLibraryToZeusProfile(
      'p_aaaa000000000001',
    );
    await storage.setActiveZeusProfile('p_aaaa000000000001');
    expect(
      storage.getWatchHistory().map((e) => e['title']),
      ['Legacy Film'],
    );
    expect(storage.getPosition(legacy.url), 1000);
    expect(
      storage.getLibraryItems().map((e) => e.title),
      ['Legacy Film'],
    );

    // The legacy boxes still hold the data until the upload succeeds.
    await storage.setActiveZeusProfile(null);
    expect(storage.getWatchHistory(), hasLength(1));

    await storage.clearLegacyHistoryAndLibrary();
    expect(storage.getWatchHistory(), isEmpty);
    expect(storage.getLibraryItems(), isEmpty);
    expect(storage.legacyHistoryOrLibraryNonEmpty, isFalse);

    // The profile's copy survives the legacy clear.
    await storage.setActiveZeusProfile('p_aaaa000000000001');
    expect(storage.getWatchHistory(), hasLength(1));
  });

  test('getAllHistoryEntries / restoreHistoryEntries follow the active pair', () async {
    await storage.saveProgress(_item('Legacy Film'), 1000, 60000);
    final legacyEntries = storage.getAllHistoryEntries();
    expect(legacyEntries, hasLength(1));

    await storage.setActiveZeusProfile('p_aaaa000000000001');
    expect(storage.getAllHistoryEntries(), isEmpty);
    await storage.restoreHistoryEntries(legacyEntries);
    expect(storage.getAllHistoryEntries(), hasLength(1));
    expect(storage.getPosition('https://example.test/Legacy Film'), 1000);
  });
}
