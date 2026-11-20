// Profiles Build 1: the profile calls against a fake Dio adapter —
// paths, bodies, and error mapping.
//
// NOTE: written but NOT run yet — the b107 agent is running flutter on
// this VM and two flutter processes OOM it. Run after b107 lands:
// `flutter test test/features/profiles/`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/account/data/zorox_sync_client.dart';
import 'package:zorox/features/profiles/data/zeus_profiles_client.dart';

/// Answers every request with the next of [answers], noting each request.
/// (Same shape as the fake adapters in test/core/addons/.)
class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  ResponseBody Function(RequestOptions options) answer = (_) =>
      ResponseBody.fromString('{}', 200, headers: _json);

  static const _json = {
    Headers.contentTypeHeader: ['application/json'],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok(Map<String, dynamic> body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {Headers.contentTypeHeader: ['application/json']},
);

ResponseBody _fail(int status, String error) => ResponseBody.fromString(
  jsonEncode({'ok': false, 'error': error}),
  status,
  headers: {Headers.contentTypeHeader: ['application/json']},
);

const _profileJson = {
  'id': 'p_9f2c41a77d3e4b08',
  'name': 'Suresh',
  'color': 'gold',
  'pinRecord': 'v1\$100000\$c2FsdA\$aGFzaA',
  'createdAt': 1795129000000,
  'updatedAt': 1795129000000,
};

void main() {
  late _Server server;
  late ZeusProfilesClient client;

  setUp(() {
    server = _Server();
    client = ZeusProfilesClient(dio: Dio()..httpClientAdapter = server);
  });

  group('ZeusProfilesClient', () {
    test('fetch profiles parses the list', () async {
      server.answer = (_) => _ok({
        'ok': true,
        'profiles': [_profileJson],
        'updatedAt': 1795129000000,
      });
      final profiles = await client.fetchZeusProfiles(
        'https://example.workers.dev',
        'tok',
      );
      expect(profiles, hasLength(1));
      expect(profiles.single.id, 'p_9f2c41a77d3e4b08');
      expect(profiles.single.name, 'Suresh');
      expect(server.requests.single.path, contains('/profiles'));
      expect(server.requests.single.queryParameters['token'], 'tok');
    });

    test('fetch with no profiles returns an empty list', () async {
      server.answer = (_) => _ok({'ok': true, 'profiles': <Object>[], 'updatedAt': 0});
      final profiles = await client.fetchZeusProfiles(
        'https://example.workers.dev',
        'tok',
      );
      expect(profiles, isEmpty);
    });

    test('fetch 401 maps to a session-expired exception', () async {
      server.answer = (_) =>
          _fail(401, 'Session expired. Log in again.');
      expect(
        () => client.fetchZeusProfiles('https://example.workers.dev', 'tok'),
        throwsA(
          isA<ZoroxSyncException>()
              .having((e) => e.sessionExpired, 'sessionExpired', isTrue)
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('create posts name, colour and the record (never a PIN)', () async {
      server.answer = (options) {
        expect(options.path, contains('/profiles'));
        final data = options.data as Map;
        expect(data['name'], 'Aarav');
        expect(data['color'], 'teal');
        expect(data['pinRecord'], startsWith('v1\$100000\$'));
        expect(data.containsKey('pin'), isFalse);
        return _ok({'ok': true, 'profile': _profileJson});
      };
      final profile = await client.createZeusProfile(
        'https://example.workers.dev',
        'tok',
        name: 'Aarav',
        color: 'teal',
        pinRecord: 'v1\$100000\$c2FsdA\$aGFzaA',
      );
      expect(profile.id, 'p_9f2c41a77d3e4b08');
    });

    test('update posts the new record with the account password', () async {
      server.answer = (options) {
        expect(options.path, contains('/profiles/p_9f2c41a77d3e4b08'));
        final data = options.data as Map;
        expect(data['pinRecord'], startsWith('v1\$100000\$'));
        expect(data['password'], 'account-password');
        return _ok({'ok': true, 'profile': _profileJson});
      };
      final profile = await client.updateZeusProfile(
        'https://example.workers.dev',
        'tok',
        'p_9f2c41a77d3e4b08',
        pinRecord: 'v1\$100000\$bmV3c2FsdA\$bmV3aGFzaA',
        accountPassword: 'account-password',
      );
      expect(profile.name, 'Suresh');
    });

    test('update with a wrong password surfaces the server message', () async {
      server.answer = (_) => _fail(401, 'Wrong account password.');
      expect(
        () => client.updateZeusProfile(
          'https://example.workers.dev',
          'tok',
          'p_9f2c41a77d3e4b08',
          pinRecord: 'v1\$100000\$bmV3c2FsdA\$bmV3aGFzaA',
          accountPassword: 'wrong',
        ),
        throwsA(
          isA<ZoroxSyncException>().having(
            (e) => e.message,
            'message',
            'Wrong account password.',
          ),
        ),
      );
    });

    test('delete posts the account password to /delete', () async {
      server.answer = (options) {
        expect(options.path, endsWith('/profiles/p_9f2c41a77d3e4b08/delete'));
        final data = options.data as Map;
        expect(data['password'], 'account-password');
        return _ok({'ok': true});
      };
      await client.deleteZeusProfile(
        'https://example.workers.dev',
        'tok',
        'p_9f2c41a77d3e4b08',
        'account-password',
      );
    });

    test('delete of the last profile surfaces the 409', () async {
      server.answer = (_) =>
          _fail(409, 'The last profile cannot be deleted.');
      expect(
        () => client.deleteZeusProfile(
          'https://example.workers.dev',
          'tok',
          'p_9f2c41a77d3e4b08',
          'account-password',
        ),
        throwsA(
          isA<ZoroxSyncException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });
  });
}
