import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/prediction.dart';
import 'package:watchnext/services/prediction_service.dart';

void main() {
  group('PredictionService', () {
    late FakeFirebaseFirestore db;
    late PredictionService svc;
    const hh = 'hh1';

    setUp(() {
      db = FakeFirebaseFirestore();
      svc = PredictionService(db: db);
    });

    test('submitPrediction writes an entry and reveal_seen false', () async {
      await svc.submitPrediction(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'X',
        stars: 4,
      );
      final snap = await db.doc('households/$hh/predictions/movie:42').get();
      final p = Prediction.fromDoc(snap);
      expect(p.entryFor('u1')?.stars, 4);
      expect(p.entryFor('u1')?.skipped, isFalse);
      expect(p.revealSeenBy('u1'), isFalse);
    });

    test('skipPrediction records skipped entry without stars', () async {
      await svc.skipPrediction(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'X',
      );
      final snap = await db.doc('households/$hh/predictions/movie:42').get();
      final p = Prediction.fromDoc(snap);
      expect(p.entryFor('u1')?.skipped, isTrue);
      expect(p.entryFor('u1')?.stars, isNull);
    });

    test('two members can submit to the same prediction doc via merge',
        () async {
      await svc.submitPrediction(
          householdId: hh,
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 42,
          title: 'X',
          stars: 4);
      await svc.submitPrediction(
          householdId: hh,
          uid: 'u2',
          mediaType: 'movie',
          tmdbId: 42,
          title: 'X',
          stars: 2);
      final snap = await db.doc('households/$hh/predictions/movie:42').get();
      final p = Prediction.fromDoc(snap);
      expect(p.entryFor('u1')?.stars, 4);
      expect(p.entryFor('u2')?.stars, 2);
      expect(p.allSubmitted(const ['u1', 'u2']), isTrue);
    });

    test('markRevealSeen flips reveal_seen and bumps predict_total', () async {
      await svc.submitPrediction(
          householdId: hh,
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 42,
          title: 'X',
          stars: 4);
      await svc.markRevealSeen(
        householdId: hh,
        uid: 'u1',
        predictionId: 'movie:42',
        won: true,
      );
      final pSnap = await db.doc('households/$hh/predictions/movie:42').get();
      expect(Prediction.fromDoc(pSnap).revealSeenBy('u1'), isTrue);

      final mSnap = await db.doc('households/$hh/members/u1').get();
      expect(mSnap.data()!['predict_total'], 1);
      expect(mSnap.data()!['predict_wins'], 1);
    });

    test('markRevealSeen with won=false only bumps predict_total', () async {
      await svc.submitPrediction(
          householdId: hh,
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 1,
          title: 'X',
          stars: 3);
      await svc.markRevealSeen(
          householdId: hh, uid: 'u1', predictionId: 'movie:1', won: false);
      final mSnap = await db.doc('households/$hh/members/u1').get();
      expect(mSnap.data()!['predict_total'], 1);
      expect(mSnap.data(), isNot(contains('predict_wins')));
    });

    test('submitPrediction persists context on the entry', () async {
      await svc.submitPrediction(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 7,
        title: 'X',
        stars: 4,
        context: 'solo',
      );
      final snap = await db.doc('households/$hh/predictions/movie:7').get();
      final p = Prediction.fromDoc(snap);
      expect(p.entryFor('u1')?.context, 'solo');
    });

    test('skipPrediction persists context on the skip entry', () async {
      await svc.skipPrediction(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 8,
        title: 'X',
        context: 'together',
      );
      final snap = await db.doc('households/$hh/predictions/movie:8').get();
      final p = Prediction.fromDoc(snap);
      expect(p.entryFor('u1')?.context, 'together');
      expect(p.entryFor('u1')?.skipped, isTrue);
    });

    test('submitPrediction without context omits the field (legacy path)',
        () async {
      await svc.submitPrediction(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 9,
        title: 'X',
        stars: 3,
      );
      final raw = (await db.doc('households/$hh/predictions/movie:9').get())
          .data()!;
      final entries = raw['entries'] as Map;
      expect((entries['u1'] as Map).containsKey('context'), isFalse);
    });

    test('markRevealSeen with context=solo bumps _solo counters only',
        () async {
      await svc.submitPrediction(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 10,
        title: 'X',
        stars: 4,
        context: 'solo',
      );
      await svc.markRevealSeen(
        householdId: hh,
        uid: 'u1',
        predictionId: 'movie:10',
        won: true,
        context: 'solo',
      );
      final m = (await db.doc('households/$hh/members/u1').get()).data()!;
      expect(m['predict_total_solo'], 1);
      expect(m['predict_wins_solo'], 1);
      expect(m, isNot(contains('predict_total')));
      expect(m, isNot(contains('predict_total_together')));
    });

    test('markRevealSeen with context=together bumps _together counters only',
        () async {
      await svc.submitPrediction(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 11,
        title: 'X',
        stars: 4,
        context: 'together',
      );
      await svc.markRevealSeen(
        householdId: hh,
        uid: 'u1',
        predictionId: 'movie:11',
        won: false,
        context: 'together',
      );
      final m = (await db.doc('households/$hh/members/u1').get()).data()!;
      expect(m['predict_total_together'], 1);
      expect(m, isNot(contains('predict_wins_together')));
      expect(m, isNot(contains('predict_total')));
      expect(m, isNot(contains('predict_total_solo')));
    });

    test('solo and together counters accumulate independently', () async {
      for (var i = 0; i < 3; i++) {
        await svc.markRevealSeen(
          householdId: hh,
          uid: 'u1',
          predictionId: 'movie:$i',
          won: i == 0,
          context: 'solo',
        );
      }
      await svc.markRevealSeen(
        householdId: hh,
        uid: 'u1',
        predictionId: 'movie:99',
        won: true,
        context: 'together',
      );
      final m = (await db.doc('households/$hh/members/u1').get()).data()!;
      expect(m['predict_total_solo'], 3);
      expect(m['predict_wins_solo'], 1);
      expect(m['predict_total_together'], 1);
      expect(m['predict_wins_together'], 1);
    });

    test('stream emits null for a non-existent doc and updates on write',
        () async {
      final events = <Prediction?>[];
      final sub = svc.stream(hh, 'movie:42').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await svc.submitPrediction(
          householdId: hh,
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 42,
          title: 'X',
          stars: 5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(events.first, isNull);
      expect(events.last?.entryFor('u1')?.stars, 5);
    });
  });
}
