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
}
