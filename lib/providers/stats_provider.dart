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
  /// Consecutive-day rating streak per member. Empty entries are omitted —
  /// call-sites should fall back to RatingStreak.empty.
  final Map<String, RatingStreak> ratingStreaks;
  /// All achievement badges, earned + unearned. Empty when members list is
  /// unavailable at compute time. Order is stable: household-level first, then
  /// per-user in member-list order.
  final List<BadgeDef> badges;
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
    this.ratingStreaks = const {},
    this.badges = const [],
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

/// Consecutive-day rating streak for a single member. Both are 0 if the user
/// has never rated anything.
class RatingStreak {
  /// Streak ending today or yesterday (1-day grace so not-yet-rated-today
  /// doesn't break a live streak). 0 if the most recent rating is older than
  /// yesterday.
  final int current;

  /// Longest consecutive-day run ever observed.
  final int best;

  const RatingStreak({required this.current, required this.best});

  static const empty = RatingStreak(current: 0, best: 0);
}

/// Single achievement badge descriptor. `earned = progress >= target`.
/// `memberUid` is null for household-level badges, set for per-user ones so
/// the Stats UI can label the row.
///
/// `iconKey` is a UI-layer string (e.g. 'trophy', 'explore') — this provider
/// stays material-free so the Dart side is easy to unit-test.
class BadgeDef {
  final String id;
  final String name;
  final String description;
  final String iconKey;
  final int target;
  final int progress;
  final bool earned;
  final String? memberUid;

  const BadgeDef({
    required this.id,
    required this.name,
    required this.description,
    required this.iconKey,
    required this.target,
    required this.progress,
    required this.earned,
    this.memberUid,
  });

  double get progressPct =>
      target == 0 ? 0 : (progress / target).clamp(0.0, 1.0);
}

/// Derives the badge list from raw household inputs. Pure — exposed for tests.
/// Household-level badges (Century Club, Genre Explorer) come first, then one
/// Prediction Machine badge per member in list order.
List<BadgeDef> computeBadges({
  required List<WatchEntry> entries,
  required List<HouseholdMember> members,
}) {
  final result = <BadgeDef>[];

  final centuryProgress = entries.length.clamp(0, 100);
  result.add(BadgeDef(
    id: 'century_club',
    name: 'Century Club',
    description: 'Watch 100 titles',
    iconKey: 'trophy',
    target: 100,
    progress: centuryProgress,
    earned: entries.length >= 100,
  ));

  final genres = <String>{};
  for (final e in entries) {
    genres.addAll(e.genres);
  }
  final genreProgress = genres.length.clamp(0, 5);
  result.add(BadgeDef(
    id: 'genre_explorer',
    name: 'Genre Explorer',
    description: 'Watch titles across 5 genres',
    iconKey: 'explore',
    target: 5,
    progress: genreProgress,
    earned: genres.length >= 5,
  ));

  for (final m in members) {
    final total = m.predictTotal;
    final wins = m.predictWins;
    final accuracy = total == 0 ? 0.0 : wins / total;
    final earned = total >= 20 && accuracy >= 0.8;
    // Two-phase progress: fill to 20 predictions first (volume), then the UI
    // surfaces accuracy once volume is met. Keep `target = 20` here so the bar
    // caps at the volume gate; the row widget adds accuracy copy.
    final progress = total >= 20 ? 20 : total;
    result.add(BadgeDef(
      id: 'prediction_machine_${m.uid}',
      name: 'Prediction Machine',
      description: '80% accuracy over 20+ predictions',
      iconKey: 'psychology',
      target: 20,
      progress: progress,
      earned: earned,
      memberUid: m.uid,
    ));
  }

  return result;
}

DateTime _dayOnlyUtc(DateTime dt) {
  final u = dt.toUtc();
  return DateTime.utc(u.year, u.month, u.day);
}

/// Computes a member's rating streak (current + best) from the full rating
/// list. Pure — exposed for unit tests. `today` is injectable so tests can
/// freeze the clock; defaults to `DateTime.now()`.
///
/// Multiple ratings on the same day collapse into a single "streak day".
/// Days are bucketed in UTC — good enough for a two-person household; can
/// switch to local-time bucketing if users in extreme timezones complain.
RatingStreak ratingStreakForUser(
  String uid,
  List<Rating> ratings, {
  DateTime? today,
}) {
  final todayDay = _dayOnlyUtc(today ?? DateTime.now());
  final yesterdayDay = todayDay.subtract(const Duration(days: 1));

  final days = <DateTime>{};
  for (final r in ratings) {
    if (r.uid != uid) continue;
    days.add(_dayOnlyUtc(r.ratedAt));
  }
  if (days.isEmpty) return RatingStreak.empty;

  final sortedDesc = days.toList()..sort((a, b) => b.compareTo(a));

  int current = 0;
  DateTime? cursor;
  if (sortedDesc.first == todayDay) {
    cursor = todayDay;
  } else if (sortedDesc.first == yesterdayDay) {
    cursor = yesterdayDay;
  }
  if (cursor != null) {
    for (final d in sortedDesc) {
      if (d == cursor) {
        current++;
        cursor = cursor!.subtract(const Duration(days: 1));
      } else if (d.isBefore(cursor!)) {
        break;
      }
    }
  }

  int best = 1;
  int run = 1;
  for (int i = 1; i < sortedDesc.length; i++) {
    if (sortedDesc[i - 1].difference(sortedDesc[i]).inDays == 1) {
      run++;
      if (run > best) best = run;
    } else {
      run = 1;
    }
  }

  return RatingStreak(current: current, best: best);
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
  List<HouseholdMember> members = const [],
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

  final ratingStreaks = <String, RatingStreak>{};
  for (final uid in perUser.keys) {
    final streak = ratingStreakForUser(uid, movieShowRatings);
    if (streak.current > 0 || streak.best > 0) {
      ratingStreaks[uid] = streak;
    }
  }

  final badges = computeBadges(entries: entries, members: members);

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
    ratingStreaks: ratingStreaks,
    badges: badges,
    compatibilityPct: compat,
  );
}

final statsProvider = Provider<HouseholdStats?>((ref) {
  final entries = ref.watch(watchEntriesProvider).value;
  final ratings = ref.watch(ratingsProvider).value;
  final members = ref.watch(membersProvider).value ?? const <HouseholdMember>[];
  final tasteProfile = ref.watch(tasteProfileProvider).value;
  if (entries == null || ratings == null) return null;
  return computeHouseholdStats(
    entries: entries,
    ratings: ratings,
    members: members,
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
