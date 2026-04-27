import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/providers/household_provider.dart';
import 'package:watchnext/providers/tonights_pick_provider.dart';

ProviderContainer _container({
  required FakeFirebaseFirestore db,
  String? householdId,
}) {
  final container = ProviderContainer(overrides: [
    householdIdProvider.overrideWith((_) async => householdId),
    tonightsPickFirestoreProvider.overrideWithValue(db),
  ]);
  // tonightsPickProvider is NOT autoDispose so a single passive listen is
  // enough to keep it alive across the awaits below.
  container.listen<AsyncValue<TonightsPick?>>(tonightsPickProvider, (_, _) {});
  return container;
}

Future<TonightsPick?> _resolvePick(ProviderContainer c,
    {bool expectValue = false}) async {
  // Drive the household FutureProvider first so its build completes — once
  // resolved, tonightsPickProvider rebuilds against the real householdId
  // rather than the loading-state null.
  await c.read(householdIdProvider.future);
  // If the test expects a parsed pick, wait until a non-null lands.
  // Otherwise (null household / missing doc), the first AsyncData(null) is
  // the answer.
  final completer = Completer<TonightsPick?>();
  final sub = c.listen<AsyncValue<TonightsPick?>>(tonightsPickProvider,
      (_, next) {
    if (completer.isCompleted) return;
    if (next is AsyncData<TonightsPick?>) {
      if (expectValue && next.value == null) return;
      completer.complete(next.value);
    }
  }, fireImmediately: true);
  final result =
      await completer.future.timeout(const Duration(seconds: 2));
  sub.close();
  return result;
}

void main() {
  group('tonightsPickProvider', () {
    test('yields null when household is unset', () async {
      final db = FakeFirebaseFirestore();
      final container = _container(db: db, householdId: null);
      addTearDown(container.dispose);
      expect(await _resolvePick(container), isNull);
    });

    test('yields null when the doc does not exist', () async {
      final db = FakeFirebaseFirestore();
      final container = _container(db: db, householdId: 'hh1');
      addTearDown(container.dispose);
      expect(await _resolvePick(container), isNull);
    });

    test('yields a parsed TonightsPick when the doc is present', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('households/hh1/tonightsPick/current').set({
        'tmdbId': 603,
        'mediaType': 'movie',
        'title': 'The Matrix',
        'posterPath': '/m.jpg',
        'year': 1999,
        'matchScore': 92,
        'aiBlurb': 'Bend the spoon.',
        'source': 'discover',
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 4, 25, 8)),
      });
      final container = _container(db: db, householdId: 'hh1');
      addTearDown(container.dispose);
      final pick = await _resolvePick(container, expectValue: true);
      expect(pick, isNotNull);
      expect(pick!.tmdbId, 603);
      expect(pick.mediaType, 'movie');
      expect(pick.title, 'The Matrix');
      expect(pick.posterPath, '/m.jpg');
      expect(pick.year, 1999);
      expect(pick.matchScore, 92);
      expect(pick.aiBlurb, 'Bend the spoon.');
      expect(pick.source, 'discover');
      // Firestore returns local-zone DateTimes from Timestamp.toDate(); we
      // only care that the round-trip preserves the instant.
      expect(pick.updatedAt?.millisecondsSinceEpoch,
          DateTime.utc(2026, 4, 25, 8).millisecondsSinceEpoch);
    });

    test('re-emits when the doc updates', () async {
      final db = FakeFirebaseFirestore();
      final ref = db.doc('households/hh1/tonightsPick/current');
      await ref.set({
        'tmdbId': 1,
        'mediaType': 'movie',
        'title': 'First',
        'posterPath': '/a.jpg',
        'matchScore': 50,
      });
      final container = _container(db: db, householdId: 'hh1');
      addTearDown(container.dispose);
      // Drive household resolution before subscribing — without this the
      // first AsyncData emission is the loading-state null, not the doc.
      await container.read(householdIdProvider.future);

      final emissions = <int>[];
      final completer = Completer<void>();
      final sub = container.listen<AsyncValue<TonightsPick?>>(
          tonightsPickProvider, (_, next) {
        final v = next.value;
        if (v != null) {
          emissions.add(v.tmdbId);
          if (emissions.length == 2 && !completer.isCompleted) {
            completer.complete();
          }
        }
      }, fireImmediately: true);

      // Allow the initial emission to land, then write the update.
      await Future<void>.delayed(Duration.zero);
      await ref.set({
        'tmdbId': 2,
        'mediaType': 'tv',
        'title': 'Second',
        'posterPath': '/b.jpg',
        'matchScore': 60,
      });

      await completer.future.timeout(const Duration(seconds: 2));
      sub.close();
      expect(emissions, [1, 2]);
    });
  });
}
