/// The decisions behind next-episode auto-play (v7), kept apart from the
/// player screen so they can be tested without one.
library;

/// How long the "Next episode" card counts down before it plays.
const Duration kNextEpisodeCountdown = Duration(seconds: 5);

/// An outro counts as "the end of the episode" only when it runs to within
/// this much of the end of the file: an ending song followed by a scene
/// after the credits must not be cut off by the card.
const double kOutroTailSlackSeconds = 10;

/// What happens when an episode reaches its end.
enum EndOfEpisodeAction {
  /// Raise the "Next episode in 5…" card.
  countdown,

  /// Start the next episode with no card: the player is in
  /// picture-in-picture, where the card could not be seen or pressed.
  advanceSilently,

  /// Stop on the ended card, with Next episode as its main button: a next
  /// episode exists but is not to start on its own (auto-play is off, the
  /// viewer cancelled the card, or a sleep timer said stop here).
  endedWithNext,

  /// Stop on the ended card: a film, or the last episode.
  ended,
}

/// Decides [EndOfEpisodeAction]. A film or a last episode ([hasNext] false)
/// never auto-plays, whatever the setting.
EndOfEpisodeAction endOfEpisodeAction({
  required bool hasNext,
  required bool autoPlay,
  required bool declined,
  required bool inPip,
  bool stopRequested = false,
}) {
  if (!hasNext) return EndOfEpisodeAction.ended;
  if (!autoPlay || declined || stopRequested) {
    return EndOfEpisodeAction.endedWithNext;
  }
  return inPip
      ? EndOfEpisodeAction.advanceSilently
      : EndOfEpisodeAction.countdown;
}

/// Whether the card should come up now because the outro has started,
/// rather than waiting for the last frame.
///
/// Only for an outro that runs to the end of the file (see
/// [kOutroTailSlackSeconds]), once per episode ([alreadyOffered]), with
/// auto-play on, a next episode, no card already up, and not in
/// picture-in-picture (there the episode simply plays to its end and
/// advances). [outroStart] / [outroEnd] are the marked segment, in seconds.
bool shouldOfferAtOutro({
  required bool hasNext,
  required bool autoPlay,
  required bool declined,
  required bool inPip,
  required bool alreadyOffered,
  required bool cardUp,
  required double positionSeconds,
  required double durationSeconds,
  required double outroStart,
  required double outroEnd,
  bool stopRequested = false,
}) {
  if (!hasNext || !autoPlay || declined || inPip || stopRequested) return false;
  if (alreadyOffered || cardUp) return false;
  if (durationSeconds <= 0 || outroEnd <= outroStart) return false;
  if (outroEnd < durationSeconds - kOutroTailSlackSeconds) return false;
  return positionSeconds >= outroStart && positionSeconds < outroEnd;
}
