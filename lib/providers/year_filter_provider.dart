import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// Release-year filter expressed as an inclusive [minYear, maxYear] range.
/// Either bound can be null, which means "unbounded on that side" — we use
/// null so the slider endpoints round-trip cleanly as "no lower bound" /
/// "no upper bound" rather than encoding a magic sentinel year.
///
/// A rec with a null `year` (source didn't provide a release date) is only
/// shown when both bounds are null. If the user has set either bound they've
/// asked for a specific era — silently including unknown-era titles would
/// mislead them. Mirrors the YearBucket contract the slider replaces.
class YearRange {
  final int? minYear;
  final int? maxYear;

  const YearRange({this.minYear, this.maxYear});

  const YearRange.unbounded() : minYear = null, maxYear = null;

  bool get hasAnyBound => minYear != null || maxYear != null;

  bool matches(int? year) {
    if (!hasAnyBound) return true;
    if (year == null) return false;
    if (minYear != null && year < minYear!) return false;
    if (maxYear != null && year > maxYear!) return false;
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is YearRange && other.minYear == minYear && other.maxYear == maxYear;

  @override
  int get hashCode => Object.hash(minYear, maxYear);

  @override
  String toString() => 'YearRange($minYear–$maxYear)';
}

/// Per-mode year range, persisted across four SharedPreferences keys
/// (`wn_year_min_solo`, `wn_year_max_solo`, `wn_year_min_together`,
/// `wn_year_max_together`). Unset bound → key absent.
class ModeYearRangeController extends StateNotifier<Map<ViewMode, YearRange>> {
  ModeYearRangeController(this._prefs, Map<ViewMode, YearRange> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _minKeyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_year_min_solo' : 'wn_year_min_together';
  static String _maxKeyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_year_max_solo' : 'wn_year_max_together';

  static YearRange _decode(SharedPreferences prefs, ViewMode mode) {
    return YearRange(
      minYear: prefs.getInt(_minKeyFor(mode)),
      maxYear: prefs.getInt(_maxKeyFor(mode)),
    );
  }

  static Map<ViewMode, YearRange> readAll(SharedPreferences prefs) => {
        ViewMode.solo: _decode(prefs, ViewMode.solo),
        ViewMode.together: _decode(prefs, ViewMode.together),
      };

  Future<void> set(ViewMode mode, YearRange range) async {
    state = {...state, mode: range};
    final minKey = _minKeyFor(mode);
    final maxKey = _maxKeyFor(mode);
    if (range.minYear == null) {
      await _prefs.remove(minKey);
    } else {
      await _prefs.setInt(minKey, range.minYear!);
    }
    if (range.maxYear == null) {
      await _prefs.remove(maxKey);
    } else {
      await _prefs.setInt(maxKey, range.maxYear!);
    }
  }

  Future<void> clear(ViewMode mode) => set(mode, const YearRange.unbounded());
}

final _yearPrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeYearRangeProvider = StateNotifierProvider<ModeYearRangeController,
    Map<ViewMode, YearRange>>((ref) {
  final prefs = ref.watch(_yearPrefsProvider).value;
  if (prefs == null) {
    return ModeYearRangeController(
      _UnsetPrefs(),
      const {
        ViewMode.solo: YearRange.unbounded(),
        ViewMode.together: YearRange.unbounded(),
      },
    );
  }
  return ModeYearRangeController(prefs, ModeYearRangeController.readAll(prefs));
});

/// Active-mode year range. `YearRange.unbounded()` = no filter.
final yearRangeProvider = Provider<YearRange>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeYearRangeProvider);
  return map[mode] ?? const YearRange.unbounded();
});

class _UnsetPrefs implements SharedPreferences {
  @override
  Future<bool> setInt(String key, int value) async => true;
  @override
  Future<bool> remove(String key) async => true;
  @override
  int? getInt(String key) => null;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
