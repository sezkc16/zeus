/// My List writes through to real storage: adding an item puts it in the
/// library box and the [Library] notifier reports it, removing takes it out.
///
/// A plain `test`, not a widget test: a real Hive box never completes its
/// writes inside a widget test's fake-async zone, so the widget-side hero
/// tests run the same notifier against an in-memory repository instead
/// (see `explore_carousel_preview_hero_test.dart`).
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/library/presentation/library_provider.dart';
import 'package:zorox/features/library/presentation/library_state.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('library_storage');
    // StorageService.init() asks path_provider where to put its boxes.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
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

  test('adding then removing an item updates the library state', () async {
    final container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    final movie = MultimediaItem(
      title: 'Title 0',
      url: 'https://fake.test/0',
      posterUrl: '',
      bannerUrl: '',
      contentType: MultimediaContentType.movie,
    );

    expect(container.read(libraryProvider), isA<LibraryEmpty>());

    await container.read(libraryProvider.notifier).addItem(movie);
    expect(storage.isInLibrary(movie.url), isTrue);
    final afterAdd = container.read(libraryProvider);
    expect(afterAdd, isA<LibrarySuccess>());
    expect(
      (afterAdd as LibrarySuccess).items.any((i) => i.url == movie.url),
      isTrue,
    );

    await container.read(libraryProvider.notifier).removeItem(movie.url);
    expect(storage.isInLibrary(movie.url), isFalse);
    expect(container.read(libraryProvider), isA<LibraryEmpty>());
  });
}
