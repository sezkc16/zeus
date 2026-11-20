import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../data/zeus_profile_photos_notifier.dart';

enum _PhotoChoice { gallery, camera, remove }

/// The profile-photo pick flow (build 110): gallery or camera, plus
/// remove when a photo is set.
///
/// When [profileId] is given, the picked photo is saved straight into
/// the local store and null is returned. When it is null (the create
/// screen: no profile exists yet to save against), the picked file is
/// returned and the caller saves it after creation.
///
/// Permission denial is explained in a SnackBar, never a crash; a
/// cancelled pick returns null.
Future<XFile?> pickZeusProfilePhoto(
  BuildContext context,
  WidgetRef ref, {
  String? profileId,
}) async {
  final hasPhoto =
      profileId != null &&
      ref.read(zeusProfilePhotosProvider.notifier).hasPhoto(profileId);
  final choice = await showModalBottomSheet<_PhotoChoice>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.of(context).pop(_PhotoChoice.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_rounded),
            title: const Text('Take a photo'),
            onTap: () => Navigator.of(context).pop(_PhotoChoice.camera),
          ),
          if (hasPhoto)
            ListTile(
              leading: Icon(
                Icons.delete_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Remove photo',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.of(context).pop(_PhotoChoice.remove),
            ),
          ListTile(
            leading: const Icon(Icons.close_rounded),
            title: const Text('Cancel'),
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ),
  );
  if (choice == null) return null;
  if (choice == _PhotoChoice.remove) {
    await ref.read(zeusProfilePhotosProvider.notifier).removePhoto(profileId!);
    return null;
  }
  final source = choice == _PhotoChoice.gallery
      ? ImageSource.gallery
      : ImageSource.camera;
  try {
    final picked = await ImagePicker().pickImage(
      source: source,
      // Downscale at pick time: an avatar never needs a 12 MP file.
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null) return null;
    if (profileId != null) {
      await ref
          .read(zeusProfilePhotosProvider.notifier)
          .savePhoto(profileId, picked);
      return null;
    }
    return picked;
  } on PlatformException catch (e) {
    if (!context.mounted) return null;
    final denied =
        e.code.contains('denied') ||
        e.code.contains('permission') ||
        e.code.contains('access');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          denied
              ? 'Photos permission is needed to choose a profile photo. '
                    'Allow it in Settings.'
              : 'Could not open the photo picker. Try again.',
        ),
      ),
    );
    return null;
  } catch (_) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not pick a photo. Try again.')),
    );
    return null;
  }
}
