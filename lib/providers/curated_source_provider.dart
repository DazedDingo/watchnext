import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// Canonical curator-list sources a cinephile might anchor discovery on.
///
/// TMDB `with_companies` is a server-side AND-composable filter — combines
/// cleanly with genre, year range, runtime bucket, media type, oscar,
/// exclude-animation, and sort. When a source is active,
/// `recommendations_service.refresh()` suppresses the trending + top_rated
/// baseline — those surfaces would dilute a curator-scoped pool.
///
/// Company ids are production companies (not pure distributors) where
/// available — distributor tags rot as rights shift between regions.
/// Criterion is kept on distributor 1771 for back-compat and because
/// Criterion doesn't produce; they only distribute.
///
/// Persisted per mode so a solo cinephile night can sit in one curator
/// rabbit hole while Together night stays broad. Compatible with every
/// other filter; self-defeating combos (e.g. Ghibli + exclude-animation)
/// render an empty pool silently — deliberately no special-case warning,
/// the user can reverse the contradiction themselves.
enum CuratedSource {
  none('Any'),
  a24('A24'),
  neon('Neon'),
  ghibli('Studio Ghibli'),
  searchlight('Searchlight');

  final String label;
  const CuratedSource(this.label);

  /// TMDB `with_companies` param — comma-AND, pipe-OR. Ids verified
  /// directly against the TMDB /discover endpoint (see provider test).
  /// Searchlight uses a pipe-OR union of the pre-Disney brand (43 — Fox
  /// Searchlight) and the current brand (127929 — Searchlight Pictures)
  /// so the catalog captures both eras.
  ///
  /// Criterion was removed from this enum: TMDB's company id for "The
  /// Criterion Collection" (204170) tags Criterion's own
  /// behind-the-scenes featurettes, not the underlying films they
  /// distribute, so the filter would surface bonus-disc content. An
  /// earlier mapping to company 1771 turned out to be "Tele Europa,"
  /// which is how `criterion` silently returned a single movie for
  /// months. A future version can restore Criterion via a hand-baked
  /// list (following the Oscar-winners pattern in `oscar_winners.dart`).
  String? get withCompanies {
    switch (this) {
      case CuratedSource.none:
        return null;
      case CuratedSource.a24:
        return '41077';
      case CuratedSource.neon:
        return '90733';
      case CuratedSource.ghibli:
        return '10342';
      case CuratedSource.searchlight:
        return '43|127929';
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
