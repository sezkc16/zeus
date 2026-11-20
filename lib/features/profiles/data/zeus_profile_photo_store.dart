import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Where profile photos live (build 110, local-only v1): one JPEG per
/// profile, `<profileId>.jpg`, under the app support directory — NOT
/// Documents, so it never shows in Files / File Sharing, and never in
/// the backup JSON or the cloud sync (the photo is not in the profile's
/// `toJson` and the server never sees it).
///
/// [directory] is injectable so tests can point at a temp dir.
class ZeusProfilePhotoStore {
  ZeusProfilePhotoStore(this._directory);

  /// Production constructor: the support dir + `profile_photos`.
  static Future<ZeusProfilePhotoStore> create() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/profile_photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return ZeusProfilePhotoStore(dir);
  }

  final Directory _directory;

  /// The photo file for a profile, whether it exists or not.
  File photoFile(String profileId) => File('${_directory.path}/$profileId.jpg');

  bool hasPhoto(String profileId) => photoFile(profileId).existsSync();

  /// All stored photos: profile id -> absolute path.
  Map<String, String> listPhotos() {
    if (!_directory.existsSync()) return <String, String>{};
    final out = <String, String>{};
    for (final entity in _directory.listSync()) {
      if (entity is! File) continue;
      final name = entity.path.split('/').last;
      if (name.endsWith('.jpg')) {
        out[name.substring(0, name.length - 4)] = entity.path;
      }
    }
    return out;
  }

  /// Copies a picked image into the store. Returns the stored path.
  Future<String> savePhoto(String profileId, XFile picked) async {
    final target = photoFile(profileId);
    await picked.saveTo(target.path);
    return target.path;
  }

  /// Deletes a profile's photo, if any. Never throws — a stale photo
  /// file must never break a profile delete.
  Future<void> deletePhoto(String profileId) async {
    try {
      final file = photoFile(profileId);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Ignore: the photo is best-effort local state.
    }
  }
}
