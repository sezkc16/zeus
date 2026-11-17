// The version string Settings shows: `2.9.0 +42`, or the version alone
// when the build number is not a build number.
//
// `PackageInfo.fromPlatform` caches its first result in a static, so the
// three cases are driven through the package's own test hook
// (`setMockInitialValues`), which writes that static directly — no
// platform channel is involved.
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zorox/features/settings/presentation/app_version_provider.dart';

void main() {
  void mockInfo({required String version, required String buildNumber}) {
    PackageInfo.setMockInitialValues(
      appName: 'ZoroX',
      packageName: 'com.toji.zorox',
      version: version,
      buildNumber: buildNumber,
      buildSignature: '',
      installerStore: null,
    );
  }

  test('renders version + build normally', () async {
    mockInfo(version: '2.9.19', buildNumber: '58');
    expect(await readAppVersion(), '2.9.19 +58');
  });

  test('a build number that equals the version is not rendered', () async {
    // The v1 bug: the phone showed "2.9.19 +2.9.19" while the plist
    // carried build 57 — the build had arrived as the version string.
    mockInfo(version: '2.9.19', buildNumber: '2.9.19');
    expect(await readAppVersion(), '2.9.19');
  });

  test('an empty build number renders the version only', () async {
    mockInfo(version: '2.9.19', buildNumber: '');
    expect(await readAppVersion(), '2.9.19');
  });

  test('the first public release: 1.0.0 build 65', () async {
    mockInfo(version: '1.0.0', buildNumber: '65');
    expect(await readAppVersion(), '1.0.0 +65');
  });
}
