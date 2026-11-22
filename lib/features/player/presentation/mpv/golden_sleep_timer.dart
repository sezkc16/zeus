/// The sleep timer's two pieces of golden chrome: the picker section the
/// Video drawer shows at its top, and the small remaining-time badge the
/// bottom bar shows while a timer is armed.
///
/// Both only read and drive the screen's one [SleepTimer]; the rules
/// (what fires when) live in `domain/sleep_timer.dart`.
library;

import 'package:flutter/material.dart';
import 'package:zorox/l10n/generated/app_localizations.dart';

import '../../domain/sleep_timer.dart';
import 'golden_player_theme.dart';

/// "Sleep timer" in the drawer: Off / 15 min / 30 min / 60 min / End of
/// episode as pills, the armed one filled, and the remaining time beside
/// the section label while a timed sleep counts down.
class GoldenSleepTimerSection extends StatelessWidget {
  const GoldenSleepTimerSection({required this.timer, super.key});

  final SleepTimer timer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        final mode = timer.mode;
        final selected = timer.selectedDuration;
        final remaining = timer.remaining;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: GoldenSectionLabel(l10n.playerSleepTimer)),
                if (mode != SleepTimerMode.off)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                    child: Text(
                      remaining != null
                          ? l10n.playerSleepTimerRemaining(
                              formatSleepRemaining(remaining),
                            )
                          : l10n.playerSleepTimerEndOfEpisodeArmed,
                      key: const Key('sleep-timer-status'),
                      style: const TextStyle(
                        color: GoldenPlayerColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                GoldenPill(
                  key: const Key('sleep-timer-off'),
                  filled: mode == SleepTimerMode.off,
                  onTap: timer.cancel,
                  child: Text(l10n.playerSleepTimerOff),
                ),
                for (final duration in kSleepTimerDurations)
                  GoldenPill(
                    key: Key('sleep-timer-${duration.inMinutes}'),
                    filled: selected == duration,
                    onTap: () => timer.start(duration),
                    child: Text(
                      l10n.playerSleepTimerMinutes(duration.inMinutes),
                    ),
                  ),
                GoldenPill(
                  key: const Key('sleep-timer-end-of-episode'),
                  filled: mode == SleepTimerMode.endOfEpisode,
                  onTap: timer.armEndOfEpisode,
                  child: Text(l10n.playerSleepTimerEndOfEpisode),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        );
      },
    );
  }
}

/// The bottom bar's badge: a moon and the remaining time ("14:05"), or
/// the moon and "End of episode". Renders nothing while no timer is
/// armed, so the bar looks exactly as it did. A tap opens the drawer the
/// picker lives in.
class GoldenSleepTimerBadge extends StatelessWidget {
  const GoldenSleepTimerBadge({required this.timer, this.onTap, super.key});

  final SleepTimer timer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        if (!timer.isActive) return const SizedBox.shrink();
        final remaining = timer.remaining;
        final text = remaining != null
            ? formatSleepRemaining(remaining)
            : l10n.playerSleepTimerEndOfEpisode;
        final badge = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.bedtime_rounded,
                size: 14,
                color: GoldenPlayerColors.accentHighlight(context),
              ),
              const SizedBox(width: 4),
              Text(
                text,
                key: const Key('sleep-timer-badge-text'),
                maxLines: 1,
                style: const TextStyle(
                  color: GoldenPlayerColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
        return Semantics(
          label: l10n.playerSleepTimer,
          child: onTap == null
              ? badge
              : InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(
                    GoldenPlayerRadii.pill,
                  ),
                  child: badge,
                ),
        );
      },
    );
  }
}
