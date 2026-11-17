import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/utils/title_quality.dart';

void main() {
  group('statedQualityBadges', () {
    test('nothing stated, no badge', () {
      expect(statedQualityBadges('One Piece'), isEmpty);
      expect(statedQualityBadges(null), isEmpty);
      expect(statedQualityBadges('', tags: const ['Action', 'Adventure']), isEmpty);
    });

    test('the best stated resolution wins', () {
      expect(
        statedQualityBadges('Blue Box (Season 1 & 2) Hindi Dubbed Blu-Ray 1080p & 720p'),
        ['1080p'],
      );
      expect(statedQualityBadges('Movie 480p 720p'), ['720p']);
      expect(statedQualityBadges('Movie 2160p 1080p'), ['4K']);
      expect(statedQualityBadges('Movie [4K] WEB-DL'), ['4K']);
      expect(statedQualityBadges('Movie UHD BluRay'), ['4K']);
    });

    test('HDR and Dolby Vision only where the words are', () {
      expect(statedQualityBadges('Film 2160p Dolby Vision HDR10+'), ['4K', 'Dolby Vision', 'HDR']);
      expect(statedQualityBadges('Film 1080p DoVi'), ['1080p', 'Dolby Vision']);
      expect(statedQualityBadges('Film 1080p HDR'), ['1080p', 'HDR']);
      expect(statedQualityBadges('Film DVDRip 720p'), ['720p']);
    });

    test('words that only contain the pattern do not count', () {
      expect(statedQualityBadges('4Kids Special'), isEmpty);
      expect(statedQualityBadges('Movie 21080p'), isEmpty);
      expect(statedQualityBadges('HDRezka pick'), isEmpty);
    });

    test('tags are read too', () {
      expect(statedQualityBadges('Film', tags: const ['Action', '4K']), ['4K']);
    });
  });

  group('ratingLabel', () {
    test('a real score is printed out of 10', () {
      expect(ratingLabel(8.7), '8.7');
      expect(ratingLabel(10), '10.0');
      expect(ratingLabel(12), '10.0');
    });
    test('no score, no label', () {
      expect(ratingLabel(null), isNull);
      expect(ratingLabel(0), isNull);
      expect(ratingLabel(double.nan), isNull);
    });
  });
}
