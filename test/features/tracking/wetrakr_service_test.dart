import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/storage/secure_token_storage.dart';
import 'package:zorox/features/tracking/data/wetrakr_service.dart';

/// WeTrakr, asserted against the wire: which requests the service makes,
/// with which headers and bodies, and what it does with each answer.
class _FakeTokenStorage implements SecureTokenStorage {
  _FakeTokenStorage([Map<String, String>? seed]) : values = {...?seed};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

typedef _Reply = FutureOr<ResponseBody> Function(RequestOptions options);

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.reply);

  _Reply reply;
  final List<RequestOptions> requests = <RequestOptions>[];

  List<String> get paths => requests.map((r) => r.uri.path).toList();

  Map<String, dynamic> bodyAt(int index) =>
      Map<String, dynamic>.from(requests[index].data as Map);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(
  Map<String, dynamic> body, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    ...headers,
  },
);

const String _clientId = 'test-client-id';
const String _accessKey = 'wetrakr_access_token';
const String _refreshKey = 'wetrakr_refresh_token';
const String _expiryKey = 'wetrakr_token_expires_at';

void main() {
  late _ScriptedAdapter adapter;
  late Dio dio;
  var now = DateTime.utc(2026, 11, 18, 12);
  DateTime clock() => now;
  final waits = <Duration>[];

  /// A delay that passes at once and moves the clock, so a ten-minute
  /// device flow runs in no time.
  Future<void> delay(Duration d) async {
    waits.add(d);
    now = now.add(d);
  }

  final movie = MultimediaItem(
    title: 'The Dark Knight',
    url: 'https://example.com/tdk',
    posterUrl: '',
    contentType: MultimediaContentType.movie,
    year: 2008,
    tmdbId: 155,
    imdbId: 'tt0468569',
  );
  final show = MultimediaItem(
    title: 'Show',
    url: 'https://example.com/show',
    posterUrl: '',
    contentType: MultimediaContentType.series,
    tmdbId: 1399,
  );
  final noIds = MultimediaItem(
    title: 'Nameless',
    url: 'https://example.com/x',
    posterUrl: '',
    contentType: MultimediaContentType.movie,
  );
  final episode = Episode(name: 'E3', url: 'e3', season: 2, episode: 3);

  Map<String, String> liveSession() => {
    _accessKey: 'live-access',
    _refreshKey: 'good-refresh',
    _expiryKey: now
        .add(const Duration(days: 5))
        .millisecondsSinceEpoch
        .toString(),
  };

  Map<String, String> expiredSession() => {
    _accessKey: 'stale-access',
    _refreshKey: 'good-refresh',
    _expiryKey: now
        .subtract(const Duration(days: 1))
        .millisecondsSinceEpoch
        .toString(),
  };

  WetrakrService service(
    _FakeTokenStorage storage, {
    String clientId = _clientId,
  }) => WetrakrService(
    dio,
    storage,
    clock: clock,
    delay: delay,
    appVersion: () async => '1.0.1',
    clientId: clientId,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 18, 12);
    waits.clear();
    adapter = _ScriptedAdapter((_) => _json({}));
    dio = Dio()..httpClientAdapter = adapter;
  });

  void expectAppHeaders(RequestOptions r) {
    expect(r.headers['wetrakr-api-key'], _clientId);
    expect(r.headers['wetrakr-api-version'], '1');
  }

  group('device sign-in', () {
    Map<String, dynamic> codes() => {
      'device_code': 'dev-123',
      'user_code': 'ABC123',
      'verification_url': 'https://wetrakr.com/activate',
      'expires_in': 600,
      'interval': 5,
    };

    test('pending, pending, then tokens: polls at the interval, stores the '
        'pair, never sends a secret', () async {
      var polls = 0;
      adapter.reply = (o) {
        if (o.uri.path == '/oauth/device/code') return _json(codes());
        polls++;
        if (polls < 3) {
          return _json({'error': 'authorization_pending'}, status: 400);
        }
        return _json({
          'access_token': 'new-access',
          'token_type': 'bearer',
          'expires_in': 604800,
          'refresh_token': 'new-refresh',
        });
      };
      final storage = _FakeTokenStorage();
      final s = service(storage);
      String? shownUrl, shownCode;

      final ok = await s.login(
        onDeviceCodeGenerated: (url, code) async {
          shownUrl = url;
          shownCode = code;
        },
      );

      expect(ok, isTrue);
      expect(shownUrl, 'https://wetrakr.com/activate');
      expect(shownCode, 'ABC123');
      expect(adapter.paths, [
        '/oauth/device/code',
        '/oauth/device/token',
        '/oauth/device/token',
        '/oauth/device/token',
      ]);
      expect(adapter.requests.first.uri.host, 'api.wetrakr.com');
      expect(adapter.bodyAt(0), {'client_id': _clientId});
      expect(adapter.bodyAt(1), {'code': 'dev-123', 'client_id': _clientId});
      for (final r in adapter.requests) {
        expectAppHeaders(r);
        expect(r.headers.containsKey('Authorization'), isFalse);
        expect(jsonEncode(r.data), isNot(contains('client_secret')));
      }
      expect(waits, List.filled(3, const Duration(seconds: 5)));
      expect(storage.values[_accessKey], 'new-access');
      expect(storage.values[_refreshKey], 'new-refresh');
      expect(
        storage.values[_expiryKey],
        '${now.millisecondsSinceEpoch + 604800 * 1000}',
      );
      expect(await s.isLoggedIn, isTrue);
    });

    test(
      'a code nobody approves expires: polling stops at expires_in',
      () async {
        adapter.reply = (o) => o.uri.path == '/oauth/device/code'
            ? _json(codes())
            : _json({'error': 'authorization_pending'}, status: 400);
        final storage = _FakeTokenStorage();
        final s = service(storage);

        expect(await s.login(), isFalse);
        // 600 s at 5 s: 119 polls, then the deadline.
        expect(
          adapter.paths.where((p) => p == '/oauth/device/token').length,
          119,
        );
        expect(storage.values, isEmpty);
        expect(await s.isLoggedIn, isFalse);
      },
    );

    test('a refused or expired code stops at once', () async {
      for (final status in [404, 409, 410, 418]) {
        adapter.requests.clear();
        adapter.reply = (o) => o.uri.path == '/oauth/device/code'
            ? _json(codes())
            : _json({'error': 'x'}, status: status);
        expect(await service(_FakeTokenStorage()).login(), isFalse);
        expect(adapter.paths.length, 2, reason: 'status $status');
      }
    });

    test('a 400 that is not "pending" is a bug, not a wait: stop', () async {
      adapter.reply = (o) => o.uri.path == '/oauth/device/code'
          ? _json(codes())
          : _json({'error': 'invalid_request'}, status: 400);
      expect(await service(_FakeTokenStorage()).login(), isFalse);
      expect(adapter.paths.length, 2);
    });

    test('cancelled by the person: no more polls', () async {
      adapter.reply = (o) => o.uri.path == '/oauth/device/code'
          ? _json(codes())
          : _json({'error': 'authorization_pending'}, status: 400);
      var cancelled = false;
      final ok = await service(_FakeTokenStorage()).login(
        onDeviceCodeGenerated: (_, _) async => cancelled = true,
        isCancelled: () => cancelled,
      );
      expect(ok, isFalse);
      expect(adapter.paths, ['/oauth/device/code']);
    });

    test('a build without the client id asks nothing', () async {
      final s = service(_FakeTokenStorage(liveSession()), clientId: '');
      expect(s.isConfigured, isFalse);
      expect(await s.login(), isFalse);
      expect(await s.isLoggedIn, isFalse);
      expect(await s.scrobbleStart(movie, null, 0.1), isTrue);
      expect(adapter.requests, isEmpty);
    });
  });

  group('token refresh', () {
    test('an expired token is refreshed once for many calls at once, and '
        'the rotated refresh token is kept', () async {
      final gate = Completer<void>();
      adapter.reply = (o) async {
        if (o.uri.path == '/oauth/token/refresh') {
          await gate.future;
          return _json({
            'access_token': 'fresh-access',
            'expires_in': 604800,
            'refresh_token': 'rotated-refresh',
            'new_refresh_token': 'rotated-refresh',
          });
        }
        return _json({'action': 'start'});
      };
      final storage = _FakeTokenStorage(expiredSession());
      final s = service(storage);

      final calls = [
        s.scrobbleStart(movie, null, 0.1),
        s.scrobblePause(movie, null, 0.2),
        s.scrobbleStop(movie, null, 0.9),
      ];
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      expect(await Future.wait(calls), [true, true, true]);

      expect(adapter.paths.where((p) => p == '/oauth/token/refresh').length, 1);
      final refresh = adapter.requests.firstWhere(
        (r) => r.uri.path == '/oauth/token/refresh',
      );
      expect(refresh.data, {'refresh_token': 'good-refresh'});
      expectAppHeaders(refresh);
      expect(storage.values[_refreshKey], 'rotated-refresh');
      expect(storage.values[_accessKey], 'fresh-access');
      for (final r in adapter.requests.where(
        (r) => r.uri.path.startsWith('/scrobble'),
      )) {
        expect(r.headers['Authorization'], 'Bearer fresh-access');
      }
    });

    test('401 INVALID_REFRESH_TOKEN signs out: the row asks to connect '
        'again and the write is not retried for ever', () async {
      adapter.reply = (o) => _json({
        'error': 'INVALID_REFRESH_TOKEN',
        'message': 'Invalid refresh token',
      }, status: 401);
      final storage = _FakeTokenStorage(expiredSession());
      final s = service(storage);

      expect(await s.scrobbleStop(movie, null, 0.9), isTrue);
      expect(storage.values, isEmpty);
      expect(await s.isLoggedIn, isFalse);
      expect(adapter.paths, ['/oauth/token/refresh']);
    });

    test('a refresh that fails for the network keeps the session', () async {
      adapter.reply = (o) => _json({}, status: 503);
      final storage = _FakeTokenStorage(expiredSession());
      final s = service(storage);

      expect(await s.scrobbleStop(movie, null, 0.9), isFalse);
      expect(storage.values[_refreshKey], 'good-refresh');
      expect(await s.isLoggedIn, isTrue);
    });
  });

  group('scrobble', () {
    test(
      'a movie: title, year and ids, progress 0-100, the app version',
      () async {
        adapter.reply = (_) => _json({'action': 'start', 'progress': 12.5});
        final s = service(_FakeTokenStorage(liveSession()));

        expect(await s.scrobbleStart(movie, null, 0.125), isTrue);

        final r = adapter.requests.single;
        expect(r.method, 'POST');
        expect(r.uri.toString(), 'https://api.wetrakr.com/scrobble/start');
        expectAppHeaders(r);
        expect(r.headers['Authorization'], 'Bearer live-access');
        expect(r.data, {
          'progress': 12.5,
          'app_version': '1.0.1',
          'movie': {
            'title': 'The Dark Knight',
            'year': 2008,
            'ids': {'tmdb': 155, 'imdb': 'tt0468569'},
          },
        });
      },
    );

    test(
      'an episode: the show plus season and number, never a movie',
      () async {
        adapter.reply = (_) => _json({'action': 'pause'});
        final s = service(_FakeTokenStorage(liveSession()));

        expect(await s.scrobblePause(show, episode, 0.47), isTrue);

        final r = adapter.requests.single;
        expect(r.uri.path, '/scrobble/pause');
        expect(r.data, {
          'progress': 47.0,
          'app_version': '1.0.1',
          'show': {
            'title': 'Show',
            'ids': {'tmdb': 1399},
          },
          'episode': {'season': 2, 'number': 3},
        });
      },
    );

    test(
      'stop sends the real progress; mark watched is a stop at 100',
      () async {
        adapter.reply = (_) => _json({'action': 'scrobble'}, status: 201);
        final s = service(_FakeTokenStorage(liveSession()));

        expect(await s.scrobbleStop(movie, null, 0.96), isTrue);
        expect(await s.markWatched(movie, null), isTrue);

        expect(adapter.paths, ['/scrobble/stop', '/scrobble/stop']);
        expect(adapter.bodyAt(0)['progress'], 96.0);
        expect(adapter.bodyAt(1)['progress'], 100.0);
      },
    );

    test('nothing WeTrakr can resolve is not sent, and not owed', () async {
      final s = service(_FakeTokenStorage(liveSession()));
      expect(await s.scrobbleStop(noIds, null, 0.9), isTrue);
      // A show with no episode.
      expect(await s.scrobbleStop(show, null, 0.9), isTrue);
      expect(adapter.requests, isEmpty);
    });

    test('signed out: nothing is sent', () async {
      final s = service(_FakeTokenStorage());
      expect(await s.scrobbleStart(movie, null, 0.1), isTrue);
      expect(adapter.requests, isEmpty);
    });

    test(
      'a title WeTrakr does not know (404) is settled, not retried',
      () async {
        adapter.reply = (_) => _json({'error': 'NOT_FOUND'}, status: 404);
        final s = service(_FakeTokenStorage(liveSession()));
        expect(await s.scrobbleStop(movie, null, 0.9), isTrue);
      },
    );

    test('a server error is owed again later', () async {
      adapter.reply = (_) => _json({}, status: 502);
      final s = service(_FakeTokenStorage(liveSession()));
      expect(await s.scrobbleStop(movie, null, 0.9), isFalse);
    });

    test('a 429 holds every call back until Retry-After has passed', () async {
      adapter.reply = (_) => _json(
        {'error': 'too_many_requests'},
        status: 429,
        headers: {
          'retry-after': ['120'],
        },
      );
      final s = service(_FakeTokenStorage(liveSession()));

      expect(await s.scrobbleStop(movie, null, 0.9), isFalse);
      expect(adapter.requests.length, 1);
      // Still inside the two minutes: nothing leaves the phone.
      now = now.add(const Duration(seconds: 60));
      expect(await s.scrobbleStart(movie, null, 0.1), isFalse);
      expect(adapter.requests.length, 1);
      // After it: calls go out again.
      now = now.add(const Duration(seconds: 61));
      adapter.reply = (_) => _json({'action': 'start'});
      expect(await s.scrobbleStart(movie, null, 0.1), isTrue);
      expect(adapter.requests.length, 2);
    });

    test('a 401 on a live token refreshes once and sends again', () async {
      var scrobbles = 0;
      adapter.reply = (o) {
        if (o.uri.path == '/oauth/token/refresh') {
          return _json({
            'access_token': 'fresh-access',
            'expires_in': 604800,
            'refresh_token': 'rotated-refresh',
          });
        }
        scrobbles++;
        return scrobbles == 1
            ? _json({'message': 'No authorized!'}, status: 401)
            : _json({'action': 'start'});
      };
      final s = service(_FakeTokenStorage(liveSession()));

      expect(await s.scrobbleStart(movie, null, 0.1), isTrue);
      expect(adapter.paths, [
        '/scrobble/start',
        '/oauth/token/refresh',
        '/scrobble/start',
      ]);
      expect(
        adapter.requests.last.headers['Authorization'],
        'Bearer fresh-access',
      );
    });
  });

  group('sign out', () {
    test('clears the tokens here, then ends the session on WeTrakr', () async {
      adapter.reply = (_) => _json({'revoked': true});
      final storage = _FakeTokenStorage(liveSession());
      final s = service(storage);

      await s.logout();

      expect(storage.values, isEmpty);
      expect(await s.isLoggedIn, isFalse);
      final r = adapter.requests.single;
      expect(r.uri.path, '/oauth/logout');
      expect(r.data, {'refresh_token': 'good-refresh'});
      expect(r.headers['Authorization'], 'Bearer live-access');
      expectAppHeaders(r);
    });

    test('with no network the person is still signed out', () async {
      adapter.reply = (_) => throw DioException.connectionError(
        requestOptions: RequestOptions(),
        reason: 'offline',
      );
      final storage = _FakeTokenStorage(liveSession());
      final s = service(storage);
      await s.logout();
      expect(storage.values, isEmpty);
    });
  });

  test('WeTrakr pulls nothing and adds to no list', () async {
    final s = service(_FakeTokenStorage(liveSession()));
    expect(await s.pullPlaybackProgress(), isEmpty);
    expect(await s.addToPlanToWatch(movie), isFalse);
    expect(adapter.requests, isEmpty);
  });
}
