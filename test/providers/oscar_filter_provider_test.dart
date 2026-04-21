import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/providers/oscar_filter_provider.dart';

/// Per-mode persistence for the "Oscar winners only" filter.
/// The toggle defaults to false in BOTH modes — most users want a wide pool
/// when they open Home; opting into Oscar-only is the deliberate narrowing.
void main() {
  group('ModeOscarController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('defaults to false for both modes when prefs are empty', () async {
      final prefs = await SharedPreferences.getInstance();
      final map = ModeOscarController.readAll(prefs);
      expect(map[ViewMode.solo], false);
      expect(map[ViewMode.together], false);
    });

    test('setting solo does not flip together (modes are independent)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final c =
          ModeOscarController(prefs, ModeOscarController.readAll(prefs));
      await c.set(ViewMode.solo, true);
      expect(c.state[ViewMode.solo], true);
      expect(c.state[ViewMode.together], false);
    });

    test('persists under wn_oscar_winners_{solo,together}', () async {
      final prefs = await SharedPreferences.getInstance();
      final c =
          ModeOscarController(prefs, ModeOscarController.readAll(prefs));
      await c.set(ViewMode.solo, true);
      await c.set(ViewMode.together, true);
      expect(prefs.getBool('wn_oscar_winners_solo'), true);
      expect(prefs.getBool('wn_oscar_winners_together'), true);
    });

    test('set(false) removes the key — keeps prefs tidy', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_oscar_winners_solo': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final c =
          ModeOscarController(prefs, ModeOscarController.readAll(prefs));
      expect(c.state[ViewMode.solo], true);

      await c.set(ViewMode.solo, false);
      expect(c.state[ViewMode.solo], false);
      expect(prefs.containsKey('wn_oscar_winners_solo'), isFalse);
    });

    test('rehydrates true value across cold start', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_oscar_winners_together': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeOscarController.readAll(prefs);
      expect(map[ViewMode.together], true);
      expect(map[ViewMode.solo], false);
    });
  });
}
