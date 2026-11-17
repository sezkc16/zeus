import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_lock_controller.dart';
import 'app_lock_passcode.dart';
import 'app_lock_strings.dart';

/// What a passcode flow is for.
enum AppLockPasscodeFlowKind {
  /// The lock screen: the current passcode (or biometrics) opens the app.
  unlock,

  /// Prove who you are (before turning the lock off or changing a switch).
  verify,

  /// Choose a first passcode: type it twice.
  create,

  /// The current passcode, then a new one twice.
  change,
}

enum _Stage { current, fresh, confirm }

/// The passcode page: a title, four dots and the app's own number pad.
///
/// One widget drives every passcode flow ([kind]) so the lock screen and
/// Settings look and behave the same: wrong tries shake and clear, five in
/// a row start a wait with a countdown, "Forgot passcode?" asks the phone
/// itself and then lets a new passcode be set.
class AppLockPasscodeFlow extends StatefulWidget {
  const AppLockPasscodeFlow({
    required this.controller,
    required this.kind,
    this.onDone,
    this.onCancel,
    this.showLogo = false,
    this.strings,
    super.key,
  });

  final AppLockController controller;
  final AppLockPasscodeFlowKind kind;

  /// Called once the flow ended well (verified, or a passcode was saved).
  /// The unlock flow needs none: the controller unlocks.
  final VoidCallback? onDone;

  /// Shows a Cancel button when set.
  final VoidCallback? onCancel;

  final bool showLogo;
  final AppLockStrings? strings;

  @override
  State<AppLockPasscodeFlow> createState() => AppLockPasscodeFlowState();
}

class AppLockPasscodeFlowState extends State<AppLockPasscodeFlow> {
  late _Stage _stage;
  String _entered = '';
  String? _first;
  String? _message;
  bool _busy = false;
  int _shake = 0;
  Timer? _ticker;

  /// Set once a forgotten passcode was reset through the phone's own
  /// authentication: the flow then ends after the new passcode is saved.
  bool _resetting = false;

  AppLockController get _c => widget.controller;
  AppLockStrings get _s => widget.strings ?? AppLockStrings.current();

  bool get _needsCurrent =>
      widget.kind != AppLockPasscodeFlowKind.create;

  @override
  void initState() {
    super.initState();
    _stage = _needsCurrent ? _Stage.current : _Stage.fresh;
    _c.addListener(_onController);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _c.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    _syncTicker();
    setState(() {});
  }

  /// Ticks once a second while a wait is running, for the countdown.
  void _syncTicker() {
    final waiting = _c.blockedFor > Duration.zero;
    if (waiting && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_c.blockedFor <= Duration.zero) {
          _ticker?.cancel();
          _ticker = null;
        }
        setState(() {});
      });
    } else if (!waiting && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  bool get _blocked => _stage == _Stage.current && _c.blockedFor > Duration.zero;

  String get _title => switch (_stage) {
    _Stage.current => widget.kind == AppLockPasscodeFlowKind.unlock
        ? _s.enterPasscode
        : _s.enterCurrent,
    _Stage.fresh => _s.enterNew,
    _Stage.confirm => _s.confirmNew,
  };

  void _reject(String message) {
    setState(() {
      _entered = '';
      _message = message;
      _shake++;
    });
    unawaited(HapticFeedback.heavyImpact());
  }

  void _digit(String d) {
    if (_busy || _blocked || _entered.length >= kAppLockPasscodeLength) return;
    setState(() {
      _entered += d;
      _message = null;
    });
    if (_entered.length == kAppLockPasscodeLength) unawaited(_complete());
  }

  void _delete() {
    if (_busy || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _complete() async {
    final code = _entered;
    switch (_stage) {
      case _Stage.current:
        setState(() => _busy = true);
        final result = widget.kind == AppLockPasscodeFlowKind.unlock
            ? await _c.submitPasscode(code)
            : await _c.checkPasscode(code);
        if (!mounted) return;
        setState(() => _busy = false);
        switch (result) {
          case AppLockPasscodeCheck.ok:
            _afterCurrent();
          case AppLockPasscodeCheck.wrong:
            _syncTicker();
            _reject(_s.wrong);
          case AppLockPasscodeCheck.blocked:
            _syncTicker();
            _reject(_s.wrong);
          case AppLockPasscodeCheck.missing:
            // Nothing saved to check against; the lock has fallen back to
            // the phone's own authentication and the parent rebuilds.
            setState(() => _entered = '');
        }
      case _Stage.fresh:
        setState(() {
          _first = code;
          _entered = '';
          _message = null;
          _stage = _Stage.confirm;
        });
      case _Stage.confirm:
        if (code != _first) {
          setState(() {
            _first = null;
            _stage = _Stage.fresh;
          });
          _reject(_s.mismatch);
          return;
        }
        setState(() => _busy = true);
        final saved = await _c.setPasscode(
          code,
          unlock: widget.kind == AppLockPasscodeFlowKind.unlock,
        );
        if (!mounted) return;
        setState(() => _busy = false);
        if (!saved) {
          setState(() {
            _first = null;
            _stage = _Stage.fresh;
          });
          _reject(_s.saveFailed);
          return;
        }
        widget.onDone?.call();
    }
  }

  void _afterCurrent() {
    if (widget.kind == AppLockPasscodeFlowKind.change) {
      setState(() {
        _entered = '';
        _message = null;
        _stage = _Stage.fresh;
      });
      return;
    }
    setState(() => _entered = '');
    widget.onDone?.call();
  }

  /// Face ID / fingerprint in place of the current passcode.
  Future<void> useBiometric() async {
    if (_busy || _stage != _Stage.current || !_c.biometricEnabled) return;
    if (widget.kind == AppLockPasscodeFlowKind.unlock) {
      await _c.unlockWithBiometric(_s.unlockReason);
      return;
    }
    final ok = await _c.confirmWithBiometric(_s.confirmReason);
    if (!mounted || !ok) return;
    _afterCurrent();
  }

  Future<void> _forgot() async {
    if (_busy) return;
    final ok = await _c.confirmDeviceOwner(_s.forgotReason);
    if (!mounted) return;
    if (!ok) {
      setState(() => _message = _s.forgotFailed);
      return;
    }
    setState(() {
      _resetting = true;
      _entered = '';
      _first = null;
      _message = null;
      _stage = _Stage.fresh;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _delete();
      return KeyEventResult.handled;
    }
    final ch = event.character;
    if (ch != null && ch.length == 1 && '0123456789'.contains(ch)) {
      _digit(ch);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wait = _c.blockedFor;
    final blocked = _blocked;
    final message = blocked ? _s.tryAgainIn(wait) : _message;
    final showBiometric = _stage == _Stage.current && _c.biometricEnabled;
    final showForgot = _stage == _Stage.current && !_resetting;

    final header = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showLogo) ...[
          Image.asset(
            'assets/images/ic_launcher_foreground.png',
            width: 72,
            height: 72,
            errorBuilder: (_, _, _) => const SizedBox(width: 72, height: 72),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          _title,
          key: const ValueKey('app-lock-pad-title'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 20),
        _Shake(
          tick: _shake,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < kAppLockPasscodeLength; i++)
                Container(
                  key: ValueKey('app-lock-dot-$i'),
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _entered.length
                        ? scheme.primary
                        : Colors.transparent,
                    border: Border.all(
                      color: i < _entered.length
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      width: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: 264,
          height: 36,
          child: Text(
            message ?? '',
            key: const ValueKey('app-lock-pad-message'),
            textAlign: TextAlign.center,
            maxLines: 2,
            style: theme.textTheme.bodySmall?.copyWith(
              color: message == null ? scheme.onSurfaceVariant : scheme.error,
            ),
          ),
        ),
      ],
    );

    Widget key(String d) => _PadKey(
      key: ValueKey('app-lock-key-$d'),
      onTap: blocked || _busy ? null : () => _digit(d),
      child: Text(
        d,
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface.withValues(alpha: blocked ? 0.38 : 1),
        ),
      ),
    );

    final pad = SizedBox(
      width: 264,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [for (final d in row) key(d)],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (showBiometric)
                _PadKey(
                  key: const ValueKey('app-lock-key-biometric'),
                  plain: true,
                  semanticLabel: _s.useBiometric,
                  onTap: _busy ? null : () => unawaited(useBiometric()),
                  child: Icon(
                    _s.platform == TargetPlatform.iOS
                        ? Icons.face_unlock_rounded
                        : Icons.fingerprint_rounded,
                    size: 34,
                    color: scheme.primary,
                  ),
                )
              else
                const SizedBox(width: 72, height: 72),
              key('0'),
              _PadKey(
                key: const ValueKey('app-lock-key-delete'),
                plain: true,
                semanticLabel: _s.delete,
                onTap: _entered.isEmpty || _busy ? null : _delete,
                child: Icon(
                  Icons.backspace_outlined,
                  size: 26,
                  color: scheme.onSurface.withValues(
                    alpha: _entered.isEmpty ? 0.38 : 1,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    final links = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showForgot)
          TextButton(
            key: const ValueKey('app-lock-forgot'),
            onPressed: _busy ? null : () => unawaited(_forgot()),
            child: Text(_s.forgot),
          ),
        if (widget.onCancel != null)
          TextButton(
            key: const ValueKey('app-lock-cancel'),
            onPressed: widget.onCancel,
            child: Text(_s.cancel),
          ),
      ],
    );

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > constraints.maxHeight;
          final content = wide
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [header, links],
                    ),
                    const SizedBox(width: 40),
                    pad,
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    header,
                    const SizedBox(height: 8),
                    pad,
                    const SizedBox(height: 8),
                    SizedBox(height: 48, child: links),
                  ],
                );
          // Scales down (never up) so the whole pad fits a short landscape
          // phone or a small cover screen without scrolling.
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: FittedBox(fit: BoxFit.scaleDown, child: content),
            ),
          );
        },
      ),
    );
  }
}

/// One round key of the pad.
class _PadKey extends StatelessWidget {
  const _PadKey({
    required this.child,
    required this.onTap,
    this.plain = false,
    this.semanticLabel,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// No filled circle behind it (the biometric and delete keys).
  final bool plain;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: plain
            ? Colors.transparent
            : scheme.onSurface.withValues(alpha: 0.08),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(width: 72, height: 72, child: Center(child: child)),
        ),
      ),
    );
  }
}

/// Shakes its child sideways once each time [tick] goes up. Still when the
/// system asks for reduced motion.
class _Shake extends StatelessWidget {
  const _Shake({required this.tick, required this.child});

  final int tick;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (tick == 0 || MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      key: ValueKey(tick),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 360),
      builder: (context, t, child) {
        // Three swings that die out.
        final dx = 10 * (1 - t) * _wave(t * 3);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: child,
    );
  }

  static double _wave(double x) {
    final f = x - x.floorToDouble();
    return f < 0.5 ? 4 * f - 1 : 3 - 4 * f;
  }
}
