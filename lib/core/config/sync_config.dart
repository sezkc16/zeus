/// Compile-time configuration for third-party sync / tracking services.
///
/// Every value below is read from a `--dart-define` flag at build time and
/// embedded as a string constant in the compiled binary, so anyone with an APK
/// or IPA can extract it with `strings`. These are not secrets. The OAuth
/// providers involved already assume public client IDs are public and tolerate
/// the "client secret" being shared with the redirect URL for device / PKCE /
/// implicit flows. Rotate the keys if abuse is detected.
class SyncConfig {
  static const String animeSkipClientId = String.fromEnvironment(
    'ANIMESKIP_CLIENT_ID',
  );

  static const String traktClientId = String.fromEnvironment('TRAKT_CLIENT_ID');
  static const String traktClientSecret = String.fromEnvironment(
    'TRAKT_CLIENT_SECRET',
  );

  /// WeTrakr's app key (a public client: device flow, no secret - the
  /// app must never carry one). Supplied at build time and kept out of
  /// the source, as WeTrakr's terms ask; empty in a build without it,
  /// which hides the WeTrakr row.
  static const String wetrakrClientId = String.fromEnvironment(
    'WETRAKR_CLIENT_ID',
  );

  static const String anilistClientId = String.fromEnvironment(
    'ANILIST_CLIENT_ID',
  );

  static const String malClientId = String.fromEnvironment('MAL_CLIENT_ID');
  static const String malClientSecret = String.fromEnvironment(
    'MAL_CLIENT_SECRET',
  );

  /// The redirect MyAnimeList's and AniList's clients have registered.
  /// ZoroX's own browser catches it before it loads, so nothing listens
  /// there: lib/features/tracking/sign_in/.
  static const String signInRedirect = 'http://localhost';

  /// Simkl's V1 app: its PIN sign-in, and the sessions signed in with it,
  /// which keep working until Simkl turns V1 off (about April 2027).
  static const String simklClientId = String.fromEnvironment('SIMKL_CLIENT_ID');
  static const String simklClientSecret = String.fromEnvironment(
    'SIMKL_CLIENT_SECRET',
  );

  /// Simkl's AUTH V2 app, a public client: every new sign-in, by device code,
  /// with no secret. A build without it signs in on V1 as before.
  static const String simklV2ClientId = String.fromEnvironment(
    'SIMKL_V2_CLIENT_ID',
  );
}
