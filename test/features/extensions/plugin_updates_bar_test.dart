import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/cloudstream/cloudstream_models.dart';
import 'package:zorox/core/cloudstream/cloudstream_repository.dart';
import 'package:zorox/features/extensions/widgets/plugin_updates_bar.dart';

const _repo = 'https://repo.test/repo.json';
const _other = 'https://other.test/repo.json';

CsPluginInfo _info(String name, int version, {String repo = _repo}) =>
    CsPluginInfo(
      internalName: name,
      name: name,
      url: 'https://cdn.test/$name-v$version.cs3',
      repositoryUrl: repo,
      version: version,
    );

CsInstalledPlugin _installed(
  String name,
  int version, {
  String repo = _repo,
  List<CsProviderInfo> providers = const [CsProviderInfo(name: 'P')],
  int extractors = 0,
  String? loadError,
}) => CsInstalledPlugin(
  info: _info(name, version, repo: repo),
  filePath: '/plugins/$name.cs3',
  providers: providers,
  extractors: extractors,
  loadError: loadError,
);

void main() {
  group('update-available detection', () {
    test('a higher version in the plugin\'s own repository is an update', () {
      final state = CloudStreamState(
        isLoading: false,
        repositories: [
          CsRepository(
            url: _repo,
            name: 'Repo',
            plugins: [_info('Alpha', 3), _info('Beta', 2), _info('Gamma', 1)],
          ),
        ],
        installed: [
          _installed('Alpha', 2),
          _installed('Beta', 2),
          _installed('Gamma', 4),
        ],
      );
      final updates = pluginUpdatesOf(state);
      expect(updates.map((u) => u.installed.info.name), ['Alpha']);
      expect(updates.single.newer.version, 3);
    });

    test('another repository\'s plugin of the same name is not an update', () {
      final state = CloudStreamState(
        isLoading: false,
        repositories: [
          CsRepository(url: _other, name: 'Other', plugins: [
            _info('Alpha', 9, repo: _other),
          ]),
          const CsRepository(url: _repo, name: 'Repo'),
        ],
        installed: [_installed('Alpha', 2)],
      );
      expect(pluginUpdatesOf(state), isEmpty);
    });

    test('a repository that did not answer keeps what is installed', () {
      const state = CloudStreamState(isLoading: false);
      expect(pluginUpdatesOf(state), isEmpty);
    });
  });

  group('Update all', () {
    test('updates one at a time and reports what failed', () async {
      final updates = [
        (installed: _installed('Alpha', 1), newer: _info('Alpha', 2)),
        (installed: _installed('Beta', 1), newer: _info('Beta', 2)),
        (installed: _installed('Gamma', 1), newer: _info('Gamma', 2)),
      ];
      var running = 0;
      var peak = 0;
      final result = await updateAllPlugins(updates, (newer) async {
        running++;
        if (running > peak) peak = running;
        await Future<void>.delayed(Duration.zero);
        running--;
        if (newer.name == 'Beta') throw StateError('download failed');
        return _installed(
          newer.name,
          newer.version,
          loadError: newer.name == 'Gamma' ? 'does not load' : null,
        );
      });
      expect(peak, 1);
      expect(result.updated, ['Alpha']);
      expect(result.failed, ['Beta', 'Gamma']);
    });
  });

  group('warm-up order', () {
    test('source plugins only, the active one first, cut to the limit', () {
      final installed = [
        _installed('Util', 1, providers: const []),
        _installed('Extractor', 1, providers: const [], extractors: 2),
        _installed('Broken', 1, loadError: 'x'),
        for (var i = 0; i < 5; i++) _installed('P$i', 1),
      ];
      final order = CloudStreamRepository.warmUpOrder(
        installed,
        first: (p) => p.info.name == 'P3',
        limit: 3,
      );
      expect(order.map((p) => p.info.name), ['P3', 'P0', 'P1']);
    });
  });
}
