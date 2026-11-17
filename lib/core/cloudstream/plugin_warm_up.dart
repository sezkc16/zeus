import 'package:flutter/widgets.dart';

/// Says when the background plugin warm-up (v7) should stop: the system
/// warned about memory, or the app left the foreground. Either one ends the
/// warm-up for this launch — the plugins not reached are loaded when they
/// are first used, as they always were.
///
/// iOS exposes Low Power Mode to native code only, and nothing in the app
/// bridges it, so it is not one of the signals here.
class PluginWarmUpGuard with WidgetsBindingObserver {
  bool _stop = false;
  bool _attached = false;

  /// Whether the warm-up should load no more plugins.
  bool get shouldStop => _stop;

  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didHaveMemoryPressure() => _stop = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stop = true;
  }
}
