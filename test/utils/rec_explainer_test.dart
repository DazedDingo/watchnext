import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/rating.dart';
import 'package:watchnext/models/recommendation.dart';
import 'package:watchnext/models/watch_entry.dart';
import 'package:watchnext/utils/rec_explainer.dart';

Recommendation _rec({
  String id = 'movie:99',
  String mediaType = 'movie',
  int tmdbId = 99,
  String title = 'Candidate',
  List<String> genres = const ['Drama'],
}) {
  return Recommendation(
    id: id,
    mediaType: mediaType,
    tmdbId: tmdbId,
    title: title,
    genres: genres,
    matchScore: 80,
  );
}

WatchEntry _entry({
  required String id,
  required String title,
  List<String> genres = const [],
}) {
  final parts = id.split(':');
  return WatchEntry(
    id: id,
    mediaType: parts.first,
    tmdbId: int.parse(parts.last),
    title: title,
    genres: genres,
  );
}

Rating _rating({
  required String uid,
  required String targetId,
  required int stars,
  DateTime? ratedAt,
  String level = 'movie',
}) {
  return Rating(
    id: Rating.buildId(uid, level, targetId),
    uid: uid,
    level: level,
    targetId: targetId,
    stars: stars,
    ratedAt: ratedAt ?? DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('pickExplainer', () {
    test('picks the highest-rated genre-matching watched title', () {
      final rec = _rec(genres: const ['Drama', 'Crime']);
      final entries = [
        _entry(id: 'movie:1', title: 'Goodfellas', genres: const ['Crime']),
        _entry(id: 'movie:2', title: 'Shrek', genres: const ['Animation']),
      ];
      final ratings = [
        _rating(uid: 'u1', targetId: 'movie:1', stars: 5),
        _rating(uid: 'u1', targetId: 'movie:2', stars: 5),
      ];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        'Goodfellas',
      );
    });

    test('returns null when no rating meets minStars', () {
      final rec = _rec();
      final entries = [
        _entry(id: 'movie:1', title: 'Meh', genres: const ['Drama']),
      ];
      final ratings = [_rating(uid: 'u1', targetId: 'movie:1', stars: 3)];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        isNull,
      );
    });

    test('returns null when there is no genre overlap', () {
      final rec = _rec(genres: const ['Horror']);
      final entries = [
        _entry(id: 'movie:1', title: 'Romcom', genres: const ['Romance']),
      ];
      final ratings = [_rating(uid: 'u1', targetId: 'movie:1', stars: 5)];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        isNull,
      );
    });

    test('returns null when rec has no genres (rec came in stripped)', () {
      final rec = _rec(genres: const []);
      final entries = [
        _entry(id: 'movie:1', title: 'Good', genres: const ['Drama']),
      ];
      final ratings = [_rating(uid: 'u1', targetId: 'movie:1', stars: 5)];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        isNull,
      );
    });

    test('returns null when the rated targetId has no matching entry', () {
      // Watch entry was manually deleted but the rating linger — don't crash.
      final rec = _rec();
      final ratings = [_rating(uid: 'u1', targetId: 'movie:1', stars: 5)];
      expect(
        pickExplainer(
          rec: rec,
          myRatings: ratings,
          entries: const [],
        ),
        isNull,
      );
    });

    test('excludes the rec itself (self-citation would be weird)', () {
      final rec = _rec(id: 'movie:99', genres: const ['Drama']);
      final entries = [
        _entry(id: 'movie:99', title: 'Candidate', genres: const ['Drama']),
        _entry(id: 'movie:1', title: 'Other', genres: const ['Drama']),
      ];
      final ratings = [
        _rating(uid: 'u1', targetId: 'movie:99', stars: 5),
        _rating(uid: 'u1', targetId: 'movie:1', stars: 4),
      ];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        'Other',
      );
    });

    test('prefers 5★ over 4★ even when 4★ is more recent', () {
      final rec = _rec(genres: const ['Drama']);
      final entries = [
        _entry(id: 'movie:1', title: 'Older Masterpiece',
            genres: const ['Drama']),
        _entry(id: 'movie:2', title: 'Recent Good-not-great',
            genres: const ['Drama']),
      ];
      final ratings = [
        _rating(
            uid: 'u1',
            targetId: 'movie:1',
            stars: 5,
            ratedAt: DateTime.utc(2024, 1, 1)),
        _rating(
            uid: 'u1',
            targetId: 'movie:2',
            stars: 4,
            ratedAt: DateTime.utc(2026, 4, 1)),
      ];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        'Older Masterpiece',
      );
    });

    test('ties on stars break by most recent rating', () {
      final rec = _rec(genres: const ['Drama']);
      final entries = [
        _entry(id: 'movie:1', title: 'Older', genres: const ['Drama']),
        _entry(id: 'movie:2', title: 'Newer', genres: const ['Drama']),
      ];
      final ratings = [
        _rating(
            uid: 'u1',
            targetId: 'movie:1',
            stars: 5,
            ratedAt: DateTime.utc(2024, 1, 1)),
        _rating(
            uid: 'u1',
            targetId: 'movie:2',
            stars: 5,
            ratedAt: DateTime.utc(2026, 3, 1)),
      ];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        'Newer',
      );
    });

    test('ties on stars AND date break deterministically by title', () {
      final rec = _rec(genres: const ['Drama']);
      final same = DateTime.utc(2025, 1, 1);
      final entries = [
        _entry(id: 'movie:1', title: 'Bravo', genres: const ['Drama']),
        _entry(id: 'movie:2', title: 'Alpha', genres: const ['Drama']),
      ];
      final ratings = [
        _rating(uid: 'u1', targetId: 'movie:1', stars: 5, ratedAt: same),
        _rating(uid: 'u1', targetId: 'movie:2', stars: 5, ratedAt: same),
      ];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        'Alpha',
      );
    });

    test('only myRatings are considered (caller pre-filters by uid)', () {
      // pickExplainer takes whatever ratings you hand it. Homescreen passes
      // only the signed-in user's. This test documents that contract.
      final rec = _rec(genres: const ['Drama']);
      final entries = [
        _entry(id: 'movie:1', title: 'Partner pick', genres: const ['Drama']),
      ];
      final partnerOnly = [_rating(uid: 'u2', targetId: 'movie:1', stars: 5)];
      expect(
        pickExplainer(
            rec: rec, myRatings: partnerOnly.where((r) => r.uid == 'u1'),
            entries: entries),
        isNull,
      );
    });

    test('minStars threshold can be raised', () {
      final rec = _rec(genres: const ['Drama']);
      final entries = [
        _entry(id: 'movie:1', title: 'Four-star', genres: const ['Drama']),
      ];
      final ratings = [_rating(uid: 'u1', targetId: 'movie:1', stars: 4)];
      expect(
        pickExplainer(
            rec: rec, myRatings: ratings, entries: entries, minStars: 5),
        isNull,
      );
      expect(
        pickExplainer(
            rec: rec, myRatings: ratings, entries: entries, minStars: 4),
        'Four-star',
      );
    });

    test('empty inputs return null without crashing', () {
      final rec = _rec();
      expect(
        pickExplainer(rec: rec, myRatings: const [], entries: const []),
        isNull,
      );
    });

    test('a single overlapping genre is enough (no "majority" rule)', () {
      final rec = _rec(genres: const ['Drama', 'Thriller', 'Crime']);
      final entries = [
        _entry(
            id: 'movie:1',
            title: 'Niche Fit',
            genres: const ['Crime', 'Comedy']),
      ];
      final ratings = [_rating(uid: 'u1', targetId: 'movie:1', stars: 5)];
      expect(
        pickExplainer(rec: rec, myRatings: ratings, entries: entries),
        'Niche Fit',
      );
    });
  });

  group('explainerLabel', () {
    test('formats the user-visible copy', () {
      expect(explainerLabel('Inception'), 'Because you loved Inception');
    });
  });
}
