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
        seekBandWidth(
          trackWidth: 800,
          bandFraction: 0.5,
          positionFraction: 0.2,
        ),
        400,
      );
    });

    test('ends exactly where the buffer ends — no fixed minimum', () {
      // Phone, build 75: 29:31 of 3:04:50 with 9.2 s buffered. On an
      // 880 px track that is under a pixel past the playhead.
      const length = 11090.0;
      const position = 1771 / length;
      const band = (1771 + 9.216) / length;
      final width = seekBandWidth(
        trackWidth: 880,
        bandFraction: band,
        positionFraction: position,
      );
      expect(width, closeTo(band * 880, 1e-9));
      expect(width - position * 880, lessThan(1));
    });

    test('grows with the buffer and shrinks as it is used up', () {
      // 60 s on a 23:40 episode is ~4% of the bar.
      double ahead(double seconds) =>
          seekBandWidth(
            trackWidth: 880,
            bandFraction: (287 + seconds) / 1420,
            positionFraction: 287 / 1420,
          ) -
          287 / 1420 * 880;
      expect(ahead(60), closeTo(60 / 1420 * 880, 1e-9));
      expect(ahead(120), closeTo(2 * ahead(60), 1e-9));
      expect(ahead(10), lessThan(ahead(60)));
    });

    test('never left of the playhead', () {
      expect(
        seekBandWidth(
          trackWidth: 800,
          bandFraction: 0.1,
          positionFraction: 0.3,
        ),
        closeTo(240, 1e-9),
      );
    });

    test('nothing ahead draws nothing ahead', () {
      expect(
        seekBandWidth(
          trackWidth: 800,
          bandFraction: 0.3,
          positionFraction: 0.3,
        ),
        closeTo(240, 1e-9),
      );
    });

    test('never past the end of the track, never negative', () {
      expect(
        seekBandWidth(
          trackWidth: 800,
          bandFraction: 1,
          positionFraction: 0.999,
        ),
        800,
      );
      expect(
        seekBandWidth(trackWidth: 0, bandFraction: 0.5, positionFraction: 0.1),
        0,
      );
    });
  });
}
