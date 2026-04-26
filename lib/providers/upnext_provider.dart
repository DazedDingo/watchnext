import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/watch_entry.dart';
import 'tmdb_provider.dart';
import 'watch_entries_provider.dart';

/// One row in the "Up next" Home surface — the next episode of a show
/// the household is mid-watch on, due within the visibility window.
class UpNextEpisode {
  final int tmdbId;
  final String showTitle;
  final String? showPosterPath;
  final int season;
  final int number;
  final String? episodeName;
  final DateTime airDate;

  /// Days from today to the air date. 0 = airs today, 1 = tomorrow,
  /// negative = aired in the recent past (still surfaces while within
  /// `kUpNextRecentDays` so a "just dropped" episode doesn't disappear
  /// the moment its date passes).
  final int daysUntilAir;

  const UpNextEpisode({
    required this.tmdbId,
    required this.showTitle,
    this.showPosterPath,
    required this.season,
    required this.number,
    this.episodeName,
    required this.airDate,
    required this.daysUntilAir,
  });

  String get key => 'tv:$tmdbId';
}

/// How many days into the future to surface upcoming episodes. Tight on
/// purpose — a 7-day horizon keeps the row tied to "this week" so it
/// only renders when there's something genuinely actionable.
const int kUpNextWindowDays = 7;

/// How many days in the recent past to keep an episode surfaced after
/// its air date. Short grace so an episode that aired today/yesterday
/// doesn't vanish before the household has watched it.
const int kUpNextRecentDays = 1;

/// Maximum tiles the Home row will render. Capped low because the whole
/// rationale for this surface is "low clutter, only when relevant" — a
/// long list defeats that. Households with more in-progress shows just
/// see the soonest-airing.
const int kUpNextMaxTiles = 3;

/// Resolves the next episode for every TV show the household is
/// currently mid-watch on, filters to those with an air date inside the
/// visibility window, and ranks by soonest-airing.
///
/// Source of "in progress" is `WatchEntry.inProgressStatus == 'watching'`
/// — the same signal Library → Watching uses. Returns empty when the
/// household isn't watching anything; the Home row collapses to nothing
/// in that case so the screen stays the same as today.
final upNextProvider =
    FutureProvider.autoDispose<List<UpNextEpisode>>((ref) async {
  final entriesAsync = ref.watch(watchEntriesProvider);
  final entries = entriesAsync.value ?? const <WatchEntry>[];
  final inProgressTv = entries
      .where((e) => e.mediaType == 'tv' && e.inProgressStatus == 'watching')
      .toList();
  if (inProgressTv.isEmpty) return const [];

  final tmdb = ref.watch(tmdbServiceProvider);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  final fetches = inProgressTv.map((e) async {
    try {
      final show = await tmdb.tvShow(e.tmdbId);
      final next = show['next_episode_to_air'] as Map<String, dynamic>?;
      if (next == null) return null;
      final airDateStr = next['air_date'] as String?;
      if (airDateStr == null || airDateStr.isEmpty) return null;
      final parsed = DateTime.tryParse(airDateStr);
      if (parsed == null) return null;
      final airDate = DateTime(parsed.year, parsed.month, parsed.day);
      final daysUntil = airDate.difference(today).inDays;
      if (daysUntil < -kUpNextRecentDays || daysUntil > kUpNextWindowDays) {
        return null;
      }
      return UpNextEpisode(
        tmdbId: e.tmdbId,
        showTitle: (show['name'] as String?) ?? '',
        showPosterPath: show['poster_path'] as String?,
        season: (next['season_number'] as num?)?.toInt() ?? 0,
        number: (next['episode_number'] as num?)?.toInt() ?? 0,
        episodeName: next['name'] as String?,
        airDate: airDate,
        daysUntilAir: daysUntil,
      );
    } catch (_) {
      // A single show's TMDB lookup failing shouldn't sink the row —
      // skip it and let other shows surface.
      return null;
    }
  }).toList();

  final results = await Future.wait(fetches);
  final out = results.whereType<UpNextEpisode>().toList()
    ..sort((a, b) => a.airDate.compareTo(b.airDate));
  return out.take(kUpNextMaxTiles).toList();
});

/// Lightweight summary used by Profile → Insights as a "feature health"
/// line. Reports total in-progress TV count + the closest upcoming
/// episode (so the user can sanity-check that the Home row's silence
/// reflects "nothing scheduled" rather than "feature broken").
class UpNextSummary {
  final int trackedShowCount;
  final UpNextEpisode? next;

  const UpNextSummary({required this.trackedShowCount, this.next});
}

final upNextSummaryProvider =
    FutureProvider.autoDispose<UpNextSummary>((ref) async {
  final entriesAsync = ref.watch(watchEntriesProvider);
  final entries = entriesAsync.value ?? const <WatchEntry>[];
  final trackedCount = entries
      .where((e) => e.mediaType == 'tv' && e.inProgressStatus == 'watching')
      .length;
  final upcoming = await ref.watch(upNextProvider.future);
  return UpNextSummary(
    trackedShowCount: trackedCount,
    next: upcoming.isEmpty ? null : upcoming.first,
  );
});
