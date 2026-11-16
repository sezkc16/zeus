import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/features/search/presentation/search_category.dart';
import 'package:zorox/features/search/presentation/search_provider.dart';

MultimediaItem _item({
  MultimediaContentType type = MultimediaContentType.movie,
  List<String>? tags,
  List<StreamResult>? streams,
}) => MultimediaItem(
  title: 'Title',
  url: 'https://fake.test/title',
  posterUrl: '',
  contentType: type,
  tags: tags,
  streams: streams,
);

void main() {
  group('searchCategoryLabel', () {
    test('spells the chips as the design preview does', () {
      expect(searchCategoryLabel(SearchCategory.all), 'All');
      expect(searchCategoryLabel(SearchCategory.movies), 'Movies');
      expect(searchCategoryLabel(SearchCategory.tvShows), 'TV Shows');
      expect(searchCategoryLabel(SearchCategory.anime), 'Anime');
      expect(searchCategoryLabel(SearchCategory.kDrama), 'K-Drama');
      expect(searchCategoryLabel(SearchCategory.fourK), '4K');
    });
  });

  group('matchesSearchCategory', () {
    test('All passes everything', () {
      for (final type in MultimediaContentType.values) {
        expect(matchesSearchCategory(_item(type: type), SearchCategory.all), isTrue);
      }
    });

    test('Movies, TV Shows and Anime read the content type', () {
      final movie = _item(type: MultimediaContentType.movie);
      final series = _item(type: MultimediaContentType.series);
      final anime = _item(type: MultimediaContentType.anime);

      expect(matchesSearchCategory(movie, SearchCategory.movies), isTrue);
      expect(matchesSearchCategory(series, SearchCategory.movies), isFalse);
      expect(matchesSearchCategory(series, SearchCategory.tvShows), isTrue);
      expect(matchesSearchCategory(anime, SearchCategory.tvShows), isFalse);
      expect(matchesSearchCategory(anime, SearchCategory.anime), isTrue);
      expect(matchesSearchCategory(movie, SearchCategory.anime), isFalse);
    });

    test('K-Drama needs a series whose tags name it', () {
      expect(
        matchesSearchCategory(
          _item(type: MultimediaContentType.series, tags: ['K-Drama', 'Romance']),
          SearchCategory.kDrama,
        ),
        isTrue,
      );
      expect(
        matchesSearchCategory(
          _item(type: MultimediaContentType.series, tags: ['korean drama']),
          SearchCategory.kDrama,
        ),
        isTrue,
      );
      // A movie tagged K-Drama is not a K-Drama series.
      expect(
        matchesSearchCategory(
          _item(type: MultimediaContentType.movie, tags: ['K-Drama']),
          SearchCategory.kDrama,
        ),
        isFalse,
      );
      // Extension results are rebuilt without tags, so they never match.
      expect(
        matchesSearchCategory(
          _item(type: MultimediaContentType.series),
          SearchCategory.kDrama,
        ),
        isFalse,
      );
    });

    test('4K needs a stream at 2160 lines or more', () {
      const StreamResult stream4k = StreamResult(
        url: 'https://fake.test/4k',
        source: 'fake',
        quality: 2160,
      );
      const StreamResult stream1080 = StreamResult(
        url: 'https://fake.test/1080',
        source: 'fake',
        quality: 1080,
      );
      expect(
        matchesSearchCategory(
          _item(streams: [stream1080, stream4k]),
          SearchCategory.fourK,
        ),
        isTrue,
      );
      expect(
        matchesSearchCategory(
          _item(streams: [stream1080]),
          SearchCategory.fourK,
        ),
        isFalse,
      );
      // Extension results carry no streams, so they never match.
      expect(
        matchesSearchCategory(_item(), SearchCategory.fourK),
        isFalse,
      );
    });
  });

  group('searchCategoryProvider', () {
    test('defaults to All and keeps the choice', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(searchCategoryProvider), SearchCategory.all);
      container.read(searchCategoryProvider.notifier).set(SearchCategory.anime);
      expect(container.read(searchCategoryProvider), SearchCategory.anime);
    });
  });
}
