import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/features/player/domain/next_episode_autoplay.dart';

void main() {
  test('the countdown is five seconds', () {
    expect(kNextEpisodeCountdown, const Duration(seconds: 5));
  });

  group('endOfEpisodeAction', () {
    EndOfEpisodeAction act({
      bool hasNext = true,
      bool autoPlay = true,
      bool declined = false,
      bool inPip = false,
      bool stop = false,
    }) => endOfEpisodeAction(
      hasNext: hasNext,
      autoPlay: autoPlay,
      declined: declined,
      inPip: inPip,
      stopRequested: stop,
    );

    test('a next episode with auto-play on counts down', () {
      expect(act(), EndOfEpisodeAction.countdown);
    });
    test('a film or the last episode never advances', () {
      expect(act(hasNext: false), EndOfEpisodeAction.ended);
      expect(act(hasNext: false, inPip: true), EndOfEpisodeAction.ended);
    });
    test('auto-play off stops with Next on the ended card', () {
      expect(act(autoPlay: false), EndOfEpisodeAction.endedWithNext);
      expect(act(autoPlay: false, inPip: true), EndOfEpisodeAction.endedWithNext);
    });
    test('a cancelled card is honoured', () {
      expect(act(declined: true), EndOfEpisodeAction.endedWithNext);
    });
    test('a sleep timer stops it', () {
      expect(act(stop: true), EndOfEpisodeAction.endedWithNext);
      expect(act(stop: true, inPip: true), EndOfEpisodeAction.endedWithNext);
    });
    test('in picture-in-picture it advances without a card', () {
      expect(act(inPip: true), EndOfEpisodeAction.advanceSilently);
    });
  });

  group('shouldOfferAtOutro', () {
    bool offer({
      bool hasNext = true,
      bool autoPlay = true,
      bool declined = false,
      bool inPip = false,
      bool alreadyOffered = false,
      bool cardUp = false,
      double position = 1325,
      double duration = 1420,
      double start = 1320,
      double end = 1415,
    }) => shouldOfferAtOutro(
      hasNext: hasNext,
      autoPlay: autoPlay,
      declined: declined,
      inPip: inPip,
      alreadyOffered: alreadyOffered,
      cardUp: cardUp,
      positionSeconds: position,
      durationSeconds: duration,
      outroStart: start,
      outroEnd: end,
    );

    test('inside an outro that runs to the end', () {
      expect(offer(), isTrue);
    });
    test('not before it starts', () {
      expect(offer(position: 1300), isFalse);
    });
    test('not for an ending followed by more episode', () {
      expect(offer(start: 1200, end: 1290, position: 1210), isFalse);
    });
    test('once per episode, and not over a card already up', () {
      expect(offer(alreadyOffered: true), isFalse);
      expect(offer(cardUp: true), isFalse);
    });
    test('not on a film, with auto-play off, after Cancel, or in PiP', () {
      expect(offer(hasNext: false), isFalse);
      expect(offer(autoPlay: false), isFalse);
      expect(offer(declined: true), isFalse);
      expect(offer(inPip: true), isFalse);
    });
    test('unknown duration offers nothing', () {
      expect(offer(duration: 0), isFalse);
    });
  });
}
