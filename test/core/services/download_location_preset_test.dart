import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/services/download_service.dart';

/// The download-location presets, resolved against a Documents directory —
/// no device, no Hive, no picker.
void main() {
  const documents = '/var/mobile/Containers/Data/Application/UUID/Documents';

  group('downloadLocationPresetDirectory', () {
    test('the default stores no custom directory', () {
      expect(
        downloadLocationPresetDirectory(
          DownloadLocationPreset.defaultLocation,
          documents,
        ),
        isNull,
      );
    });

    test('Files › Downloads stores Documents/Downloads', () {
      expect(
        downloadLocationPresetDirectory(
          DownloadLocationPreset.filesDownloads,
          documents,
        ),
        '$documents/Downloads',
      );
    });
  });

  group('downloadLocationPresetOf', () {
    test('null and blank are the default', () {
      expect(
        downloadLocationPresetOf(null, documents),
        DownloadLocationPreset.defaultLocation,
      );
      expect(
        downloadLocationPresetOf('   ', documents),
        DownloadLocationPreset.defaultLocation,
      );
    });

    test('Documents/Downloads is the Files preset', () {
      expect(
        downloadLocationPresetOf('$documents/Downloads', documents),
        DownloadLocationPreset.filesDownloads,
      );
    });

    test('anything else is Custom', () {
      expect(
        downloadLocationPresetOf('/tmp/somewhere-else', documents),
        DownloadLocationPreset.custom,
      );
      expect(
        downloadLocationPresetOf(documents, documents),
        DownloadLocationPreset.custom,
        reason:
            'the Documents folder itself is not a preset — the default '
            'already means Documents/ZoroX, so storing it as custom would '
            'be a second name for the same place',
      );
    });
  });
}
