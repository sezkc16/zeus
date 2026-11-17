// The first public release is tagged `v1` and the app is 1.0.0: the
// updater must read them as the same version (no prompt), and later short
// tags (`v1.1`, `v2`) as newer.
import 'package:flutter_test/flutter_test.dart';
import 'package:version/version.dart';
import 'package:zorox/core/services/update_service.dart';

void main() {
  final app = parseReleaseVersion('1.0.0');

  test('tag v1 equals app 1.0.0: no update, no downgrade', () {
    expect(parseReleaseVersion('v1'), Version(1, 0, 0));
    expect(parseReleaseVersion('v1') > app, isFalse);
    expect(parseReleaseVersion('v1') < app, isFalse);
    expect(parseReleaseVersion('1'), app);
    expect(parseReleaseVersion('v1.0'), app);
    expect(parseReleaseVersion('v1.0.0'), app);
    expect(parseReleaseVersion('V1'), app);
  });

  test('later tags are newer, short or full', () {
    expect(parseReleaseVersion('v1.1') > app, isTrue);
    expect(parseReleaseVersion('v1.0.1') > app, isTrue);
    expect(parseReleaseVersion('v2') > app, isTrue);
    expect(parseReleaseVersion('v2') > parseReleaseVersion('v1.9'), isTrue);
    expect(parseReleaseVersion('v1.10') > parseReleaseVersion('v1.9'), isTrue);
  });

  test('full versions with build metadata still parse', () {
    expect(parseReleaseVersion('2.9.19+64'), Version.parse('2.9.19+64'));
    expect(parseReleaseVersion('  v1.2.3 '), Version(1, 2, 3));
  });

  test('a tag that is not a version throws, which means "no update"', () {
    expect(() => parseReleaseVersion('latest'), throwsFormatException);
    expect(() => parseReleaseVersion(''), throwsFormatException);
  });
}
