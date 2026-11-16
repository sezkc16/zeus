import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/data/models/github_release.dart';
import 'package:zorox/core/services/update_service.dart';

GithubAsset _asset(String name) => GithubAsset(
  name: name,
  browserDownloadUrl: 'https://example.com/$name',
  size: 1,
  contentType: 'application/octet-stream',
);

/// A release as release.yml publishes it for Linux.
final _release = [
  for (final arch in ['x64', 'arm64'])
    for (final ext in ['tar.gz', 'deb', 'AppImage'])
      _asset('zorox-linux-$arch-2.9.0.$ext'),
  _asset('zorox-windows-x64-2.9.0.exe'),
];

void main() {
  group('linuxInstallOf', () {
    test('an AppImage: the runtime set APPIMAGE and APPDIR, and the binary '
        'runs from inside APPDIR', () {
      expect(
        UpdateService.linuxInstallOf(
          environment: {
            'APPIMAGE': '/home/u/Apps/ZoroX.AppImage',
            'APPDIR': '/tmp/.mount_ZoroXAbC123',
          },
          executable: '/tmp/.mount_ZoroXAbC123/opt/zorox/zorox',
        ),
        LinuxInstall.appImage,
      );
    });

    test('APPIMAGE inherited from another AppImage that started ZoroX '
        'is not an AppImage install', () {
      expect(
        UpdateService.linuxInstallOf(
          environment: {
            'APPIMAGE': '/home/u/Apps/Launcher.AppImage',
            'APPDIR': '/tmp/.mount_LauncXyZ789',
          },
          executable: '/opt/zorox/zorox',
        ),
        LinuxInstall.deb,
      );
    });

    test('the .deb installs to /opt/zorox', () {
      expect(
        UpdateService.linuxInstallOf(
          environment: const {},
          executable: '/opt/zorox/zorox',
        ),
        LinuxInstall.deb,
      );
    });

    test('anything else is the tarball, unpacked wherever its owner chose', () {
      expect(
        UpdateService.linuxInstallOf(
          environment: const {},
          executable: '/home/u/zorox/zorox',
        ),
        LinuxInstall.tarball,
      );
      expect(
        UpdateService.linuxInstallOf(
          environment: const {},
          executable: '/opt/zorox-old/zorox',
        ),
        LinuxInstall.tarball,
      );
    });
  });

  group('linuxAsset', () {
    test('each install gets its own format, for its architecture', () {
      expect(
        UpdateService.linuxAsset(
          _release,
          isArm: false,
          install: LinuxInstall.appImage,
        )?.name,
        'zorox-linux-x64-2.9.0.AppImage',
      );
      expect(
        UpdateService.linuxAsset(
          _release,
          isArm: true,
          install: LinuxInstall.deb,
        )?.name,
        'zorox-linux-arm64-2.9.0.deb',
      );
      expect(
        UpdateService.linuxAsset(
          _release,
          isArm: false,
          install: LinuxInstall.tarball,
        )?.name,
        'zorox-linux-x64-2.9.0.tar.gz',
      );
    });

    test('a .deb install is never sent an AppImage, which would install a '
        'second copy beside it', () {
      expect(
        UpdateService.linuxAsset(
          _release,
          isArm: false,
          install: LinuxInstall.deb,
        )?.name,
        endsWith('.deb'),
      );
    });

    test('none when the release lacks the format, so the release page opens '
        'instead', () {
      final withoutAppImage = _release
          .where((a) => !a.name.endsWith('.AppImage'))
          .toList();
      expect(
        UpdateService.linuxAsset(
          withoutAppImage,
          isArm: false,
          install: LinuxInstall.appImage,
        ),
        isNull,
      );
    });

    test('never an asset for the other architecture', () {
      final x64Only = _release.where((a) => a.name.contains('x64')).toList();
      expect(
        UpdateService.linuxAsset(
          x64Only,
          isArm: true,
          install: LinuxInstall.deb,
        ),
        isNull,
      );
    });

    test('x86_64 and amd64 name the x64 build too', () {
      expect(
        UpdateService.linuxAsset(
          [_asset('zorox-linux-x86_64.AppImage')],
          isArm: false,
          install: LinuxInstall.appImage,
        )?.name,
        'zorox-linux-x86_64.AppImage',
      );
      expect(
        UpdateService.linuxAsset(
          [_asset('zorox-linux-amd64.deb')],
          isArm: false,
          install: LinuxInstall.deb,
        )?.name,
        'zorox-linux-amd64.deb',
      );
    });

    test('a name without an architecture serves either', () {
      expect(
        UpdateService.linuxAsset(
          [_asset('zorox-linux.deb')],
          isArm: true,
          install: LinuxInstall.deb,
        )?.name,
        'zorox-linux.deb',
      );
    });
  });
}
