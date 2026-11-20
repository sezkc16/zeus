/// Build 100: fMP4 HLS detection — the targeted, permanent Nebula fix.
///
/// The b99 phone test proved VideoToolbox is what kept Nebula's video off
/// the screen: it decoded the fMP4 HLS track (QoE showed `src: 1920x800`)
/// but the frame never became an output texture (`out: x tex: 0x0`), while
/// the Paris control test showed plain .ts HLS plays fine on the same
/// decoder. b99 answered that with `hwdec=no` on the whole HLS proxy
/// path, which also took hardware decode off Paris. This file scopes it:
/// software decode only for fragmented-MP4 HLS, VideoToolbox everywhere
/// else.
///
/// A media playlist is fMP4 when it carries an init segment
/// (`#EXT-X-MAP`) — per HLS, only fragmented-MP4 playlists have one; a
/// plain .ts playlist never does. Segment URIs ending in `.mp4` / `.m4s`
/// say the same thing. Everything here is pure text parsing (no I/O), so
/// it is unit-tested directly; the caller supplies the fetch.
library;

import 'dart:convert';

import 'hls_video_length.dart' show PlaylistFetcher;

/// Whether [text] is a master playlist — it lists variants with
/// `#EXT-X-STREAM-INF`.
bool isHlsMasterPlaylist(String text) {
  for (final raw in LineSplitter.split(text)) {
    if (raw.trim().startsWith('#EXT-X-STREAM-INF:')) return true;
  }
  return false;
}

/// Whether a media playlist [text] is fragmented-MP4 (fMP4) or plain .ts.
///
/// True when it carries an init segment (`#EXT-X-MAP`) or `.mp4` / `.m4s`
/// segment URIs; false when segments (`#EXTINF`) arrive with neither —
/// an init segment always precedes the segments, so reaching them without
/// one settles it. Null when the text says neither (not a playlist at
/// all, or a head cut off before both markers), which the caller treats
/// as "unknown".
bool? isFmp4MediaPlaylist(String text) {
  var sawSegment = false;
  for (final raw in LineSplitter.split(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    // A master playlist is not a media playlist at all: its bare lines
    // are variant URIs, not segments, so it says nothing here — the
    // caller reads a variant instead.
    if (line.startsWith('#EXT-X-STREAM-INF:')) return null;
    if (line.startsWith('#EXT-X-MAP:')) return true;
    if (line.startsWith('#EXTINF:')) {
      sawSegment = true;
    } else if (!line.startsWith('#')) {
      // A bare segment URI: fMP4 when it names an .mp4 / .m4s part.
      final path = line.split('?').first.toLowerCase();
      if (path.endsWith('.mp4') || path.endsWith('.m4s')) return true;
      sawSegment = true;
    }
  }
  return sawSegment ? false : null;
}

/// The first variant a master playlist [text] lists — the bare URI line
/// after an `#EXT-X-STREAM-INF` — resolved against [base], or null when
/// it lists none. Same shape as `firstVariantOf` in live_window.dart,
/// repeated here so this module stays pure Dart (that file pulls in
/// Flutter and the VLC player).
Uri? firstVariantUri(String text, Uri base) {
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    for (final line in lines.skip(i + 1)) {
      final uri = line.trim();
      if (uri.isEmpty || uri.startsWith('#')) continue;
      return base.resolve(uri);
    }
  }
  return null;
}

/// Detects whether the HLS stream at [url] is fragmented-MP4, by reading
/// its playlist: one request when [url] is already a media playlist, two
/// when it is a master (the first variant is then read).
///
/// True means fMP4 — the caller opens it with software decode; false
/// means plain .ts — keep VideoToolbox. Null when the playlist could
/// not be read at all, which the caller falls back to software decode
/// for (a working picture matters more than the scoping: b99 proved
/// `hwdec=no` plays the fMP4 shape, and a .ts stream plays under it too,
/// only less efficiently).
Future<bool?> detectFmp4Hls(Uri url, PlaylistFetcher fetch) async {
  final first = await fetch(url);
  if (first == null) return null;
  final media = isFmp4MediaPlaylist(first);
  if (media != null) return media;
  if (!isHlsMasterPlaylist(first)) return null;
  final variant = firstVariantUri(first, url);
  if (variant == null) return null;
  final second = await fetch(variant);
  if (second == null) return null;
  return isFmp4MediaPlaylist(second);
}
