import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// How many digits the app's own passcode has.
const int kAppLockPasscodeLength = 4;

/// Wrong tries allowed before the first wait.
const int kAppLockFreeAttempts = 5;

/// The first wait after [kAppLockFreeAttempts] wrong tries; it doubles with
/// each further wrong try up to [kAppLockMaxWait].
const Duration kAppLockFirstWait = Duration(seconds: 30);

/// The longest wait between tries.
const Duration kAppLockMaxWait = Duration(minutes: 5);

/// Whether [code] is a well-formed passcode: exactly four digits.
bool isValidAppLockPasscode(String code) =>
    code.length == kAppLockPasscodeLength &&
    code.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

/// How long to wait after the [failedAttempts]-th wrong try in a row, or
/// zero while tries are still free: 30 s after the 5th, then 1 min, 2 min,
/// 4 min, and 5 min from there on.
Duration appLockWaitAfter(int failedAttempts) {
  if (failedAttempts < kAppLockFreeAttempts) return Duration.zero;
  final doublings = min(failedAttempts - kAppLockFreeAttempts, 16);
  final seconds = kAppLockFirstWait.inSeconds * (1 << doublings);
  return seconds >= kAppLockMaxWait.inSeconds
      ? kAppLockMaxWait
      : Duration(seconds: seconds);
}

/// The passcode as it is kept: never the digits, only a salted
/// PBKDF2-HMAC-SHA256 hash with a random salt made on this install.
///
/// Stored as `v1$<rounds>$<salt base64>$<hash base64>`.
class AppLockPasscodeHash {
  AppLockPasscodeHash._();

  static const int _rounds = 10000;
  static const int _saltLength = 16;

  /// A new record for [passcode] with a fresh random salt.
  ///
  /// [rounds] defaults to the app lock's 10,000. Profiles pass 100,000
  /// ([kZeusProfilePinRounds]): their record leaves the device, so it
  /// gets the account-password count. `verify` already parses any rounds.
  static String create(String passcode, {Random? random, int rounds = _rounds}) {
    final rng = random ?? Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(_saltLength, (_) => rng.nextInt(256)),
    );
    final hash = _pbkdf2(utf8.encode(passcode), salt, rounds);
    return 'v1\$$rounds\$${base64.encode(salt)}\$${base64.encode(hash)}';
  }

  /// Whether [record] is a record this class can check.
  static bool isWellFormed(String? record) => _parse(record) != null;

  /// Whether [passcode] is the one [record] was made from. A record that
  /// cannot be read matches nothing.
  static bool verify(String passcode, String? record) {
    final parsed = _parse(record);
    if (parsed == null) return false;
    final hash = _pbkdf2(utf8.encode(passcode), parsed.salt, parsed.rounds);
    return _constantTimeEquals(hash, parsed.hash);
  }

  static ({int rounds, Uint8List salt, Uint8List hash})? _parse(
    String? record,
  ) {
    if (record == null) return null;
    final parts = record.split(r'$');
    if (parts.length != 4 || parts[0] != 'v1') return null;
    final rounds = int.tryParse(parts[1]);
    if (rounds == null || rounds < 1 || rounds > 1000000) return null;
    try {
      final salt = base64.decode(parts[2]);
      final hash = base64.decode(parts[3]);
      if (salt.isEmpty || hash.length != 32) return null;
      return (rounds: rounds, salt: salt, hash: hash);
    } catch (_) {
      return null;
    }
  }

  /// PBKDF2 with HMAC-SHA256, one 32-byte block.
  static Uint8List _pbkdf2(List<int> password, List<int> salt, int rounds) {
    final hmac = Hmac(sha256, password);
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < rounds; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Where the app lock keeps what it must remember besides the on/off
/// switch. The small flags are read synchronously (the lock decides before
/// the first frame); the passcode record is read when a passcode is typed.
///
/// None of this is ever part of a backup or the account sync.
abstract class AppLockStorage {
  /// Whether a custom passcode has been set.
  bool get hasPasscode;
  Future<void> setHasPasscode(bool value);

  /// Whether Face ID / fingerprint may unlock instead of the passcode.
  bool get biometricEnabled;
  Future<void> setBiometricEnabled(bool value);

  /// Wrong passcode tries in a row.
  int get failedAttempts;

  /// Until when (ms since epoch) no passcode is accepted; 0 for none.
  int get blockedUntilMs;
  Future<void> setAttempts({
    required int failedAttempts,
    required int blockedUntilMs,
  });

  Future<String?> readPasscodeRecord();
  Future<void> writePasscodeRecord(String record);
  Future<void> deletePasscodeRecord();
}

/// [AppLockStorage] that forgets everything with the object: the default
/// for a controller built without storage, and what tests use.
class InMemoryAppLockStorage implements AppLockStorage {
  InMemoryAppLockStorage({
    this.hasPasscode = false,
    this.biometricEnabled = false,
    this.failedAttempts = 0,
    this.blockedUntilMs = 0,
    this.record,
  });

  @override
  bool hasPasscode;
  @override
  bool biometricEnabled;
  @override
  int failedAttempts;
  @override
  int blockedUntilMs;
  String? record;

  @override
  Future<void> setHasPasscode(bool value) async => hasPasscode = value;

  @override
  Future<void> setBiometricEnabled(bool value) async =>
      biometricEnabled = value;

  @override
  Future<void> setAttempts({
    required int failedAttempts,
    required int blockedUntilMs,
  }) async {
    this.failedAttempts = failedAttempts;
    this.blockedUntilMs = blockedUntilMs;
  }

  @override
  Future<String?> readPasscodeRecord() async => record;

  @override
  Future<void> writePasscodeRecord(String value) async => record = value;

  @override
  Future<void> deletePasscodeRecord() async => record = null;
}
