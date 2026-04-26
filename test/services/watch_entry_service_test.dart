import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/services/watch_entry_service.dart';

void main() {
  late FakeFirebaseFirestore db;
  late WatchEntryService svc;

  const hh = 'hh1';
  const uid = 'u1';
  const partner = 'u2';
  const tmdbId = 42;
  const mt = 'movie';
  const entryPath = 'households/hh1/watchEntries/movie:42';

  final details = {
    'title': 'The Answer',
    'release_date': '2005-06-01',
    'runtime': 120,
    'genres': [
      {'id': 18, 'name': 'Drama'},
    ],
    'poster_path': '/poster.jpg',
    'overview': 'An answer.',
  };

  setUp(() {
    db = FakeFirebaseFirestore();
    svc = WatchEntryService(db: db);
  });

  group('markWatched', () {
    test('creates a fresh entry with metadata on first write', () async {
      await svc.markWatched(
        householdId: hh, uid: uid, mediaType: mt,
        tmdbId: tmdbId, details: details,
      );
      final snap = await db.doc(entryPath).get();
      expect(snap.exists, isTrue);
      final d = snap.data()!;
      expect(d['title'], 'The Answer');
      expect(d['watched_by'], {uid: true});
      expect(d['added_source'], 'manual');
    });

    test('writes watched_by as a nested map, not a literal dotted key',
        () async {
      await svc.markWatched(
        householdId: hh, uid: uid, mediaType: mt,
        tmdbId: tmdbId, details: details,
      );
      // Second mark — exercises the existing-entry branch that used to call
      // .set({'watched_by.<uid>': true}, merge:true), creating a literal
      // "watched_by.<uid>" field. Must now route through .update() which
      // correctly honours dot notation.
      await svc.markWatched(
        householdId: hh, uid: partner, mediaType: mt,
        tmdbId: tmdbId, details: details,
      );
      final d = (await db.doc(entryPath).get()).data()!;
      final watchedBy = (d['watched_by'] as Map).cast<String, dynamic>();
      expect(watchedBy, {uid: true, partner: true});
      expect(d.containsKey('watched_by.$partner'), isFalse,
          reason: 'dot-notation must not be stored as a literal field name');
    });
  });

  group('unmarkWatched', () {
    test('flips watched_by[uid] back to false', () async {
      await svc.markWatched(
        householdId: hh, uid: uid, mediaType: mt,
        tmdbId: tmdbId, details: details,
      );
      await svc.unmarkWatched(
        householdId: hh, uid: uid, mediaType: mt, tmdbId: tmdbId,
      );
      final d = (await db.doc(entryPath).get()).data()!;
      final watchedBy = (d['watched_by'] as Map).cast<String, dynamic>();
      expect(watchedBy[uid], false);
      expect(d.containsKey('watched_by.$uid'), isFalse);
    });

    test('no-op when the entry does not exist', () async {
      await svc.unmarkWatched(
        householdId: hh, uid: uid, mediaType: mt, tmdbId: tmdbId,
      );
      final snap = await db.doc(entryPath).get();
      expect(snap.exists, isFalse);
    });
  });

  group('markWatching', () {
    test('creates entry with in_progress_status on first write', () async {
      await svc.markWatching(
        householdId: hh, uid: uid, mediaType: 'tv',
        tmdbId: tmdbId, details: {
          'name': 'A Show',
          'first_air_date': '2010-01-01',
          'episode_run_time': [50],
          'genres': [],
        },
      );
      final snap = await db.doc('households/hh1/watchEntries/tv:42').get();
      final d = snap.data()!;
      expect(d['in_progress_status'], 'watching');
      expect((d['watched_by'] as Map)[uid], false);
    });

    test('sets in_progress_status on existing entry via update', () async {
      await svc.markWatched(
        householdId: hh, uid: uid, mediaType: mt,
        tmdbId: tmdbId, details: details,
      );
      await svc.markWatching(
        householdId: hh, uid: uid, mediaType: mt,
        tmdbId: tmdbId, details: details,
      );
      final d = (await db.doc(entryPath).get()).data()!;
      expect(d['in_progress_status'], 'watching');
      final watchedBy = (d['watched_by'] as Map).cast<String, dynamic>();
      expect(watchedBy[uid], false);
      expect(d.containsKey('watched_by.$uid'), isFalse);
      expect(d.containsKey('in_progress_status'), isTrue);
    });
  });

  group('unmarkWatching', () {
    test('removes in_progress_status field', () async {
      await svc.markWatching(
        householdId: hh, uid: uid, mediaType: 'tv',
        tmdbId: tmdbId, details: {
          'name': 'A Show',
          'first_air_date': '2010-01-01',
          'genres': [],
        },
      );
      await svc.unmarkWatching(
        householdId: hh, mediaType: 'tv', tmdbId: tmdbId,
      );
      final d = (await db.doc('households/hh1/watchEntries/tv:42').get())
          .data()!;
      expect(d.containsKey('in_progress_status'), isFalse);
    });
  });

  group('markEpisodeWatched', () {
    final tvDetails = {
      'name': 'A Show',
      'first_air_date': '2010-01-01',
      'episode_run_time': [50],
      'genres': [
        {'id': 18, 'name': 'Drama'},
      ],
      'poster_path': '/show.jpg',
      'overview': 'About a show.',
    };
    final episodeMeta = {
      'id': 99001,
      'name': 'Pilot',
      'overview': 'Walter takes a class.',
      'still_path': '/still.jpg',
      'runtime': 58,
      'air_date': '2010-01-20',
    };
    const showId = 'households/hh1/watchEntries/tv:42';
    const epDocPath = 'households/hh1/watchEntries/tv:42/episodes/1_1';

    test('creates parent watchEntry on first mark + writes episode metadata',
        () async {
      await svc.markEpisodeWatched(
        householdId: hh, uid: uid, tmdbId: tmdbId,
        season: 1, number: 1,
        parentDetails: tvDetails,
        episodeMeta: episodeMeta,
      );
      final entry = (await db.doc(showId).get()).data()!;
      expect(entry['title'], 'A Show');
      expect(entry['in_progress_status'], 'watching');
      expect(entry['last_season'], 1);
      expect(entry['last_episode'], 1);

      final ep = (await db.doc(epDocPath).get()).data()!;
      expect(ep['season'], 1);
      expect(ep['number'], 1);
      expect(ep['title'], 'Pilot');
      expect(ep['overview'], 'Walter takes a class.');
      expect(ep['still_path'], '/still.jpg');
      expect(ep['tmdb_id'], 99001);
      expect(ep['runtime'], 58);
      expect(ep['aired_at'], isNotNull);
      // watched_by_at must be a NESTED MAP, not a flat dotted key (gotcha 27).
      final watched = (ep['watched_by_at'] as Map).cast<String, dynamic>();
      expect(watched.containsKey(uid), isTrue);
      expect(ep.containsKey('watched_by_at.$uid'), isFalse);
    });

    test("partner's existing timestamp survives a fresh mark", () async {
      await svc.markEpisodeWatched(
        householdId: hh, uid: uid, tmdbId: tmdbId,
        season: 1, number: 1,
        parentDetails: tvDetails, episodeMeta: episodeMeta,
      );
      await svc.markEpisodeWatched(
        householdId: hh, uid: partner, tmdbId: tmdbId,
        season: 1, number: 1,
        parentDetails: tvDetails, episodeMeta: episodeMeta,
      );
      final ep = (await db.doc(epDocPath).get()).data()!;
      final watched = (ep['watched_by_at'] as Map).cast<String, dynamic>();
      expect(watched.keys.toSet(), {uid, partner});
      expect(ep.containsKey('watched_by_at.$partner'), isFalse);
    });
  });

  group('unmarkEpisodeWatched', () {
    test("clears the user's timestamp without touching the partner's",
        () async {
      const tvDetails = <String, dynamic>{'name': 'X', 'genres': []};
      await svc.markEpisodeWatched(
        householdId: hh, uid: uid, tmdbId: tmdbId,
        season: 1, number: 1,
        parentDetails: tvDetails,
      );
      await svc.markEpisodeWatched(
        householdId: hh, uid: partner, tmdbId: tmdbId,
        season: 1, number: 1,
        parentDetails: tvDetails,
      );
      await svc.unmarkEpisodeWatched(
        householdId: hh, uid: uid, tmdbId: tmdbId,
        season: 1, number: 1,
      );
      final ep = (await db
              .doc('households/hh1/watchEntries/tv:42/episodes/1_1')
              .get())
          .data()!;
      final watched = (ep['watched_by_at'] as Map).cast<String, dynamic>();
      expect(watched.keys.toList(), [partner]);
    });

    test('no-op when episode doc does not exist', () async {
      await svc.unmarkEpisodeWatched(
        householdId: hh, uid: uid, tmdbId: tmdbId,
        season: 1, number: 1,
      );
      final snap = await db
          .doc('households/hh1/watchEntries/tv:42/episodes/1_1')
          .get();
      expect(snap.exists, isFalse);
    });
  });
}
