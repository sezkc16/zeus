/// The buffered band of the mpv seek bar (build 72): where it ends and
/// where it is drawn. Pure, so it is unit-tested (see
/// `seek_band_test.dart`).
library;

/// The inset of a Material `Slider`'s track from each edge of its box:
/// the larger of the overlay radius and the thumb radius. The golden
/// seek bar uses overlay 14 / thumb 7, so its track starts 14 px in.
///
/// Up to build 71 the band was drawn across the FULL box width while
/// the track is inset, so in the first half of a film the band ended
/// up to 14 px LEFT of where it belonged — a short buffer (12 s on a
/// 23-minute episode is ~8 px) ended under the thumb and was never
/// seen (phone screenshot 2026-11-18).
const double kSeekBandTrackInset = 14;

/// The smallest band drawn past the thumb when anything at all is
/// buffered ahead, in px: the thumb (radius 7) covers the first 7 px
/// after the playhead, so a real but short buffer still shows.
const double kSeekBandMinVisibleAhead = 12;

/// Where the buffered band ends, as a fraction of the film.
///
/// [bufferedEnd] is mpv's `demuxer-cache-time` (media_kit's `buffer`
/// stream): the timestamp the cache reaches — already position + ahead,
/// not the seconds ahead. Never left of the playhead; 0 for a live or
/// unknown-length stream.
double seekBandFraction({
  required Duration bufferedEnd,
  required Duration position,
  required Duration duration,
}) {
  if (duration <= Duration.zero) return 0;
  final end = bufferedEnd > position ? bufferedEnd : position;
  final fraction = end.inMicroseconds / duration.inMicroseconds;
  if (!fraction.isFinite) return 0;
  return fraction.clamp(0.0, 1.0);
}

/// The band's width in px inside a track of [trackWidth] px (the box
/// width minus twice [kSeekBandTrackInset]).
///
/// [bandFraction] is [seekBandFraction]; [positionFraction] is the
/// playhead. A buffer that is ahead of the playhead by anything gets at
/// least [kSeekBandMinVisibleAhead] px past the thumb's centre, capped
/// at the end of the track.
double seekBandWidth({
  required double trackWidth,
  required double bandFraction,
  required double positionFraction,
}) {
  if (trackWidth <= 0) return 0;
  final band = bandFraction.clamp(0.0, 1.0);
  final position = positionFraction.clamp(0.0, 1.0);
  var width = band * trackWidth;
  if (band > position) {
    final least = position * trackWidth + kSeekBandMinVisibleAhead;
    if (width < least) width = least;
  }
  return width.clamp(0.0, trackWidth);
}
