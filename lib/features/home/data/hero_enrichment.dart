/// Real details for the Home hero (build 85): genre, runtime, year,
/// certification, status, language, rating, title logo and clean art,
/// looked up on TMDB for a title a plugin only names.
///
/// Honest-data rules: a plugin title is matched only when the cleaned
/// name is the same as TMDB's (and the year agrees when the plugin states
/// one). No match, no key, or no network gives null and the hero looks as
/// it did. A rating is called IMDb's only when it came from IMDb (through
/// Cinemeta, by the IMDb id TMDB gives); TMDB's own average is a plain
/// star score.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/tmdb_config.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/services/tmdb_service.dart';

/// What the lookup found. Every field is optional: only what the sources
/// really carry.
class HeroEnrichment {
  const HeroEnrichment({
    this.genres = const [],
    this.runtimeMinutes,
    this.year,
    this.certification,
    this.status,
    this.language,
    this.imdbScore,
    this.tmdbScore,
    this.logoUrl,
    this.artUrl,
  });

  final List<String> genres;
  final int? runtimeMinutes;
  final int? year;
  final String? certification;

  /// Already in badge form: RELEASED, ONGOING, ENDED, UPCOMING, CANCELLED.
  final String? status;

  /// Original language code as TMDB gives it ("ja").
  final String? language;

  /// IMDb's rating (from Cinemeta), 0-10.
  final double? imdbScore;

  /// TMDB's vote average, 0-10. Never shown as IMDb.
  final double? tmdbScore;
  final String? logoUrl;

  /// Art without the title printed on it, when TMDB has one.
  final String? artUrl;

  Map<String, dynamic> toJson() => {
    'g': genres,
    'r': runtimeMinutes,
    'y': year,
    'c': certification,
    's': status,
    'l': language,
    'i': imdbScore,
    't': tmdbScore,
    'lo': logoUrl,
    'a': artUrl,
  };

  factory HeroEnrichment.fromJson(Map<String, dynamic> j) => HeroEnrichment(
    genres: ((j['g'] as List?) ?? const []).map((e) => '$e').toList(),
    runtimeMinutes: (j['r'] as num?)?.toInt(),
    year: (j['y'] as num?)?.toInt(),
    certification: j['c'] as String?,
    status: j['s'] as String?,
    language: j['l'] as String?,
    imdbScore: (j['i'] as num?)?.toDouble(),
    tmdbScore: (j['t'] as num?)?.toDouble(),
    logoUrl: j['lo'] as String?,
    artUrl: j['a'] as String?,
  );

  /// [item] with the gaps filled. What the plugin states itself is kept;
  /// the one exception is the score, where a real IMDb rating wins.
  MultimediaItem applyTo(MultimediaItem item) {
    final ownTags = item.tags ?? const <String>[];
    return item.copyWith(
      tags: [...ownTags, ...genres],
      duration: item.duration ?? runtimeMinutes,
      year: item.year ?? year,
      contentRating: (item.contentRating?.trim().isNotEmpty ?? false)
          ? item.contentRating
          : certification,
      score: imdbScore ?? item.score ?? tmdbScore,
      logoUrl: (item.logoUrl?.isNotEmpty ?? false) ? item.logoUrl : logoUrl,
    );
  }

  /// Whether the score [applyTo] leaves on the item is IMDb's.
  bool get scoreIsImdb => imdbScore != null;
}

/// A plugin's title split into the name and the year it states.
class CleanTitle {
  const CleanTitle(this.name, this.year);
  final String name;
  final int? year;
}

final _yearInBrackets = RegExp(r'[\(\[]\s*((?:19|20)\d{2})\s*[\)\]]');
final _bareYear = RegExp(r'\b((?:19|20)\d{2})\b');
final _cutAt = RegExp(
  r'(\b(?:2160p|1080p|720p|480p|4k|uhd|hdr|web-?dl|web-?rip|blu-?ray|'
  r'brrip|hdrip|hdtv|dvdrip|hdcam|camrip|hevc|x26[45]|10bit|dual audio|'
  r'multi audio|hindi dubbed|hindi|english|tamil|telugu|esubs?|'
  r'season\s*\d+|s\d{1,2}\s*e\d{1,3}|s\d{1,2}\b|complete series|'
  r'all episodes|download|netflix|amzn|unrated|extended|remastered)\b|'
  r'[\[\{\|])',
  caseSensitive: false,
);

/// "Guarding Stars (2026) WEB-DL [Hindi (DD5.1) & English] 4K 1080p" →
/// name "Guarding Stars", year 2026. The name ends at the year, at the
/// first bracket, or at the first release word, whichever comes first.
CleanTitle cleanHeroTitle(String raw) {
  var text = raw.replaceAll(RegExp(r'[._]+'), ' ').trim();
  int? year;
  final bracketed = _yearInBrackets.firstMatch(text);
  if (bracketed != null) {
    year = int.parse(bracketed.group(1)!);
    text = text.substring(0, bracketed.start);
  } else {
    // A bare year counts only after some name ("2012" alone is a title).
    for (final m in _bareYear.allMatches(text)) {
      if (m.start > 0 && text.substring(0, m.start).trim().isNotEmpty) {
        year = int.parse(m.group(1)!);
        text = text.substring(0, m.start);
        break;
      }
    }
  }
  final cut = _cutAt.firstMatch(text);
  if (cut != null && cut.start > 0) text = text.substring(0, cut.start);
  text = text
      .replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*$'), '')
      .replaceAll(RegExp(r'[\s\-–:|,]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return CleanTitle(text, year);
}

/// A title reduced to what must be equal for two names to be the same
/// film: lower case, "&" as "and", no punctuation, no leading article.
String heroTitleKey(String title) {
  var t = title.toLowerCase().replaceAll('&', ' and ');
  t = t.replaceAll(RegExp(r"['’`]"), '');
  t = t.replaceAll(RegExp(r'[^a-z0-9\u00c0-\uffff]+'), ' ').trim();
  t = t.replaceFirst(RegExp(r'^(the|a|an) '), '');
  return t.replaceAll(RegExp(r'\s+'), ' ');
}

/// The release year of a TMDB search result, or null.
int? _heroResultYear(Map<String, dynamic> r) {
  final d = (r['release_date'] ?? r['first_air_date'] ?? '').toString();
  return d.length >= 4 ? int.tryParse(d.substring(0, 4)) : null;
}

/// A TMDB search result's popularity, or 0.
double _heroResultPopularity(Map<String, dynamic> r) =>
    (r['popularity'] as num?)?.toDouble() ?? 0;

/// The one result among [same] that is confidently the title: a stated
/// year must agree within one (closest wins); without one, a single
/// result wins, or the most popular must lead the next by a wide margin.
/// Null when unsure. Shared by the title match and the alternate-title
/// match, so both hold the same bar.
Map<String, dynamic>? _disambiguateHeroMatches(
  List<Map<String, dynamic>> same, {
  required int? year,
}) {
  if (same.isEmpty) return null;
  if (year != null) {
    final dated = same.where((r) {
      final y = _heroResultYear(r);
      return y != null && (y - year).abs() <= 1;
    }).toList();
    if (dated.isEmpty) return null;
    dated.sort(
      (a, b) => ((_heroResultYear(a)! - year).abs()).compareTo(
        (_heroResultYear(b)! - year).abs(),
      ),
    );
    return dated.first;
  }
  if (same.length == 1) return same.first;
  same.sort(
    (a, b) => _heroResultPopularity(b).compareTo(_heroResultPopularity(a)),
  );
  return _heroResultPopularity(same[0]) >= 3 * _heroResultPopularity(same[1]) &&
          _heroResultPopularity(same[0]) > 0
      ? same.first
      : null;
}

/// The one search result that is confidently [title]: the same name
/// (title or original title), and a release year within one of [year]
/// when the plugin states it. Without a stated year the name must match
/// exactly one result, or the most popular of several must lead the next
/// by a wide margin. Null when unsure.
Map<String, dynamic>? pickHeroMatch(
  List<Map<String, dynamic>> results, {
  required String title,
  required int? year,
}) {
  final key = heroTitleKey(title);
  if (key.isEmpty) return null;
  final same = results.where((r) {
    for (final f in ['title', 'name', 'original_title', 'original_name']) {
      final v = r[f];
      if (v is String && heroTitleKey(v) == key) return true;
    }
    return false;
  }).toList();
  return _disambiguateHeroMatches(same, year: year);
}

/// The alternate titles TMDB lists for a film or show: the movie
/// endpoint answers `titles`, the TV endpoint `results`. Each entry's
/// `title` is a name the film is known by somewhere.
List<String> heroAlternateTitles(Map<String, dynamic> alt) {
  final list =
      (alt['titles'] as List?) ?? (alt['results'] as List?) ?? const [];
  return [
    for (final t in list)
      if (t is Map && t['title'] is String) t['title'] as String,
  ];
}

/// The alternate-title matches among [results]: candidates whose
/// alternate titles (by TMDB id, from [alternates]) include [title]
/// exactly after cleaning. A film may be listed under another name:
/// "Last Meal" is TMDB's "Last Dinner", whose original title is
/// "Son Yemek" — the title match finds nothing, the alternate title
/// does. The same year and popularity rules as [pickHeroMatch] apply;
/// nothing fuzzy, no wrong-film data.
Map<String, dynamic>? pickHeroAltMatch(
  List<Map<String, dynamic>> results,
  Map<int, List<String>> alternates, {
  required String title,
  required int? year,
}) {
  final key = heroTitleKey(title);
  if (key.isEmpty) return null;
  final matched = results.where((r) {
    final id = (r['id'] as num?)?.toInt();
    if (id == null) return false;
    return (alternates[id] ?? const []).any((n) => heroTitleKey(n) == key);
  }).toList();
  return _disambiguateHeroMatches(matched, year: year);
}

/// TMDB's status word as the badge prints it, or null.
String? heroStatusFromTmdb(String? status) =>
    switch (status?.trim().toLowerCase()) {
      'released' => 'RELEASED',
      'returning series' => 'ONGOING',
      'ended' => 'ENDED',
      'canceled' || 'cancelled' => 'CANCELLED',
      'in production' || 'post production' || 'planned' || 'rumored' =>
        'UPCOMING',
      _ => null,
    };

/// The certification from a TMDB details map: the US one, else India's,
/// else Britain's. Null when none is stated.
String? heroCertification(Map<String, dynamic> details, {required bool tv}) {
  String? forCountry(String iso) {
    if (tv) {
      final list = (details['content_ratings'] as Map?)?['results'] as List?;
      for (final r in list ?? const []) {
        if (r is Map && r['iso_3166_1'] == iso) {
          final v = '${r['rating'] ?? ''}'.trim();
          if (v.isNotEmpty) return v;
        }
      }
      return null;
    }
    final list = (details['release_dates'] as Map?)?['results'] as List?;
    for (final r in list ?? const []) {
      if (r is Map && r['iso_3166_1'] == iso) {
        for (final d in (r['release_dates'] as List?) ?? const []) {
          final v = d is Map ? '${d['certification'] ?? ''}'.trim() : '';
          if (v.isNotEmpty) return v;
        }
      }
    }
    return null;
  }

  return forCountry('US') ?? forCountry('IN') ?? forCountry('GB');
}

/// Builds the enrichment from a TMDB details map (with `images`).
HeroEnrichment heroEnrichmentFromDetails(
  Map<String, dynamic> d, {
  required bool tv,
  double? imdbScore,
}) {
  final date = '${d['release_date'] ?? d['first_air_date'] ?? ''}';
  final runtime = tv
      ? (((d['episode_run_time'] as List?) ?? const []).isNotEmpty
            ? ((d['episode_run_time'] as List).first as num?)?.toInt()
            : null)
      : (d['runtime'] as num?)?.toInt();
  final vote = (d['vote_average'] as num?)?.toDouble();
  final votes = (d['vote_count'] as num?)?.toInt() ?? 0;
  final images = d['images'] as Map?;
  final logos = List<Map<String, dynamic>>.from(
    ((images?['logos'] as List?) ?? const []).whereType<Map<dynamic, dynamic>>().map(
      (m) => Map<String, dynamic>.from(m),
    ),
  );
  final logoPath = logos.isEmpty ? null : TmdbService.pickBestLogo(logos, 'en');
  String? textless(String field) {
    final list = ((images?[field] as List?) ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .where((m) => m['iso_639_1'] == null && m['file_path'] is String)
        .toList();
    if (list.isEmpty) return null;
    list.sort(
      (a, b) => ((b['vote_average'] as num?) ?? 0).compareTo(
        (a['vote_average'] as num?) ?? 0,
      ),
    );
    return list.first['file_path'] as String;
  }

  final poster = textless('posters');
  final backdrop = textless('backdrops');
  const root = 'https://image.tmdb.org/t/p';
  final lang = '${d['original_language'] ?? ''}'.trim();
  return HeroEnrichment(
    genres: [
      for (final g in (d['genres'] as List?) ?? const [])
        if (g is Map && '${g['name'] ?? ''}'.trim().isNotEmpty)
          '${g['name']}'.trim(),
    ],
    runtimeMinutes: runtime != null && runtime > 0 ? runtime : null,
    year: date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null,
    certification: heroCertification(d, tv: tv),
    status: heroStatusFromTmdb(d['status'] as String?),
    language: lang.isEmpty ? null : lang,
    imdbScore: imdbScore != null && imdbScore > 0 ? imdbScore : null,
    tmdbScore: vote != null && vote > 0 && votes >= 5 ? vote : null,
    logoUrl: logoPath == null
        ? null
        : (logoPath.startsWith('http') ? logoPath : '$root/w500$logoPath'),
    artUrl: poster != null
        ? '$root/w780$poster'
        : (backdrop != null ? '$root/w1280$backdrop' : null),
  );
}

/// One GET that returns the decoded JSON map, or null on any failure.
typedef HeroJsonGet =
    Future<Map<String, dynamic>?> Function(
      String url,
      Map<String, dynamic> query,
    );

/// The lookup itself, with its two caches. Failures are quiet: nothing
/// here may log a URL, because TMDB's carries the key.
class HeroEnrichmentService {
  HeroEnrichmentService({
    required HeroJsonGet get,
    required String Function() apiKey,
    Future<SharedPreferences> Function()? prefs,
    DateTime Function()? now,
  }) : _get = get,
       _apiKey = apiKey,
       _prefs = prefs ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now;

  final HeroJsonGet _get;
  final String Function() _apiKey;
  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _now;

  static const _storeKey = 'home_hero_enrichment_v1';
  static const _hitTtl = Duration(days: 7);
  static const _missTtl = Duration(days: 1);
  static const _maxEntries = 60;

  Map<String, dynamic>? _disk;
  final Map<String, Future<HeroEnrichment?>> _inFlight = {};
  Future<void> _queue = Future<void>.value();

  static String cacheKey(MultimediaItem item) {
    final clean = cleanHeroTitle(item.title);
    final tv = _isTv(item);
    return '${tv ? 'tv' : 'movie'}|${heroTitleKey(clean.name)}|'
        '${item.year ?? clean.year ?? ''}';
  }

  static bool _isTv(MultimediaItem item) =>
      item.contentType == MultimediaContentType.series ||
      item.contentType == MultimediaContentType.anime;

  Future<Map<String, dynamic>> _load() async {
    final cached = _disk;
    if (cached != null) return cached;
    try {
      final raw = (await _prefs()).getString(_storeKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      _disk = decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      _disk = {};
    }
    return _disk!;
  }

  Future<void> _save() async {
    final disk = _disk;
    if (disk == null) return;
    try {
      if (disk.length > _maxEntries) {
        final keys = disk.keys.toList()
          ..sort(
            (a, b) => (((disk[a] as Map)['at'] as num?) ?? 0).compareTo(
              ((disk[b] as Map)['at'] as num?) ?? 0,
            ),
          );
        for (final k in keys.take(disk.length - _maxEntries)) {
          disk.remove(k);
        }
      }
      await (await _prefs()).setString(_storeKey, jsonEncode(disk));
    } catch (_) {}
  }

  /// The details for [item], or null. Never throws.
  Future<HeroEnrichment?> lookup(MultimediaItem item) {
    if (_apiKey().isEmpty) return Future.value();
    if (item.contentType == MultimediaContentType.livestream) {
      return Future.value();
    }
    final key = cacheKey(item);
    return _inFlight[key] ??= _lookup(item, key).whenComplete(() {
      // A block, not an arrow: returning the removed future here would
      // make it wait for itself.
      _inFlight.remove(key);
    });
  }

  Future<HeroEnrichment?> _lookup(MultimediaItem item, String key) async {
    try {
      final disk = await _load();
      final entry = disk[key];
      if (entry is Map) {
        final at = DateTime.fromMillisecondsSinceEpoch(
          (entry['at'] as num?)?.toInt() ?? 0,
        );
        final data = entry['d'];
        final ttl = data == null ? _missTtl : _hitTtl;
        if (_now().difference(at) < ttl) {
          return data is Map
              ? HeroEnrichment.fromJson(Map<String, dynamic>.from(data))
              : null;
        }
      }
      // One title at a time: a hero has seven, and TMDB is not hammered.
      final done = Completer<void>();
      final before = _queue;
      _queue = done.future;
      await before;
      (HeroEnrichment?, bool) result;
      try {
        result = await _fetch(item);
      } finally {
        done.complete();
      }
      final (found, answered) = result;
      // Only an answer is remembered; a network failure is tried again.
      if (answered) {
        disk[key] = {
          'at': _now().millisecondsSinceEpoch,
          'd': found?.toJson(),
        };
        unawaited(_save());
      }
      return found;
    } catch (_) {
      return null;
    }
  }

  /// How many search results the alternate-title pass asks TMDB about:
  /// the most popular few. TMDB's search already ranks by relevance,
  /// and the right film is near the top; eight bounds the extra calls
  /// a miss costs, and a miss is remembered for a day.
  static const _altTitleCandidates = 8;

  /// (match, whether TMDB answered at all). For the most popular few
  /// [results], fetches each one's alternate titles and keeps the ones
  /// the plugin title equals exactly after cleaning, under the same
  /// year and popularity rules as the title match. A network failure
  /// is not an answer: the miss is not remembered, it is tried again.
  Future<(Map<String, dynamic>?, bool)> _matchByAlternateTitle(
    List<Map<String, dynamic>> results, {
    required String title,
    required int? year,
    required bool tv,
  }) async {
    final ordered = [...results]
      ..sort(
        (a, b) =>
            _heroResultPopularity(b).compareTo(_heroResultPopularity(a)),
      );
    final alternates = <int, List<String>>{};
    for (final r in ordered.take(_altTitleCandidates)) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      final alt = await _get(
        '${TmdbConfig.baseUrl}/${tv ? 'tv' : 'movie'}/$id/alternative_titles',
        {'api_key': _apiKey()},
      );
      if (alt == null) return (null, false);
      alternates[id] = heroAlternateTitles(alt);
    }
    return (
      pickHeroAltMatch(results, alternates, title: title, year: year),
      true,
    );
  }

  /// (details, whether TMDB answered at all).
  Future<(HeroEnrichment?, bool)> _fetch(MultimediaItem item) async {    final clean = cleanHeroTitle(item.title);
    if (clean.name.length < 2) return (null, true);
    final year = item.year ?? clean.year;
    var tv = _isTv(item);
    int? id = item.tmdbId;
    if (id == null) {
      Future<List<Map<String, dynamic>>?> search(bool asTv) async {
        final res = await _get(
          '${TmdbConfig.baseUrl}/search/${asTv ? 'tv' : 'movie'}',
          {
            'api_key': _apiKey(),
            'query': clean.name,
            'include_adult': false,
            'year': ?(asTv ? null : year),
            'first_air_date_year': ?(asTv ? year : null),
          },
        );
        if (res == null) return null;
        return ((res['results'] as List?) ?? const [])
            .whereType<Map<dynamic, dynamic>>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      }

      final results = await search(tv);
      if (results == null) return (null, false);
      var match = pickHeroMatch(results, title: clean.name, year: year);
      // A plugin that calls everything a movie: try the other kind, but
      // only with a stated year to hold the match to.
      List<Map<String, dynamic>>? otherResults;
      if (match == null && year != null) {
        otherResults = await search(!tv);
        if (otherResults == null) return (null, false);
        match = pickHeroMatch(otherResults, title: clean.name, year: year);
        if (match != null) tv = !tv;
      }
      // Last resort: the film may be listed under another name. The
      // title match above found nothing, so ask TMDB for the
      // candidates' alternate titles and accept one that is the plugin
      // title, under the same strict rules.
      if (match == null) {
        final (alt, answered) = await _matchByAlternateTitle(
          results,
          title: clean.name,
          year: year,
          tv: tv,
        );
        if (!answered) return (null, false);
        match = alt;
        if (match == null && otherResults != null) {
          final (otherAlt, otherAnswered) = await _matchByAlternateTitle(
            otherResults,
            title: clean.name,
            year: year,
            tv: !tv,
          );
          if (!otherAnswered) return (null, false);
          match = otherAlt;
          if (match != null) tv = !tv;
        }
      }
      id = (match?['id'] as num?)?.toInt();
      if (id == null) return (null, true);
    }
    final details = await _get(
      '${TmdbConfig.baseUrl}/${tv ? 'tv' : 'movie'}/$id',
      {
        'api_key': _apiKey(),
        'language': 'en-US',
        'append_to_response':
            '${tv ? 'content_ratings' : 'release_dates'},external_ids,images',
        'include_image_language': 'en,null',
      },
    );
    if (details == null) return (null, false);
    final imdbId =
        (details['imdb_id'] ?? (details['external_ids'] as Map?)?['imdb_id'])
            as String?;
    double? imdbScore;
    if (imdbId != null && imdbId.startsWith('tt')) {
      final meta = await _get(
        'https://v3-cinemeta.strem.io/meta/${tv ? 'series' : 'movie'}/'
        '$imdbId.json',
        const {},
      );
      final raw = (meta?['meta'] as Map?)?['imdbRating'];
      imdbScore = raw == null ? null : double.tryParse('$raw');
    }
    return (
      heroEnrichmentFromDetails(details, tv: tv, imdbScore: imdbScore),
      true,
    );
  }
}

final heroEnrichmentServiceProvider = Provider<HeroEnrichmentService>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );
  ref.onDispose(dio.close);
  return HeroEnrichmentService(
    apiKey: () => TmdbConfig.apiKey,
    get: (url, query) async {
      try {
        final res = await dio.get<dynamic>(url, queryParameters: query);
        final data = res.data;
        if (res.statusCode == 200 && data is Map) {
          return Map<String, dynamic>.from(data);
        }
      } catch (_) {
        // Quiet on purpose: the request URL carries the TMDB key.
      }
      return null;
    },
  );
});

/// The Home hero's details for one item; null until (and unless) found.
final heroEnrichmentProvider = FutureProvider.family<HeroEnrichment?, String>((
  ref,
  key,
) {
  final item = ref.watch(_heroItemsProvider)[key];
  if (item == null) return null;
  return ref.watch(heroEnrichmentServiceProvider).lookup(item);
});

/// The items the hero asked about, by cache key, so the family above can
/// be keyed by a plain string.
final _heroItemsProvider = Provider<Map<String, MultimediaItem>>((ref) => {});

/// Registers [item] and returns its details if they are already known.
HeroEnrichment? watchHeroEnrichment(WidgetRef ref, MultimediaItem item) {
  if (TmdbConfig.apiKey.isEmpty) return null;
  final key = HeroEnrichmentService.cacheKey(item);
  ref.read(_heroItemsProvider)[key] = item;
  return ref.watch(heroEnrichmentProvider(key)).asData?.value;
}
