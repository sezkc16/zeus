import 'package:flutter_riverpod/flutter_riverpod.dart' show FutureProvider;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_version_provider.g.dart';

@riverpod
Future<String> appVersion(Ref ref) => readAppVersion();

/// The app's version for providers kept alive for the app's lifetime, such as
/// the CloudStream repository, which records the version a plugin failed to
/// load under.
///
/// [appVersionProvider] is disposed when nothing watches it, and a kept-alive
/// provider reading one of those can see it disposed while the read is still
/// pending (riverpod_lint's `only_use_keep_alive_inside_keep_alive`). This one
/// is kept alive too.
final keptAppVersionProvider = FutureProvider<String>(
  (ref) => readAppVersion(),
);

/// The version and build number, as Settings shows them: `2.9.0 +42`.
///
/// The build number has been observed arriving as the version string
/// itself — "2.9.19 +2.9.19" on a phone whose Info.plist carries build 57
/// — so a build that is not a build number is never rendered: when the
/// build equals the version (or is empty), the version alone is shown,
/// which is also how the approved design preview draws it ("Version
/// 2.9.19", no suffix). The root cause was not proven from static code:
/// the plist is correct, so this guards the display, not the read.
Future<String> readAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  final build = info.buildNumber;
  if (build.isEmpty || build == info.version) return info.version;
  return '${info.version} +$build';
}
