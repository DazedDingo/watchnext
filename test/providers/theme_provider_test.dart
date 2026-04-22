import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/theme_provider.dart';

void main() {
  group('AppAccent', () {
    test('fromName returns the named accent', () {
      expect(AppAccent.fromName('yellow'), AppAccent.yellow);
      expect(AppAccent.fromName('teal'), AppAccent.teal);
    });

    test('fromName falls back to red on unknown / null', () {
      expect(AppAccent.fromName(null), AppAccent.red);
      expect(AppAccent.fromName('nonsense'), AppAccent.red);
    });

    test('every accent has a distinct seed color', () {
      final seeds = AppAccent.values.map((a) => a.seed.toARGB32()).toSet();
      expect(seeds.length, AppAccent.values.length);
    });
  });

  group('AccentController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to red when no prior selection is stored', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = AccentController(prefs);
      expect(c.state, AppAccent.red);
    });

    test('rehydrates stored accent on construction', () async {
      SharedPreferences.setMockInitialValues({'wn_accent': 'yellow'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final c = AccentController(prefs);
      expect(c.state, AppAccent.yellow);
    });

    test('set persists to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = AccentController(prefs);
      await c.set(AppAccent.teal);
      expect(prefs.getString('wn_accent'), 'teal');
      expect(c.state, AppAccent.teal);
    });

    test('gracefully falls back when stored value is a stale accent name',
        () async {
      SharedPreferences.setMockInitialValues({'wn_accent': 'ultraviolet'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final c = AccentController(prefs);
      expect(c.state, AppAccent.red);
    });
  });

  group('themeDataProvider', () {
    test('rebuilds ThemeData from the current accent seed', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        accentProvider.overrideWith((_) => AccentController(prefs)),
      ]);
      addTearDown(container.dispose);

      final redTheme = container.read(themeDataProvider);
      expect(redTheme.brightness.name, 'dark');
      expect(redTheme.useMaterial3, isTrue);

      await container.read(accentProvider.notifier).set(AppAccent.yellow);
      final yellowTheme = container.read(themeDataProvider);
      // Primary swatch should actually change when the seed rotates.
      expect(yellowTheme.colorScheme.primary,
          isNot(equals(redTheme.colorScheme.primary)));
    });
  });
}
