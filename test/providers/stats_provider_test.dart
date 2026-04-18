import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/rating.dart';
import 'package:watchnext/models/watch_entry.dart';
import 'package:watchnext/providers/stats_provider.dart';

WatchEntry _entry({
  required String id,
  required String title,
  String mediaType = 'movie',
  int? runtime,
  List<String> genres = const [],
}) {
  final parts = id.split(':');
  return WatchEntry(
    id: id,
    mediaType: mediaType,
    tmdbId: int.parse(parts.last),
    title: title,
    runtime: runtime,
    genres: genres,
  );
}

Rating _rating({
  required String uid,
  required String targetId,
  required int stars,
  String level = 'movie',
  String? context,
  DateTime? ratedAt,
}) {
  return Rating(
    id: Rating.buildId(uid, level, targetId),
    uid: uid,
    level: level,
    targetId: targetId,
    stars: stars,
    ratedAt: ratedAt ?? DateTime.utc(2026, 1, 1),
    context: context,
  );
}

void main() {
  group('computeHouseholdStats — totals', () {
    test('counts movies vs TV, sums runtime, aggregates genres', () {
      final stats = computeHouseholdStats(
        entries: [
          _entry(
            id: 'movie:1',
            title: 'A',
            runtime: 100,
            genres: const ['Action', 'Thriller'],
          ),
          _entry(
            id: 'movie:2',
            title: 'B',
            runtime: 120,
            genres: const ['Action'],
          ),
          _entry(
            id: 'tv:1',
            title: 'Show',
            mediaType: 'tv',
            genres: const ['Drama'],
          ),
        ],
        ratings: const [],
      );
      expect(stats.totalTitles, 3);
      expect(stats.movieCount, 2);
      expect(stats.tvCount, 1);
      expect(stats.totalMinutes, 220);
      expect(stats.topGenres.first.genre, 'Action');
      expect(stats.topGenres.first.count, 2);
    });
  });

  group('computeHouseholdStats — per-user rating aggregation', () {
    test('excludes episode/season-level ratings', () {
      final stats = computeHouseholdStats(
        entries: const [],
        ratings: [
          _rating(uid: 'u1', targetId: 'tv:1', stars: 5, level: 'episode'),
          _rating(uid: 'u1', targetId: 'tv:1', stars: 5, level: 'season'),
        ],
      );
      expect(stats.perUser['u1'], isNull);
    });

    test('avg + distribution across all contexts', () {
      final stats = computeHouseholdStats(
        entries: const [],
        ratings: [
          _rating(uid: 'u1', targetId: 'movie:1', stars: 5, context: 'solo'),
          _rating(uid: 'u1', targetId: 'movie:2', stars: 3, context: 'together'),
          _rating(uid: 'u1', targetId: 'movie:3', stars: 4),
        ],
      );
      final u1 = stats.perUser['u1']!;
      expect(u1.ratedCount, 3);
      expect(u1.avgRating, closeTo(4.0, 1e-9));
      expect(u1.distribution[5], 1);
      expect(u1.distribution[4], 1);
      expect(u1.distribution[3], 1);
    });
  });

  group('computeHouseholdStats — per-mode breakdowns', () {
    final ratings = [
      _rating(uid: 'u1', targetId: 'movie:1', stars: 5, context: 'solo'),
      _rating(uid: 'u1', targetId: 'movie:2', stars: 4, context: 'solo'),
      _rating(uid: 'u1', targetId: 'movie:3', stars: 3, context: 'together'),
      // Null-context — stays out of both per-mode breakouts.
      _rating(uid: 'u1', targetId: 'movie:4', stars: 2),
      _rating(uid: 'u2', targetId: 'movie:1', stars: 4, context: 'together'),
    ];

    test('perUserSolo filters to context="solo" ratings only', () {
      final stats =
          computeHouseholdStats(entries: const [], ratings: ratings);
      final u1Solo = stats.perUserSolo['u1']!;
      expect(u1Solo.ratedCount, 2);
      expect(u1Solo.avgRating, closeTo(4.5, 1e-9));
    });

    test('perUserTogether filters to context="together" ratings only', () {
      final stats =
          computeHouseholdStats(entries: const [], ratings: ratings);
      final u1Together = stats.perUserTogether['u1']!;
      expect(u1Together.ratedCount, 1);
      expect(u1Together.avgRating, closeTo(3.0, 1e-9));
      expect(stats.perUserTogether['u2']!.ratedCount, 1);
    });

    test('null-context ratings are not counted in per-mode breakouts', () {
      final stats =
          computeHouseholdStats(entries: const [], ratings: ratings);
      // u1 has 4 movie ratings total (perUser ratedCount = 4) but only 2 solo + 1 together.
      expect(stats.perUser['u1']!.ratedCount, 4);
      expect(stats.perUserSolo['u1']!.ratedCount, 2);
      expect(stats.perUserTogether['u1']!.ratedCount, 1);
    });

    test('member with only cross-context ratings has no per-mode entries', () {
      final stats = computeHouseholdStats(
        entries: const [],
        ratings: [
          _rating(uid: 'u3', targetId: 'movie:5', stars: 5),
        ],
      );
      expect(stats.perUser['u3'], isNotNull);
      expect(stats.perUserSolo['u3'], isNull);
      expect(stats.perUserTogether['u3'], isNull);
    });
  });

  group('ratingStreakForUser', () {
    final today = DateTime.utc(2026, 4, 18);
    Rating r(String uid, DateTime d, {int id = 0}) => _rating(
          uid: uid,
          targetId: 'movie:$id',
          stars: 5,
          ratedAt: d,
        );

    test('empty ratings → (0, 0)', () {
      final s = ratingStreakForUser('u1', const [], today: today);
      expect(s.current, 0);
      expect(s.best, 0);
    });

    test('only today → current 1, best 1', () {
      final s = ratingStreakForUser(
        'u1',
        [r('u1', today)],
        today: today,
      );
      expect(s.current, 1);
      expect(s.best, 1);
    });

    test('only yesterday → current 1 (grace), best 1', () {
      final s = ratingStreakForUser(
        'u1',
        [r('u1', today.subtract(const Duration(days: 1)))],
        today: today,
      );
      expect(s.current, 1);
      expect(s.best, 1);
    });

    test('last rating two days ago → current 0, best 1', () {
      final s = ratingStreakForUser(
        'u1',
        [r('u1', today.subtract(const Duration(days: 2)))],
        today: today,
      );
      expect(s.current, 0);
      expect(s.best, 1);
    });

    test('three consecutive days ending today → current 3, best 3', () {
      final s = ratingStreakForUser(
        'u1',
        [
          r('u1', today, id: 1),
          r('u1', today.subtract(const Duration(days: 1)), id: 2),
          r('u1', today.subtract(const Duration(days: 2)), id: 3),
        ],
        today: today,
      );
      expect(s.current, 3);
      expect(s.best, 3);
    });

    test('multiple ratings on same day collapse into one streak day', () {
      final s = ratingStreakForUser(
        'u1',
        [
          r('u1', today, id: 1),
          r('u1', today.add(const Duration(hours: 3)), id: 2),
          r('u1', today.subtract(const Duration(days: 1)), id: 3),
        ],
        today: today,
      );
      expect(s.current, 2);
      expect(s.best, 2);
    });

    test('gap breaks current streak but best survives', () {
      // Streak of 3 ending 5 days ago, then single rating yesterday.
      final s = ratingStreakForUser(
        'u1',
        [
          r('u1', today.subtract(const Duration(days: 1)), id: 1),
          r('u1', today.subtract(const Duration(days: 5)), id: 2),
          r('u1', today.subtract(const Duration(days: 6)), id: 3),
          r('u1', today.subtract(const Duration(days: 7)), id: 4),
        ],
        today: today,
      );
      expect(s.current, 1);
      expect(s.best, 3);
    });

    test('isolates ratings by uid', () {
      final s = ratingStreakForUser(
        'u1',
        [
          r('u1', today, id: 1),
          r('u2', today.subtract(const Duration(days: 1)), id: 2),
          r('u2', today.subtract(const Duration(days: 2)), id: 3),
        ],
        today: today,
      );
      expect(s.current, 1);
      expect(s.best, 1);
    });

    test('computeHouseholdStats exposes streaks for members with activity', () {
      final stats = computeHouseholdStats(
        entries: const [],
        ratings: [
          _rating(
            uid: 'u1',
            targetId: 'movie:1',
            stars: 5,
            ratedAt: today,
          ),
          _rating(
            uid: 'u1',
            targetId: 'movie:2',
            stars: 4,
            ratedAt: today.subtract(const Duration(days: 1)),
          ),
        ],
      );
      // Provider uses DateTime.now() internally — can't freeze today here, so
      // only assert structural shape (key exists for u1 with activity).
      expect(stats.ratingStreaks.keys, contains('u1'));
    });
  });

  group('computeHouseholdStats — compatibility', () {
    test('reads combined.compatibility.within_1_star_pct from tasteProfile', () {
      final stats = computeHouseholdStats(
        entries: const [],
        ratings: const [],
        tasteProfile: const {
          'combined': {
            'compatibility': {'within_1_star_pct': 0.82},
          },
        },
      );
      expect(stats.compatibilityPct, closeTo(0.82, 1e-9));
    });

    test('missing tasteProfile → compatibilityPct = -1', () {
      final stats =
          computeHouseholdStats(entries: const [], ratings: const []);
      expect(stats.compatibilityPct, -1);
    });
  });
}
