import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the "Ask AI" entry point is rendered on the Home screen.
///
/// `icon` (default) — small AppBar action icon. Discoverable but unobtrusive.
/// `fab`            — extended FloatingActionButton at the bottom-right.
/// `hidden`         — not rendered at all; reach the concierge by flipping
///                    this preference back. The "Like these" button on Home
///                    is unaffected by this setting (different surface).
enum AskAiPlacement {
  icon('Icon in app bar'),
  fab('Floating action button'),
  hidden('Hidden');

  final String label;
  const AskAiPlacement(this.label);

  static AskAiPlacement fromName(String? name) {
    for (final p in AskAiPlacement.values) {
      if (p.name == name) return p;
    }
    return AskAiPlacement.icon;
  }
}

const _kAskAiPlacementKey = 'wn_ask_ai_placement';

class AskAiPlacementController extends StateNotifier<AskAiPlacement> {
  final SharedPreferences _prefs;

  AskAiPlacementController(this._prefs)
      : super(AskAiPlacement.fromName(_prefs.getString(_kAskAiPlacementKey)));

  Future<void> set(AskAiPlacement placement) async {
    state = placement;
    await _prefs.setString(_kAskAiPlacementKey, placement.name);
  }
}

final askAiPlacementProvider =
    StateNotifierProvider<AskAiPlacementController, AskAiPlacement>((ref) {
  throw UnimplementedError('askAiPlacementProvider not initialised');
});
