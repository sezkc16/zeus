import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/dio_client_provider.dart';

/// Looks a cast member's photo up by name (v8).
///
/// Cinemeta - what Browse lists - names a title's cast and sends no photos,
/// and TMDB's credits need an API key this app does not ship with. IMDb's
/// public name-suggestion endpoint needs no key and answers with the
/// person's headshot. Only a person whose name is exactly the one asked for
/// is taken, so a near miss shows initials rather than a stranger's face.
class CastPhotoService {
  CastPhotoService(this._get);

  /// GETs a url and returns the decoded JSON body, or null.
  final Future<Object?> Function(String url) _get;

  final Map<String, Future<String?>> _cache = {};

  static String _key(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<String?> photoFor(String name) {
    final key = _key(name);
    if (key.isEmpty) return Future.value(null);
    return _cache.putIfAbsent(key, () => _lookup(key));
  }

  Future<String?> _lookup(String key) async {
    try {
      final first = Uri.encodeComponent(key[0]);
      final body = await _get(
        'https://v3.sg.media-imdb.com/suggestion/names/$first/'
        '${Uri.encodeComponent(key)}.json',
      );
      return pickPhoto(body, key);
    } catch (error) {
      if (kDebugMode) debugPrint('[CastPhoto] $key: $error');
      // Not remembered: the next visit may have a network.
      unawaited(Future<void>.microtask(() => _cache.remove(key)));
      return null;
    }
  }

  /// The headshot of the person in [body] named exactly [name], sized for
  /// an avatar; null when there is none.
  @visibleForTesting
  static String? pickPhoto(Object? body, String name) {
    if (body is! Map) return null;
    final entries = body['d'];
    if (entries is! List) return null;
    final wanted = _key(name);
    for (final entry in entries) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || !id.startsWith('nm')) continue;
      final label = entry['l'];
      if (label is! String || _key(label) != wanted) continue;
      final image = entry['i'];
      final url = image is Map ? image['imageUrl'] : null;
      if (url is! String || !url.startsWith('http')) continue;
      return avatarSized(url);
    }
    return null;
  }

  /// IMDb's image host resizes by a suffix after `._V1_`: ask for a small
  /// square-ish one instead of the multi-megabyte original.
  @visibleForTesting
  static String avatarSized(String url) {
    final at = url.indexOf('._V1_');
    if (at < 0) return url;
    return '${url.substring(0, at)}._V1_UX240_.jpg';
  }
}

final castPhotoServiceProvider = Provider<CastPhotoService>((ref) {
  final dio = ref.watch(dioClientProvider);
  return CastPhotoService((url) async {
    final response = await dio.get<dynamic>(
      url,
      options: Options(
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 12),
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    return response.statusCode == 200 ? response.data : null;
  });
});

/// A cast member's photo url by name, or null.
final castPhotoProvider = FutureProvider.family<String?, String>(
  (ref, name) => ref.watch(castPhotoServiceProvider).photoFor(name),
);
