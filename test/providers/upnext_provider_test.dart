import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/models/watch_entry.dart';
import 'package:watchnext/providers/tmdb_provider.dart';
import 'package:watchnext/providers/upnext_provider.dart';
import 'package:watchnext/providers/watch_entries_provider.dart';
import 'package:watchnext/services/tmdb_service.dart';

http.Response _json(Object payload) => http.Response(
      json.encode(payload),
      200,
      headers: const {'content-type': 'application/json'},
    );

String _dateStr(int daysFromToday) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = today.add(Duration(days: daysFromToday));
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

WatchEntry _watchingTv(int tmdbId) {
  return WatchEntry(
    id: 'tv:$tmdbId',
    mediaType: 'tv',
    tmdbId: tmdbId,
    title: 'Show $tmdbId',
    inProgressStatus: 'watching',
  );
}

ProviderContainer _container({
  required http.Client client,
  required List<WatchEntry> entries,
}) {
  final container = ProviderContainer(overrides: [
    tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
    watchEntriesProvider
        .overrideWith((_) => Stream.value(entries)),
  ]);
  // upNextSummaryProvider is autoDispose — without an active listener it
  // gets disposed mid-load and the future read throws "disposed during
  // loading state". A no-op listen keeps it alive for the test.
  container.listen<AsyncValue<List<UpNextEpisode>>>(
    upNextProvider,
    (_, _) {},
  );
  container.listen<AsyncValue<UpNextSummary>>(
    upNextSummaryProvider,
    (_, _) {},
  );
  return container;
}

void main() {
  setUp(() {
    // The new disk-backed cache reads SharedPreferences on every
    // upNextProvider re-run; mock the platform channel with an empty
    // store so reads succeed and don't accidentally hit a cached blob
    // from a sibling test.
    SharedPreferences.setMockInitialValues(const {});
  });

  group('upNextProvider', () {
    test('returns empty when no shows are in progress', () async {
      final client = MockClient((_) async => _json({}));
      final container = _container(client: client, entries: const []);
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      expect(out, isEmpty);
    });

    test('surfaces an in-progress show with a next episode this week',
        () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tv/100')) {
          return _json({
            'id': 100,
            'name': 'Test Show',
            'poster_path': '/p.jpg',
            'next_episode_to_air': {
              'season_number': 3,
              'episode_number': 4,
              'name': 'Big Reveal',
              'air_date': _dateStr(2),
            },
          });
        }
        return http.Response('not mocked: ${req.url}', 404);
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(100)],
      );
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      expect(out, hasLength(1));
      expect(out.first.tmdbId, 100);
      expect(out.first.season, 3);
      expect(out.first.number, 4);
      expect(out.first.daysUntilAir, 2);
      expect(out.first.episodeName, 'Big Reveal');
    });

    test('drops shows whose next episode is more than 7 days out', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tv/200')) {
          return _json({
            'id': 200,
            'name': 'Far-out Show',
            'next_episode_to_air': {
              'season_number': 1,
              'episode_number': 1,
              'air_date': _dateStr(30),
            },
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(200)],
      );
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      expect(out, isEmpty);
    });

    test('keeps an episode that aired yesterday (within recent grace)',
        () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tv/300')) {
          return _json({
            'id': 300,
            'name': 'Just-aired Show',
            'next_episode_to_air': {
              'season_number': 2,
              'episode_number': 5,
              'air_date': _dateStr(-1),
            },
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(300)],
      );
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      expect(out, hasLength(1));
      expect(out.first.daysUntilAir, -1);
    });

    test('drops shows TMDB reports as having no next episode', () async {
      // Cancelled/ended shows return next_episode_to_air = null.
      final client = MockClient((req) async {
        return _json({
          'id': 400,
          'name': 'Cancelled Show',
          'next_episode_to_air': null,
        });
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(400)],
      );
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      expect(out, isEmpty);
    });

    test('a single show throwing on TMDB does not sink the row', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tv/500')) {
          return http.Response('boom', 500);
        }
        if (req.url.path.endsWith('/tv/600')) {
          return _json({
            'id': 600,
            'name': 'Reachable Show',
            'next_episode_to_air': {
              'season_number': 1,
              'episode_number': 2,
              'air_date': _dateStr(3),
            },
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(500), _watchingTv(600)],
      );
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      expect(out.map((e) => e.tmdbId).toList(), [600]);
    });

    test('sorts by air date ascending and caps at kUpNextMaxTiles', () async {
      // Five in-progress shows, all with eps in window. Result should be
      // three (kUpNextMaxTiles=3) ordered by soonest first.
      final byTmdbId = <int, int>{
        700: 6,
        701: 1,
        702: 4,
        703: 0, // today
        704: 7,
      };
      final client = MockClient((req) async {
        for (final entry in byTmdbId.entries) {
          if (req.url.path.endsWith('/tv/${entry.key}')) {
            return _json({
              'id': entry.key,
              'name': 'Show ${entry.key}',
              'next_episode_to_air': {
                'season_number': 1,
                'episode_number': 1,
                'air_date': _dateStr(entry.value),
              },
            });
          }
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        entries: byTmdbId.keys.map(_watchingTv).toList(),
      );
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      expect(out, hasLength(kUpNextMaxTiles));
      // 703 (today=0), 701 (1), 702 (4) — soonest three.
      expect(out.map((e) => e.tmdbId).toList(), [703, 701, 702]);
    });

    test('only watches TV (movies in progress are ignored)', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return _json({});
      });
      final container = _container(
        client: client,
        entries: [
          WatchEntry(
            id: 'movie:42',
            mediaType: 'movie',
            tmdbId: 42,
            title: 'Some Movie',
            inProgressStatus: 'watching',
          ),
        ],
      );
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      expect(out, isEmpty);
      expect(called, isFalse,
          reason: 'no TMDB call should fire for non-TV in-progress entries');
    });

    test('yields disk cache first, then fresh', () async {
      // Pre-seed prefs with a previous-session cache. Stream should emit
      // the cached snapshot immediately, then the fresh TMDB result.
      final cached = [
        UpNextEpisode(
          tmdbId: 999,
          showTitle: 'Cached Show',
          showPosterPath: '/old.jpg',
          season: 1,
          number: 1,
          episodeName: 'Cached Ep',
          airDate: DateTime(2026, 1, 1),
          daysUntilAir: 0,
        ),
      ];
      SharedPreferences.setMockInitialValues({
        kUpNextCacheKey: jsonEncode(cached.map((e) => e.toJson()).toList()),
      });

      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tv/100')) {
          return _json({
            'id': 100,
            'name': 'Fresh Show',
            'next_episode_to_air': {
              'season_number': 5,
              'episode_number': 5,
              'air_date': _dateStr(2),
            },
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(100)],
      );
      addTearDown(container.dispose);

      final emitted = <List<UpNextEpisode>>[];
      container.listen<AsyncValue<List<UpNextEpisode>>>(
        upNextProvider,
        (_, next) {
          final v = next.value;
          if (v != null) emitted.add(v);
        },
        fireImmediately: true,
      );
      // Wait for the fresh emit (it's the second value).
      await container.read(upNextProvider.future);
      // Drain any pending microtasks so both emits land.
      await Future<void>.delayed(Duration.zero);

      expect(emitted.length, greaterThanOrEqualTo(2),
          reason: 'expected at least cached + fresh emits');
      expect(emitted.first.first.tmdbId, 999,
          reason: 'first emit should be the disk cache');
      expect(emitted.last.first.tmdbId, 100,
          reason: 'last emit should be the fresh TMDB result');
    });

    test('empty in-progress with no cache yields [] and saves []', () async {
      // First-time-empty case: cache is empty/null and entries is
      // empty. We yield [] and save [] so a subsequent cold start
      // loads `[]` once instead of null (keeps the load semantics
      // consistent across the pipeline).
      SharedPreferences.setMockInitialValues(const {});
      final client = MockClient((_) async => _json({}));
      final container = _container(client: client, entries: const []);
      addTearDown(container.dispose);

      final out = await container.read(upNextProvider.future);
      await Future<void>.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kUpNextCacheKey), '[]');
      expect(out, isEmpty);
    });

    test('empty in-progress with non-empty cache keeps the cache intact',
        () async {
      // Bias-toward-keeping-cache: empty entries can be a transient
      // Firestore emit during cold start, so we deliberately do NOT
      // overwrite a non-empty cache with []. The next watchEntries
      // emit (probably carrying real data) re-runs the stream and
      // either confirms via the non-empty branch or stays paused
      // here — either way the cached row stays visible.
      final stale = [
        UpNextEpisode(
          tmdbId: 555,
          showTitle: 'Stale',
          season: 1,
          number: 1,
          airDate: DateTime(2026, 1, 1),
          daysUntilAir: 0,
        ),
      ];
      SharedPreferences.setMockInitialValues({
        kUpNextCacheKey: jsonEncode(stale.map((e) => e.toJson()).toList()),
      });

      final client = MockClient((_) async => _json({}));
      final container = _container(client: client, entries: const []);
      addTearDown(container.dispose);

      await container.read(upNextProvider.future);
      await Future<void>.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kUpNextCacheKey);
      expect(raw, isNot('[]'),
          reason:
              'transient empty must not nuke a non-empty cache');
      expect(raw, contains('555'));
    });

    test('cache survives a transient empty watchEntries emit on cold start',
        () async {
      // Real-world scenario the user kept hitting: Firestore offline
      // persistence emits an empty snapshot BEFORE the server data
      // arrives. The provider must not nuke its cached row during that
      // window — the next emit carries the real shows.
      final cached = [
        UpNextEpisode(
          tmdbId: 100,
          showTitle: 'Severance',
          season: 3,
          number: 4,
          airDate: DateTime(2026, 1, 1),
          daysUntilAir: 0,
        ),
      ];
      SharedPreferences.setMockInitialValues({
        kUpNextCacheKey: jsonEncode(cached.map((e) => e.toJson()).toList()),
      });

      // Stream: emit empty first (cold-start blip), then real shows.
      final controller = StreamController<List<WatchEntry>>();
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tv/100')) {
          return _json({
            'id': 100,
            'name': 'Severance',
            'next_episode_to_air': {
              'season_number': 3,
              'episode_number': 4,
              'air_date': _dateStr(2),
            },
          });
        }
        return http.Response('unexpected: ${req.url}', 404);
      });

      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
        watchEntriesProvider.overrideWith((_) => controller.stream),
      ]);
      final emitted = <List<UpNextEpisode>>[];
      container.listen<AsyncValue<List<UpNextEpisode>>>(
        upNextProvider,
        (_, next) {
          if (next.value != null) emitted.add(next.value!);
        },
        fireImmediately: true,
      );
      addTearDown(() {
        controller.close();
        container.dispose();
      });

      // First yield should be the cached row (instantly).
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Simulate Firestore's transient empty snapshot.
      controller.add(const []);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // The bug: row used to flicker to empty here. After the fix, the
      // cached row remains the visible state.
      final stateMidEmpty = container.read(upNextProvider);
      expect(stateMidEmpty.value, isNotEmpty,
          reason:
              'cached row must survive a transient empty Firestore emit');
      expect(stateMidEmpty.value!.first.tmdbId, 100);

      // Cache must NOT have been overwritten with [].
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kUpNextCacheKey), isNot('[]'),
          reason:
              'transient empty must not nuke the on-disk cache');

      // Now the real Firestore emit arrives.
      controller.add([_watchingTv(100)]);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final stateAfter = container.read(upNextProvider);
      expect(stateAfter.value, hasLength(1));
      expect(stateAfter.value!.first.tmdbId, 100);

      // No emitted state should ever have been empty (which would have
      // been the visible flicker).
      expect(emitted.where((e) => e.isEmpty), isEmpty,
          reason:
              'row should never visibly flicker through an empty state');
    });

    test('cache stays painted while watchEntries is still loading',
        () async {
      // Regression: the first run used to read `entriesAsync.value`,
      // see null while Firestore was still emitting its first snapshot,
      // and immediately clear the cache + yield empty. The fix guards
      // on `entriesAsync.value == null` so the cached yield remains
      // the visible state until authoritative data lands.
      final cached = [
        UpNextEpisode(
          tmdbId: 100,
          showTitle: 'Cached Show',
          season: 1,
          number: 1,
          airDate: DateTime(2026, 1, 1),
          daysUntilAir: 0,
        ),
      ];
      SharedPreferences.setMockInitialValues({
        kUpNextCacheKey: jsonEncode(cached.map((e) => e.toJson()).toList()),
      });

      final client = MockClient((_) async => _json({}));
      // Override watchEntriesProvider with a stream that never emits —
      // simulating Firestore still loading.
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
        watchEntriesProvider
            .overrideWith((_) => const Stream<List<WatchEntry>>.empty()),
      ]);
      container.listen<AsyncValue<List<UpNextEpisode>>>(
        upNextProvider,
        (_, _) {},
      );
      addTearDown(container.dispose);

      // Wait one microtask for the prefs read + cache yield.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final state = container.read(upNextProvider);
      expect(state.value?.first.tmdbId, 100,
          reason: 'cache should remain visible while entries is still loading');
      // Cache must NOT have been overwritten with [] during the loading
      // window — the original cache JSON should still be there.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kUpNextCacheKey), isNotNull);
      expect(prefs.getString(kUpNextCacheKey), isNot('[]'),
          reason: 'cache must not be wiped while watchEntries is loading');
    });

    test('UpNextEpisode round-trips through JSON', () {
      final ep = UpNextEpisode(
        tmdbId: 42,
        showTitle: 'Round Trip',
        showPosterPath: '/r.jpg',
        season: 2,
        number: 7,
        episodeName: 'Carousel',
        airDate: DateTime(2026, 4, 15),
        daysUntilAir: 3,
      );
      final json = ep.toJson();
      final restored = UpNextEpisode.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(json)) as Map),
      );
      expect(restored.tmdbId, ep.tmdbId);
      expect(restored.showTitle, ep.showTitle);
      expect(restored.showPosterPath, ep.showPosterPath);
      expect(restored.season, ep.season);
      expect(restored.number, ep.number);
      expect(restored.episodeName, ep.episodeName);
      expect(restored.airDate, ep.airDate);
      expect(restored.daysUntilAir, ep.daysUntilAir);
    });

    test('corrupted disk cache is silently dropped', () async {
      SharedPreferences.setMockInitialValues({
        kUpNextCacheKey: '{not json',
      });
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tv/100')) {
          return _json({
            'id': 100,
            'name': 'Fresh',
            'next_episode_to_air': {
              'season_number': 1,
              'episode_number': 1,
              'air_date': _dateStr(1),
            },
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(100)],
      );
      addTearDown(container.dispose);
      final out = await container.read(upNextProvider.future);
      // No throw, no garbage cached entry — just the fresh result.
      expect(out, hasLength(1));
      expect(out.first.tmdbId, 100);
    });
  });

  group('upNextSummaryProvider', () {
    test('reports tracked count + closest upcoming episode', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/tv/800')) {
          return _json({
            'id': 800,
            'name': 'Show A',
            'next_episode_to_air': {
              'season_number': 1,
              'episode_number': 1,
              'air_date': _dateStr(5),
            },
          });
        }
        if (req.url.path.endsWith('/tv/801')) {
          return _json({
            'id': 801,
            'name': 'Show B',
            'next_episode_to_air': {
              'season_number': 1,
              'episode_number': 1,
              'air_date': _dateStr(2),
            },
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(800), _watchingTv(801)],
      );
      addTearDown(container.dispose);
      final summary = await container.read(upNextSummaryProvider.future);
      expect(summary.trackedShowCount, 2);
      expect(summary.next?.tmdbId, 801,
          reason: 'closest air date should be the surfaced "next"');
    });

    test('reports tracked count even when nothing is scheduled', () async {
      final client = MockClient((req) async {
        return _json({
          'id': 900,
          'name': 'Cancelled',
          'next_episode_to_air': null,
        });
      });
      final container = _container(
        client: client,
        entries: [_watchingTv(900)],
      );
      addTearDown(container.dispose);
      final summary = await container.read(upNextSummaryProvider.future);
      expect(summary.trackedShowCount, 1);
      expect(summary.next, isNull);
    });
  });
}
