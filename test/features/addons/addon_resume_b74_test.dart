// Build 74: a Stremio title resumes — from Continue Watching and from
// its page — on the source it last played on.
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/addons/models/addon_stream_source.dart';
import 'package:zorox/features/addons/presentation/addon_resume_intent.dart';

AddonStreamSource _source(String addon, String name, {String? url}) =>
    AddonStreamSource(
      addonId: addon.toLowerCase(),
      addonName: addon,
      name: name,
      url: url ?? 'https://example.invalid/$addon/$name',
    );

void main() {
  group('resumeSourceFor', () {
    final a = _source('4KHDHub', '4KHDHub 2160p');
    final b = _source('Torrentio', 'Torrentio 1080p');

    test('no memory, nothing plays by itself', () {
      expect(resumeSourceFor([a, b], null), isNull);
      expect(resumeSourceFor([a, b], ''), isNull);
    });

    test('the remembered source is picked wherever it sits', () {
      expect(resumeSourceFor([a, b], addonSourceKey(b)), same(b));
      expect(resumeSourceFor([b, a], addonSourceKey(a)), same(a));
    });

    test('a remembered source that has not answered is not replaced', () {
      expect(resumeSourceFor([a], addonSourceKey(b)), isNull);
      expect(resumeSourceFor(const [], addonSourceKey(b)), isNull);
    });

    test('the memory survives a new link for the same source', () {
      final fresh = _source(
        '4KHDHub',
        '4KHDHub 2160p',
        url: 'https://example.invalid/new-link',
      );
      expect(resumeSourceFor([b, fresh], addonSourceKey(a)), same(fresh));
    });
  });

  group('AddonResumeIntent', () {
    setUp(AddonResumeIntent.clear);

    test('is true once, for the title that was asked', () {
      AddonResumeIntent.request('tt4154796');
      expect(AddonResumeIntent.consume('tt0000001'), isFalse);
      expect(AddonResumeIntent.consume('tt4154796'), isTrue);
      expect(AddonResumeIntent.consume('tt4154796'), isFalse);
    });

    test('nothing asked, nothing resumes', () {
      expect(AddonResumeIntent.consume('tt4154796'), isFalse);
    });

    test('a stale note does not start a later visit', () {
      final at = DateTime(2026, 11, 18, 15);
      AddonResumeIntent.request('tt4154796', now: at);
      expect(
        AddonResumeIntent.consume(
          'tt4154796',
          now: at.add(const Duration(minutes: 2)),
        ),
        isFalse,
      );
      // And it is spent.
      expect(AddonResumeIntent.consume('tt4154796', now: at), isFalse);
    });

    test('a newer tap replaces an older one', () {
      AddonResumeIntent.request('tt1');
      AddonResumeIntent.request('tt2');
      expect(AddonResumeIntent.consume('tt1'), isFalse);
      expect(AddonResumeIntent.consume('tt2'), isTrue);
    });
  });

  test('addonHasResume draws the line at five seconds', () {
    expect(addonHasResume(0), isFalse);
    expect(addonHasResume(5000), isFalse);
    expect(addonHasResume(5001), isTrue);
  });
}
