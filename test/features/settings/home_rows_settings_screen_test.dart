// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/core/extensions/extension_manager.dart';
import 'package:zorox/core/storage/settings_repository.dart';
import 'package:zorox/features/home/presentation/home_provider.dart';
import 'package:zorox/features/home/presentation/home_row_prefs.dart';
import 'package:zorox/features/home/presentation/home_state.dart';
import 'package:zorox/features/settings/presentation/home_rows_settings_screen.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

/// Settings → General → Home rows (v7): the screen lists the current
/// source's rows, a switch hides one, Reset to Default clears it, and with
/// nothing loaded it says so instead of showing an empty page.

class _Repo implements SettingsRepository {
  String? saved;

  @override
  String? getHomeRowPrefsJson() => saved;

  @override
  Future<void> setHomeRowPrefsJson(String? json) async => saved = json;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MultimediaItem _item(String t) =>
    MultimediaItem(title: t, url: 'https://t.test/$t', posterUrl: '');

void main() {
  Future<_Repo> pump(WidgetTester tester, HomeState home) async {
    final repo = _Repo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repo),
          activeProviderProvider.overrideWithValue(null),
          homeDataProvider.overrideWithValue(home),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomeRowsSettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    return repo;
  }

  final feed = HomeSuccess({
    'Trending': [_item('hero')],
    'Popular Anime': [_item('a')],
    'Top Movies in 4K': [_item('b')],
  });

  testWidgets('lists Continue Watching and the feed rows, not the hero row', (
    tester,
  ) async {
    await pump(tester, feed);
    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('Popular Anime'), findsOneWidget);
    expect(find.text('Top Movies in 4K'), findsOneWidget);
    expect(find.text('Trending'), findsNothing);
    expect(find.text('ROWS FROM DEFAULT FEED'), findsOneWidget);
  });

  testWidgets('a switch hides a row for this source; reset brings it back', (
    tester,
  ) async {
    final repo = await pump(tester, feed);
    await tester.tap(
      find.byKey(const ValueKey('home-row-switch-Popular Anime')),
    );
    await tester.pump();
    final saved = decodeHomeRowPrefs(repo.saved);
    expect(saved[kHomeRowsKeyFreeSource]!.hidden, {'Popular Anime'});
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('home-row-switch-Popular Anime')),
          )
          .value,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('home-rows-reset')));
    await tester.pump();
    expect(repo.saved, isNull);
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('home-row-switch-Popular Anime')),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('rows not loaded: says so, still lists Continue Watching', (
    tester,
  ) async {
    await pump(tester, const HomeError('boom'));
    expect(find.text('Continue Watching'), findsOneWidget);
    expect(
      find.textContaining("Open Home once to load this source's rows."),
      findsOneWidget,
    );

    await pump(tester, const HomeLoading());
    expect(find.textContaining("Loading this source's rows"), findsOneWidget);
  });
}
