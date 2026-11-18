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

/// A "film" shorter than this is not worth holding — and is far more
/// likely a playlist or an error page than a film.
const int kStreamCacheMinLength = 8 * kMiB;

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
  });

  /// Bytes on disk right now.
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
    this.minLength = kStreamCacheMinLength,
    this.connectTimeout = const Duration(seconds: 10),
    this.responseTimeout = const Duration(seconds: 15),
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  /// Where the ring files live. Emptied when the server starts.
  final String directory;
  final int capacity;
  final int readAhead;
  final int skipAhead;
  final int minLength;
  final Duration connectTimeout;
  final Duration responseTimeout;
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
        start <= store.end + skipAhead;
    if (local) {
      session.hits++;
    } else {
      final ok = await _anchor(session, start);
      if (!ok) {
        await _redirect(request, session.origin);
        return null;
      }
      session.misses++;
    }
    session.noteRequest(start, local && start < session.store!.end);

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
    final buffer = Uint8List(256 * 1024);
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
            math.min(store.end, reader.endExclusive) - reader.offset;
        if (available <= 0) {
          if (session.complete) break;
          session.pump(this);
          await session.waitForData(const Duration(seconds: 5));
          continue;
        }
        final count = store.read(
          reader.offset,
          buffer,
          math.min(available, buffer.length),
        );
        if (count <= 0) break;
        reader.socket.add(Uint8List.sublistView(buffer, 0, count));
        await reader.socket.flush();
        reader.offset += count;
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

  // -------------------------------------------------------------------------
  // The host's side.
  // -------------------------------------------------------------------------

  /// Starts the film's one host connection at [offset] and waits for
  /// its first bytes. Everything held before is dropped: the window
  /// begins again at [offset]. False when the host cannot be used this
  /// way — the film is then given up for good (see [_Session.kill]).
  Future<bool> _anchor(_Session session, int offset) async {
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
      store.reset(offset);
      session
        ..complete = false
        ..lastOffset = offset;
      _attach(session, upstream.response, sniff: known == null && offset == 0);
      final deadline = DateTime.now().add(responseTimeout);
      while (!session.dead && !session.complete && store.end <= offset) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) throw const _Unusable('no data');
        await session.waitForData(left);
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

  void _attach(_Session session, HttpClientResponse response, {bool sniff = false}) {
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
        final store = session.store;
        if (store == null) return;
        try {
          store.append(chunk);
        } catch (_) {
          session.kill('disk');
          return;
        }
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
    if (store != null && total != null && store.end >= total) {
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
        if (session.dead || session.fetch != null) return;
        try {
          final upstream = await _openUpstream(session, store.end);
          if (session.dead) {
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
  Future<_Upstream> _openUpstream(_Session session, int offset) async {
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
        session.resolved = uri;
        return _Upstream(
          response: response,
          total: range.$2,
          contentType: response.headers.value(HttpHeaders.contentTypeHeader),
        );
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

  void _discard(HttpClientResponse response) {
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
  });
  final HttpClientResponse response;
  final int total;
  final String? contentType;
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

  RingStore? store;
  int? total;
  String? contentType;
  Uri? resolved;
  Map<String, List<String>> clientHeaders = const <String, List<String>>{};

  _Fetch? fetch;
  bool refetching = false;
  bool complete = false;
  int failures = 0;

  final Set<_Reader> readers = <_Reader>{};
  int lastOffset = 0;

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
    final lead = store.end - demand;
    final fetch = this.fetch;
    if (fetch == null) {
      if (!complete && !refetching && lead < server.readAhead) {
        unawaited(server._refetch(this));
      }
      return;
    }
    final subscription = fetch.subscription;
    if (subscription == null) return;
    if (!fetch.paused && lead >= server.readAhead) {
      fetch.paused = true;
      subscription.pause();
    } else if (fetch.paused && lead <= server.readAhead - server.readAhead ~/ 8) {
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
      held: store?.length ?? 0,
      ahead: store == null ? 0 : math.max(0, store.end - demand),
      total: total,
      hits: hits,
      misses: misses,
      dead: dead,
      reason: reason,
      requests: List<StreamCacheRequest>.of(requests),
    );
  }
}
