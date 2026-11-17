import 'package:flutter/foundation.dart';

/// The App lock's wording (v1.0.1, English only). Kept beside the feature
/// rather than in the shared l10n tables; the parts that name the
/// biometric follow the platform: Face ID on iOS, face or fingerprint on
/// Android.
class AppLockStrings {
  const AppLockStrings(this.platform);

  /// The wording for the platform the app is running on.
  factory AppLockStrings.current() => AppLockStrings(defaultTargetPlatform);

  final TargetPlatform platform;

  bool get _android => platform == TargetPlatform.android;

  String get title => 'App lock';
  String get rowSubtitle => _android
      ? 'Passcode, face or fingerprint to open Zeus'
      : 'Passcode or Face ID to open Zeus';
  String get on => 'On';
  String get off => 'Off';

  String get masterSubtitle => 'Ask for a passcode when Zeus opens';
  String get passcodeRow => 'Passcode';
  String get setPasscode => 'Set passcode';
  String get changePasscode => 'Change passcode';
  String get biometricSwitch =>
      _android ? 'Unlock with face or fingerprint' : 'Unlock with Face ID';
  String get biometricSubtitle => _android
      ? 'Uses the face or fingerprint saved on this phone'
      : 'The passcode still works';
  String get legacyPrompt => _android
      ? 'App lock is using this phone\'s own screen lock. Set a passcode '
            'for Zeus to use your own code.'
      : 'App lock is using this iPhone\'s Face ID and passcode. Set a '
            'passcode for Zeus to use your own code.';
  String get footnote =>
      'Zeus locks when it opens and after a minute in the background. '
      'The passcode stays on this device and is never synced.';

  String get enterPasscode => 'Enter passcode';
  String get enterCurrent => 'Enter current passcode';
  String get enterNew => 'Enter a new passcode';
  String get confirmNew => 'Enter it again';
  String get mismatch => 'Passcodes did not match. Try again.';
  String get wrong => 'Wrong passcode';
  String tryAgainIn(Duration wait) {
    final s = wait.inSeconds < 1 ? 1 : wait.inSeconds;
    final text = s >= 60 ? '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}'
        : '$s s';
    return 'Too many wrong tries. Try again in $text';
  }

  String get forgot => 'Forgot passcode?';
  String get forgotReason => 'Confirm it\'s you to reset the Zeus passcode';
  String get forgotFailed => _android
      ? 'Could not confirm it\'s you with this phone\'s screen lock.'
      : 'Could not confirm it\'s you with this iPhone\'s passcode.';
  String get unlockReason => 'Unlock Zeus';
  String get confirmReason => 'Confirm it\'s you';
  String get useBiometric =>
      _android ? 'Use face or fingerprint' : 'Use Face ID';
  String get cancel => 'Cancel';
  String get delete => 'Delete';
  String get saveFailed => 'Could not save the passcode. Try again.';
  String get passcodeSet => 'Passcode set';
  String get passcodeChanged => 'Passcode changed';
}
