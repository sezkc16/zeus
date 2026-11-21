/// Build 119: the Instant temp-download files live as long as Zeus is
/// open and are deleted only when Zeus closes. The app-lifecycle
/// observer sweeps them on detach — and must NOT sweep them on pause
/// (switching to another app for a moment), or Continue Watching
/// would re-download on return.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/temp_download.dart';
import 'package:zorox/features/player/domain/temp_download_lifecycle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late TempDownloadLifecycleObserver observer;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zeus_temp_lifecycle_');
    observer = TempDownloadLifecycleObserver(
      directoryProvider: () async => dir,
    );
    WidgetsBinding.instance.addObserver(observer);
  });

  tearDown(() async {
    WidgetsBinding.instance.removeObserver(observer);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> keptFile() async {
    final file = File('${dir.path}/${kTempDownloadFilePrefix}abc123.mkv');
    await file.writeAsBytes(const [1, 2, 3]);
    return file;
  }

  Future<void> waitForGone(File file) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (await file.exists()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for ${file.path} to be deleted');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  testWidgets('detached (Zeus closed) deletes the kept files', (tester) async {
    final file = await keptFile();
    // The sweep is real async (directory listing + deletes): run it
    // outside the test's fake clock, or the delays never fire.
    await tester.runAsync(() async {
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.detached,
      );
      await waitForGone(file);
    });
    expect(await file.exists(), isFalse);
  });

  testWidgets('paused (switched apps for a moment) keeps the files',
      (tester) async {
    final file = await keptFile();
    await tester.runAsync(() async {
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    expect(await file.exists(), isTrue);
  });
}
