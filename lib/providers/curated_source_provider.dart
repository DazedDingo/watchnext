import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// Canonical curator-list sources a cinephile might anchor discovery on.
///
/// Currently only [criterion] is wired up (via TMDB company id 1771, the
/// Criterion Collection's distributor tag — stable and documented). Other
/// curator lists (Sight & Sound 250, AFI 100, MUBI) will be added as
/// separate enum cases once we pin canonical ids. When a source is active,
/// `recommendations_service.refresh()` suppresses the trending + top_rated
/// baseline — those surfaces would dilute a curator-scoped pool.
///
/// Persisted per mode so a solo cinephile night can sit in the Criterion
/// rabbit hole while Together night stays broad.
enum CuratedSource {
  none('Any'),
  criterion('Criterion');

  final String label;
  const CuratedSource(this.label);

  /// TMDB `with_companies` param — comma-AND, pipe-OR. Criterion is a
  /// single distributor so a bare id suffices.
  String? get withCompanies {
    switch (this) {
      case CuratedSource.none:
        return null;
      case CuratedSource.criterion:
        return '1771';
    }
  }
}

class ModeCuratedSourceController
    extends StateNotifier<Map<ViewMode, CuratedSource>> {
  ModeCuratedSourceController(this._prefs, Map<ViewMode, CuratedSource> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) => mode == ViewMode.solo
      ? 'wn_curated_source_solo'
      : 'wn_curated_source_together';

  static CuratedSource _decode(String? raw) {
    if (raw == null) return CuratedSource.none;
    for (final c in CuratedSource.values) {
      if (c.name == raw) return c;
    }
    return CuratedSource.none;
  }

  static Map<ViewMode, CuratedSource> readAll(SharedPreferences prefs) => {
        ViewMode.solo: _decode(prefs.getString(_keyFor(ViewMode.solo))),
        ViewMode.together: _decode(prefs.getString(_keyFor(ViewMode.together))),
      };

  Future<void> set(ViewMode mode, CuratedSource value) async {
    state = {...state, mode: value};
    final key = _keyFor(mode);
    if (value == CuratedSource.none) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value.name);
    }
  }
}

final _curatedSourcePrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeCuratedSourceProvider = StateNotifierProvider<
    ModeCuratedSourceController, Map<ViewMode, CuratedSource>>((ref) {
  final prefs = ref.watch(_curatedSourcePrefsProvider).value;
  if (prefs == null) {
    return ModeCuratedSourceController(
      _UnsetPrefs(),
      const {
        ViewMode.solo: CuratedSource.none,
        ViewMode.together: CuratedSource.none,
      },
    );
  }
  return ModeCuratedSourceController(
      prefs, ModeCuratedSourceController.readAll(prefs));
});

final curatedSourceProvider = Provider<CuratedSource>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeCuratedSourceProvider);
  return map[mode] ?? CuratedSource.none;
});

class _UnsetPrefs implements SharedPreferences {
  @override
  Future<bool> setString(String key, String value) async => true;
  @override
  Future<bool> remove(String key) async => true;
  @override
  String? getString(String key) => null;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
