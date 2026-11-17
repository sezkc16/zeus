import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/seek_band.dart';

void main() {
  const film = Duration(minutes: 23, seconds: 40);

  group('seekBandFraction', () {
    test('is the cache end (position + ahead) over the length', () {
      // The phone screenshot: 04:47 with 12.28 s cached ahead.
      final fraction = seekBandFraction(
        bufferedEnd: const Duration(minutes: 4, seconds: 59, milliseconds: 280),
        position: const Duration(minutes: 4, seconds: 47),
        duration: film,
      );
      expect(fraction, closeTo(299.28 / 1420, 1e-6));
    });

    test('never left of the playhead', () {
      final fraction = seekBandFraction(
        bufferedEnd: Duration.zero,
        position: const Duration(minutes: 10),
        duration: film,
      );
      expect(fraction, closeTo(600 / 1420, 1e-6));
    });

    test('clamped to the bar, zero for an unknown length', () {
      expect(
        seekBandFraction(
          bufferedEnd: const Duration(hours: 1),
          position: Duration.zero,
          duration: film,
        ),
        1.0,
      );
      expect(
        seekBandFraction(
          bufferedEnd: const Duration(seconds: 30),
          position: Duration.zero,
          duration: Duration.zero,
        ),
        0.0,
      );
    });
  });

  group('seekBandWidth', () {
    test('maps the fraction onto the track', () {
      expect(
        seekBandWidth(trackWidth: 800, bandFraction: 0.5, positionFraction: 0.2),
        400,
      );
    });

    test('a short buffer still shows past the thumb', () {
      // 12 s of a 23:40 film on an 880 px track is ~7 px: under the
      // thumb. It gets the minimum visible length instead.
      final position = 287 / 1420;
      final band = 299.28 / 1420;
      final width = seekBandWidth(
        trackWidth: 880,
        bandFraction: band,
        positionFraction: position,
      );
      expect(width, closeTo(position * 880 + kSeekBandMinVisibleAhead, 1e-6));
    });

    test('nothing ahead draws nothing ahead', () {
      expect(
        seekBandWidth(trackWidth: 800, bandFraction: 0.3, positionFraction: 0.3),
        closeTo(240, 1e-9),
      );
    });

    test('never past the end of the track, never negative', () {
      expect(
        seekBandWidth(trackWidth: 800, bandFraction: 1, positionFraction: 0.999),
        800,
      );
      expect(
        seekBandWidth(trackWidth: 0, bandFraction: 0.5, positionFraction: 0.1),
        0,
      );
    });
  });
}
