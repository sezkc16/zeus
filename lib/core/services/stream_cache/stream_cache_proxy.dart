/// Build 77: a loopback HTTP proxy that keeps the bytes of the film it
/// passes to the player, so a request for a region it still holds is
/// answered from the phone instead of from the host.
///
/// WHY (phone, build 76, Avengers 4K): moving the mpv picture between
/// the hardware and the software renderer (the PiP button, and coming
/// back from the PiP window) makes mpv throw its whole read-ahead away
/// and ask the host again for the bytes at the playhead. The overlay
/// measured that wait as almost entirely the host's round trip
/// (`net 3422 / 2721 / 1222 ms`). mpv 0.36 cannot keep its buffer across
/// that move, so the bytes have to be kept somewhere mpv can reach
/// without the network: here.
///
/// HOW: the player opens `http://127.0.0.1:<port>/<token>/<name>`
/// instead of the film's own address. The proxy forwards the player's
/// own request headers to the host, writes every byte it receives into a
/// [RingStore] (a bounded file — no copy in memory), and serves the
/// player from that file. Fetching from the host and serving the player
/// are decoupled: when the player drops its connection and asks again
/// for a place the store still holds, the answer starts at once from
/// the file while the one host connection simply carries on from where
/// it was.
///
/// FAIL SAFE: whenever the proxy cannot or should not serve a request —
/// the host does not answer a ranged request with 206, the answer looks
/// like a playlist, the disk refuses a write, the host connection is
/// lost for good — it answers `302` to the film's own address. The
/// player (ffmpeg's HTTP client) follows that with the same headers and
/// from then on talks to the host directly, exactly as it did before
/// this proxy existed.
///
/// Nothing here depends on Flutter: the class runs in its own isolate
/// in the app (see `stream_cache_service.dart`) and in-process in tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ring_store.dart';

/// 1 MiB.
const int kMiB = 1024 * 1024;

/// The most disk one film's window may take.
///
/// The window has to reach from the picture's keyframe back at the
/// playhead up to wherever mpv had read ahead, or the request after a
/// renderer move is not inside it. mpv's read-ahead is capped at
/// 768 MiB (`demuxer-max-bytes`, see `kMpvIosOptions`), so the window is
/// that plus room for the keyframe interval and the proxy's own lead.
const int kStreamCacheCapacity = 1024 * kMiB;

/// How far ahead of the player's reading point the proxy keeps
/// fetching when the player is not pulling (or has dropped its
/// connection for a moment, as it does in a renderer move).
const int kStreamCacheReadAhead = 32 * kMiB;

/// A request this close past the window's end waits for the running
/// fetch instead of starting a new one at the host.
const int kStreamCacheSkipAhead = 2 * kMiB;

/// Build 78: see [StreamCacheProxyServer.sideMax]. mpv reads a
/// Matroska film's index (a few hundred KiB to a few MiB at the very
/// end) right after opening it, then goes back to the start.
const int kStreamCacheSideMax = 8 * kMiB;

/// Build 105: how old a session must be for a refused side read (the
/// film's index, at a seek) to give the film up instead of only
/// redirecting that one read.
///
/// The phone (b104, Twinkling Watermelon): after playing to 02:35 the
/// viewer sought to 06:14. mpv first asked for the index at the end;
/// the host ignores Range, so the probe was sent to the origin — and
/// the session stayed alive. The player never came back with the seek
/// target (its next requests went to the origin, where the host
/// answers every Range with the whole film from byte 0), the proxy's
/// own fetch kept eating the host's bandwidth, and the picture froze
/// on the old frame, then went black, forever — while the overlay
/// still said `proxy: on`. A refused side read once the session is
/// past its opening means the seek behind it cannot be served: the
/// session is killed, so the fetch stops and every later request goes
/// to the film's own address (b101 behaviour: it plays from the
/// start). A probe inside the opening (the head read, under a second
/// or two in) leaves the session alone, so a film still plays through
/// the proxy after it (build 104's test).
///
/// Age, not how far the player has read: the proxy only knows how much
/// it has *written* to the player, and on a fast host the reader races
/// several MiB ahead of what the player has consumed before the
/// hangup is noticed — the open-time probe would read as mid-film.
/// The opening is over in a second or two even on a slow host; a real
/// seek comes minutes in.
const Duration kStreamCacheSideKillAfter = Duration(seconds: 5);

/// Build 78: see [StreamCacheProxyServer.memoryKeep].
const int kStreamCacheMemoryKeep = 4 * kMiB;

/// Build 78: see [StreamCacheProxyServer.maxUnwritten].
const int kStreamCacheMaxUnwritten = 48 * kMiB;

/// A "film" shorter than this is not worth holding — and is far more
/// likely a playlist or an error page than a film.
const int kStreamCacheMinLength = 8 * kMiB;

/// Build 104: the longest a read-forward skip may be estimated to
/// take, from the host speed observed so far. A skip longer than this
/// is not attempted — the film is given up to the origin instead,
/// which plays from the start (b101 behaviour). Without the cap a
/// far skip holds the player's connection with nothing coming back
/// for minutes: the film loads forever (b103, Twinkling Watermelon).
const Duration kStreamCacheMaxReadForwardWait = Duration(seconds: 30);

/// Build 104: the longest skip attempted when the host speed is not
/// known yet (a fresh session, no bytes in). A fresh far seek cannot
/// be timed, so it is capped by distance instead.
const int kStreamCacheMaxReadForwardUnknown = 64 * kMiB;

/// Build 106: how long a player connection may wait for its next bytes
/// before the session is given up as stalled.
///
/// The phone (b105, Twinkling Watermelon S1 E2): after an early seek
/// to 02:00 the player sat on a black screen for minutes with
/// `cache: 0.000000s 982 B/s` and `proxy: on held 6MB ahead 0s` — the
/// session alive, the fetch trickling, nothing decodable reaching the
/// player. Nothing else fires in that state: no side read is refused
/// (`side 0`, so build 105's kill never runs), mpv does not report
/// buffering (`paused-cache: no`, so the slow-proxy watch never trips),
/// and the playhead keeps creeping (the viewer's +10 s taps), which
/// resets the stall ladder's budget every tick. So the proxy watches
/// the one thing that cannot lie — bytes actually delivered to the
/// player: a reader still waiting after this long with nothing
/// arriving means the session is given up to the origin (b101
/// behaviour: it plays from the start) instead of holding the player
/// on a black screen.
const Duration kClientStarveAfter = Duration(seconds: 20);

/// What the proxy knows about one open film, for the player's overlay.
class StreamCacheStats {
  const StreamCacheStats({
    required this.held,
    required this.ahead,
    required this.total,
    required this.hits,
    required this.misses,
    required this.dead,
    required this.reason,
    required this.requests,
    this.hostRate = 0,
    this.clientRate = 0,
    this.unwritten = 0,
    this.sides = 0,
  });

  /// Build 78: bytes per second arriving from the host, and going out
  /// to the player, over the last second.
  final int hostRate;
  final int clientRate;

  /// Build 78: bytes received and not on the file yet.
  final int unwritten;

  /// Build 78: short side requests (the film's index) answered with
  /// their own request to the host, leaving the window alone.
  final int sides;

  /// Bytes held right now.
  final int held;

  /// Bytes held past the player's reading point.
  final int ahead;

  /// The film's length in bytes, or null before the host has said.
  final int? total;

  /// Requests answered from the store with no new request to the host.
  final int hits;

  /// Requests that needed a new request to the host.
  final int misses;

  /// The proxy has stepped aside for this film (every request is now
  /// redirected to the host), and why.
  final bool dead;
  final String? reason;

  /// The last few requests the player made: when (ms since epoch),
  /// where (byte offset), and whether the store answered.
  final List<StreamCacheRequest> requests;

  Map<String, Object?> toMap() => <String, Object?>{
    'held': held,
    'ahead': ahead,
    'total': total,
    'hits': hits,
    'misses': misses,
    'dead': dead,
    'reason': reason,
    'hostRate': hostRate,
    'clientRate': clientRate,
    'unwritten': unwritten,
    'sides': sides,
    'requests': <Object?>[
      for (final r in requests) <Object?>[r.atMs, r.offset, r.local],
    ],
  };

  static StreamCacheStats? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final requests = <StreamCacheRequest>[];
    final list = raw['requests'];
    if (list is List) {
      for (final item in list) {
        if (item is List && item.length >= 3) {
          requests.add(
            StreamCacheRequest(
              atMs: (item[0] as num).toInt(),
              offset: (item[1] as num).toInt(),
              local: item[2] == true,
            ),
          );
        }
      }
    }
    return StreamCacheStats(
      held: (raw['held'] as num?)?.toInt() ?? 0,
      ahead: (raw['ahead'] as num?)?.toInt() ?? 0,
      total: (raw['total'] as num?)?.toInt(),
      hits: (raw['hits'] as num?)?.toInt() ?? 0,
      misses: (raw['misses'] as num?)?.toInt() ?? 0,
      dead: raw['dead'] == true,
      reason: raw['reason'] as String?,
      requests: requests,
      hostRate: (raw['hostRate'] as num?)?.toInt() ?? 0,
      clientRate: (raw['clientRate'] as num?)?.toInt() ?? 0,
      unwritten: (raw['unwritten'] as num?)?.toInt() ?? 0,
      sides: (raw['sides'] as num?)?.toInt() ?? 0,
    );
  }
}

class StreamCacheRequest {
  const StreamCacheRequest({
    required this.atMs,
    required this.offset,
    required this.local,
  });
  final int atMs;
  final int offset;
  final bool local;
}

/// The address the player opens, and the handle to close it by.
class StreamCacheSession {
  const StreamCacheSession({required this.token, required this.url});
  final String token;
  final String url;
}

class StreamCacheProxyServer {
  StreamCacheProxyServer({
    required this.directory,
    this.capacity = kStreamCacheCapacity,
    this.readAhead = kStreamCacheReadAhead,
    this.skipAhead = kStreamCacheSkipAhead,
    this.sideMax = kStreamCacheSideMax,
    this.memoryKeep = kStreamCacheMemoryKeep,
    this.maxUnwritten = kStreamCacheMaxUnwritten,
    this.minLength = kStreamCacheMinLength,
    this.connectTimeout = const Duration(seconds: 10),
    this.responseTimeout = const Duration(seconds: 15),
    this.maxReadForwardWait = kStreamCacheMaxReadForwardWait,
    this.maxReadForwardUnknown = kStreamCacheMaxReadForwardUnknown,
    this.clientStarveAfter = kClientStarveAfter,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  /// Where the ring files live. Emptied when the server starts.
  final String directory;
  final int capacity;
  final int readAhead;
  final int skipAhead;

  /// Build 78: a request outside the window for no more than this many
  /// bytes (to the film's end, or a bounded range) is a side read.
  /// 0 turns side reads off.
  final int sideMax;

  /// Build 78: how much already-written film stays in memory behind
  /// the newest bytes.
  final int memoryKeep;

  /// Build 78: the host is paused while this much is waiting for the
  /// disk.
  final int maxUnwritten;
  final int minLength;
  final Duration connectTimeout;
  final Duration responseTimeout;

  /// Build 104: the longest a read-forward skip may be estimated to
  /// take (see [kStreamCacheMaxReadForwardWait]). A skip estimated
  /// longer than this is refused in [_openUpstream], and a skip
  /// running past it is cut off in [_anchorInner] — either way the
  /// film is given up to the origin instead of loading forever.
  final Duration maxReadForwardWait;

  /// Build 104: the longest skip attempted when the host speed is
  /// not known yet (see [kStreamCacheMaxReadForwardUnknown]).
  final int maxReadForwardUnknown;

  /// Build 106: how long a waiting reader goes without bytes before
  /// its session is given up (see [kClientStarveAfter]).
  final Duration clientStarveAfter;

  final HttpClient Function() _clientFactory;

  HttpServer? _server;
  HttpClient? _client;
  int _port = 0;
  final Map<String, _Session> _sessions = <String, _Session>{};
  final math.Random _random = math.Random.secure();

  int get port => _port;

  bool get isRunning => _server != null;

  /// Binds the loopback port (a free one, unless [port] is given) and
  /// clears anything a previous run left in [directory].
  Future<int> start({int port = 0}) async {
    sweepDirectory(directory);
    _client = _clientFactory()
      ..autoUncompress = false
      ..userAgent = null
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 15);
    await _bind(port);
    return _port;
  }

  Future<void> _bind(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    _port = server.port;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  /// Whether the listening socket still answers. iOS can take a
  /// suspended app's listening socket away; the player's next request
  /// would then be refused.
  Future<bool> ping() async {
    if (_server == null) return false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 700);
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$_port/__ping'))
          .timeout(const Duration(milliseconds: 900));
      final response = await request.close().timeout(
        const Duration(milliseconds: 900),
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.noContent;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Listens again on the SAME port, so the address the player holds
  /// stays good. Returns whether it worked.
  Future<bool> rebind() async {
    final old = _server;
    _server = null;
    try {
      await old?.close(force: true);
    } catch (_) {}
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await _bind(_port);
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }
    return false;
  }

  /// [ping], and [rebind] when it fails. When the port cannot be had
  /// back every film is given up (their next request is refused, and
  /// the player's own recovery re-opens directly).
  Future<bool> ensureListening() async {
    if (await ping()) return true;
    if (await rebind()) return true;
    for (final session in _sessions.values.toList()) {
      session.kill('listen');
    }
    return false;
  }

  /// Registers a film and returns the loopback address for it. Nothing
  /// is asked of the host until the player makes its first request.
  StreamCacheSession openSession(String url) {
    final origin = Uri.parse(url);
    if (!origin.hasScheme ||
        (origin.scheme != 'http' && origin.scheme != 'https') ||
        origin.host.isEmpty) {
      throw ArgumentError('not an http(s) address');
    }
    final token = _newToken();
    final name = _entryName(origin);
    final session = _Session(
      token: token,
      origin: origin,
      name: name,
      path: '$directory${Platform.pathSeparator}$token.ring',
    );
    _sessions[token] = session;
    return StreamCacheSession(
      token: token,
      url: 'http://127.0.0.1:$_port/$token/$name',
    );
  }

  /// Ends a film: drops its connections and deletes its file.
  void closeSession(String token) {
    final session = _sessions.remove(token);
    session?.dispose();
  }

  StreamCacheStats? stats(String token) => _sessions[token]?.stats();

  Future<void> shutdown() async {
    for (final session in _sessions.values.toList()) {
      session.dispose();
    }
    _sessions.clear();
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (_) {}
    _client?.close(force: true);
    _client = null;
  }

  /// Deletes every ring file in [directory] (left by a crash or a kill).
  static void sweepDirectory(String directory) {
    try {
      final dir = Directory(directory);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
        return;
      }
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.ring')) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _entryName(Uri origin) {
    final last = origin.pathSegments.isEmpty ? '' : origin.pathSegments.last;
    final safe = last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty) return 'stream';
    return safe.length > 80 ? safe.substring(safe.length - 80) : safe;
  }

  // -------------------------------------------------------------------------
  // The player's side.
  // -------------------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.isEmpty) {
        await _plain(request, HttpStatus.notFound);
        return;
      }
      if (segments.first == '__ping') {
        await _plain(request, HttpStatus.noContent);
        return;
      }
      final session = _sessions[segments.first];
      if (session == null) {
        await _plain(request, HttpStatus.notFound);
        return;
      }
      final rest = segments.skip(1).join('/');
      if (rest != session.name) {
        // Not the film itself: something named relative to it (a
        // playlist's segment, a side file). Send it to the same place
        // relative to the film's own address.
        final query = request.uri.hasQuery ? '?${request.uri.query}' : '';
        await _redirect(request, session.origin.resolve('$rest$query'));
        return;
      }
      if (request.method != 'GET' || session.dead) {
        await _redirect(request, session.origin);
        return;
      }
      final reader = await session.locked(() => _admit(request, session));
      if (reader == null) return;
      await _serve(session, reader);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _plain(HttpRequest request, int status) async {
    request.response
      ..statusCode = status
      ..headers.contentLength = 0;
    await request.response.close();
  }

  Future<void> _redirect(HttpRequest request, Uri to) async {
    request.response
      ..statusCode = HttpStatus.found
      ..headers.set(HttpHeaders.locationHeader, to.toString())
      ..headers.contentLength = 0;
    await request.response.close();
  }

  /// Decides how to answer one request for the film and writes the
  /// answer's head. Returns the reader to feed, or null when the
  /// request has been answered some other way (redirect, 416).
  Future<_Reader?> _admit(HttpRequest request, _Session session) async {
    if (session.dead) {
      await _redirect(request, session.origin);
      return null;
    }
    final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader));
    if (range == null) {
      // A range shape the proxy does not speak (several ranges).
      await _redirect(request, session.origin);
      return null;
    }
    session.clientHeaders = _forwardable(request.headers);

    var start = range.start ?? 0;
    final total = session.total;
    if (range.suffix != null) {
      if (total == null) {
        await _redirect(request, session.origin);
        return null;
      }
      start = math.max(0, total - range.suffix!);
    }
    if (total != null && start >= total) {
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total')
        ..headers.contentLength = 0;
      await request.response.close();
      return null;
    }

    final store = session.store;
    final local =
        store != null &&
        total != null &&
        start >= store.start &&
        start <= session.end + skipAhead;
    if (local) {
      session.hits++;
    } else if (store != null &&
        total != null &&
        _isSideRequest(start, range, total)) {
      // Build 78: a short read far from the window (the index at the
      // film's end, a bounded probe). It gets its own short request to
      // the host; the window and the running fetch are left alone.
      await _side(request, session, start, range, total);
      return null;
    } else {
      final ok = await _anchor(session, start);
      if (!ok) {
        await _redirect(request, session.origin);
        return null;
      }
      session.misses++;
    }
    session.noteRequest(start, local && start < session.end);

    final length = session.total!;
    var endExclusive = length;
    if (range.end != null) endExclusive = math.min(length, range.end! + 1);
    if (endExclusive <= start) endExclusive = length;

    final socket = await request.response.detachSocket(writeHeaders: false);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final ranged = range.present;
    final head = StringBuffer()
      ..write(
        ranged ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n',
      )
      ..write('Content-Type: ${session.contentType ?? 'application/octet-stream'}\r\n')
      ..write('Accept-Ranges: bytes\r\n');
    if (ranged) {
      head.write('Content-Range: bytes $start-${endExclusive - 1}/$length\r\n');
    }
    head
      ..write('Content-Length: ${endExclusive - start}\r\n')
      ..write('Connection: close\r\n\r\n');
    socket.add(latin1.encode(head.toString()));

    final reader = _Reader(socket, start, endExclusive);
    // The player hanging up is the only thing it ever "says" from here.
    reader.watch = socket.listen(
      (_) {},
      onDone: () {
        reader.closed = true;
        session.notify();
      },
      onError: (Object _) {
        reader.closed = true;
        session.notify();
      },
      cancelOnError: true,
    );
    session.readers.add(reader);
    session.pump(this);
    return reader;
  }

  /// Feeds one player connection from the store until it has had
  /// everything it asked for, hangs up, or cannot be served any more.
  Future<void> _serve(_Session session, _Reader reader) async {
    Uint8List? buffer;
    var finished = false;
    try {
      while (!reader.closed && !session.dead) {
        if (reader.offset >= reader.endExclusive) {
          finished = true;
          break;
        }
        final store = session.store;
        if (store == null || store.isClosed) break;
        // Dropped from the window behind this reader: it cannot be
        // continued from the file. Hanging up makes the player ask
        // again from where it is.
        if (reader.offset < store.start) break;
        final available =
            math.min(session.end, reader.endExclusive) - reader.offset;
        if (available <= 0) {
          if (session.complete) break;
          // Build 106: the player is waiting and nothing has reached
          // it for a while — the session is not delivering, whatever
          // the host is doing (a trickle, a skip that never lands).
          // Give the film up to the origin instead of holding the
          // player on a black screen.
          if (session.clientStarved(clientStarveAfter)) {
            session.kill('stalled');
            break;
          }
          session.pump(this);
          await session.waitForData(const Duration(seconds: 5));
          continue;
        }
        var count = 0;
        if (reader.offset >= session.memStart) {
          // Build 78: the newest bytes go to the player straight from
          // memory — the disk is never between the host and the player.
          count = session.writeFromMemory(reader, 256 * 1024);
        } else {
          // Older bytes (a renderer move going back) come off the file,
          // without holding this isolate on the read.
          final onDisk =
              math.min(store.end, reader.endExclusive) - reader.offset;
          if (onDisk <= 0) break;
          buffer ??= Uint8List(256 * 1024);
          count = await store.readAsync(
            reader.offset,
            buffer,
            math.min(onDisk, buffer.length),
          );
          if (reader.closed || session.dead) break;
          if (count > 0) {
            reader.socket.add(Uint8List.sublistView(buffer, 0, count));
          }
        }
        if (count <= 0) break;
        await reader.socket.flush();
        reader.offset += count;
        session.clientRate.add(count);
        session.noteClientBytes();
        session.pump(this);
      }
    } catch (_) {
      // The player hung up mid-write, or the file went away.
    } finally {
      session.detach(reader);
      await reader.end(graceful: finished);
      session.pump(this);
    }
  }

  /// Build 78: whether a request outside the window is a short side
  /// read rather than the player moving.
  bool _isSideRequest(int start, _Range range, int total) {
    if (sideMax <= 0) return false;
    if (total - start <= sideMax) return true;
    final end = range.end;
    return end != null && end >= start && end - start + 1 <= sideMax;
  }

  /// Build 78: answers one short request with its own request to the
  /// host, piped straight to the player.
  ///
  /// Build 104: a side read is the film's index (or another probe) —
  /// it never read-forwards. On a host that ignores Range the whole
  /// film would have to be skipped to answer it, and the player sits
  /// waiting for the probe with nothing playing (b103: Instant loads
  /// forever). So the host's 200 is refused here and the player is
  /// sent to the origin, which plays from the start (b101 behaviour).
  Future<void> _side(
    HttpRequest request,
    _Session session,
    int start,
    _Range range,
    int total,
  ) async {
    var endExclusive = total;
    if (range.end != null) endExclusive = math.min(total, range.end! + 1);
    if (endExclusive <= start) endExclusive = total;
    final _Upstream upstream;
    try {
      upstream = await _openUpstream(
        session,
        start,
        remember: false,
        allowReadForward: false,
      );
      if (upstream.total != total) {
        _discard(upstream.response);
        throw const _Unusable('length changed');
      }
    } catch (error) {
      // Build 105: not this way — the player asks the host itself for
      // this one. And once the player is into the film, a refused
      // index read means the seek behind it cannot be served either:
      // the film is given up (see [kStreamCacheSideKillAfter]) so the
      // fetch stops and the player's next request goes to the host
      // itself, instead of the player freezing on a proxy that stays
      // alive but can no longer serve it.
      if (DateTime.now().difference(session.createdAt) >
          kStreamCacheSideKillAfter) {
        session.kill(error is _Unusable ? error.reason : 'host');
      }
      await _redirect(request, session.origin);
      return;
    }
    session.sides++;
    session.noteRequest(start, false);
    final socket = await request.response.detachSocket(writeHeaders: false);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    socket.add(
      latin1.encode(
        _responseHead(
          ranged: range.present,
          contentType: session.contentType,
          start: start,
          endExclusive: endExclusive,
          total: total,
        ),
      ),
    );
    unawaited(_pipeSide(session, upstream.response, socket, endExclusive - start));
  }

  Future<void> _pipeSide(
    _Session session,
    Stream<List<int>> response,
    Socket socket,
    int length,
  ) async {
    var left = length;
    var hungUp = false;
    final watch = socket.listen(
      (_) {},
      onDone: () => hungUp = true,
      onError: (Object _) => hungUp = true,
      cancelOnError: true,
    );
    var graceful = false;
    try {
      await for (final chunk in response) {
        if (hungUp || session.dead) break;
        final take = math.min(left, chunk.length);
        socket.add(
          take == chunk.length ? chunk : chunk.sublist(0, take),
        );
        await socket.flush();
        session.clientRate.add(take);
        left -= take;
        if (left <= 0) {
          graceful = true;
          break;
        }
      }
    } catch (_) {
      // Either end went away.
    } finally {
      try {
        await watch.cancel();
      } catch (_) {}
      try {
        if (graceful) {
          await socket.flush();
          await socket.close();
        }
      } catch (_) {}
      try {
        socket.destroy();
      } catch (_) {}
    }
  }

  static String _responseHead({
    required bool ranged,
    required String? contentType,
    required int start,
    required int endExclusive,
    required int total,
  }) {
    final head = StringBuffer()
      ..write(
        ranged ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n',
      )
      ..write('Content-Type: ${contentType ?? 'application/octet-stream'}\r\n')
      ..write('Accept-Ranges: bytes\r\n');
    if (ranged) {
      head.write('Content-Range: bytes $start-${endExclusive - 1}/$total\r\n');
    }
    head
      ..write('Content-Length: ${endExclusive - start}\r\n')
      ..write('Connection: close\r\n\r\n');
    return head.toString();
  }

  // -------------------------------------------------------------------------
  // The host's side.
  // -------------------------------------------------------------------------

  /// Starts the film's one host connection at [offset] and waits for
  /// its first bytes. Everything held before is dropped: the window
  /// begins again at [offset]. False when the host cannot be used this
  /// way — the film is then given up for good (see [_Session.kill]).
  Future<bool> _anchor(_Session session, int offset) async {
    // Build 78: nothing may pick the old window's fetch up again while
    // the new one is being set up.
    session.anchoring = true;
    try {
      return await _anchorInner(session, offset);
    } finally {
      session.anchoring = false;
      session.pump(this);
    }
  }

  Future<bool> _anchorInner(_Session session, int offset) async {
    session.cancelFetch();
    for (final reader in session.readers.toList()) {
      reader.closed = true;
      unawaited(reader.end(graceful: false));
    }
    session.readers.clear();
    session.notify();
    try {
      final upstream = await _openUpstream(session, offset);
      final known = session.total;
      if (known != null && known != upstream.total) {
        _discard(upstream.response);
        throw const _Unusable('length changed');
      }
      if (known == null) {
        final reason = _unusableBecause(upstream);
        if (reason != null) {
          _discard(upstream.response);
          throw _Unusable(reason);
        }
      }
      session
        ..total = upstream.total
        ..contentType = upstream.contentType;
      final store = session.store ??= RingStore.open(session.path, capacity);
      // Anything still on its way to the file belongs to the old window.
      session.dropMemory();
      await store.idle();
      if (session.dead) return false;
      store.reset(offset);
      session
        ..memStart = offset
        ..end = offset
        ..complete = false
        ..lastOffset = offset
        ..skipped = 0;
      _attach(session, upstream.response, sniff: known == null && offset == 0);
      // Build 103: a read-forward anchor only gets its first bytes
      // after the skipped prefix has arrived, which can take a while
      // on a slow host. The deadline is on silence, not on the whole
      // skip: as long as bytes keep arriving (skipped or stored) the
      // wait goes on; only a stall gives the film up.
      //
      // Build 104: the silence deadline is not enough — a host that
      // stays slow but never stalls would extend it forever while
      // the skip crawls. A read-forward anchor also gets a hard
      // deadline ([maxReadForwardWait] past the response timeout):
      // past it the film is given up to the origin (b101 behaviour)
      // instead of loading forever.
      final hardDeadline = upstream.readForward
          ? DateTime.now().add(maxReadForwardWait + responseTimeout)
          : null;
      var deadline = DateTime.now().add(responseTimeout);
      var lastProgress = offset + session.skipped;
      while (!session.dead && !session.complete && session.end <= offset) {
        var left = deadline.difference(DateTime.now());
        if (hardDeadline != null) {
          final hardLeft = hardDeadline.difference(DateTime.now());
          if (hardLeft < left) left = hardLeft;
        }
        if (left <= Duration.zero) throw const _Unusable('no data');
        await session.waitForData(left);
        final progress = session.end + session.skipped;
        if (progress > lastProgress) {
          lastProgress = progress;
          deadline = DateTime.now().add(responseTimeout);
        }
      }
      return !session.dead;
    } catch (error) {
      session.kill(error is _Unusable ? error.reason : 'host');
      return false;
    }
  }

  String? _unusableBecause(_Upstream upstream) {
    if (upstream.total < minLength) return 'small';
    final type = (upstream.contentType ?? '').toLowerCase();
    if (type.contains('mpegurl') ||
        type.contains('dash+xml') ||
        type.startsWith('text/') ||
        type.contains('json') ||
        type.contains('xml')) {
      return 'type';
    }
    return null;
  }

  void _attach(_Session session, Stream<List<int>> response, {bool sniff = false}) {
    final fetch = _Fetch();
    session.fetch = fetch;
    var first = sniff;
    fetch.subscription = response.listen(
      (chunk) {
        if (!identical(session.fetch, fetch) || session.dead) return;
        if (first) {
          first = false;
          if (_looksLikeText(chunk)) {
            session.kill('playlist');
            return;
          }
        }
        if (session.store == null) return;
        // Build 78: into memory first (the player is fed from there),
        // and onto the disk behind it, off this isolate's thread.
        session.take(chunk, this);
        fetch.received += chunk.length;
        session.failures = 0;
        session.notify();
        session.pump(this);
      },
      onDone: () => _fetchEnded(session, fetch),
      onError: (Object _) => _fetchEnded(session, fetch),
      cancelOnError: true,
    );
  }

  void _fetchEnded(_Session session, _Fetch fetch) {
    if (!identical(session.fetch, fetch) || session.dead) return;
    session.fetch = null;
    final store = session.store;
    final total = session.total;
    if (store != null && total != null && session.end >= total) {
      session.complete = true;
      session.notify();
      return;
    }
    // The host hung up early (or the phone slept on it).
    if (fetch.received == 0) session.failures++;
    session.notify();
    session.pump(this);
  }

  /// Picks the host connection up again from the window's end.
  Future<void> _refetch(_Session session) async {
    if (session.dead || session.refetching || session.complete) return;
    final store = session.store;
    if (store == null) return;
    session.refetching = true;
    const waits = <int>[0, 300, 1000, 2000];
    try {
      while (!session.dead && session.fetch == null) {
        if (session.failures >= waits.length) {
          session.kill('host lost');
          return;
        }
        final wait = waits[session.failures];
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
        if (session.dead || session.fetch != null || session.anchoring) return;
        try {
          final from = session.end;
          final window = session.generation;
          final upstream = await _openUpstream(session, from);
          // The window moved (or was picked up) while the host was
          // answering: this connection is for a place nobody wants.
          if (session.dead ||
              session.anchoring ||
              session.fetch != null ||
              session.generation != window ||
              session.end != from) {
            _discard(upstream.response);
            return;
          }
          if (upstream.total != session.total) {
            _discard(upstream.response);
            session.kill('length changed');
            return;
          }
          _attach(session, upstream.response);
        } catch (_) {
          session.failures++;
        }
      }
    } finally {
      session.refetching = false;
    }
  }

  /// One ranged GET to the host with the player's own headers,
  /// following redirects the way ffmpeg does (same headers to the new
  /// place; later requests start at the last place that worked, and go
  /// back to the first address when that stops answering).
  ///
  /// [allowReadForward] is false for a side read (the film's index):
  /// a host that ignores Range is refused there instead of skipped
  /// past (build 104 — a skipped index probe loads the film forever).
  Future<_Upstream> _openUpstream(
    _Session session,
    int offset, {
    bool remember = true,
    bool allowReadForward = true,
  }) async {
    final client = _client;
    if (client == null) throw const _Unusable('stopped');
    var uri = session.resolved ?? session.origin;
    var triedOrigin = uri == session.origin;
    for (var hop = 0; hop < 10; hop++) {
      final request = await client.getUrl(uri).timeout(connectTimeout);
      request.followRedirects = false;
      // dart:io adds `Accept-Encoding: gzip` to every request it makes.
      // ffmpeg sends none, and a host asked for gzip may answer a
      // ranged request with the whole file (200) instead of 206.
      request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      session.clientHeaders.forEach((name, values) {
        for (final value in values) {
          request.headers.add(name, value, preserveHeaderCase: true);
        }
      });
      request.headers.set('Range', 'bytes=$offset-', preserveHeaderCase: true);
      final HttpClientResponse response;
      try {
        response = await request.close().timeout(responseTimeout);
      } on TimeoutException {
        request.abort();
        rethrow;
      }
      final status = response.statusCode;
      if (status == 301 || status == 302 || status == 303 ||
          status == 307 || status == 308) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        _discard(response);
        if (location == null) throw const _Unusable('redirect');
        uri = uri.resolve(location);
        if (uri.scheme != 'http' && uri.scheme != 'https') {
          throw const _Unusable('redirect');
        }
        continue;
      }
      if (status == HttpStatus.partialContent) {
        final range = _parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (range == null || range.$1 != offset) {
          _discard(response);
          throw const _Unusable('range');
        }
        if (remember) session.resolved = uri;
        return _Upstream(
          response: response,
          total: range.$2,
          contentType: response.headers.value(HttpHeaders.contentTypeHeader),
        );
      }
      if (status == HttpStatus.ok) {
        // Build 103: the host ignores Range and answers with the
        // whole film from byte 0 (Driveseed). Do not give the film
        // up: take the film from byte 0 and skip to [offset]
        // instead. The skipped prefix is never written anywhere —
        // only the ring cache holds what the player reads, so no
        // file is downloaded. Without a Content-Length the film's
        // length is unknown, so this cannot be served; fall through
        // to the old 'no range' failure below.
        final length = response.contentLength;
        if (length > 0) {
          if (remember) session.resolved = uri;
          final contentType =
              response.headers.value(HttpHeaders.contentTypeHeader);
          if (offset <= 0) {
            return _Upstream(
              response: response,
              total: length,
              contentType: contentType,
            );
          }
          // Build 104: read-forward only when it is allowed here
          // and the skip is short enough to be worth the wait (see
          // [_readForwardWorthIt]). A skip that would hold the
          // player for minutes falls through to 'no range' instead:
          // the caller gives the film up to the origin, which plays
          // from the start (b101 behaviour) rather than loading
          // forever.
          if (allowReadForward && _readForwardWorthIt(session, offset)) {
            return _Upstream(
              response: _skipPrefix(response, offset, session),
              total: length,
              contentType: contentType,
              readForward: true,
            );
          }
        }
      }
      _discard(response);
      if (!triedOrigin) {
        // The place a redirect led to has stopped answering (a signed
        // link that ran out): ask the first address again.
        triedOrigin = true;
        uri = session.origin;
        continue;
      }
      throw _Unusable(status == HttpStatus.ok ? 'no range' : 'http $status');
    }
    throw const _Unusable('redirect');
  }

  /// Build 104: whether a read-forward skip of [offset] bytes is
  /// worth attempting, from the host speed observed so far. A skip
  /// estimated past [maxReadForwardWait] is refused — the player
  /// would sit loading for that long with nothing coming back. With
  /// no speed observed yet (a fresh session) the skip is capped by
  /// distance instead ([maxReadForwardUnknown]).
  bool _readForwardWorthIt(_Session session, int offset) {
    final rate = session.hostRate.perSecond;
    if (rate > 0) {
      return offset / rate <= maxReadForwardWait.inSeconds;
    }
    // Build 106: no speed observed right now. On a fresh session that
    // means nothing yet — the distance cap still applies. On a session
    // that has already been fed, a silent host is a stalled host: a
    // skip would spend the player's wait discarding bytes that never
    // arrive (the b105 blank phase: the early seek's refetch re-skipped
    // 40 MiB on a host delivering ~1 KiB/s, forever). Refuse, so the
    // caller gives the film up to the origin instead.
    if (session.end > 0 || session.skipped > 0) return false;
    return offset <= maxReadForwardUnknown;
  }

  /// Build 103: drops the first [skip] bytes of a host answer that
  /// ignored Range (200 with the whole film from byte 0), so the
  /// caller is fed the film from [skip] on. Reports progress on the
  /// session so an anchor waiting for its first bytes can tell a
  /// slow host from a stalled one. If the answer ends before [skip]
  /// bytes are dropped, the stream just ends — the anchor times out
  /// and the film is given up, as before.
  Stream<List<int>> _skipPrefix(
    Stream<List<int>> source,
    int skip,
    _Session session,
  ) async* {
    var remaining = skip;
    await for (final chunk in source) {
      if (session.dead) break;
      if (remaining <= 0) {
        yield chunk;
        continue;
      }
      if (chunk.length <= remaining) {
        remaining -= chunk.length;
        session.skipped += chunk.length;
        session.notify();
        continue;
      }
      final drop = remaining;
      session.skipped += drop;
      remaining = 0;
      session.notify();
      yield chunk.sublist(drop);
    }
  }

  void _discard(Stream<List<int>> response) {
    try {
      unawaited(
        response.listen((_) {}, onError: (Object _) {}).cancel().catchError(
          (Object _) {},
        ),
      );
    } catch (_) {}
  }

  static bool _looksLikeText(List<int> chunk) {
    var i = 0;
    // A byte-order mark and leading white space.
    if (chunk.length >= 3 &&
        chunk[0] == 0xEF && chunk[1] == 0xBB && chunk[2] == 0xBF) {
      i = 3;
    }
    while (i < chunk.length &&
        (chunk[i] == 0x20 || chunk[i] == 0x0A || chunk[i] == 0x0D ||
            chunk[i] == 0x09)) {
      i++;
    }
    if (i >= chunk.length) return false;
    // '#EXTM3U', or markup ('<?xml', '<MPD', '<html', '<!DOCTYPE').
    if (chunk[i] == 0x3C) return true;
    const tag = <int>[0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55];
    if (chunk.length - i < tag.length) return false;
    for (var k = 0; k < tag.length; k++) {
      if (chunk[i + k] != tag[k]) return false;
    }
    return true;
  }

  /// The player's request headers that belong to the host: everything
  /// except the ones that describe this hop.
  static Map<String, List<String>> _forwardable(HttpHeaders headers) {
    const skip = <String>{
      'host',
      'range',
      'connection',
      'content-length',
      'transfer-encoding',
      'keep-alive',
      'proxy-connection',
      'proxy-authorization',
      'te',
      'upgrade',
      'accept-encoding',
    };
    final out = <String, List<String>>{};
    headers.forEach((name, values) {
      if (skip.contains(name.toLowerCase())) return;
      out[_headerCase(name)] = List<String>.of(values);
    });
    return out;
  }

  static String _headerCase(String name) => name
      .split('-')
      .map((part) => part.isEmpty
          ? part
          : part[0].toUpperCase() + part.substring(1).toLowerCase())
      .join('-');
}

// ---------------------------------------------------------------------------

class _Unusable implements Exception {
  const _Unusable(this.reason);
  final String reason;
}

class _Upstream {
  _Upstream({
    required this.response,
    required this.total,
    required this.contentType,
    this.readForward = false,
  });

  /// The host's answer, from the requested offset on. For a
  /// read-forward answer this is the 200 body with its prefix
  /// already skipped (see [_skipPrefix]).
  final Stream<List<int>> response;
  final int total;
  final String? contentType;

  /// Build 103: the host answered a ranged request with the whole
  /// film from byte 0 (200) instead of 206, and [response] is that
  /// answer with the bytes before the requested offset skipped.
  /// Nothing before the offset was written anywhere.
  final bool readForward;
}

class _Chunk {
  _Chunk(this.offset, this.data);
  final int offset;
  final Uint8List data;
  int get end => offset + data.length;
}

/// Bytes per second over the last second or so.
class _Rate {
  final Stopwatch _clock = Stopwatch()..start();
  int _windowStart = 0;
  int _bytes = 0;
  int _last = 0;
  int _lastAt = -1;

  void add(int count) {
    _roll();
    _bytes += count;
  }

  void _roll() {
    final now = _clock.elapsedMilliseconds;
    final elapsed = now - _windowStart;
    if (elapsed >= 1000) {
      _last = (_bytes * 1000) ~/ elapsed;
      _lastAt = now;
      _windowStart = now;
      _bytes = 0;
    }
  }

  /// 0 when nothing has moved for a few seconds.
  int get perSecond {
    _roll();
    final now = _clock.elapsedMilliseconds;
    if (_lastAt < 0) {
      // Not a full second in yet: what there is so far.
      final elapsed = now - _windowStart;
      return elapsed <= 0 ? 0 : (_bytes * 1000) ~/ elapsed;
    }
    return now - _lastAt > 3000 ? 0 : _last;
  }
}

class _Fetch {
  StreamSubscription<List<int>>? subscription;
  bool paused = false;
  int received = 0;
}

class _Reader {
  _Reader(this.socket, this.offset, this.endExclusive);
  final Socket socket;
  int offset;
  final int endExclusive;
  bool closed = false;
  bool _ended = false;
  StreamSubscription<Uint8List>? watch;

  Future<void> end({required bool graceful}) async {
    if (_ended) return;
    _ended = true;
    closed = true;
    try {
      await watch?.cancel();
    } catch (_) {}
    try {
      if (graceful) {
        await socket.flush();
        await socket.close();
      }
    } catch (_) {}
    try {
      socket.destroy();
    } catch (_) {}
  }
}

class _Range {
  const _Range({this.start, this.end, this.suffix, required this.present});
  final int? start;
  final int? end;
  final int? suffix;
  final bool present;
}

/// `bytes=A-`, `bytes=A-B`, `bytes=-N`, or no header at all. Null for
/// anything else.
_Range? _parseRange(String? header) {
  if (header == null || header.trim().isEmpty) {
    return const _Range(present: false);
  }
  final match = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$').firstMatch(header);
  if (match == null) return null;
  final a = match.group(1)!;
  final b = match.group(2)!;
  if (a.isEmpty && b.isEmpty) return null;
  if (a.isEmpty) return _Range(suffix: int.parse(b), present: true);
  return _Range(
    start: int.parse(a),
    end: b.isEmpty ? null : int.parse(b),
    present: true,
  );
}

/// `bytes A-B/T` → (A, T). Null when the total is not given.
(int, int)? _parseContentRange(String? header) {
  if (header == null) return null;
  final match = RegExp(r'bytes\s+(\d+)\s*-\s*(\d+)\s*/\s*(\d+)').firstMatch(header);
  if (match == null) return null;
  return (int.parse(match.group(1)!), int.parse(match.group(3)!));
}

class _Session {
  _Session({
    required this.token,
    required this.origin,
    required this.name,
    required this.path,
  });

  final String token;
  final Uri origin;
  final String name;
  final String path;

  /// Build 105: when the film was opened. A side read refused after
  /// the opening gives the film up (see [kStreamCacheSideKillAfter]).
  final DateTime createdAt = DateTime.now();

  RingStore? store;
  int? total;
  String? contentType;
  Uri? resolved;
  Map<String, List<String>> clientHeaders = const <String, List<String>>{};

  _Fetch? fetch;
  bool refetching = false;
  bool anchoring = false;
  bool complete = false;
  int failures = 0;

  /// Build 103: bytes a read-forward fetch has dropped from the
  /// front of a 200 answer so far (a host that ignores Range). The
  /// anchor's wait uses it as progress, so a slow host is not
  /// mistaken for a stalled one.
  int skipped = 0;

  final Set<_Reader> readers = <_Reader>{};
  int lastOffset = 0;

  // Build 78: the newest part of the window, in memory. [end] is the
  // window's real end; the file ([store]) follows it. Everything from
  // [memStart] on is in [memory], and everything not on the file yet
  // is at or past [memStart], so the two always meet.
  final List<_Chunk> memory = <_Chunk>[];
  int memStart = 0;
  int end = 0;
  int memBytes = 0;
  int generation = 0;
  bool _writing = false;
  int sides = 0;
  final _Rate hostRate = _Rate();
  final _Rate clientRate = _Rate();

  /// Build 106: when bytes were last written to a player connection.
  /// The starvation watch in [_serve] reads it: a reader still waiting
  /// this long after the last byte means the session is not delivering
  /// decodable data any more, whatever the host is doing. Side reads
  /// do not refresh it — they are the film's index, not the picture.
  DateTime _lastClientByteAt = DateTime.now();

  /// Bytes reached a player connection just now.
  void noteClientBytes() {
    _lastClientByteAt = DateTime.now();
  }

  /// True when no byte has reached a player connection for [limit]
  /// (see [StreamCacheProxyServer.clientStarveAfter]).
  bool clientStarved(Duration limit) =>
      DateTime.now().difference(_lastClientByteAt) > limit;

  /// Bytes received from the host and not on the file yet.
  int get unwritten => store == null ? 0 : math.max(0, end - store!.end);

  /// A chunk from the host: held in memory, readers woken, the file
  /// write queued.
  void take(List<int> chunk, StreamCacheProxyServer server) {
    if (chunk.isEmpty) return;
    final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    memory.add(_Chunk(end, data));
    end += data.length;
    memBytes += data.length;
    hostRate.add(data.length);
    if (!_writing) unawaited(_write(server));
  }

  Future<void> _write(StreamCacheProxyServer server) async {
    _writing = true;
    final window = generation;
    try {
      while (!dead && window == generation) {
        final store = this.store;
        if (store == null) return;
        final next = _chunkAt(store.end);
        if (next == null) return;
        final skip = store.end - next.offset;
        await store.appendAsync(
          skip == 0 ? next.data : Uint8List.sublistView(next.data, skip),
        );
        if (dead || window != generation) return;
        // Keep a little of what is already on the file in memory too,
        // so a reader right behind the newest bytes stays off the disk.
        while (memory.length > 1 &&
            memory.first.end <= store.end &&
            memBytes - memory.first.data.length >= server.memoryKeep) {
          memBytes -= memory.first.data.length;
          memory.removeAt(0);
          memStart = memory.first.offset;
        }
        pump(server);
      }
    } catch (_) {
      if (window == generation) kill('disk');
    } finally {
      _writing = false;
      // A window started while this one was finishing its last write.
      if (!dead && window != generation && memory.isNotEmpty) {
        unawaited(_write(server));
      }
    }
  }

  /// The chunk in [memory] holding [offset], or null.
  _Chunk? _chunkAt(int offset) {
    var low = 0;
    var high = memory.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final chunk = memory[mid];
      if (offset < chunk.offset) {
        high = mid - 1;
      } else if (offset >= chunk.end) {
        low = mid + 1;
      } else {
        return chunk;
      }
    }
    return null;
  }

  /// Hands [reader] up to about [most] bytes from memory, starting at
  /// its offset; returns how many.
  int writeFromMemory(_Reader reader, int most) {
    var offset = reader.offset;
    var sent = 0;
    while (sent < most && offset < reader.endExclusive) {
      final chunk = _chunkAt(offset);
      if (chunk == null) break;
      final from = offset - chunk.offset;
      final count = math.min(
        chunk.data.length - from,
        reader.endExclusive - offset,
      );
      reader.socket.add(
        from == 0 && count == chunk.data.length
            ? chunk.data
            : Uint8List.sublistView(chunk.data, from, from + count),
      );
      offset += count;
      sent += count;
    }
    return sent;
  }

  /// Forgets what is in memory (a new window is starting).
  void dropMemory() {
    generation++;
    memory.clear();
    memBytes = 0;
  }

  bool dead = false;
  String? reason;
  int hits = 0;
  int misses = 0;
  final List<StreamCacheRequest> requests = <StreamCacheRequest>[];

  Completer<void>? _signal;
  Future<void> _lock = Future<void>.value();

  /// One request at a time decides what to do with the window.
  Future<T> locked<T>(Future<T> Function() action) {
    final previous = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  void notify() {
    final signal = _signal;
    _signal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<void> waitForData(Duration limit) {
    final signal = _signal ??= Completer<void>();
    return signal.future.timeout(limit, onTimeout: () {});
  }

  /// Where the player is reading: the furthest connection it has open,
  /// or where its last one stopped.
  int get demand {
    if (readers.isEmpty) return lastOffset;
    var furthest = 0;
    for (final reader in readers) {
      if (reader.offset > furthest) furthest = reader.offset;
    }
    return furthest;
  }

  void detach(_Reader reader) {
    if (readers.remove(reader) && readers.isEmpty) lastOffset = reader.offset;
  }

  void noteRequest(int offset, bool local) {
    requests.add(
      StreamCacheRequest(
        atMs: DateTime.now().millisecondsSinceEpoch,
        offset: offset,
        local: local,
      ),
    );
    if (requests.length > 8) requests.removeAt(0);
  }

  /// Keeps the host connection [StreamCacheProxyServer.readAhead] ahead
  /// of the player and no further; restarts it when it has ended early.
  void pump(StreamCacheProxyServer server) {
    if (dead) return;
    final store = this.store;
    if (store == null) return;
    final lead = end - demand;
    // Build 78: the host is also held back when the disk falls far
    // behind it, so memory stays bounded.
    final behind = unwritten;
    final fetch = this.fetch;
    if (fetch == null) {
      if (!complete && !refetching && !anchoring && lead < server.readAhead) {
        unawaited(server._refetch(this));
      }
      return;
    }
    final subscription = fetch.subscription;
    if (subscription == null) return;
    if (!fetch.paused &&
        (lead >= server.readAhead || behind >= server.maxUnwritten)) {
      fetch.paused = true;
      subscription.pause();
    } else if (fetch.paused &&
        lead <= server.readAhead - server.readAhead ~/ 8 &&
        behind <= server.maxUnwritten ~/ 2) {
      fetch.paused = false;
      subscription.resume();
    }
  }

  void cancelFetch() {
    final fetch = this.fetch;
    this.fetch = null;
    if (fetch == null) return;
    try {
      unawaited(fetch.subscription?.cancel().catchError((Object _) {}));
    } catch (_) {}
  }

  /// Gives the film up: from here every request is redirected to the
  /// film's own address.
  void kill(String why) {
    if (dead) return;
    dead = true;
    reason = why;
    _release();
  }

  void dispose() {
    dead = true;
    reason ??= 'closed';
    _release();
  }

  void _release() {
    cancelFetch();
    for (final reader in readers.toList()) {
      reader.closed = true;
      unawaited(reader.end(graceful: false));
    }
    readers.clear();
    notify();
    dropMemory();
    final store = this.store;
    this.store = null;
    store?.close();
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  StreamCacheStats stats() {
    final store = this.store;
    return StreamCacheStats(
      held: store == null ? 0 : math.max(0, end - store.start),
      ahead: store == null ? 0 : math.max(0, end - demand),
      hostRate: hostRate.perSecond,
      clientRate: clientRate.perSecond,
      unwritten: unwritten,
      sides: sides,
      total: total,
      hits: hits,
      misses: misses,
      dead: dead,
      reason: reason,
      requests: List<StreamCacheRequest>.of(requests),
    );
  }
}
