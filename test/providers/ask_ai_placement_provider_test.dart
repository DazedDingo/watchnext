import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/ask_ai_placement_provider.dart';

void main() {
  group('AskAiPlacement', () {
    test('fromName returns the named placement', () {
      expect(AskAiPlacement.fromName('icon'), AskAiPlacement.icon);
      expect(AskAiPlacement.fromName('fab'), AskAiPlacement.fab);
      expect(AskAiPlacement.fromName('hidden'), AskAiPlacement.hidden);
    });

    test('fromName falls back to icon (the new default) on null / unknown',
        () {
      // Existing installs land here on first read post-upgrade — we
      // deliberately move them off the FAB to honour the "less obtrusive
      // by default" intent, even though previous behaviour was FAB-only.
      expect(AskAiPlacement.fromName(null), AskAiPlacement.icon);
      expect(AskAiPlacement.fromName('nonsense'), AskAiPlacement.icon);
    });
  });

  group('AskAiPlacementController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to icon when no prior selection is stored', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = AskAiPlacementController(prefs);
      expect(c.state, AskAiPlacement.icon);
    });

    test('rehydrates stored placement on construction', () async {
      SharedPreferences.setMockInitialValues({'wn_ask_ai_placement': 'fab'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final c = AskAiPlacementController(prefs);
      expect(c.state, AskAiPlacement.fab);
    });

    test('set persists to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = AskAiPlacementController(prefs);
      await c.set(AskAiPlacement.hidden);
      expect(prefs.getString('wn_ask_ai_placement'), 'hidden');
      expect(c.state, AskAiPlacement.hidden);
    });

    test('falls back to icon when stored value is a stale name', () async {
      SharedPreferences.setMockInitialValues(
          {'wn_ask_ai_placement': 'sidebar'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final c = AskAiPlacementController(prefs);
      expect(c.state, AskAiPlacement.icon);
    });
  });
}
