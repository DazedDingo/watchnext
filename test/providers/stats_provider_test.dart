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
  DateTime? lastWatchedAt,
}) {
  final parts = id.split(':');
  return WatchEntry(
    id: id,
    mediaType: mediaType,
    tmdbId: int.parse(parts.last),
    title: title,
    runtime: runtime,
    genres: genres,
    lastWatchedAt: lastWatchedAt,
  );
}

Rating _rating({
  required String uid,
  required String targetId,
  required int stars,
  String level = 'movie',
  String? context,
  DateTime? ratedAt,
  String? note,
  List<String> tags = const [],
}) {
  return Rating(
    id: Rating.buildId(uid, level, targetId),
    uid: uid,
    level: level,
    targetId: targetId,
    stars: stars,
    ratedAt: ratedAt ?? DateTime.utc(2026, 1, 1),
    context: context,
    note: note,
    tags: tags,
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

  group('computeBadges', () {
    BadgeDef find(List<BadgeDef> list, String id) =>
        list.firstWhere((b) => b.id == id);

    test('Century Club — not earned, progress caps at 100', () {
      final entries = List.generate(
        45,
        (i) => _entry(id: 'movie:$i', title: 'T$i'),
      );
      final badges = computeBadges(entries: entries, members: const []);
      final century = find(badges, 'century_club');
      expect(century.earned, false);
      expect(century.progress, 45);
      expect(century.target, 100);
    });

    test('Century Club — earned once 100+ titles logged', () {
      final entries = List.generate(
        120,
        (i) => _entry(id: 'movie:$i', title: 'T$i'),
      );
      final badges = computeBadges(entries: entries, members: const []);
      final century = find(badges, 'century_club');
      expect(century.earned, true);
      expect(century.progress, 100); // capped
    });

    test('Genre Explorer — counts distinct genres across entries', () {
      final entries = [
        _entry(
            id: 'movie:1',
            title: 'A',
            genres: const ['Action', 'Thriller']),
        _entry(id: 'movie:2', title: 'B', genres: const ['Action']),
        _entry(id: 'movie:3', title: 'C', genres: const ['Drama']),
      ];
      final badges = computeBadges(entries: entries, members: const []);
      final ge = find(badges, 'genre_explorer');
      expect(ge.earned, false);
      expect(ge.progress, 3);
    });

    test('Genre Explorer — earned at 5 distinct genres', () {
      final entries = [
        _entry(
            id: 'movie:1',
            title: 'A',
            genres: const ['Action', 'Thriller', 'Drama']),
        _entry(
            id: 'movie:2',
            title: 'B',
            genres: const ['Comedy', 'Horror']),
      ];
      final badges = computeBadges(entries: entries, members: const []);
      final ge = find(badges, 'genre_explorer');
      expect(ge.earned, true);
      expect(ge.progress, 5);
    });

    test('Prediction Machine — below volume gate → not earned', () {
      final m = HouseholdMember(
        uid: 'u1',
        displayName: 'Alice',
        predictTotalLegacy: 5,
        predictWinsLegacy: 5,
      );
      final badges = computeBadges(entries: const [], members: [m]);
      final pm = find(badges, 'prediction_machine_u1');
      expect(pm.earned, false); // 100% accuracy but only 5 predictions
      expect(pm.progress, 5);
      expect(pm.memberUid, 'u1');
    });

    test('Prediction Machine — above volume but below accuracy → not earned',
        () {
      final m = HouseholdMember(
        uid: 'u1',
        displayName: 'Alice',
        predictTotalLegacy: 30,
        predictWinsLegacy: 20, // ~66%
      );
      final badges = computeBadges(entries: const [], members: [m]);
      final pm = find(badges, 'prediction_machine_u1');
      expect(pm.earned, false);
      expect(pm.progress, 20); // capped at target
    });

    test('Prediction Machine — earned at 20+ predictions & 80% accuracy', () {
      final m = HouseholdMember(
        uid: 'u1',
        displayName: 'Alice',
        predictTotalLegacy: 25,
        predictWinsLegacy: 20, // 80%
      );
      final badges = computeBadges(entries: const [], members: [m]);
      final pm = find(badges, 'prediction_machine_u1');
      expect(pm.earned, true);
    });

    test('Prediction Machine — one badge per member', () {
      final a = HouseholdMember(
        uid: 'u1',
        displayName: 'Alice',
        predictTotalLegacy: 25,
        predictWinsLegacy: 22,
      );
      final b = HouseholdMember(
        uid: 'u2',
        displayName: 'Bob',
        predictTotalLegacy: 10,
        predictWinsLegacy: 8,
      );
      final badges = computeBadges(entries: const [], members: [a, b]);
      final pmA = find(badges, 'prediction_machine_u1');
      final pmB = find(badges, 'prediction_machine_u2');
      expect(pmA.earned, true);
      expect(pmB.earned, false);
      expect(pmB.progress, 10);
    });

    test('Prediction Machine — sums legacy + per-mode counters', () {
      // predictTotal/predictWins are across-context getters on HouseholdMember.
      final m = HouseholdMember(
        uid: 'u1',
        displayName: 'Alice',
        predictTotalLegacy: 10,
        predictWinsLegacy: 8,
        predictTotalSolo: 15,
        predictWinsSolo: 12,
      );
      final badges = computeBadges(entries: const [], members: [m]);
      final pm = find(badges, 'prediction_machine_u1');
      // Total 25, wins 20 → 80%, earned.
      expect(pm.earned, true);
    });

    test('computeHouseholdStats surfaces badges in returned struct', () {
      final entries = List.generate(
        5,
        (i) => _entry(id: 'movie:$i', title: 'T$i'),
      );
      final stats = computeHouseholdStats(
        entries: entries,
        ratings: const [],
        members: [HouseholdMember(uid: 'u1', displayName: 'Alice')],
      );
      expect(stats.badges, isNotEmpty);
      // Six household badges + three per-user badges (prediction, five-star,
      // critic).
      expect(stats.badges.length, 9);
    });

    test('First Watch — not earned at zero entries, earned at first', () {
      final zero = computeBadges(entries: const [], members: const []);
      expect(find(zero, 'first_watch').earned, false);

      final one = computeBadges(
        entries: [_entry(id: 'movie:1', title: 'A')],
        members: const [],
      );
      expect(find(one, 'first_watch').earned, true);
    });

    test('Binge Master — counts only TV entries', () {
      final entries = [
        ...List.generate(
          20,
          (i) => _entry(id: 'movie:$i', title: 'Movie $i'),
        ),
        ...List.generate(
          4,
          (i) => _entry(id: 'tv:$i', title: 'Show $i', mediaType: 'tv'),
        ),
      ];
      final badges = computeBadges(entries: entries, members: const []);
      final b = find(badges, 'binge_master');
      expect(b.earned, false);
      expect(b.progress, 4);
    });

    test('Binge Master — earned at 10 TV entries', () {
      final entries = List.generate(
        12,
        (i) => _entry(id: 'tv:$i', title: 'Show $i', mediaType: 'tv'),
      );
      final badges = computeBadges(entries: entries, members: const []);
      expect(find(badges, 'binge_master').earned, true);
    });

    test('Perfect Sync — no taste profile yet → zero progress', () {
      final badges =
          computeBadges(entries: const [], members: const []);
      final b = find(badges, 'perfect_sync');
      expect(b.progress, 0);
      expect(b.earned, false);
    });

    test('Perfect Sync — below threshold → not earned, progress rounds', () {
      final badges = computeBadges(
        entries: const [],
        members: const [],
        compatibilityPct: 0.675,
      );
      final b = find(badges, 'perfect_sync');
      expect(b.progress, 68); // 0.675 * 100 rounds to 68
      expect(b.earned, false);
    });

    test('Perfect Sync — earned at 90% compatibility', () {
      final badges = computeBadges(
        entries: const [],
        members: const [],
        compatibilityPct: 0.9,
      );
      expect(find(badges, 'perfect_sync').earned, true);
    });

    test('Perfect Sync — progress caps at target when compat > 0.9', () {
      final badges = computeBadges(
        entries: const [],
        members: const [],
        compatibilityPct: 0.98,
      );
      final b = find(badges, 'perfect_sync');
      expect(b.earned, true);
      expect(b.progress, 90);
    });

    test('Marathon Mode — entries with no lastWatchedAt contribute nothing',
        () {
      final entries = List.generate(
        8,
        (i) => _entry(id: 'movie:$i', title: 'T$i'),
      );
      final badges = computeBadges(entries: entries, members: const []);
      final b = find(badges, 'marathon_mode');
      expect(b.progress, 0);
      expect(b.earned, false);
    });

    test('Marathon Mode — earned at 5 watches on the same UTC day', () {
      final day = DateTime.utc(2026, 4, 18, 20);
      final entries = [
        for (var i = 0; i < 5; i++)
          _entry(
            id: 'movie:$i',
            title: 'T$i',
            lastWatchedAt: day.add(Duration(minutes: i * 15)),
          ),
        // A straggler on a different day shouldn't boost the count.
        _entry(
          id: 'movie:99',
          title: 'Z',
          lastWatchedAt: day.add(const Duration(days: 3)),
        ),
      ];
      final badges = computeBadges(entries: entries, members: const []);
      final b = find(badges, 'marathon_mode');
      expect(b.earned, true);
      expect(b.progress, 5);
    });

    test('Marathon Mode — 4 in one day → not earned, progress tracks max day',
        () {
      final day = DateTime.utc(2026, 4, 18, 9);
      final entries = [
        for (var i = 0; i < 4; i++)
          _entry(
            id: 'movie:$i',
            title: 'T$i',
            lastWatchedAt: day.add(Duration(hours: i)),
          ),
        _entry(
          id: 'movie:50',
          title: 'Other',
          lastWatchedAt: day.add(const Duration(days: 1, hours: 2)),
        ),
      ];
      final badges = computeBadges(entries: entries, members: const []);
      final b = find(badges, 'marathon_mode');
      expect(b.earned, false);
      expect(b.progress, 4);
    });

    test('Five Star Fan — below threshold → not earned, progress tracks count',
        () {
      final m = HouseholdMember(uid: 'u1', displayName: 'Alice');
      final ratings = [
        for (var i = 0; i < 4; i++)
          _rating(uid: 'u1', targetId: 'movie:$i', stars: 5),
        _rating(uid: 'u1', targetId: 'movie:10', stars: 4),
      ];
      final badges = computeBadges(
        entries: const [],
        members: [m],
        ratings: ratings,
      );
      final b = find(badges, 'five_star_fan_u1');
      expect(b.earned, false);
      expect(b.progress, 4);
    });

    test('Five Star Fan — earned at 10 five-star ratings, progress caps', () {
      final m = HouseholdMember(uid: 'u1', displayName: 'Alice');
      final ratings = [
        for (var i = 0; i < 12; i++)
          _rating(uid: 'u1', targetId: 'movie:$i', stars: 5),
      ];
      final badges = computeBadges(
        entries: const [],
        members: [m],
        ratings: ratings,
      );
      final b = find(badges, 'five_star_fan_u1');
      expect(b.earned, true);
      expect(b.progress, 10);
    });

    test('Five Star Fan — other members\' ratings do not count', () {
      final a = HouseholdMember(uid: 'u1', displayName: 'Alice');
      final b = HouseholdMember(uid: 'u2', displayName: 'Bob');
      final ratings = [
        for (var i = 0; i < 10; i++)
          _rating(uid: 'u2', targetId: 'movie:$i', stars: 5),
      ];
      final badges = computeBadges(
        entries: const [],
        members: [a, b],
        ratings: ratings,
      );
      expect(find(badges, 'five_star_fan_u1').earned, false);
      expect(find(badges, 'five_star_fan_u2').earned, true);
    });

    test('Five Star Fan — episode ratings do not inflate the count', () {
      final m = HouseholdMember(uid: 'u1', displayName: 'Alice');
      final ratings = [
        for (var i = 0; i < 12; i++)
          _rating(
            uid: 'u1',
            targetId: 'tv:1:s1_e$i',
            stars: 5,
            level: 'episode',
          ),
      ];
      final badges = computeBadges(
        entries: const [],
        members: [m],
        ratings: ratings,
      );
      expect(find(badges, 'five_star_fan_u1').earned, false);
      expect(find(badges, 'five_star_fan_u1').progress, 0);
    });

    test('Critic — counts only ratings with a non-empty note', () {
      final m = HouseholdMember(uid: 'u1', displayName: 'Alice');
      final ratings = [
        for (var i = 0; i < 6; i++)
          _rating(
            uid: 'u1',
            targetId: 'movie:$i',
            stars: 4,
            note: 'Thoughts on title $i',
          ),
        // Whitespace-only note should not qualify.
        _rating(
          uid: 'u1',
          targetId: 'movie:50',
          stars: 3,
          note: '   ',
        ),
        // No note at all.
        _rating(uid: 'u1', targetId: 'movie:51', stars: 2),
      ];
      final badges = computeBadges(
        entries: const [],
        members: [m],
        ratings: ratings,
      );
      final critic = find(badges, 'critic_u1');
      expect(critic.earned, false);
      expect(critic.progress, 6);
    });

    test('Critic — earned at 10 rated-with-note entries', () {
      final m = HouseholdMember(uid: 'u1', displayName: 'Alice');
      final ratings = [
        for (var i = 0; i < 10; i++)
          _rating(
            uid: 'u1',
            targetId: 'movie:$i',
            stars: 4,
            note: 'note $i',
          ),
      ];
      final badges = computeBadges(
        entries: const [],
        members: [m],
        ratings: ratings,
      );
      expect(find(badges, 'critic_u1').earned, true);
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
