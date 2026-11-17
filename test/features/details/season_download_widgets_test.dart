import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/domain/entity/multimedia_item.dart';
import 'package:zorox/features/details/domain/season_download.dart';
import 'package:zorox/features/details/presentation/season_download_controller.dart';
import 'package:zorox/features/details/presentation/widgets/season_download_widgets.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

final MultimediaItem _item = MultimediaItem(
  title: 'A Show',
  url: 'https://example.com/a-show',
  posterUrl: '',
);

Episode _ep(int number) => Episode(
  name: 'Episode $number',
  url: 'https://example.com/a-show/e$number',
  season: 1,
  episode: number,
);

/// The controller with its disk and network taken out: the plan is
/// whatever the test says, and a started batch is held open until the
/// test lets it finish.
class _FakeController extends SeasonDownloadController {
  _FakeController(this.planned);

  final SeasonDownloadPlan planned;
  int starts = 0;
  int cancels = 0;

  @override
  Future<SeasonDownloadPlan> plan(
    MultimediaItem item,
    List<Episode> episodes,
  ) async => planned;

  @override
  Future<bool> start({
    required MultimediaItem item,
    required SeasonDownloadPlan plan,
    required AppLocalizations l10n,
    SeasonSourceAsker? askPick,
  }) async {
    starts++;
    state = SeasonDownloadBatch(
      itemUrl: item.url,
      progress: SeasonDownloadProgress(
        total: plan.toDownload.length,
        processed: 2,
        queued: 2,
      ),
      alreadyDownloaded: plan.alreadyDownloaded,
    );
    return true;
  }

  @override
  void cancel() {
    cancels++;
    super.cancel();
  }

  void finish(SeasonDownloadProgress progress) {
    state = state!.copyWith(progress: progress);
  }
}

void main() {
  late _FakeController controller;

  Future<void> pump(WidgetTester tester, SeasonDownloadPlan plan) async {
    final container = ProviderContainer(
      overrides: [
        seasonDownloadControllerProvider.overrideWith(
          () => controller = _FakeController(plan),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    SeasonDownloadButton(
                      item: _item,
                      episodes: <Episode>[for (var i = 1; i <= 12; i++) _ep(i)],
                    ),
                  ],
                ),
                SeasonDownloadStatusBar(itemUrl: _item.url),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('asks with the real count, then queues and shows progress', (
    tester,
  ) async {
    await pump(
      tester,
      SeasonDownloadPlan(
        toDownload: <Episode>[for (var i = 2; i <= 12; i++) _ep(i)],
        alreadyDownloaded: 1,
        alreadyQueued: 0,
      ),
    );
    expect(find.byKey(const Key('season-download-status')), findsNothing);
    expect(find.byTooltip('Download season'), findsOneWidget);

    await tester.tap(find.byKey(const Key('season-download-button')));
    await tester.pumpAndSettle();
    expect(find.text('Download 11 episodes?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('season-download-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.starts, 1);
    expect(find.text('Queuing 3/11…'), findsOneWidget);

    // Stop: asks the controller, and cannot be pressed twice.
    await tester.tap(find.byKey(const Key('season-download-stop')));
    await tester.pump();
    expect(controller.cancels, 1);
    final stop = tester.widget<TextButton>(
      find.byKey(const Key('season-download-stop')),
    );
    expect(stop.onPressed, isNull);

    controller.finish(
      const SeasonDownloadProgress(
        total: 11,
        processed: 4,
        queued: 3,
        noSource: 1,
        finished: true,
        cancelled: true,
      ),
    );
    await tester.pump();
    expect(
      find.text(
        'Queued 3 · 1 already downloaded · 1 no downloadable source · '
        '7 not queued (stopped)',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('season-download-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('season-download-status')), findsNothing);
  });

  testWidgets('cancelling the question queues nothing', (tester) async {
    await pump(
      tester,
      SeasonDownloadPlan(
        toDownload: <Episode>[_ep(1)],
        alreadyDownloaded: 0,
        alreadyQueued: 0,
      ),
    );
    await tester.tap(find.byKey(const Key('season-download-button')));
    await tester.pumpAndSettle();
    expect(find.text('Download 1 episode?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.starts, 0);
  });

  testWidgets('a fully downloaded season says so and offers no download', (
    tester,
  ) async {
    await pump(
      tester,
      const SeasonDownloadPlan(
        toDownload: <Episode>[],
        alreadyDownloaded: 12,
        alreadyQueued: 0,
      ),
    );
    await tester.tap(find.byKey(const Key('season-download-button')));
    await tester.pumpAndSettle();
    expect(
      find.text('All episodes of this season are already downloaded'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('season-download-confirm')), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(controller.starts, 0);
  });

  test('the summary names only what happened', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      seasonDownloadSummary(
        l10n,
        const SeasonDownloadBatch(
          itemUrl: 'u',
          progress: SeasonDownloadProgress(
            total: 11,
            processed: 11,
            queued: 10,
            noSource: 1,
            finished: true,
          ),
          alreadyDownloaded: 1,
        ),
      ),
      'Queued 10 · 1 already downloaded · 1 no downloadable source',
    );
    expect(
      seasonDownloadSummary(
        l10n,
        const SeasonDownloadBatch(
          itemUrl: 'u',
          progress: SeasonDownloadProgress(
            total: 3,
            processed: 3,
            queued: 2,
            failed: 1,
            finished: true,
          ),
          alreadyQueued: 2,
        ),
      ),
      'Queued 2 · 2 already in queue · 1 failed',
    );
  });
}
