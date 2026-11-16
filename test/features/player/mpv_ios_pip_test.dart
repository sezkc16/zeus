/// iOS Picture-in-Picture for the mpv player (+28).
///
/// The Dart side only: the channel contract with the native
/// `ZoroxMpvPipPlugin`, the decoder the PiP setting selects, and the
/// setting's default. The native half (frame tap, sample-buffer layer,
/// background delivery) cannot run on this VM and is a phone test — see
/// the report.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/presentation/mpv/mpv_ios_options.dart';
import 'package:zorox/features/settings/presentation/player_settings_provider.dart';
import 'package:zorox_mpv_pip/zorox_mpv_pip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'dev.toji.zorox.player/pip_mpv_ios';
  const channel = MethodChannel(channelName);

  group('mpvIosHwdec', () {
    test('PiP mode copies VideoToolbox frames to system memory', () {
      // Hardware decode, software render: the only combination the
      // software renderer can read.
      expect(mpvIosHwdec(pipEnabled: true), 'videotoolbox-copy');
    });

    test('normal mode keeps plain VideoToolbox', () {
      expect(mpvIosHwdec(pipEnabled: false), 'videotoolbox');
    });
  });

  group('PlayerSettings.iosMpvPip', () {
    test('off by default, so every install keeps the hardware renderer', () {
      expect(const PlayerSettings().iosMpvPip, isFalse);
    });

    test('copyWith sets it', () {
      expect(
        const PlayerSettings().copyWith(iosMpvPip: true).iosMpvPip,
        isTrue,
      );
    });
  });

  group('MpvPipIos', () {
    late List<MethodCall> calls;
    late MpvPipIos pip;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            if (call.method == 'isSupported') return true;
            if (call.method == 'enterPip') return true;
            if (call.method == 'diag') {
              return 'layer=2 inWindow=true possible=true '
                  'audio=playback frames=42 primed=true primeAgeMs=120 '
                  'primes=3';
            }
            return null;
          });
      pip = MpvPipIos();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    /// Delivers a native-to-Dart call the way the engine would.
    Future<void> sendNative(String method, [dynamic arguments]) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channelName,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (ByteData? data) {},
          );
    }

    Future<void> preparePip() => pip.prepare(
      position: const Duration(seconds: 5),
      duration: const Duration(minutes: 2),
      playing: true,
    );

    test('isSupported asks the native side', () async {
      expect(await MpvPipIos.isSupported, isTrue);
      expect(calls.map((c) => c.method), contains('isSupported'));
    });

    test('isSupported is false when the native side throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: 'nope');
          });
      expect(await MpvPipIos.isSupported, isFalse);
    });

    test(
      'prepare sends position/duration/playing and marks prepared',
      () async {
        await preparePip();
        expect(pip.isPrepared, isTrue);
        final call = calls.singleWhere((c) => c.method == 'prepare');
        expect(call.arguments['position'], 5.0);
        expect(call.arguments['duration'], 120.0);
        expect(call.arguments['playing'], isTrue);
        expect(call.arguments['rate'], 1.0);
      },
    );

    test('updateState is a no-op before prepare', () async {
      await pip.updateState(
        position: Duration.zero,
        duration: Duration.zero,
        playing: false,
      );
      expect(calls, isEmpty);
    });

    test('updateState syncs after prepare', () async {
      await preparePip();
      calls.clear();
      await pip.updateState(
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 2),
        playing: false,
      );
      final call = calls.singleWhere((c) => c.method == 'updateState');
      expect(call.arguments['position'], 10.0);
      expect(call.arguments['playing'], isFalse);
    });

    test('enterPiP is false before prepare, true after', () async {
      expect(await pip.enterPiP(), isFalse);
      expect(calls, isEmpty);
      await preparePip();
      expect(await pip.enterPiP(), isTrue);
      expect(calls.map((c) => c.method), contains('enterPip'));
    });

    test('enterPiP reports the native failure instead of throwing', () async {
      await preparePip();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            if (call.method == 'enterPip') {
              throw PlatformException(
                code: 'not_possible',
                message:
                    'layer=-1 inWindow=false possible=false '
                    'audio=playback frames=0',
              );
            }
            return null;
          });
      String? reason;
      pip.onPipFailed = (r) => reason = r;
      expect(await pip.enterPiP(), isFalse);
      // The message, not the code: it carries the native diag string.
      expect(reason, contains('possible=false'));
    });

    test(
      'a failed enterPiP leaves the bridge prepared, so a retry is '
      'possible (+30)',
      () async {
        await preparePip();
        var attempts = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              if (call.method == 'enterPip') {
                attempts++;
                // First attempt: the layer held no frame yet (+29).
                if (attempts == 1) {
                  throw PlatformException(
                    code: 'not_possible',
                    message: 'possible=false primed=false',
                  );
                }
                // Second attempt, after the native prime: opens.
                return true;
              }
              return null;
            });
        String? reason;
        pip.onPipFailed = (r) => reason = r;
        expect(await pip.enterPiP(), isFalse);
        expect(reason, contains('primed=false'));
        // The failure must not tear the bridge down: the retry goes
        // through the same prepared bridge.
        expect(pip.isPrepared, isTrue);
        expect(await pip.enterPiP(), isTrue);
        expect(attempts, 2);
      },
    );

    test('exitPiP is a no-op before prepare', () async {
      await pip.exitPiP();
      expect(calls, isEmpty);
    });

    test('native pipStarted marks inPip and fires the callback', () async {
      var started = false;
      pip.onPipStarted = () => started = true;
      await preparePip();
      await sendNative('pipStarted');
      expect(pip.inPip, isTrue);
      expect(started, isTrue);
    });

    test('native pipStopped clears inPip and reports restored', () async {
      bool? restored;
      pip.onPipStopped = (r) => restored = r;
      await preparePip();
      await sendNative('pipStarted');
      await sendNative('pipStopped', {'restored': true});
      expect(pip.inPip, isFalse);
      expect(restored, isTrue);
    });

    test('native pipStopped with restored false is still a stop', () async {
      bool? restored;
      pip.onPipStopped = (r) => restored = r;
      await preparePip();
      await sendNative('pipStarted');
      await sendNative('pipStopped', {'restored': false});
      expect(pip.inPip, isFalse);
      expect(restored, isFalse);
    });

    test('native pipSetPlaying and pipSkip route through', () async {
      bool? playing;
      int? skipped;
      pip.onPipSetPlaying = (p) => playing = p;
      pip.onPipSkip = (s) => skipped = s;
      await preparePip();
      await sendNative('pipSetPlaying', false);
      await sendNative('pipSkip', -10);
      expect(playing, isFalse);
      expect(skipped, -10);
    });

    test('native pipFailed routes the reason', () async {
      String? reason;
      pip.onPipFailed = (r) => reason = r;
      await preparePip();
      await sendNative('pipFailed', {'reason': 'boom | diag'});
      expect(reason, 'boom | diag');
    });

    test('diag asks the native side', () async {
      await preparePip();
      final d = await pip.diag;
      expect(d, contains('frames=42'));
      // +30: the diag carries the prime state, so a future "PiP
      // doesn't open" can be told apart from a layer problem.
      expect(d, contains('primed=true'));
      expect(d, contains('primeAgeMs=120'));
    });

    test('dispose releases and clears prepared and inPip', () async {
      await preparePip();
      await sendNative('pipStarted');
      await pip.dispose();
      expect(calls.map((c) => c.method), contains('release'));
      expect(pip.isPrepared, isFalse);
      expect(pip.inPip, isFalse);
    });

    test('dispose without prepare only clears the handler', () async {
      await pip.dispose();
      expect(calls, isEmpty);
      expect(pip.isPrepared, isFalse);
    });
  });

  group('MpvPipIos off iOS', () {
    test('isSupported is false without touching the channel', () async {
      // No platform override here: the host is Linux, so the gate
      // answers before any channel call.
      expect(await MpvPipIos.isSupported, isFalse);
    });

    test('prepare is a no-op without touching the channel', () async {
      final p = MpvPipIos();
      await p.prepare(
        position: Duration.zero,
        duration: Duration.zero,
        playing: false,
      );
      expect(p.isPrepared, isFalse);
    });
  });
}
