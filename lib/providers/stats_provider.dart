import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/rating.dart';
import '../models/watch_entry.dart';
import 'auth_provider.dart';
import 'household_provider.dart';
import 'ratings_provider.dart';
import 'watch_entries_provider.dart';

// ---------------------------------------------------------------------------
// Member model
// ---------------------------------------------------------------------------

class HouseholdMember {
  final String uid;
  final String displayName;
  final String? avatarUrl;

  /// Lifetime counters from before context-aware prediction counters existed.
  /// New writes land in the per-mode fields below; these are only populated
  /// for legacy rows (null-context predictions) or historical data.
  final int predictTotalLegacy;
  final int predictWinsLegacy;
  final int predictTotalSolo;
  final int predictWinsSolo;
  final int predictTotalTogether;
  final int predictWinsTogether;

  const HouseholdMember({
    required this.uid,
    required this.displayName,
    this.avatarUrl,
    this.predictTotalLegacy = 0,
    this.predictWinsLegacy = 0,
    this.predictTotalSolo = 0,
    this.predictWinsSolo = 0,
    this.predictTotalTogether = 0,
    this.predictWinsTogether = 0,
  });

  /// Sum across all contexts — keep as the default for existing leaderboard UI.
  int get predictTotal =>
      predictTotalLegacy + predictTotalSolo + predictTotalTogether;
  int get predictWins =>
      predictWinsLegacy + predictWinsSolo + predictWinsTogether;

  double get predictWinRate =>
      predictTotal == 0 ? 0 : predictWins / predictTotal;
  double get predictWinRateSolo => predictTotalSolo == 0
      ? 0
      : predictWinsSolo / predictTotalSolo;
  double get predictWinRateTogether => predictTotalTogether == 0
      ? 0
      : predictWinsTogether / predictTotalTogether;

  factory HouseholdMember.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return HouseholdMember(
      uid: doc.id,
      displayName: d['display_name'] as String? ?? 'Member',
      avatarUrl: d['avatar_url'] as String?,
      predictTotalLegacy: (d['predict_total'] as num?)?.toInt() ?? 0,
      predictWinsLegacy: (d['predict_wins'] as num?)?.toInt() ?? 0,
      predictTotalSolo: (d['predict_total_solo'] as num?)?.toInt() ?? 0,
      predictWinsSolo: (d['predict_wins_solo'] as num?)?.toInt() ?? 0,
      predictTotalTogether: (d['predict_total_together'] as num?)?.toInt() ?? 0,
      predictWinsTogether: (d['predict_wins_together'] as num?)?.toInt() ?? 0,
    );
  }
}

final membersProvider = StreamProvider<List<HouseholdMember>>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) {
    yield const [];
    return;
  }
  yield* FirebaseFirestore.instance
      .collection('households/$householdId/members')
      .snapshots()
      .map((s) => s.docs
          .map((d) => HouseholdMember.fromDoc(
              d as DocumentSnapshot<Map<String, dynamic>>))
          .toList());
});

// ---------------------------------------------------------------------------
// Stats model
// ---------------------------------------------------------------------------

class HouseholdStats {
  final int totalTitles;
  final int movieCount;
  final int tvCount;
  final int totalMinutes; // best-effort from runtime fields
  final List<({String genre, int count})> topGenres; // sorted desc
  /// Cross-context per-user stats (every movie/show rating the user made).
  final Map<String, UserStats> perUser;
  /// Per-user stats filtered to `context == 'solo'` ratings only.
  /// Null-context ratings do NOT fold in — solo breakout only reflects
  /// ratings explicitly tagged solo, so the surfaced number tracks the
  /// user's actual solo activity post-rollout. Empty until the first
  /// solo-tagged rating exists.
  final Map<String, UserStats> perUserSolo;
  /// Per-user stats filtered to `context == 'together'` ratings only.
  /// Same rationale as perUserSolo — null-context ratings stay out of the
  /// breakout so the count reflects actual together-mode activity.
  final Map<String, UserStats> perUserTogether;
  final double compatibilityPct; // 0-1 from tasteProfile, or -1 if unknown

  const HouseholdStats({
    required this.totalTitles,
    required this.movieCount,
    required this.tvCount,
    required this.totalMinutes,
    required this.topGenres,
    required this.perUser,
    this.perUserSolo = const {},
    this.perUserTogether = const {},
    this.compatibilityPct = -1,
  });
}

class UserStats {
  final double avgRating; // 0 if no ratings
  final int ratedCount;
  final Map<int, int> distribution; // star (1-5) → count

  const UserStats({
    required this.avgRating,
    required this.ratedCount,
    required this.distribution,
  });
}

// ---------------------------------------------------------------------------
// Taste profile provider (reads /tasteProfile doc)
// ---------------------------------------------------------------------------

final tasteProfileProvider =
    StreamProvider<Map<String, dynamic>?>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) {
    yield null;
    return;
  }
  yield* FirebaseFirestore.instance
      .doc('households/$householdId/tasteProfile/default')
      .snapshots()
      .map((s) => s.data());
});

// ---------------------------------------------------------------------------
// Derived stats provider — pure computation, no Firestore
// ---------------------------------------------------------------------------

/// Pure derivation — exposed for unit tests. Provider just wires Firestore
/// data into this.
HouseholdStats computeHouseholdStats({
  required List<WatchEntry> entries,
  required List<Rating> ratings,
  Map<String, dynamic>? tasteProfile,
}) {
  int movies = 0;
  int tv = 0;
  int totalMinutes = 0;
  final genreCounts = <String, int>{};

  for (final e in entries) {
    if (e.mediaType == 'movie') {
      movies++;
    } else {
      tv++;
    }
    if (e.runtime != null) totalMinutes += e.runtime!;
    for (final g in e.genres) {
      genreCounts[g] = (genreCounts[g] ?? 0) + 1;
    }
  }

  final topGenres = genreCounts.entries
      .map((e) => (genre: e.key, count: e.value))
      .toList()
    ..sort((a, b) => b.count.compareTo(a.count));

  final movieShowRatings = ratings
      .where((r) => r.level == 'movie' || r.level == 'show')
      .toList();

  Map<String, UserStats> buildPerUser(List<Rating> source) {
    final uids = source.map((r) => r.uid).toSet();
    final out = <String, UserStats>{};
    for (final uid in uids) {
      final userRatings = source.where((r) => r.uid == uid).toList();
      if (userRatings.isEmpty) continue;
      final dist = <int, int>{1: 0, 2: 0, 3: 0, 4: 0, 5: 0};
      int sum = 0;
      for (final r in userRatings) {
        dist[r.stars] = (dist[r.stars] ?? 0) + 1;
        sum += r.stars;
      }
      out[uid] = UserStats(
        avgRating: sum / userRatings.length,
        ratedCount: userRatings.length,
        distribution: dist,
      );
    }
    return out;
  }

  final perUser = buildPerUser(movieShowRatings);
  final perUserSolo = buildPerUser(
    movieShowRatings.where((r) => r.context == 'solo').toList(),
  );
  final perUserTogether = buildPerUser(
    movieShowRatings.where((r) => r.context == 'together').toList(),
  );

  final combined = tasteProfile?['combined'] as Map<String, dynamic>?;
  final compatRaw =
      (combined?['compatibility'] as Map?)?['within_1_star_pct'] as num?;
  final compat = compatRaw?.toDouble() ?? -1;

  return HouseholdStats(
    totalTitles: entries.length,
    movieCount: movies,
    tvCount: tv,
    totalMinutes: totalMinutes,
    topGenres: topGenres.take(8).toList(),
    perUser: perUser,
    perUserSolo: perUserSolo,
    perUserTogether: perUserTogether,
    compatibilityPct: compat,
  );
}

final statsProvider = Provider<HouseholdStats?>((ref) {
  final entries = ref.watch(watchEntriesProvider).value;
  final ratings = ref.watch(ratingsProvider).value;
  final tasteProfile = ref.watch(tasteProfileProvider).value;
  if (entries == null || ratings == null) return null;
  return computeHouseholdStats(
    entries: entries,
    ratings: ratings,
    tasteProfile: tasteProfile,
  );
});

// Convenience: current-user stats shortcut.
final myStatsProvider = Provider<UserStats?>((ref) {
  final uid = ref.watch(authStateProvider).value?.uid;
  final stats = ref.watch(statsProvider);
  if (uid == null || stats == null) return null;
  return stats.perUser[uid];
});
