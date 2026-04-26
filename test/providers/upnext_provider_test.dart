import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  // Both providers are autoDispose — without an active listener they get
  // disposed mid-load and the future read throws "disposed during
  // loading state". A no-op listen on each keeps them alive for the test.
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
