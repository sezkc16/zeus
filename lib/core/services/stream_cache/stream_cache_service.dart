/// Build 77: runs [StreamCacheProxyServer] in its own isolate and gives
/// the player a small, never-throwing way to use it.
///
/// Its own isolate, because the proxy's work (reading the host, writing
/// and reading the store file) must keep going at full speed exactly
/// when the UI isolate is busiest — during a renderer move.
///
/// Every call here answers within a short limit and answers "no" rather
/// than throw: a player that gets no proxied address simply opens the
/// film's own address, as it did before build 77.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'stream_cache_proxy.dart';

/// A film opened through the proxy.
class StreamCacheHandle {
  const StreamCacheHandle({required this.token, required this.url});

  /// Names the film to [StreamCacheService.close] / `stats`.
  final String token;

  /// What the player opens instead of the film's own address.
  final String url;
}

class StreamCacheService {
  StreamCacheService._();

  static final StreamCacheService instance = StreamCacheService._();

  /// Only the iPhone/iPad app uses the proxy. (`dart:io`'s platform, not
  /// Flutter's — a widget test that pretends to be iOS on a build
  /// machine must never start a server.)
  static bool get supported => Platform.isIOS || debugDirectory != null;

  /// Tests only: run the proxy on the build machine, in this directory.
  @visibleForTesting
  static String? debugDirectory;

  static const Duration _startLimit = Duration(seconds: 3);
  static const Duration _callLimit = Duration(milliseconds: 1500);

  SendPort? _commands;
  Future<bool>? _starting;
  ReceivePort? _replies;
  Isolate? _isolate;
  int _nextId = 1;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  bool _broken = false;

  /// Why the last [open] gave no proxied address (for the overlay).
  String? lastFailure;

  static Future<String> _directory() async {
    final forced = debugDirectory;
    if (forced != null) return forced;
    final temp = await getTemporaryDirectory();
    return '${temp.path}/zeus_stream_cache';
  }

  /// Deletes store files a crash or a kill left behind. Called once at
  /// app start, before any film can be open.
  static Future<void> sweepLeftovers() async {
    if (!supported) return;
    try {
      final directory = await _directory();
      await Isolate.run(() => StreamCacheProxyServer.sweepDirectory(directory));
    } catch (_) {}
  }

  Future<bool> _ensureStarted() {
    if (_commands != null) return Future<bool>.value(true);
    if (_broken) return Future<bool>.value(false);
    return _starting ??= _start();
  }

  Future<bool> _start() async {
    try {
      final directory = await _directory();
      final replies = ReceivePort();
      final ready = Completer<SendPort?>();
      replies.listen((message) {
        if (message is SendPort) {
          if (!ready.isCompleted) ready.complete(message);
          return;
        }
        if (message is List && message.length == 2 && message[0] is int) {
          _pending.remove(message[0] as int)?.complete(message[1]);
          return;
        }
        // The isolate ended (error or exit).
        if (!ready.isCompleted) ready.complete(null);
        _lost();
      });
      _replies = replies;
      _isolate = await Isolate.spawn<List<Object?>>(
        _streamCacheIsolateMain,
        <Object?>[replies.sendPort, directory],
        onExit: replies.sendPort,
        onError: replies.sendPort,
        errorsAreFatal: true,
        debugName: 'zeus-stream-cache',
      );
      final commands = await ready.future.timeout(
        _startLimit,
        onTimeout: () => null,
      );
      if (commands == null) {
        lastFailure = 'start';
        _lost(permanent: true);
        return false;
      }
      _commands = commands;
      return true;
    } catch (_) {
      lastFailure = 'start';
      _lost(permanent: true);
      return false;
    } finally {
      _starting = null;
    }
  }

  void _lost({bool permanent = false}) {
    _commands = null;
    _replies?.close();
    _replies = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    if (permanent) _broken = true;
    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) waiting.complete(null);
    }
    _pending.clear();
  }

  Future<Object?> _call(String what, [Object? argument]) async {
    if (!await _ensureStarted()) return null;
    final commands = _commands;
    if (commands == null) return null;
    final id = _nextId++;
    final answer = Completer<Object?>();
    _pending[id] = answer;
    commands.send(<Object?>[id, what, argument]);
    return answer.future.timeout(
      _callLimit,
      onTimeout: () {
        _pending.remove(id);
        return null;
      },
    );
  }

  /// A proxied address for [url], or null — then the player opens [url]
  /// itself. Nothing is asked of the host here.
  Future<StreamCacheHandle?> open(String url) async {
    if (!supported) return null;
    try {
      final answer = await _call('open', url);
      if (answer is List && answer.length == 2) {
        lastFailure = null;
        return StreamCacheHandle(
          token: answer[0] as String,
          url: answer[1] as String,
        );
      }
      lastFailure = answer is String ? answer : (lastFailure ?? 'no answer');
    } catch (_) {
      lastFailure = 'error';
    }
    return null;
  }

  /// Forgets a film and deletes its store file.
  void close(String token) {
    final commands = _commands;
    if (commands == null) return;
    try {
      commands.send(<Object?>[0, 'close', token]);
    } catch (_) {}
  }

  /// What the proxy holds for a film, or null.
  Future<StreamCacheStats?> stats(String token) async {
    if (_commands == null) return null;
    try {
      return StreamCacheStats.fromMap(await _call('stats', token));
    } catch (_) {
      return null;
    }
  }

  /// After the app comes back from the background: iOS may have closed
  /// the listening socket while the app was suspended. Checks it and
  /// opens it again on the same port, so the address the player already
  /// holds keeps working.
  Future<bool> ensureListening() async {
    if (_commands == null) return false;
    try {
      return await _call('listen') == true;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  Future<void> debugShutdown() async {
    final commands = _commands;
    if (commands != null) {
      try {
        await _call('shutdown');
      } catch (_) {}
    }
    _lost();
    _broken = false;
  }
}

/// The isolate: one [StreamCacheProxyServer], driven by small messages
/// `[id, what, argument]` answered with `[id, result]`.
Future<void> _streamCacheIsolateMain(List<Object?> boot) async {
  final replies = boot[0]! as SendPort;
  final directory = boot[1]! as String;
  final server = StreamCacheProxyServer(directory: directory);
  String? startFailure;
  try {
    await server.start();
  } catch (_) {
    startFailure = 'bind';
  }
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  await for (final message in commands) {
    if (message is! List || message.length != 3) continue;
    final id = message[0] as int;
    final what = message[1] as String;
    final argument = message[2];
    Object? result;
    try {
      switch (what) {
        case 'open':
          if (startFailure != null) {
            // Try once more: the port may have been busy for a moment.
            try {
              await server.start();
              startFailure = null;
            } catch (_) {}
          }
          if (startFailure != null) {
            result = startFailure;
          } else if (!await server.ensureListening()) {
            result = 'bind';
          } else {
            final session = server.openSession(argument! as String);
            result = <String>[session.token, session.url];
          }
        case 'close':
          server.closeSession(argument! as String);
        case 'stats':
          result = server.stats(argument! as String)?.toMap();
        case 'listen':
          result = startFailure == null && await server.ensureListening();
        case 'shutdown':
          await server.shutdown();
          result = true;
      }
    } catch (_) {
      result = what == 'open' ? 'error' : null;
    }
    if (id != 0) replies.send(<Object?>[id, result]);
    if (what == 'shutdown') break;
  }
  commands.close();
}
