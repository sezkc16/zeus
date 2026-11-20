import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/zeus_profile.dart';
import '../data/zeus_profile_photos_notifier.dart';

/// A profile's avatar tile: the custom photo when one is set (build
/// 110, local-only), else a rounded square in the profile's palette
/// colour with the big initial letter, the way Netflix draws its
/// profiles. No image assets.
///
/// [circular] draws the tile as a circle — the Home top bar only, where
/// it sits next to the round search/settings buttons and must read as
/// exactly their size (36 pt). Everywhere else the rounded square stays.
///
/// Stateful on purpose: the photo bytes are read once per path and kept
/// in state, so [Image.memory] gets the same byte list — and therefore
/// the same image-cache key — on every rebuild. A fresh read on each
/// build would hand it a new key every time, so the image would
/// re-decode on every rebuild and the tile would never settle (that
/// loop is what hung the avatar test on the first attempt).
class ZeusProfileAvatar extends ConsumerStatefulWidget {
  const ZeusProfileAvatar({
    required this.profile,
    this.size = 76,
    this.fontSize,
    this.circular = false,
    this.photoPath,
    super.key,
  });

  final ZeusProfile profile;
  final double size;
  final double? fontSize;

  /// Circle instead of the rounded square (Home top bar only).
  final bool circular;

  /// A photo to show instead of the stored one — the create screen's
  /// not-yet-saved pick. Null means "look the photo up from the store".
  final String? photoPath;

  @override
  ConsumerState<ZeusProfileAvatar> createState() => _ZeusProfileAvatarState();
}

class _ZeusProfileAvatarState extends ConsumerState<ZeusProfileAvatar> {
  /// The path the bytes in [_photoBytes] were read from.
  String? _loadedPath;

  /// The photo file's last-modified time when [_photoBytes] was read.
  /// A re-picked photo overwrites the same `<id>.jpg` path, so the path
  /// alone cannot tell a new photo from the old one — the mtime can.
  DateTime? _loadedModified;

  /// The photo bytes for [_loadedPath], or null when there is no photo
  /// (or the file is gone/unreadable). Kept across rebuilds so the
  /// image-cache key stays stable.
  Uint8List? _photoBytes;

  @override
  Widget build(BuildContext context) {
    final color = zeusProfileColor(widget.profile.color);
    final initial = widget.profile.name.isEmpty
        ? '?'
        : widget.profile.name.trim()[0].toUpperCase();
    final storedPath =
        widget.photoPath ??
        ref.watch(zeusProfilePhotosProvider)[widget.profile.id];
    // Read once per (path, mtime): a stale path (file deleted outside
    // the app) renders the colour/initial tile immediately — the photo
    // is only built for a file that is actually there, so a missing
    // file never leaves the tile in a loading or broken-image state.
    final modified = storedPath == null ? null : _fileModified(storedPath);
    if (storedPath != _loadedPath || modified != _loadedModified) {
      _loadedPath = storedPath;
      _loadedModified = modified;
      _photoBytes = storedPath == null
          ? null
          : readZeusProfilePhotoBytes(storedPath);
    }
    final radius = widget.circular ? widget.size / 2 : widget.size * 0.22;
    if (_photoBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.memory(
          _photoBytes!,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          // A corrupt file falls back to the colour/initial tile
          // instead of a broken image.
          errorBuilder: (_, _, _) => _initialTile(color, initial, radius),
        ),
      );
    }
    return _initialTile(color, initial, radius);
  }

  /// A file's last-modified time, or null when it cannot be read.
  DateTime? _fileModified(String path) {
    try {
      return File(path).lastModifiedSync();
    } catch (_) {
      return null;
    }
  }

  Widget _initialTile(Color color, String initial, double radius) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: widget.fontSize ?? widget.size * 0.44,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Reads a stored photo's bytes, or null when the file is gone or
/// unreadable. Synchronous on purpose: the pick flow downscales to max
/// 1024 px (a few hundred KiB at most), so the read is ~1 ms.
/// Image.memory (not Image.file) renders the bytes, because FileImage's
/// load never resolves in this VM's flutter_tester — a bare Image.file
/// probe hangs there, while Image.memory decodes fine.
@visibleForTesting
Uint8List? readZeusProfilePhotoBytes(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  } catch (_) {
    return null;
  }
}
