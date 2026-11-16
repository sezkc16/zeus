/// PiP render-cap decision (+35 P1, +47 540p): the PiP cap and the
/// thermal cap share one actuation (the fork's `VideoController.setSize`),
/// so the target is always the min of the two — PiP up takes 540p,
/// thermal alone 1080p; only both clear restores full size.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_pip_quality.dart';

void main() {
  group('pipRenderCapTarget', () {
    test('PiP up + 4K => 540p', () {
      expect(
        pipRenderCapTarget(
          pipUp: true,
          thermalLightened: false,
          sourceHeight: 2160,
        ),
        PipRenderCap.capped540p,
      );
    });

    test('PiP up + thermal lightened => 540p (min of the two caps)', () {
      expect(
        pipRenderCapTarget(
          pipUp: true,
          thermalLightened: true,
          sourceHeight: 2160,
        ),
        PipRenderCap.capped540p,
      );
    });

    test('PiP down + thermal lightened => 1080p (governor state kept)', () {
      expect(
        pipRenderCapTarget(
          pipUp: false,
          thermalLightened: true,
          sourceHeight: 2160,
        ),
        PipRenderCap.capped1080p,
      );
    });

    test('PiP down + cool => full size', () {
      expect(
        pipRenderCapTarget(
          pipUp: false,
          thermalLightened: false,
          sourceHeight: 2160,
        ),
        PipRenderCap.full,
      );
    });

    test('<=1080p source => full size always', () {
      for (final height in <int>[1080, 720, 480, 360]) {
        expect(
          pipRenderCapTarget(
            pipUp: true,
            thermalLightened: true,
            sourceHeight: height,
          ),
          PipRenderCap.full,
          reason: 'height $height',
        );
      }
    });

    test('unknown height (0) => full size (nothing to cap)', () {
      expect(
        pipRenderCapTarget(
          pipUp: true,
          thermalLightened: true,
          sourceHeight: 0,
        ),
        PipRenderCap.full,
      );
    });
  });
}
