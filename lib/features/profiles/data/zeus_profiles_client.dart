import 'package:dio/dio.dart';

import '../../account/data/zorox_sync_client.dart';
import 'zeus_profile.dart';

/// The Worker v2 profile calls: list, create, update, delete.
///
/// A fresh [Dio] of its own — not the app's shared client — so profile
/// calls never pick up a plugin's cookies or DNS overrides, like
/// [ZoroxSyncClient]. Throws [ZoroxSyncException] with a readable message
/// for anything the server or the network reports.
///
/// The PIN is never sent: [createZeusProfile] takes the PBKDF2 record
/// (made on the device by the caller), and the server stores it verbatim.
class ZeusProfilesClient {
  ZeusProfilesClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
              responseType: ResponseType.json,
            ),
          );

  final Dio _dio;

  /// The account's profiles, newest first by creation order on the
  /// server (the stored order). Empty when the account has none yet.
  Future<List<ZeusProfile>> fetchZeusProfiles(
    String baseUrl,
    String token,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$baseUrl/profiles',
        queryParameters: {'token': token},
      );
      final body = response.data ?? const {};
      if (body['ok'] != true) {
        throw ZoroxSyncException(_serverMessage(body));
      }
      final raw = body['profiles'];
      if (raw is! List) return const [];
      return [
        for (final e in raw)
          if (e is Map) ZeusProfile.fromJson(Map<String, dynamic>.from(e)),
      ];
    } on ZoroxSyncException {
      rethrow;
    } on DioException catch (e) {
      throw ZoroxSyncException(
        _dioMessage(e),
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// Creates a profile. The server generates the id and enforces the
  /// 5-profile cap (409 past it).
  Future<ZeusProfile> createZeusProfile(
    String baseUrl,
    String token, {
    required String name,
    required String color,
    required String pinRecord,
  }) async {
    final body = await _post(baseUrl, '/profiles', {
      'token': token,
      'name': name,
      'color': color,
      'pinRecord': pinRecord,
    });
    final profile = body['profile'];
    if (profile is! Map) {
      throw const ZoroxSyncException(
        'The sync server did not return the new profile.',
      );
    }
    return ZeusProfile.fromJson(Map<String, dynamic>.from(profile));
  }

  /// Renames / recolours a profile (token only), or changes its PIN
  /// record ([pinRecord] + [accountPassword] — the server verifies the
  /// password before accepting a new record).
  Future<ZeusProfile> updateZeusProfile(
    String baseUrl,
    String token,
    String profileId, {
    String? name,
    String? color,
    String? pinRecord,
    String? accountPassword,
  }) async {
    final body = await _post(baseUrl, '/profiles/$profileId', {
      'token': token,
      if (name != null) 'name': name,
      if (color != null) 'color': color,
      if (pinRecord != null) 'pinRecord': pinRecord,
      if (accountPassword != null) 'password': accountPassword,
    });
    final profile = body['profile'];
    if (profile is! Map) {
      throw const ZoroxSyncException(
        'The sync server did not return the updated profile.',
      );
    }
    return ZeusProfile.fromJson(Map<String, dynamic>.from(profile));
  }

  /// Deletes a profile and its backup. Requires the account password;
  /// the server refuses when it is the last profile.
  Future<void> deleteZeusProfile(
    String baseUrl,
    String token,
    String profileId,
    String accountPassword,
  ) async {
    await _post(baseUrl, '/profiles/$profileId/delete', {
      'token': token,
      'password': accountPassword,
    });
  }

  Future<Map<String, dynamic>> _post(
    String baseUrl,
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$baseUrl$path',
        data: body,
      );
      final data = response.data ?? const {};
      if (data['ok'] != true) {
        throw ZoroxSyncException(_serverMessage(data));
      }
      return data;
    } on ZoroxSyncException {
      rethrow;
    } on DioException catch (e) {
      throw ZoroxSyncException(
        _dioMessage(e),
        statusCode: e.response?.statusCode,
      );
    }
  }

  static String _serverMessage(Map<String, dynamic> body) {
    final error = body['error'];
    if (error is String && error.isNotEmpty) return error;
    return 'The sync server answered with an error.';
  }

  static String _dioMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final error = data['error'];
      if (error is String && error.isNotEmpty) return error;
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        'The sync server took too long to answer.',
      DioExceptionType.connectionError =>
        'Could not reach the sync server. Check your connection.',
      _ => 'Could not reach the sync server.',
    };
  }
}
