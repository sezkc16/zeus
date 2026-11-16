/// VideoToolbox session-loss decision (+40 P4): `hwdec-current` is the
/// decoder actually in use — empty (or `no`) once iOS has invalidated
/// the session while the app was backgrounded, `videotoolbox` /
/// `videotoolbox-copy` while it is alive. Either VideoToolbox flavour
/// counts as alive.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_ios_options.dart';

void main() {
  group('hwdecSessionLost', () {
    test('videotoolbox => alive', () {
      expect(hwdecSessionLost(current: 'videotoolbox'), isFalse);
    });

    test('videotoolbox-copy => alive', () {
      expect(hwdecSessionLost(current: 'videotoolbox-copy'), isFalse);
    });

    test('empty => lost (the phone-proof signal)', () {
      expect(hwdecSessionLost(current: ''), isTrue);
    });

    test('no => lost (software decode)', () {
      expect(hwdecSessionLost(current: 'no'), isTrue);
    });

    test('whitespace around a live value => alive', () {
      expect(hwdecSessionLost(current: '  videotoolbox  '), isFalse);
    });

    test('an unknown value => lost', () {
      expect(hwdecSessionLost(current: 'auto'), isTrue);
    });
  });
}
