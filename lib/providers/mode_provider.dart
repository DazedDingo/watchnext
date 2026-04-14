import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/tmdb_service.dart';
import '../services/share_parser.dart';

/// Solo vs Together viewing mode. Persists per-device via SharedPreferences
/// so the toggle state survives restarts without a Firestore round-trip.
/// Phase 7 will also read `members/{uid}.default_mode` on first launch —
/// wiring that lives in the onboarding flow (Phase 11).
enum ViewMode { solo, together }

class ModeController extends StateNotifier<ViewMode> {
  ModeController(this._prefs, ViewMode initial) : super(initial);
  final SharedPreferences _prefs;
  static const _key = 'wn_view_mode';

  Future<void> set(ViewMode mode) async {
    state = mode;
    await _prefs.setString(_key, mode == ViewMode.solo ? 'solo' : 'together');
  }

  static ViewMode _read(SharedPreferences prefs) {
    final v = prefs.getString(_key);
    return v == 'solo' ? ViewMode.solo : ViewMode.together;
  }
}

final _sharedPrefsProvider = FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final viewModeProvider = StateNotifierProvider<ModeController, ViewMode>((ref) {
  final prefs = ref.watch(_sharedPrefsProvider).value;
  if (prefs == null) return ModeController(_UnsetPrefs(), ViewMode.together);
  return ModeController(prefs, ModeController._read(prefs));
});

/// Sentinel used while SharedPreferences loads on first build. Writes are
/// dropped — the real controller takes over once prefs resolve.
class _UnsetPrefs implements SharedPreferences {
  @override
  Future<bool> setString(String key, String value) async => true;
  @override
  String? getString(String key) => null;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

final shareParserProvider = Provider<ShareParser>((ref) => ShareParser(tmdb: TmdbService()));
