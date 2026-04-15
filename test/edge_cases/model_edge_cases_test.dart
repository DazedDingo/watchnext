import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/prediction.dart';
import 'package:watchnext/models/rating.dart';
import 'package:watchnext/models/recommendation.dart';
import 'package:watchnext/models/watch_entry.dart';
import 'package:watchnext/models/watchlist_item.dart';

/// Edge-case coverage for the model layer. Focused on malformed Firestore
/// documents, unicode, boundary values, and stale legacy-shape data — the
/// things that'll surface during real QA but are tedious to hit by hand.
void main() {
  late FakeFirebaseFirestore db;
  setUp(() => db = FakeFirebaseFirestore());

  group('Rating edge cases', () {
    test('stars field as a double (Firestore sometimes widens ints)',
        () async {
      await db.doc('r/1').set({
        'uid': 'u1',
        'level': 'movie',
        'target_id': 'movie:1',
        'stars': 4.0,
        'rated_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final r = Rating.fromDoc(await db.doc('r/1').get());
      expect(r.stars, 4);
      expect(r.stars, isA<int>());
    });

    test('unicode in note and tags roundtrips', () async {
      final original = Rating(
        id: 'x',
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:1',
        stars: 5,
        ratedAt: DateTime.utc(2025, 1, 1),
        tags: const ['🎬', 'слоу', '中文'],
        note: 'loved it 💯',
      );
      await db.doc('r/1').set(original.toFirestore());
      final parsed = Rating.fromDoc(await db.doc('r/1').get());
      expect(parsed.tags, ['🎬', 'слоу', '中文']);
      expect(parsed.note, 'loved it 💯');
    });

    test('empty tags list survives roundtrip', () async {
      final r = Rating(
        id: 'x',
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:1',
        stars: 3,
        ratedAt: DateTime.utc(2025, 1, 1),
      );
      await db.doc('r/1').set(r.toFirestore());
      final parsed = Rating.fromDoc(await db.doc('r/1').get());
      expect(parsed.tags, isEmpty);
    });

    test('tags with mixed types are cast-filtered to strings via List.cast',
        () async {
      // Simulate Firestore sometimes returning dynamic list that claims to be
      // List<String> — the .cast<String>() handles it.
      await db.doc('r/1').set({
        'uid': 'u1',
        'level': 'movie',
        'target_id': 'movie:1',
        'stars': 4,
        'tags': <dynamic>['a', 'b'], // dynamic list
        'rated_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final r = Rating.fromDoc(await db.doc('r/1').get());
      expect(r.tags, ['a', 'b']);
    });
  });

  group('WatchEntry edge cases', () {
    test('watched_by map with various bool-ish values casts cleanly',
        () async {
      await db.doc('w/1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'X',
        'watched_by': <String, dynamic>{'u1': true, 'u2': false},
      });
      final e = WatchEntry.fromDoc(await db.doc('w/1').get());
      expect(e.watchedBy, {'u1': true, 'u2': false});
    });

    test('tmdb_id stored as double still parses as int', () async {
      await db.doc('w/1').set({
        'media_type': 'movie',
        'tmdb_id': 42.0,
        'title': 'X',
      });
      expect(WatchEntry.fromDoc(await db.doc('w/1').get()).tmdbId, 42);
    });

    test('extremely long title roundtrips intact', () async {
      final longTitle = 'A' * 500;
      final e = WatchEntry(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: longTitle,
      );
      await db.doc('w/1').set(e.toFirestore());
      expect(WatchEntry.fromDoc(await db.doc('w/1').get()).title, longTitle);
    });

    test('in_progress_status with invalid value passes through verbatim',
        () async {
      // Service/UI layer is responsible for validating enum values.
      await db.doc('w/1').set({
        'media_type': 'tv',
        'tmdb_id': 1,
        'title': 'X',
        'in_progress_status': 'paused_for_plot_reasons',
      });
      final e = WatchEntry.fromDoc(await db.doc('w/1').get());
      expect(e.inProgressStatus, 'paused_for_plot_reasons');
    });

    test('buildId is ASCII-only but accepts unusual mediaType', () {
      // Guard: if media_type ever shifts (e.g., "short"), id still forms cleanly.
      expect(WatchEntry.buildId('short', 5), 'short:5');
    });
  });

  group('Prediction edge cases', () {
    test('fromDoc handles fully empty doc', () async {
      await db.doc('p/1').set(<String, dynamic>{});
      final p = Prediction.fromDoc(await db.doc('p/1').get());
      expect(p.entries, isEmpty);
      expect(p.revealSeen, isEmpty);
    });

    test('entries with unexpected extra keys pass through', () async {
      await db.doc('p/1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'X',
        'entries': {
          'u1': {
            'stars': 4,
            'skipped': false,
            'legacy_extra_field': 'ignored',
          },
        },
      });
      final p = Prediction.fromDoc(await db.doc('p/1').get());
      expect(p.entryFor('u1')?.stars, 4);
    });

    test('star values at the edge (1 and 5) are preserved', () async {
      await db.doc('p/1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'X',
        'entries': {
          'u1': {'stars': 1},
          'u2': {'stars': 5},
        },
      });
      final p = Prediction.fromDoc(await db.doc('p/1').get());
      expect(p.entryFor('u1')?.stars, 1);
      expect(p.entryFor('u2')?.stars, 5);
    });

    test('revealSeen tolerates missing uids — treats as false', () {
      const p = Prediction(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        revealSeen: {'u1': true},
      );
      expect(p.revealSeenBy('u1'), isTrue);
      expect(p.revealSeenBy('u2'), isFalse);
      expect(p.revealSeenBy(''), isFalse);
    });

    test('allSubmitted with empty uid list returns true (vacuously)', () {
      const p = Prediction(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
      );
      expect(p.allSubmitted(const []), isTrue);
    });
  });

  group('Recommendation edge cases', () {
    test('match_score_solo with mixed-type values (int + double)', () async {
      await db.doc('r/1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'X',
        'match_score': 80,
        'match_score_solo': {'u1': 90, 'u2': 75.5},
      });
      final r = Recommendation.fromDoc(await db.doc('r/1').get());
      expect(r.matchScoreSolo['u1'], 90);
      expect(r.matchScoreSolo['u2'], 75); // double truncated by toInt()
    });

    test('empty blurb and empty solo blurb map default to empty string', () {
      const r = Recommendation(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        matchScore: 50,
      );
      expect(r.blurbFor('u1'), '');
      expect(r.blurbFor(null), '');
    });

    test('score clamps via fallback when uid missing from solo map', () {
      const r = Recommendation(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        matchScore: 50,
        matchScoreSolo: {'u1': 99},
      );
      expect(r.scoreFor('u1'), 99);
      expect(r.scoreFor('u2'), 50); // fall back to together
      expect(r.scoreFor(null), 50);
    });

    test('source field passes through any string (not enum-validated)',
        () async {
      await db.doc('r/1').set({
        'tmdb_id': 1,
        'title': 'X',
        'source': 'future_phase_source_name',
      });
      final r = Recommendation.fromDoc(await db.doc('r/1').get());
      expect(r.source, 'future_phase_source_name');
    });
  });

  group('WatchlistItem edge cases', () {
    test('genres as empty list preserved', () async {
      final w = WatchlistItem(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
      );
      await db.doc('w/1').set(w.toFirestore());
      final parsed = WatchlistItem.fromDoc(await db.doc('w/1').get());
      expect(parsed.genres, isEmpty);
    });

    test('year boundary 1888 (first film) and far future', () async {
      final old = WatchlistItem(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'Roundhay Garden Scene',
        year: 1888,
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
      );
      final future = WatchlistItem(
        id: 'movie:2',
        mediaType: 'movie',
        tmdbId: 2,
        title: 'Future',
        year: 2099,
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
      );
      await db.doc('w/a').set(old.toFirestore());
      await db.doc('w/b').set(future.toFirestore());
      expect(WatchlistItem.fromDoc(await db.doc('w/a').get()).year, 1888);
      expect(WatchlistItem.fromDoc(await db.doc('w/b').get()).year, 2099);
    });
  });
}
