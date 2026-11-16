import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/skip_segments.dart';
import 'package:zorox/features/skip/data/skip_service.dart';

void main() {
  SkipSegment seg(double start, double end, [SkipType type = SkipType.intro]) =>
      SkipSegment(startTime: start, endTime: end, type: type);

  group('segmentAt', () {
    final segments = <SkipSegment>[
      seg(30, 90),
      seg(1200, 1260, SkipType.outro),
    ];

    test('finds the segment containing the position', () {
      expect(segmentAt(segments, const Duration(seconds: 45))?.type,
          SkipType.intro);
      expect(segmentAt(segments, const Duration(seconds: 1230))?.type,
          SkipType.outro);
    });

    test('is null between segments', () {
      expect(segmentAt(segments, const Duration(seconds: 600)), isNull);
    });

    // Half-open: start is inside, end is not, so the button disappears exactly
    // when the seek would become a no-op.
    test('includes the start instant and excludes the end instant', () {
      expect(segmentAt(segments, const Duration(seconds: 30)), isNotNull);
      expect(segmentAt(segments, const Duration(seconds: 90)), isNull);
      expect(segmentAt(segments, const Duration(seconds: 89)), isNotNull);
    });

    test('handles sub-second positions', () {
      expect(segmentAt(segments, const Duration(milliseconds: 29999)), isNull);
      expect(segmentAt(segments, const Duration(milliseconds: 30001)), isNotNull);
    });

    test('an empty list never matches', () {
      expect(segmentAt(const <SkipSegment>[], const Duration(seconds: 45)),
          isNull);
    });

    test('the reported Attack on Titan case: the playhead inside the OP '
        'shows the chip (+56)', () {
      // +56, user proof 2026-11-16: S1E2 at 01:12-01:18 showed no Skip
      // Intro, although AniSkip reports the OP as 54.312-144.312. The
      // chip renders exactly when segmentAt finds a segment, so at
      // 72 s the chip must show — the missing button was the lookup
      // never running (no MAL id), not the chip.
      final aotOp = <SkipSegment>[seg(54.312, 144.312)];
      expect(segmentAt(aotOp, const Duration(seconds: 72)), isNotNull);
      expect(segmentAt(aotOp, const Duration(seconds: 72))?.type,
          SkipType.intro);
      expect(segmentAt(aotOp, const Duration(seconds: 78)), isNotNull);
      expect(segmentAt(aotOp, const Duration(seconds: 150)), isNull,
          reason: 'past the OP the chip is gone');
    });
  });
}
