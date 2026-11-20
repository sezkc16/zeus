// Profiles Build 1: the backup carries its profile (schema 3), and old
// backups still restore with no profile.
//
// NOTE: written but NOT run yet — the b107 agent is running flutter on
// this VM and two flutter processes OOM it. Run after b107 lands:
// `flutter test test/features/account/`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/account/data/zorox_backup.dart';

void main() {
  group('ZoroxBackup profiles (schema 3)', () {
    test('round trip keeps the profile id', () {
      final backup = ZoroxBackup(
        exportedAt: 1763390000000,
        history: const [
          {'key': 'k', 'entry': {'position': 5}},
        ],
        library: const [],
        profileId: 'p_9f2c41a77d3e4b08',
      );
      final back = ZoroxBackup.fromJson(
        jsonDecode(jsonEncode(backup.toJson())) as Map<String, dynamic>,
      );
      expect(back.profileId, 'p_9f2c41a77d3e4b08');
      expect(back.schema, 3);
      expect(back.toJson()['profileId'], 'p_9f2c41a77d3e4b08');
    });

    test('the format name and version are what old builds read', () {
      final json = ZoroxBackup(exportedAt: 1).toJson();
      expect(json['format'], 'zorox-backup');
      // Old builds refuse any version but 1, so the additive revision
      // stays in `schema` and the profile id is an ignored field to them.
      expect(json['version'], 1);
      expect(json['schema'], 3);
      expect(json.containsKey('profileId'), isFalse);
    });

    test('a pre-profiles backup restores with no profile', () {
      const oldJson = '''
{
  "format": "zorox-backup",
  "version": 1,
  "exportedAt": 1763380000000,
  "history": [{"key": "k", "entry": {"position": 120}}],
  "library": [],
  "schema": 2
}
''';
      final backup = ZoroxBackup.fromJson(
        jsonDecode(oldJson) as Map<String, dynamic>,
      );
      expect(backup.profileId, isNull);
      expect(backup.schema, 2);
      expect(backup.history, hasLength(1));
    });
  });
}
