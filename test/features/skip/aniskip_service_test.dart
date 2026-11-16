import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/skip/data/aniskip_service.dart';
import 'package:zorox/features/skip/data/skip_service.dart';

/// Answers every request from a table keyed by URL substring, noting
/// each request — the mock-Dio pattern the add-on tests use
/// (`Dio()..httpClientAdapter = server`).
class _FakeServer implements HttpClientAdapter {
  _FakeServer(this._answers);

  final Map<String, ResponseBody Function(RequestOptions)> _answers;
  final requests = <RequestOptions>[];

  static const _json = {
    Headers.contentTypeHeader: ['application/json'],
  };

  static ResponseBody json(Object body) => ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: _json,
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    for (final entry in _answers.entries) {
      if (options.uri.toString().contains(entry.key)) {
        return entry.value(options);
      }
    }
    return ResponseBody.fromString('{}', 404, headers: _json);
  }

  @override
  void close({bool force = false}) {}
}

/// The live AniSkip answer for Attack on Titan S1E2 (MAL 16498),
/// verified 2026-11-16 against api.aniskip.com.
Map<String, dynamic> _aotEp2Aniskip() => {
      'found': true,
      'results': [
        {
          'interval': {'startTime': 54.312, 'endTime': 144.312},
          'skipType': 'op',
          'skipId': '27cc3728-2b3f-4f61-9e32-1da3d05bb01b',
          'episodeLength': 1450.032,
        },
        {
          'interval': {'startTime': 1372.218, 'endTime': 1451},
          'skipType': 'ed',
          'skipId': '90a64e79-86ba-44f6-ae39-cddcd71a7895',
          'episodeLength': 1451.099,
        },
      ],
      'message': 'Successfully found skip times',
      'statusCode': 200,
    };

void main() {
  group('AniskipService.parseResponse', () {
    // Live payloads, verified 2026-11-16 against api.aniskip.com.
    test('maps Demon Slayer ep 1 OP + ED to intro + outro', () {
      final segments = AniskipService.parseResponse({
        'found': true,
        'results': [
          {
            'interval': {'startTime': 5.617, 'endTime': 95.617},
            'skipType': 'op',
            'skipId': '04e8cbb7-60d6-4132-840a-24a867c1a80c',
            'episodeLength': 1435.193,
          },
          {
            'interval': {'startTime': 1295.128, 'endTime': 1385.128},
            'skipType': 'ed',
            'skipId': 'a46dcea2-4075-43ac-bcc9-e9b00f710424',
            'episodeLength': 1426.0304,
          },
        ],
        'message': 'Successfully found skip times',
        'statusCode': 200,
      }, durationSec: 1435);
      expect(segments.length, 2);
      expect(segments[0].type, SkipType.intro);
      expect(segments[0].startTime, 5.617);
      expect(segments[0].endTime, 95.617);
      expect(segments[1].type, SkipType.outro);
      expect(segments[1].startTime, 1295.128);
      expect(segments[1].endTime, 1385.128);
    });

    test('maps One Piece ep 1000 OP-only answer', () {
      final segments = AniskipService.parseResponse({
        'found': true,
        'results': [
          {
            'interval': {'startTime': 13.891, 'endTime': 123.834},
            'skipType': 'op',
            'skipId': '5bcf9262-b16f-40ad-9d12-8168e4ecad2d',
            'episodeLength': 1430.721,
          },
        ],
        'message': 'Successfully found skip times',
        'statusCode': 200,
      }, durationSec: 1430);
      expect(segments.length, 1);
      expect(segments[0].type, SkipType.intro);
    });

    test('found:false and missing results are an empty list, not an error', () {
      expect(
        AniskipService.parseResponse(<String, dynamic>{
          'found': false,
          'results': <Object>[],
        }),
        isEmpty,
      );
      expect(
        AniskipService.parseResponse(<String, dynamic>{'found': true}),
        isEmpty,
      );
      expect(AniskipService.parseResponse(<String, dynamic>{}), isEmpty);
    });

    test('ignores unknown skip types and malformed entries', () {
      final segments = AniskipService.parseResponse({
        'found': true,
        'results': [
          {
            'interval': {'startTime': 10, 'endTime': 90},
            'skipType': 'op',
          },
          {
            'interval': {'startTime': 500, 'endTime': 590},
            'skipType': 'recap',
          },
          {
            'interval': {'startTime': 700},
            'skipType': 'ed',
          },
          'not-a-map',
        ],
      }, durationSec: 1400);
      expect(segments.length, 1);
      expect(segments[0].type, SkipType.intro);
    });
  });

  group('AniskipService sync-data id readings', () {
    test('reads MAL id under every spelling plugins use', () {
      expect(AniskipService.malIdFromSyncData({'mal': '38000'}), 38000);
      expect(AniskipService.malIdFromSyncData({'malId': '21'}), 21);
      expect(AniskipService.malIdFromSyncData({'mal_id': '21'}), 21);
      expect(AniskipService.malIdFromSyncData({'anilist': '21'}), isNull);
      expect(AniskipService.malIdFromSyncData(null), isNull);
      expect(AniskipService.malIdFromSyncData({'mal': 'not-a-number'}), isNull);
    });

    test('reads AniList id under every spelling plugins use', () {
      expect(AniskipService.anilistIdFromSyncData({'anilist': '21'}), 21);
      expect(AniskipService.anilistIdFromSyncData({'anilistId': '21'}), 21);
      expect(AniskipService.anilistIdFromSyncData({'anilist_id': '21'}), 21);
      expect(AniskipService.anilistIdFromSyncData(null), isNull);
    });
  });

  group('getSkipSegments title fallback (+56)', () {
    // The +55 bug, user proof 2026-11-16: Attack on Titan S1E2 on the
    // phone showed no Skip Intro at 01:12-01:18 although AniSkip HAS
    // the OP (54.312-144.312) — Miruro files no sync ids, so the
    // lookup never ran. The title search is the last resort that
    // makes the lookup run anyway.
    test('a bare title resolves Attack on Titan to MAL 16498 and '
        'returns its OP + ED', () async {
      final server = _FakeServer({
        'graphql.anilist.co': (_) => _FakeServer.json({
              'data': {
                'Media': {'idMal': 16498},
              },
            }),
        'skip-times/16498/2': (_) => _FakeServer.json(_aotEp2Aniskip()),
      });
      final service = AniskipService(Dio()..httpClientAdapter = server);

      final segments = await service.getSkipSegments(
        title: 'Attack on Titan',
        episode: 2,
        duration: 1466,
      );

      expect(segments.length, 2);
      expect(segments[0].type, SkipType.intro);
      expect(segments[0].startTime, 54.312);
      expect(segments[0].endTime, 144.312);
      expect(segments[1].type, SkipType.outro);
      expect(segments[1].startTime, 1372.218);
      expect(segments[1].endTime, 1451);
      // The title search ran first, then the AniSkip fetch with the
      // resolved MAL id.
      expect(
        server.requests
            .where((r) => r.uri.toString().contains('graphql.anilist.co'))
            .length,
        1,
      );
      expect(
        server.requests
            .where((r) => r.uri.toString().contains('skip-times/16498/2'))
            .length,
        1,
      );
    });

    test('a filed MAL id never touches AniList', () async {
      final server = _FakeServer({
        'skip-times/16498/2': (_) => _FakeServer.json(_aotEp2Aniskip()),
      });
      final service = AniskipService(Dio()..httpClientAdapter = server);

      final segments = await service.getSkipSegments(
        malId: 16498,
        title: 'Attack on Titan',
        episode: 2,
        duration: 1466,
      );

      expect(segments.length, 2);
      expect(
        server.requests
            .where((r) => r.uri.toString().contains('graphql.anilist.co')),
        isEmpty,
      );
    });

    test('a title AniList does not know is [] and never asks AniSkip',
        () async {
      final server = _FakeServer({
        'graphql.anilist.co': (_) => _FakeServer.json({
              'data': {
                'Media': {'idMal': null},
              },
            }),
      });
      final service = AniskipService(Dio()..httpClientAdapter = server);

      expect(
        await service.getSkipSegments(
          title: 'A Show That Does Not Exist Anywhere',
          episode: 1,
          duration: 1400,
        ),
        isEmpty,
      );
      expect(
        server.requests
            .where((r) => r.uri.toString().contains('skip-times/')),
        isEmpty,
      );
    });

    test('the title resolution is cached: a second episode asks '
        'AniList once, not twice', () async {
      // A different title from the first test, so the shared static
      // title cache cannot leak between tests.
      final server = _FakeServer({
        'graphql.anilist.co': (_) => _FakeServer.json({
              'data': {
                'Media': {'idMal': 21},
              },
            }),
        'skip-times/21/1000': (_) => _FakeServer.json({
              'found': true,
              'results': [
                {
                  'interval': {'startTime': 13.891, 'endTime': 123.834},
                  'skipType': 'op',
                  'skipId': '5bcf9262-b16f-40ad-9d12-8168e4ecad2d',
                  'episodeLength': 1430.721,
                },
              ],
            }),
      });
      final service = AniskipService(Dio()..httpClientAdapter = server);

      final first = await service.getSkipSegments(
        title: 'One Piece',
        episode: 1000,
        duration: 1430,
      );
      final second = await service.getSkipSegments(
        title: 'One Piece',
        episode: 1000,
        duration: 1430,
      );

      expect(first.length, 1);
      expect(second.length, 1);
      expect(
        server.requests
            .where((r) => r.uri.toString().contains('graphql.anilist.co'))
            .length,
        1,
        reason: 'the MAL id came from the title cache the second time',
      );
      expect(
        server.requests
            .where((r) => r.uri.toString().contains('skip-times/21/1000'))
            .length,
        1,
        reason: 'the segments came from the segment cache the second time',
      );
    });
  });
}
