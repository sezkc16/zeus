// v8 (2.9.19+64): Zeus Account works with no setup. The built-in sync
// server is used until the viewer saves one of their own, and clearing that
// goes back to the default. The dialog wears the app accent, not gold.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/theme/accent_color.dart';
import 'package:zorox/core/theme/app_theme.dart';
import 'package:zorox/features/account/data/zorox_account_notifier.dart';
import 'package:zorox/features/account/data/zorox_sync_client.dart';
import 'package:zorox/features/account/presentation/zorox_account_section.dart';

/// Answers every request with one fixed status and JSON body.
class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
  final List<String> urls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri.toString());
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeAccount extends ZoroxAccountNotifier {
  _FakeAccount(this._state);

  final ZoroxAccountState _state;

  @override
  ZoroxAccountState build() => _state;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ZoroxAccountState state = const ZoroxAccountState(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [zoroxAccountProvider.overrideWith(() => _FakeAccount(state))],
      child: MaterialApp(
        theme: AppTheme.createDarkTheme(
          null,
          seedColor: ZoroxAccent.green.color,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('which sync server is used', () {
    test('the built-in server when nothing is saved', () {
      expect(kZoroxSyncWorkerUrl, 'https://zorox-sync.deepace115.workers.dev');
      expect(effectiveSyncServerUrl(null), kZoroxSyncWorkerUrl);
      expect(effectiveSyncServerUrl(''), kZoroxSyncWorkerUrl);
      expect(effectiveSyncServerUrl('   '), kZoroxSyncWorkerUrl);
      // It passes the same check every account call makes first.
      ZoroxSyncClient.checkBaseUrl(effectiveSyncServerUrl(null));
    });

    test('a saved server wins, without its trailing slash', () {
      expect(
        effectiveSyncServerUrl(' https://my.example.workers.dev/ '),
        'https://my.example.workers.dev',
      );
    });

    test('a fresh account state is already set up, on the default', () {
      const state = ZoroxAccountState();
      expect(state.cloudConfigured, isTrue);
      expect(state.usingDefaultServer, isTrue);
      expect(state.workerUrl, kZoroxSyncWorkerUrl);
    });
  });

  testWidgets('the dialog no longer says cloud sync is not set up', (
    tester,
  ) async {
    await _pump(tester, const ZoroxAccountDialog());
    expect(find.text('Zeus Account'), findsOneWidget);
    expect(find.textContaining('not set up'), findsNothing);
    expect(find.text('Log in'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
  });

  testWidgets('the dialog wears the app accent, not gold', (tester) async {
    await _pump(tester, const ZoroxAccountDialog());
    final context = tester.element(find.text('Log in'));
    final primary = Theme.of(context).colorScheme.primary;
    final hsl = HSLColor.fromColor(primary);
    // Green accent: hue in the green band, nowhere near gold (~46).
    expect(hsl.hue, inInclusiveRange(90, 170));
    final material = tester.widget<Material>(
      find
          .ancestor(of: find.text('Log in'), matching: find.byType(Material))
          .first,
    );
    expect(material.color, primary);
  });

  testWidgets('the Sync server editor is empty on the default', (tester) async {
    await _pump(tester, const ZoroxWorkerUrlDialog());
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.textContaining('built-in sync server'), findsOneWidget);
  });

  testWidgets('the Sync server editor shows a saved server', (tester) async {
    await _pump(
      tester,
      const ZoroxWorkerUrlDialog(),
      state: const ZoroxAccountState(
        workerUrl: 'https://my.example.workers.dev',
        usingDefaultServer: false,
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'https://my.example.workers.dev',
    );
  });

  group('an expired session', () {
    test('a 401 from the server is told apart from other errors', () async {
      final adapter = _FixedAdapter(401, {
        'ok': false,
        'error': 'Session expired. Log in again.',
      });
      final client = ZoroxSyncClient(dio: Dio()..httpClientAdapter = adapter);
      Object? caught;
      try {
        await client.upload(effectiveSyncServerUrl(null), 'old-token', {});
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<ZoroxSyncException>());
      final error = caught! as ZoroxSyncException;
      expect(error.sessionExpired, isTrue);
      expect(error.message, 'Session expired. Log in again.');
      expect(adapter.urls.single, '$kZoroxSyncWorkerUrl/sync');
    });

    test('a server error is not an expired session', () async {
      final client = ZoroxSyncClient(
        dio: Dio()
          ..httpClientAdapter = _FixedAdapter(500, {
            'ok': false,
            'error': 'Server not configured.',
          }),
      );
      await expectLater(
        client.login(kZoroxSyncWorkerUrl, 'a@b.co', 'password1'),
        throwsA(
          isA<ZoroxSyncException>().having(
            (e) => e.sessionExpired,
            'sessionExpired',
            isFalse,
          ),
        ),
      );
    });

    testWidgets('the Zeus Account card says to log in again', (tester) async {
      await _pump(
        tester,
        const SingleChildScrollView(child: ZoroxAccountSection()),
        state: const ZoroxAccountState(
          email: 'a@b.co',
          sessionExpired: true,
          error: kSessionExpiredMessage,
        ),
      );
      expect(
        find.text('Session expired — tap to log in again'),
        findsOneWidget,
      );
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Sync now'), findsNothing);
    });
  });
}
