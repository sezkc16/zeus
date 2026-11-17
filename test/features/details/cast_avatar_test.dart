/// A cast member's picture (v8): the photo when there is one - sent with the
/// title, or looked up by name - and initials otherwise; never a
/// broken-image icon or the name inside the circle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/models/tmdb_details.dart';
import 'package:zorox/features/details/data/cast_photo_service.dart';
import 'package:zorox/features/details/presentation/widgets/cast_avatar.dart';
import 'package:zorox/features/details/presentation/widgets/movie_cast_list.dart';

Finder get _photo => find.byKey(const ValueKey('cast-photo'));
Finder get _initials => find.byKey(const ValueKey('cast-initials'));

Future<void> _pump(WidgetTester tester, CastPhotoService service) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [castPhotoServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        home: Scaffold(
          body: MovieCastList(
            lookupPhotos: true,
            cast: [
              TmdbCast(name: 'Matt Damon', character: ''),
              TmdbCast(name: 'Nobody Known', character: ''),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  test('initials', () {
    expect(castInitials('Matt Damon'), 'MD');
    expect(castInitials('  Anne   Marie Hathaway '), 'AH');
    expect(castInitials('Zendaya'), 'ZE');
    expect(castInitials(''), '?');
  });

  test('only the person with exactly that name is taken, sized down', () {
    final body = {
      'd': [
        {
          'id': 'tt1',
          'l': 'Matt Damon',
          'i': {'imageUrl': 'https://img.test/film._V1_.jpg'},
        },
        {
          'id': 'nm2',
          'l': 'Matt Damonn',
          'i': {'imageUrl': 'https://img.test/other._V1_.jpg'},
        },
        {
          'id': 'nm0000354',
          'l': 'Matt  DAMON',
          'i': {'imageUrl': 'https://img.test/md._V1_CR1,2,3,4_.jpg'},
        },
      ],
    };
    expect(
      CastPhotoService.pickPhoto(body, 'matt damon'),
      'https://img.test/md._V1_UX240_.jpg',
    );
    expect(CastPhotoService.pickPhoto(body, 'someone else'), isNull);
    expect(CastPhotoService.pickPhoto('nonsense', 'x'), isNull);
  });

  testWidgets('a looked-up photo is used; no photo means initials', (
    tester,
  ) async {
    final asked = <String>[];
    final service = CastPhotoService((url) async {
      asked.add(url);
      if (!url.contains('matt')) return {'d': <Object>[]};
      return {
        'd': [
          {
            'id': 'nm0000354',
            'l': 'Matt Damon',
            'i': {'imageUrl': 'https://img.test/md._V1_.jpg'},
          },
        ],
      };
    });
    await _pump(tester, service);
    expect(asked, hasLength(2));
    expect(_photo, findsOneWidget);
    expect(find.text('NK'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    // The name is under the circle once, not inside it again.
    expect(find.text('Nobody Known'), findsOneWidget);
  });

  testWidgets('a lookup that fails shows initials for everyone', (
    tester,
  ) async {
    await _pump(tester, CastPhotoService((_) async => throw Exception('off')));
    expect(_photo, findsNothing);
    expect(_initials, findsNWidgets(2));
    expect(find.text('MD'), findsOneWidget);
  });
}
