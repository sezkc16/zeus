import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'tracking_service.dart';
import '../domain/sync_progress_item.dart';
import '../../../../core/config/sync_config.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/secure_token_storage.dart';

/// WeTrakr (https://wetrakr.com): sign-in by device code and scrobbling.
///
/// From WeTrakr's API docs (v1):
///  * every request carries `wetrakr-api-key: <client id>` and
///    `wetrakr-api-version: 1`, plus `Authorization: Bearer` once signed in;
///  * device flow: `POST /oauth/device/code {client_id}` then poll
///    `POST /oauth/device/token {code, client_id}` every `interval` seconds
///    until `expires_in` runs out. 400 `authorization_pending` means keep
///    polling; any other status ends it;
///  * access tokens last 7 days, refresh tokens 180. A refresh ROTATES the
///    refresh token, so refreshes are single-flight here; 401
///    `INVALID_REFRESH_TOKEN` means the session is over;
///  * `POST /scrobble/start | pause | stop` with `movie`, or `show` +
///    `episode {season, number}`, and `progress` 0-100. WeTrakr decides
///    "watched" itself at stop >= 80.
///
/// An installed app must never hold a client secret: none is sent, stored
/// or read anywhere in this file.
///
/// The app shares one small request budget across every user (a develop
/// key: 1,000 requests a day), so this service makes no call of its own
/// accord: no catalogue lookups, no history pulls, no polling outside the
/// sign-in. A 429 puts every call on hold until the time the server names.
class WetrakrService implements TrackingService {
  WetrakrService(
    this._dio,
    this._storage, {
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    Future<String> Function()? appVersion,
    String clientId = SyncConfig.wetrakrClientId,
  }) : _clock = clock ?? DateTime.now,
       _delay = delay ?? _wait,
       _appVersion = appVersion ?? _packageVersion,
       _clientId = clientId {
    _initFuture = _initToken();
  }

  final Dio _dio;
  final SecureTokenStorage _storage;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final Future<String> Function() _appVersion;
  final String _clientId;

  static const String _api = 'https://api.wetrakr.com';
  static const String _kAccessTokenKey = 'wetrakr_access_token';
  static const String _kRefreshTokenKey = 'wetrakr_refresh_token';
  static const String _kExpiresAtKey = 'wetrakr_token_expires_at';

  /// Refresh a day before the 7-day access token runs out; the 401 path
  /// below covers what the clock missed.
  static const Duration _refreshSkew = Duration(days: 1);

  /// How long to stay quiet after a 429 that names no time.
  static const Duration _defaultBackoff = Duration(minutes: 5);

  String? _accessToken;
  String? _refreshToken;
  int? _expiresAtMs;
  Future<void>? _initFuture;
  Future<bool>? _refreshInFlight;
  DateTime? _quietUntil;

  static Future<void> _wait(Duration duration) =>
      Future<void>.delayed(duration);

  static Future<String>? _version;
  static Future<String> _packageVersion() =>
      _version ??= PackageInfo.fromPlatform().then((info) => info.version);

  /// False in a build made without the WeTrakr client id: the Accounts row
  /// is hidden and nothing here makes a request.
  bool get isConfigured => _clientId.isNotEmpty;

  Future<void> _initToken() async {
    _accessToken = await _storage.read(_kAccessTokenKey);
    _refreshToken = await _storage.read(_kRefreshTokenKey);
    _expiresAtMs = int.tryParse(await _storage.read(_kExpiresAtKey) ?? '');
  }

  Future<void> _ensureInit() async {
    if (_initFuture != null) await _initFuture;
  }

  @override
  String get name => 'WeTrakr';

  @override
  String get idPrefix => 'wetrakr';

  @override
  String get mainUrl => 'https://wetrakr.com';

  @override
  Future<bool> get isLoggedIn async {
    if (!isConfigured) return false;
    await _ensureInit();
    return _accessToken != null;
  }

  Map<String, String> get _baseHeaders => {
    'Content-Type': 'application/json',
    'wetrakr-api-version': '1',
    'wetrakr-api-key': _clientId,
  };

  Map<String, String> get _authHeaders => {
    ..._baseHeaders,
    'Authorization': 'Bearer $_accessToken',
  };

  bool get _quiet {
    final until = _quietUntil;
    return until != null && _clock().isBefore(until);
  }

  /// Notes a 429: nothing more is sent until the server's `Retry-After`
  /// (seconds), or [_defaultBackoff] when it names none.
  void _noteRateLimit(Response<dynamic>? response) {
    final header = response?.headers.value('retry-after');
    final seconds = int.tryParse(header ?? '');
    _quietUntil = _clock().add(
      seconds != null && seconds > 0
          ? Duration(seconds: seconds)
          : _defaultBackoff,
    );
    talker.error('WetrakrService: rate limited, holding off');
  }

  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    if (!isConfigured) return false;
    try {
      final response = await _dio.post<dynamic>(
        '$_api/oauth/device/code',
        data: {'client_id': _clientId},
        options: Options(headers: _baseHeaders),
      );
      final data = response.data;
      if (data is! Map) return false;
      final userCode = data['user_code'] as String;
      final deviceCode = data['device_code'] as String;
      final verificationUrl =
          (data['verification_url'] as String?) ??
          'https://wetrakr.com/activate';
      var interval = (data['interval'] as num?)?.toInt() ?? 5;
      if (interval < 1) interval = 5;
      final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 600;
      final deadline = _clock().add(Duration(seconds: expiresIn));

      if (onDeviceCodeGenerated != null) {
        await onDeviceCodeGenerated(verificationUrl, userCode);
      }

      while (true) {
        if (isCancelled != null && isCancelled()) return false;
        await _delay(Duration(seconds: interval));
        if (isCancelled != null && isCancelled()) return false;
        if (!_clock().isBefore(deadline)) {
          talker.debug('WetrakrService: the device code expired');
          return false;
        }
        try {
          final tokenResponse = await _dio.post<dynamic>(
            '$_api/oauth/device/token',
            data: {'code': deviceCode, 'client_id': _clientId},
            options: Options(headers: _baseHeaders),
          );
          final tokens = tokenResponse.data;
          if (tokenResponse.statusCode == 200 &&
              tokens is Map &&
              tokens['access_token'] != null) {
            await _storeTokens(Map<String, dynamic>.from(tokens));
            return true;
          }
          // An answer that is neither tokens nor an error: stop.
          return false;
        } on DioException catch (e) {
          final status = e.response?.statusCode;
          final body = e.response?.data;
          final error = body is Map ? body['error']?.toString() : null;
          if (status == 400 && error == 'authorization_pending') continue;
          if (status == 429) {
            // Polling faster than allowed: wait longer, keep going.
            interval += 5;
            continue;
          }
          if (status == null) {
            // No answer at all (a dropped connection): try again in time.
            continue;
          }
          // 400 invalid_request, 404, 409 used, 410 expired, 418 denied...
          talker.debug('WetrakrService: sign-in ended with $status');
          return false;
        }
      }
    } catch (e) {
      talker.error('WetrakrService: sign-in failed', e);
      return false;
    }
  }

  Future<void> _storeTokens(Map<String, dynamic> data) async {
    _accessToken = data['access_token'].toString();
    final refresh = (data['refresh_token'] ?? data['new_refresh_token'])
        ?.toString();
    if (refresh != null && refresh.isNotEmpty) _refreshToken = refresh;

    final expiresIn = (data['expires_in'] as num?)?.toInt();
    _expiresAtMs = expiresIn != null && expiresIn > 0
        ? _clock().millisecondsSinceEpoch + expiresIn * 1000
        : null;

    // The refresh token first: the one it replaces is retired, so an app
    // killed before this write would be signed out at its next refresh.
    if (_refreshToken != null) {
      await _storage.write(_kRefreshTokenKey, _refreshToken!);
    }
    await _storage.write(_kAccessTokenKey, _accessToken!);
    if (_expiresAtMs != null) {
      await _storage.write(_kExpiresAtKey, _expiresAtMs!.toString());
    } else {
      await _storage.delete(_kExpiresAtKey);
    }
  }

  Future<void> _clearSession(String reason) async {
    talker.error('WetrakrService: clearing the session - $reason');
    _accessToken = null;
    _refreshToken = null;
    _expiresAtMs = null;
    await _storage.delete(_kAccessTokenKey);
    await _storage.delete(_kRefreshTokenKey);
    await _storage.delete(_kExpiresAtKey);
  }

  Future<bool> _ensureFreshToken() async {
    await _ensureInit();
    if (_accessToken == null) return false;
    final expiresAt = _expiresAtMs;
    if (expiresAt == null) return true;
    if (_clock().millisecondsSinceEpoch + _refreshSkew.inMilliseconds <
        expiresAt) {
      return true;
    }
    return _refreshAccessToken();
  }

  /// Single-flight: the refresh token rotates, so two refreshes at once
  /// would spend it twice and sign the person out.
  Future<bool> _refreshAccessToken() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final fut = _doRefreshAccessToken();
    _refreshInFlight = fut;
    fut.whenComplete(() => _refreshInFlight = null);
    return fut;
  }

  Future<bool> _doRefreshAccessToken() async {
    final refresh = _refreshToken;
    if (refresh == null) {
      await _clearSession('no refresh token stored');
      return false;
    }
    if (_quiet) return false;
    try {
      final response = await _dio.post<dynamic>(
        '$_api/oauth/token/refresh',
        data: {'refresh_token': refresh},
        options: Options(headers: _baseHeaders),
      );
      final data = response.data;
      if (response.statusCode == 200 &&
          data is Map &&
          data['access_token'] != null) {
        await _storeTokens(Map<String, dynamic>.from(data));
        return true;
      }
      return false;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401) {
        // INVALID_REFRESH_TOKEN: it will never work again. The Accounts
        // row goes back to "Connect".
        await _clearSession('refresh refused with 401');
      } else if (status == 429) {
        _noteRateLimit(e.response);
      } else {
        talker.error('WetrakrService: token refresh failed, will retry', e);
      }
      return false;
    } catch (e) {
      talker.error('WetrakrService: token refresh failed, will retry', e);
      return false;
    }
  }

  @override
  Future<void> logout() async {
    await _ensureInit();
    final access = _accessToken;
    final refresh = _refreshToken;
    // Sign out on this device first: it must work with no network.
    _accessToken = null;
    _refreshToken = null;
    _expiresAtMs = null;
    await _storage.delete(_kAccessTokenKey);
    await _storage.delete(_kRefreshTokenKey);
    await _storage.delete(_kExpiresAtKey);
    if (!isConfigured || access == null || refresh == null) return;
    try {
      // Then end the session on WeTrakr's side. Best effort.
      await _dio.post<dynamic>(
        '$_api/oauth/logout',
        data: {'refresh_token': refresh},
        options: Options(
          headers: {..._baseHeaders, 'Authorization': 'Bearer $access'},
        ),
      );
    } catch (e) {
      talker.debug('WetrakrService: remote sign-out failed: $e');
    }
  }

  @override
  Future<List<MultimediaItem>> search(String query) async => [];

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async => {};

  /// The scrobble body, or null when the title has no id WeTrakr can
  /// resolve (it takes tmdb, imdb and tvdb ids).
  Future<Map<String, dynamic>?> _scrobbleBody(
    MultimediaItem item,
    Episode? episode,
    double progress,
  ) async {
    if (item.tmdbId == null && item.imdbId == null) return null;
    final media = <String, dynamic>{
      'title': item.title,
      if (item.year != null) 'year': item.year,
      'ids': {
        if (item.tmdbId != null) 'tmdb': item.tmdbId,
        if (item.imdbId != null) 'imdb': item.imdbId,
      },
    };
    final percent = (progress * 100).clamp(0.0, 100.0);
    String version;
    try {
      version = await _appVersion();
    } catch (_) {
      version = 'unknown';
    }
    final body = <String, dynamic>{
      'progress': double.parse(percent.toStringAsFixed(2)),
      'app_version': version,
    };
    if (item.contentType == MultimediaContentType.movie) {
      body['movie'] = media;
    } else {
      // A show needs its episode: never send a show alone.
      if (episode == null) return null;
      body['show'] = media;
      body['episode'] = {'season': episode.season, 'number': episode.episode};
    }
    return body;
  }

  /// Sends one scrobble. The answer is "is this write settled?", which is
  /// what the sync outbox asks: true when WeTrakr took it AND when it can
  /// never take it (no usable id, a title it does not know, a body it
  /// refuses) - retrying those would only spend the shared request budget.
  /// False only when trying again later can help: no network, a server
  /// error, a rate limit, or a session that could not be refreshed now.
  Future<bool> _scrobble(
    String action,
    MultimediaItem item,
    Episode? episode,
    double progress,
  ) async {
    if (!isConfigured) return true;
    await _ensureInit();
    if (_accessToken == null) return true;
    final body = await _scrobbleBody(item, episode, progress);
    if (body == null) return true;
    if (_quiet) return false;
    if (!await _ensureFreshToken()) return _accessToken == null;

    Future<Response<dynamic>> send() => _dio.post<dynamic>(
      '$_api/scrobble/$action',
      data: body,
      options: Options(headers: _authHeaders),
    );

    try {
      await send();
      return true;
    } on DioException catch (e) {
      var status = e.response?.statusCode;
      if (status == 401) {
        // The clock said the token was fine and WeTrakr disagrees.
        if (!await _refreshAccessToken()) return _accessToken == null;
        try {
          await send();
          return true;
        } on DioException catch (retry) {
          status = retry.response?.statusCode;
          if (status == 429) _noteRateLimit(retry.response);
          return status != null &&
              status >= 400 &&
              status < 500 &&
              status != 429;
        } catch (_) {
          return false;
        }
      }
      if (status == 429) {
        _noteRateLimit(e.response);
        return false;
      }
      talker.debug('WetrakrService: scrobble $action answered $status');
      // 400 / 404 / 422: settled, it will never be accepted. Else retry.
      return status != null && status >= 400 && status < 500;
    } catch (e) {
      talker.error('WetrakrService: scrobble $action failed', e);
      return false;
    }
  }

  @override
  Future<bool> markWatched(
    MultimediaItem item,
    Episode? episode, {
    Map<String, String>? resolvedIds,
  }) => _scrobble('stop', item, episode, 1.0);

  @override
  Future<bool> scrobbleStart(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) => _scrobble('start', item, episode, progress);

  @override
  Future<bool> scrobblePause(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) => _scrobble('pause', item, episode, progress);

  @override
  Future<bool> scrobbleStop(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) => _scrobble('stop', item, episode, progress);

  /// Not wired: WeTrakr lists are left alone in this build.
  @override
  Future<bool> addToPlanToWatch(
    MultimediaItem item, {
    Map<String, String>? resolvedIds,
  }) async => false;

  /// Not wired: no history or progress is pulled from WeTrakr (it would
  /// spend the shared request budget on every Home load).
  @override
  Future<List<SyncProgressItem>> pullPlaybackProgress() async => [];

  @override
  Future<bool> removePlaybackProgress(String id) async => false;
}

/// Whether this build carries the WeTrakr client id. The Accounts row is
/// shown only when it does.
final wetrakrConfiguredProvider = Provider<bool>(
  (ref) => SyncConfig.wetrakrClientId.isNotEmpty,
);

final wetrakrServiceProvider = Provider<WetrakrService>((ref) {
  return WetrakrService(
    ref.watch(dioClientProvider),
    ref.watch(secureTokenStorageProvider),
  );
});
