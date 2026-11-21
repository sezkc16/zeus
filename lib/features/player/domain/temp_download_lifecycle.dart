/// Build 119: deletes the Instant temp-download files when Zeus
/// closes. The files live as long as Zeus is open (the player
/// closing does not delete them), so the close is when they are due
/// to go. Only [AppLifecycleState.detached] — switching to another
/// app for a moment ([AppLifecycleState.paused]) must NOT wipe them,
/// or Continue Watching would re-download on return. Best effort:
/// a kill may never deliver detach, so the launch sweep in main.dart
/// is the safety net that clears whatever is left behind.
///
/// The temp directory arrives as a provider (main.dart passes
/// [appTempDirectory]) so this stays unit-testable without importing
/// the app's storage layer.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'temp_download.dart';

class TempDownloadLifecycleObserver extends WidgetsBindingObserver {
  TempDownloadLifecycleObserver({
    required Future<Directory> Function() directoryProvider,
  }) : _directoryProvider = directoryProvider;

  final Future<Directory> Function() _directoryProvider;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_directoryProvider().then(TempDownload.sweepStale));
    }
  }
}
