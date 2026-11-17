// Settings rows carry Reicon icons, not emoji (public 1.0.0): accent
// icon on an accent-tinted tile, one constant for the weight.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/icons/reicon_icon.dart';
import 'package:zorox/features/settings/presentation/widgets/settings_widgets.dart';

/// Pictographs, dingbats, arrows, geometric shapes, enclosed letters and
/// the joiners/selectors that build emoji sequences.
final RegExp _emoji = RegExp(
  '[\u{1F000}-\u{1FAFF}\u{2190}-\u{21FF}\u{2300}-\u{23FF}\u{25A0}-\u{27BF}'
  '\u{2900}-\u{297F}\u{2B00}-\u{2BFF}\u{FE0F}]',
  unicode: true,
);

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));

void main() {
  test('no Settings row still passes an emoji', () {
    final offenders = <String>[];
    for (final dir in <String>[
      'lib/features/settings',
      'lib/features/account',
      'lib/features/extensions',
    ]) {
      for (final file in _dartFiles(dir)) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (RegExp(r'\bemoji\s*:').hasMatch(line)) {
            offenders.add('${file.path}:${i + 1}: emoji: argument');
          }
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('SettingsTile has no emoji parameter any more', () {
    final source = File(
      'lib/features/settings/presentation/widgets/settings_widgets.dart',
    ).readAsStringSync();
    expect(source.contains('emoji'), isFalse);
  });

  test('no emoji in the string literals of the Settings screens', () {
    final offenders = <String>[];
    for (final file in _dartFiles('lib/features/settings')) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        if (_emoji.hasMatch(code)) {
          offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('the weight is one constant, and it is Filled', () {
    expect(kSettingsIconWeight, ReiconWeight.filled);
  });

  test('every vendored icon has both weights and is valid markup', () {
    expect(Reicon.values.length, greaterThan(50));
    for (final icon in Reicon.values) {
      expect(icon.outline, isNotEmpty, reason: icon.name);
      expect(icon.filled, isNotEmpty, reason: icon.name);
      for (final weight in ReiconWeight.values) {
        final svg = reiconSvg(icon, weight);
        expect(svg.startsWith('<svg'), isTrue);
        expect(svg.contains('viewBox="0 0 24 24"'), isTrue);
        expect(svg.endsWith('</svg>'), isTrue);
      }
    }
  });

  test('the MIT notice travels with the icons', () {
    for (final path in <String>[
      'lib/core/icons/reicon_data.dart',
      'NOTICE.md',
    ]) {
      final text = File(path).readAsStringSync();
      expect(text.contains('Copyright (c) 2026 Dev Chauhan'), isTrue, reason: path);
      expect(text.contains('MIT License'), isTrue, reason: path);
    }
    // Vendored, not a dependency.
    expect(
      File('pubspec.yaml').readAsStringSync().contains('reicon_flutter'),
      isFalse,
    );
  });

  for (final accent in <Color>[
    const Color(0xFF22C55E),
    const Color(0xFFD4AF37),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('tile: accent icon on a 14% accent tile ($accent, $brightness)', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: brightness,
              colorScheme: ColorScheme.fromSeed(
                seedColor: accent,
                brightness: brightness,
              ).copyWith(primary: accent),
            ),
            home: const Scaffold(
              body: SettingsTile(reicon: Reicon.moon, title: 'Dark Mode'),
            ),
          ),
        );
        await tester.pump();
        final icon = tester.widget<ReiconIcon>(find.byType(ReiconIcon));
        expect(icon.icon, Reicon.moon);
        expect(icon.color, accent);
        expect(icon.size, 21);
        expect(icon.weight, ReiconWeight.filled);
        expect(find.byType(SvgPicture), findsOneWidget);
        final box = tester.widget<Container>(
          find.ancestor(
            of: find.byType(ReiconIcon),
            matching: find.byType(Container),
          ).first,
        );
        expect(tester.getSize(find.byWidget(box)), const Size(36, 36));
        final decoration = box.decoration! as BoxDecoration;
        expect(decoration.color, accent.withValues(alpha: 0.14));
        expect(decoration.borderRadius, BorderRadius.circular(10));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('every vendored icon renders in both weights', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Wrap(
              children: <Widget>[
                for (final icon in Reicon.values)
                  for (final weight in ReiconWeight.values)
                    ReiconIcon(icon, color: Colors.green, weight: weight),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ReiconIcon), findsNWidgets(Reicon.values.length * 2));
  });

  test('Settings rows are open rows: no card, no Divider widget, one padding '
      'constant', () {
    final source = File(
      'lib/features/settings/presentation/widgets/settings_widgets.dart',
    ).readAsStringSync();
    expect(source.contains('Divider('), isFalse);
    expect(source.contains('Border.all(color: Theme.of(context).dividerColor'),
        isFalse);
    expect(
      source.contains('const double kSettingsRowVerticalPadding = 19;'),
      isTrue,
    );
    expect(
      source.contains('minVerticalPadding: kSettingsRowVerticalPadding'),
      isTrue,
    );
  });
}
