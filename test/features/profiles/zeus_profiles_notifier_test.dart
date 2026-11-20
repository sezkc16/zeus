// Profiles Build 1: the profiles notifier — fetch + migration flags,
// PIN verify + lockout, switching, PIN change, logout clear.
//
// NOTE: written but NOT run yet — the b107 agent is running flutter on
// this VM and two flutter processes OOM it. Run after b107 lands:
// `flutter test test/features/profiles/`.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/storage/storage_service.dart';
import 'package:zorox/features/app_lock/app_lock_passcode.dart';
import 'package:zorox/features/profiles/data/zeus_profile.dart';
import 'package:zorox/features/profiles/data/zeus_profiles_client.dart';
import 'package:zorox/features/profiles/data/zeus_profiles_notifier.dart';

/// In-memory settings box: the notifier only ever touches getString /
/// setString / the profile-box switches, never Hive itself.
class _FakeStorage extends StorageService {
  final values = <String, String>{};
  String? activeProfileId;
  bool legacyNonEmpty = false;
  int copyCalls = 0;
  int clearLegacyCalls = 0;

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> setActiveZeusProfile(String? profileId) async {
    activeProfileId = profileId;
  }

  @override
  bool get legacyHistoryOrLibraryNonEmpty => legacyNonEmpty;

  @override
  Future<void> copyLegacyHistoryAndLibraryToZeusProfile(
    String profileId,
  ) async {
    copyCalls++;
  }

  @override
  Future<void> clearLegacyHistoryAndLibrary() async {
    clearLegacyCalls++;
  }
}

/// The server's profile list, in memory. Records are made with a fast
/// round count except where the test says otherwise — the notifier only
/// ever verifies them.
class _FakeProfilesClient extends ZeusProfilesClient {
  _FakeProfilesClient() : super(dio: Dio());

  List<ZeusProfile> serverProfiles = [];

  ZeusProfile profile(String id, String pin, {String name = 'Suresh'}) {
    return ZeusProfile(
      id: id,
      name: name,
      color: 'gold',
      pinRecord: AppLockPasscodeHash.create(pin, rounds: 1000),
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );
  }

  @override
  Future<List<ZeusProfile>> fetchZeusProfiles(
    String baseUrl,
    String token,
  ) async => List.of(serverProfiles);

  @override
  Future<ZeusProfile> createZeusProfile(
    String baseUrl,
    String token, {
    required String name,
    required String color,
    required String pinRecord,
  }) async {
    final created = ZeusProfile(
      id: 'p_new${serverProfiles.length}',
      name: name,
      color: color,
      pinRecord: pinRecord,
      createdAt: DateTime.fromMillisecondsSinceEpoch(2),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
    );
    serverProfiles.add(created);
    return created;
  }

  @override
  Future<ZeusProfile> updateZeusProfile(
    String baseUrl,
    String token,
    String profileId, {
    String? name,
    String? color,
    String? pinRecord,
    String? accountPassword,
  }) async {
    final i = serverProfiles.indexWhere((p) => p.id == profileId);
    final updated = serverProfiles[i].copyWith(
      name: name,
      color: color,
      pinRecord: pinRecord,
    );
    serverProfiles[i] = updated;
    return updated;
  }

  @override
  Future<void> deleteZeusProfile(
    String baseUrl,
    String token,
    String profileId,
    String accountPassword,
  ) async {
    serverProfiles.removeWhere((p) => p.id == profileId);
  }
}

void main() {
  late _FakeStorage storage;
  late _FakeProfilesClient client;
  late ProviderContainer container;

  setUp(() {
    storage = _FakeStorage();
    client = _FakeProfilesClient();
    container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        zeusProfilesClientProvider.overrideWithValue(client),
      ],
    );
  });

  tearDown(() => container.dispose());

  ZeusProfilesNotifier get notifier =>
      container.read(zeusProfilesProvider.notifier);

  Future<void> seed({String pin = '1234', String id = 'p_one'}) async {
    client.serverProfiles = [client.profile(id, pin)];
    await notifier.refreshAfterAuth(
      baseUrl: 'https://example.workers.dev',
      token: 'tok',
    );
  }

  group('ZeusProfilesNotifier', () {
    test('empty server list means the first profile still needs its PIN', () async {
      await notifier.refreshAfterAuth(
        baseUrl: 'https://example.workers.dev',
        token: 'tok',
      );
      final state = container.read(zeusProfilesProvider);
      expect(state.fetched, isTrue);
      expect(state.profiles, isEmpty);
      expect(state.needsDefaultPin, isTrue);
      expect(state.legacyDataPendingMove, isFalse);
    });

    test('profiles + legacy data means a move is pending (Build 2 prompt)', () async {
      storage.legacyNonEmpty = true;
      await seed();
      final state = container.read(zeusProfilesProvider);
      expect(state.profiles, hasLength(1));
      expect(state.needsDefaultPin, isFalse);
      expect(state.legacyDataPendingMove, isTrue);
    });

    test('no legacy data, no pending move', () async {
      await seed();
      expect(
        container.read(zeusProfilesProvider).legacyDataPendingMove,
        isFalse,
      );
    });

    test('correct PIN verifies and clears the counters', () async {
      await seed();
      final check = await notifier.checkZeusProfilePin('p_one', '1234');
      expect(check, AppLockPasscodeCheck.ok);
      expect(storage.values.containsKey('profiles_pin_attempts_p_one'), isFalse);
    });

    test('wrong PIN 5x then blocked, with the app-lock wait', () async {
      await seed();
      for (var i = 0; i < 5; i++) {
        expect(
          await notifier.checkZeusProfilePin('p_one', '0000'),
          AppLockPasscodeCheck.wrong,
        );
      }
      expect(
        await notifier.checkZeusProfilePin('p_one', '0000'),
        AppLockPasscodeCheck.blocked,
      );
      // Even the right PIN is refused while blocked.
      expect(
        await notifier.checkZeusProfilePin('p_one', '1234'),
        AppLockPasscodeCheck.blocked,
      );
      expect(
        notifier.blockedForZeusProfile('p_one'),
        greaterThan(Duration.zero),
      );
      expect(
        notifier.blockedForZeusProfile('p_one'),
        lessThanOrEqualTo(const Duration(seconds: 31)),
      );
    });

    test('unknown profile verifies as missing', () async {
      await seed();
      expect(
        await notifier.checkZeusProfilePin('p_nope', '1234'),
        AppLockPasscodeCheck.missing,
      );
    });

    test('switching points the storage at the profile boxes', () async {
      await seed();
      await notifier.switchZeusProfile('p_one');
      expect(storage.activeProfileId, 'p_one');
      expect(
        storage.values[ZeusProfileCacheKeys.activeId],
        'p_one',
      );
      expect(
        container.read(zeusProfilesProvider).activeProfileId,
        'p_one',
      );
    });

    test('switching to an unknown id is a no-op', () async {
      await seed();
      await notifier.switchZeusProfile('p_nope');
      expect(storage.activeProfileId, isNull);
      expect(
        container.read(zeusProfilesProvider).activeProfileId,
        isNull,
      );
    });

    test('create makes a 100,000-round record and caches the list', () async {
      await seed();
      final created = await notifier.createZeusProfile(
        name: 'Aarav',
        color: 'teal',
        pin: '5678',
      );
      expect(created, isNotNull);
      expect(created!.name, 'Aarav');
      expect(created.pinRecord.startsWith('v1\$100000\$'), isTrue);
      // The real record verifies (one 100k round trip, on purpose).
      expect(AppLockPasscodeHash.verify('5678', created.pinRecord), isTrue);
      expect(container.read(zeusProfilesProvider).profiles, hasLength(2));
      expect(
        storage.values.containsKey(ZeusProfileCacheKeys.list),
        isTrue,
      );
    });

    test('create rejects a bad name, colour, or PIN', () async {
      await seed();
      expect(
        await notifier.createZeusProfile(name: '', color: 'gold', pin: '1234'),
        isNull,
      );
      expect(
        await notifier.createZeusProfile(
          name: 'Aarav',
          color: 'pink',
          pin: '1234',
        ),
        isNull,
      );
      expect(
        await notifier.createZeusProfile(
          name: 'Aarav',
          color: 'gold',
          pin: '123',
        ),
        isNull,
      );
      expect(container.read(zeusProfilesProvider).profiles, hasLength(1));
    });

    test('PIN change replaces the record and resets the counters', () async {
      await seed();
      // One wrong try first, so the reset is visible.
      await notifier.checkZeusProfilePin('p_one', '0000');
      final ok = await notifier.updateZeusProfilePin(
        profileId: 'p_one',
        newPin: '4321',
        accountPassword: 'account-password',
      );
      expect(ok, isTrue);
      expect(
        await notifier.checkZeusProfilePin('p_one', '4321'),
        AppLockPasscodeCheck.ok,
      );
      expect(
        await notifier.checkZeusProfilePin('p_one', '1234'),
        AppLockPasscodeCheck.wrong,
      );
    });

    test('logout clears the cache, the active profile and the counters', () async {
      await seed();
      await notifier.switchZeusProfile('p_one');
      await notifier.checkZeusProfilePin('p_one', '0000');
      await notifier.clearLocalState();
      final state = container.read(zeusProfilesProvider);
      expect(state.profiles, isEmpty);
      expect(state.activeProfileId, isNull);
      expect(storage.activeProfileId, isNull);
      expect(storage.values.containsKey(ZeusProfileCacheKeys.list), isFalse);
      expect(
        storage.values.containsKey('profiles_pin_attempts_p_one'),
        isFalse,
      );
    });
  });
}
