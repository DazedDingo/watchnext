import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/exclude_animation_provider.dart';
import 'package:watchnext/providers/mode_provider.dart';

/// Per-mode persistence for the "Exclude animation" toggle.
/// Default is false in both modes — most users aren't strict about it; Solo
/// might opt in for grown-up picks while Together allows kid-friendly nights.
void main() {
  group('ModeExcludeAnimationController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('defaults to false for both modes when prefs empty', () async {
      final prefs = await SharedPreferences.getInstance();
      final map = ModeExcludeAnimationController.readAll(prefs);
      expect(map[ViewMode.solo], false);
      expect(map[ViewMode.together], false);
    });

    test('setting solo does not flip together (modes are independent)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeExcludeAnimationController(
          prefs, ModeExcludeAnimationController.readAll(prefs));
      await c.set(ViewMode.solo, true);
      expect(c.state[ViewMode.solo], true);
      expect(c.state[ViewMode.together], false);
    });

    test('persists under wn_exclude_animation_{solo,together}', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeExcludeAnimationController(
          prefs, ModeExcludeAnimationController.readAll(prefs));
      await c.set(ViewMode.solo, true);
      await c.set(ViewMode.together, true);
      expect(prefs.getBool('wn_exclude_animation_solo'), true);
      expect(prefs.getBool('wn_exclude_animation_together'), true);
    });

    test('set(false) removes the key — keeps prefs tidy', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_exclude_animation_solo': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeExcludeAnimationController(
          prefs, ModeExcludeAnimationController.readAll(prefs));
      expect(c.state[ViewMode.solo], true);

      await c.set(ViewMode.solo, false);
      expect(c.state[ViewMode.solo], false);
      expect(prefs.containsKey('wn_exclude_animation_solo'), isFalse);
    });

    test('rehydrates true value across cold start', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_exclude_animation_together': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeExcludeAnimationController.readAll(prefs);
      expect(map[ViewMode.together], true);
      expect(map[ViewMode.solo], false);
    });
  });
}
