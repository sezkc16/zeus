import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'zeus_profile_photo_store.dart';

/// The profile ids that have a local photo, mapped to the stored file
/// path (build 110). Every [ZeusProfileAvatar] watches this, so a pick
/// or a remove refreshes the Home tile, the switcher grid and the
/// picker at once.
///
/// The photo itself is local-only: it is not in the profile JSON and
/// never syncs. Deleting a profile deletes its photo too (see
/// [ZeusProfilesNotifier.deleteZeusProfile]).
class ZeusProfilePhotosNotifier extends Notifier<Map<String, String>> {
  ZeusProfilePhotoStore? _store;

  @override
  Map<String, String> build() {
    Future.microtask(_refresh);
    return {};
  }

  Future<ZeusProfilePhotoStore> _storeOrCreate() async =>
      _store ??= await ZeusProfilePhotoStore.create();

  Future<void> _refresh() async {
    try {
      final store = await _storeOrCreate();
      state = store.listPhotos();
    } catch (_) {
      // Photos are best-effort: the colour/initial avatar is the
      // fallback, and a failed scan must never break the picker.
    }
  }

  bool hasPhoto(String profileId) => state.containsKey(profileId);

  String? photoPath(String profileId) => state[profileId];

  /// Stores a picked image for a profile (copies it into the store).
  /// Best-effort: a store that cannot be created (no support dir)
  /// leaves the colour/initial avatar in place instead of throwing.
  Future<void> savePhoto(String profileId, XFile picked) async {
    try {
      final store = await _storeOrCreate();
      final path = await store.savePhoto(profileId, picked);
      state = {...state, profileId: path};
    } catch (_) {
      // Best-effort: the avatar falls back to colour/initial.
    }
  }

  /// Removes a profile's photo, if any. Best-effort like [savePhoto]:
  /// a store that cannot be reached keeps the map entry, so the tile
  /// still shows the photo that is still on disk.
  Future<void> removePhoto(String profileId) async {
    try {
      final store = await _storeOrCreate();
      await store.deletePhoto(profileId);
    } catch (_) {
      return;
    }
    if (!state.containsKey(profileId)) return;
    final next = Map<String, String>.of(state)..remove(profileId);
    state = next;
  }
}

final zeusProfilePhotosProvider =
    NotifierProvider<ZeusProfilePhotosNotifier, Map<String, String>>(
      ZeusProfilePhotosNotifier.new,
    );
