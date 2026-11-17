/// The hairline between Settings rows (1.0.1, design A): present between
/// two consecutive rows of a group, absent above the first row, after the
/// last row, beside a non-row block, and around a hidden row — and it must
/// not change the height of anything.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorox/core/theme/app_theme.dart';
import 'package:zorox/core/theme/theme_variant.dart';
import 'package:zorox/features/settings/presentation/widgets/settings_widgets.dart';

SettingsTile _tile(String title) =>
    SettingsTile(icon: Icons.settings, title: title, subtitle: 'sub');

Future<void> _pump(
  WidgetTester tester,
  List<Widget> children, {
  Brightness brightness = Brightness.dark,
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? ThemeData(brightness: brightness),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsGroup(title: 'General', children: children),
        ),
      ),
    ),
  );
  // A theme change is animated; let it land before reading colours.
  await tester.pumpAndSettle();
}

RenderSettingsRowLine _line(WidgetTester tester, String title) =>
    tester.renderObject<RenderSettingsRowLine>(
      find.ancestor(
        of: find.text(title),
        matching: find.byType(SettingsRowLine),
      ),
    );

void main() {
  testWidgets('a line sits between rows, none above the first, none after '
      'the last', (tester) async {
    await _pump(tester, [_tile('One'), _tile('Two'), _tile('Three')]);

    expect(_line(tester, 'One').hasLineAbove, isFalse);
    expect(_line(tester, 'Two').hasLineAbove, isTrue);
    expect(_line(tester, 'Three').hasLineAbove, isTrue);

    // Exactly rows - 1 lines: nothing is drawn below the last row.
    final lines = tester
        .renderObjectList<RenderSettingsRowLine>(find.byType(SettingsRowLine))
        .where((row) => row.hasLineAbove);
    expect(lines, hasLength(2));

    // Full row width, one pixel thick, centred on the boundary.
    final two = _line(tester, 'Two');
    final box = tester.getRect(
      find.ancestor(
        of: find.text('Two'),
        matching: find.byType(SettingsRowLine),
      ),
    );
    expect(
      two,
      paints..rect(
        rect: Rect.fromLTWH(
          0,
          -kSettingsRowDividerThickness / 2,
          box.width,
          kSettingsRowDividerThickness,
        ),
      ),
    );
    expect(_line(tester, 'One'), isNot(paints..rect()));
  });

  testWidgets('the line adds no height to a row or the group', (tester) async {
    await _pump(tester, [_tile('One')]);
    final single = tester.getSize(find.byType(SettingsTile)).height;

    await _pump(tester, [_tile('One'), _tile('Two'), _tile('Three')]);
    for (final title in ['One', 'Two', 'Three']) {
      expect(
        tester
            .getSize(
              find.ancestor(
                of: find.text(title),
                matching: find.byType(SettingsTile),
              ),
            )
            .height,
        single,
      );
    }
  });

  testWidgets('no line beside a block that is not a row', (tester) async {
    await _pump(tester, [
      const SizedBox(height: 40, child: Text('Theme picker')),
      _tile('One'),
      _tile('Two'),
      const SizedBox(height: 40, child: Text('Swatches')),
      _tile('Three'),
    ]);

    expect(_line(tester, 'One').hasLineAbove, isFalse);
    expect(_line(tester, 'Two').hasLineAbove, isTrue);
    expect(_line(tester, 'Three').hasLineAbove, isFalse);
  });

  testWidgets('a hidden row leaves neither a doubled nor an orphan line', (
    tester,
  ) async {
    await _pump(tester, [
      const SizedBox.shrink(),
      _tile('One'),
      const SizedBox.shrink(),
      _tile('Two'),
      const SizedBox.shrink(),
    ]);

    expect(_line(tester, 'One').hasLineAbove, isFalse);
    expect(_line(tester, 'Two').hasLineAbove, isTrue);
  });

  testWidgets('rows wrapped in a nested column still get their lines', (
    tester,
  ) async {
    await _pump(tester, [
      _tile('One'),
      Builder(
        builder: (_) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [_tile('Two'), _tile('Three')],
        ),
      ),
      _tile('Four'),
    ]);

    expect(_line(tester, 'One').hasLineAbove, isFalse);
    expect(_line(tester, 'Two').hasLineAbove, isTrue);
    expect(_line(tester, 'Three').hasLineAbove, isTrue);
    expect(_line(tester, 'Four').hasLineAbove, isTrue);
  });

  testWidgets('the line follows the theme: light on dark, dark on light', (
    tester,
  ) async {
    await _pump(tester, [_tile('One'), _tile('Two')]);
    final dark = _line(tester, 'Two').color;
    expect(dark.a, closeTo(kSettingsRowDividerOpacity, 0.001));
    expect(dark.computeLuminance(), greaterThan(0.5));

    await _pump(tester, [
      _tile('One'),
      _tile('Two'),
    ], brightness: Brightness.light);
    final light = _line(tester, 'Two').color;
    expect(light.a, closeTo(kSettingsRowDividerOpacity, 0.001));
    expect(light.computeLuminance(), lessThan(0.5));

    // The app's own themes: Liquid Glass (dark) and Frost (light).
    await _pump(
      tester,
      [_tile('One'), _tile('Two')],
      theme: AppTheme.createDarkTheme(
        null,
        variant: ZoroxThemeVariant.liquidGlass,
      ),
    );
    final glass = _line(tester, 'Two');
    expect(glass.hasLineAbove, isTrue);
    expect(glass.color.computeLuminance(), greaterThan(0.5));

    await _pump(
      tester,
      [_tile('One'), _tile('Two')],
      theme: AppTheme.createLightTheme(null, variant: ZoroxThemeVariant.frost),
    );
    final frost = _line(tester, 'Two');
    expect(frost.hasLineAbove, isTrue);
    expect(frost.color.a, closeTo(kSettingsRowDividerOpacity, 0.001));
    expect(frost.color.computeLuminance(), lessThan(0.1));
  });
}
