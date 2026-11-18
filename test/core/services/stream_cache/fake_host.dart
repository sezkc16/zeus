// Build 77: a stand-in for a film host, for the stream cache proxy's
// tests. It serves a deterministic "film" (any byte can be recomputed
// from its offset, so any range can be checked without holding the
// film) and can be told to misbehave the ways real hosts do.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

int filmByte(int offset) => (offset * 31 + (offset >> 8) * 7 + 3) & 0xFF;

Uint8List film(int from, int count) {
  final out = Uint8List(count);
  for (var i = 0; i < count; i++) {
    out[i] = filmByte(from + i);
  }
  return out;
}

class HostRequest {
  HostRequest(this.path, this.headers, this.rangeStart);
  final String path;
  final Map<String, String> headers;
  final int? rangeStart;
}

class FakeHost {
  FakeHost({this.length = 3 * 1024 * 1024});

  /// The film's length in bytes.
  int length;

  late HttpServer _server;
  final List<HostRequest> requests = <HostRequest>[];
  final Set<Socket> _open = <Socket>{};

  /// What the host says the film is.
  String contentType = 'video/x-matroska';

  /// Answer every request with the whole film and 200 (no ranges).
  bool ignoreRange = false;

  /// Answer `/film.mkv` with this status and nothing else, from the
  /// request with this index on (0 = every request).
  int? failStatus;
  int failFromRequest = 0;

  /// Hang up after this many body bytes, this many times.
  int? dropAfter;
  int dropTimes = 0;

  /// Wait this long before answering at all.
  Duration delay = Duration.zero;

  /// Serve this text instead of the film (a playlist behind a film's
  /// address), padded to [length].
  String? textBody;

  /// Serve this real file instead of the made-up film.
  String? filePath;

  /// Stop sending after this many body bytes and hold the connection
  /// open (a host that stalls), for requests from this index on.
  int? stallAfter;

  /// Build 78: wait this long after each 32 KiB (a host with a speed).
  Duration pace = Duration.zero;

  /// Build 78: body bytes sent, per request (by its index in
  /// [requests]).
  final Map<int, int> sentBy = <int, int>{};

  /// Build 78: connections the host still has open.
  int get openConnections => _open.length;

  int get port => _server.port;
  String get base => 'http://127.0.0.1:$port';

  /// Requests for the film itself (redirect hops not counted).
  int get filmRequests =>
      requests.where((r) => r.path == '/film.mkv').length;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    for (final socket in _open.toList()) {
      socket.destroy();
    }
    await _server.close(force: true);
  }

  /// Cuts every connection the host has open (the phone slept).
  void cutConnections() {
    for (final socket in _open.toList()) {
      socket.destroy();
    }
    _open.clear();
  }

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    int? start;
    final range = headers['range'];
    if (range != null) {
      final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (match != null) start = int.parse(match.group(1)!);
    }
    final path = request.uri.path;
    final index = requests.length;
    requests.add(HostRequest(path, headers, start));
    if (delay > Duration.zero) await Future<void>.delayed(delay);

    if (path == '/go') {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set('location', '/film.mkv')
        ..headers.contentLength = 0;
      await request.response.close();
      return;
    }
    if (path != '/film.mkv') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final fail = failStatus;
    if (fail != null && index >= failFromRequest) {
      request.response
        ..statusCode = fail
        ..headers.contentLength = 0;
      await request.response.close();
      return;
    }

    final path0 = filePath;
    final RandomAccessFile? file = path0 == null
        ? null
        : File(path0).openSync();
    if (file != null) length = file.lengthSync();
    final from = ignoreRange ? 0 : (start ?? 0);
    final Socket socket;
    try {
      socket = await request.response.detachSocket(writeHeaders: false);
    } catch (_) {
      return; // the proxy gave up waiting and hung up
    }
    _open.add(socket);
    socket.listen(
      (_) {},
      onDone: () => _open.remove(socket),
      onError: (Object _) => _open.remove(socket),
      cancelOnError: true,
    );
    final ranged = !ignoreRange && start != null;
    final head = StringBuffer()
      ..write(ranged ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: $contentType\r\n');
    if (ranged) {
      head
        ..write('Accept-Ranges: bytes\r\n')
        ..write('Content-Range: bytes $from-${length - 1}/$length\r\n');
    }
    head
      ..write('Content-Length: ${length - from}\r\n')
      ..write('Connection: close\r\n\r\n');
    socket.add(latin1.encode(head.toString()));

    final text = textBody == null ? null : utf8.encode(textBody!);
    var at = from;
    var sent = 0;
    try {
      while (at < length) {
        final drop = dropAfter;
        if (drop != null && dropTimes > 0 && sent >= drop) {
          dropTimes--;
          socket.destroy();
          _open.remove(socket);
          return;
        }
        final stall = stallAfter;
        if (stall != null && sent >= stall) {
          // Hold the line and send nothing more.
          await socket.flush();
          return;
        }
        var count = length - at;
        if (count > 32 * 1024) count = 32 * 1024;
        if (drop != null && dropTimes > 0 && sent + count > drop) {
          count = drop - sent;
        }
        if (stall != null && sent + count > stall) count = stall - sent;
        if (count <= 0) continue;
        final Uint8List chunk;
        if (file != null) {
          file.setPositionSync(at);
          chunk = file.readSync(count);
        } else {
          chunk = film(at, count);
        }
        if (text != null) {
          for (var i = 0; i < count; i++) {
            final k = at + i;
            chunk[i] = k < text.length ? text[k] : 0x20;
          }
        }
        socket.add(chunk);
        await socket.flush();
        at += count;
        sent += count;
        sentBy[index] = sent;
        if (pace > Duration.zero) await Future<void>.delayed(pace);
      }
      await socket.close();
    } catch (_) {
      // The proxy hung up.
    } finally {
      file?.closeSync();
      _open.remove(socket);
      socket.destroy();
    }
  }
}

/// What a player's request to the proxy got back.
class PlayerAnswer {
  PlayerAnswer(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
}

/// One request the way ffmpeg makes it: a ranged GET with a few
/// headers. Reads at most [take] body bytes, then hangs up.
Future<PlayerAnswer> playerGet(
  String url, {
  int? from,
  int? to,
  int? take,
  Map<String, String> headers = const <String, String>{},
  Duration timeout = const Duration(seconds: 20),
}) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = false;
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
    headers.forEach((name, value) => request.headers.set(name, value));
    if (from != null) {
      request.headers.set('Range', 'bytes=$from-${to ?? ''}');
    }
    final response = await request.close().timeout(timeout);
    final answerHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      answerHeaders[name.toLowerCase()] = values.join(', ');
    });
    final body = BytesBuilder(copy: false);
    final done = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        body.add(chunk);
        if (take != null && body.length >= take && !done.isCompleted) {
          done.complete();
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await done.future.timeout(timeout);
    await subscription.cancel();
    var bytes = body.toBytes();
    if (take != null && bytes.length > take) {
      bytes = Uint8List.sublistView(bytes, 0, take);
    }
    return PlayerAnswer(response.statusCode, answerHeaders, bytes);
  } finally {
    client.close(force: true);
  }
}
