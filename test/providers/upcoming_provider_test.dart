import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/providers/auth_provider.dart';
import 'package:watchnext/providers/media_type_filter_provider.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/providers/stats_provider.dart';
import 'package:watchnext/providers/tmdb_provider.dart';
import 'package:watchnext/providers/upcoming_provider.dart';
import 'package:watchnext/providers/watch_entries_provider.dart';
import 'package:watchnext/services/tmdb_service.dart';

class _FixedModeController extends StateNotifier<ViewMode>
    implements ModeController {
  _FixedModeController(super.state);

  @override
  Future<void> set(ViewMode mode) async {
    state = mode;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

ProviderContainer _container({
  required http.Client client,
  required MediaTypeFilter? mediaType,
  Set<String> watchedKeys = const <String>{},
  Map<String, dynamic>? tasteProfile,
}) {
  final container = ProviderContainer(overrides: [
    tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
    viewModeProvider
        .overrideWith((_) => _FixedModeController(ViewMode.together)),
    mediaTypeFilterProvider.overrideWithValue(mediaType),
    watchedKeysProvider.overrideWithValue(watchedKeys),
    tasteProfileProvider.overrideWith((_) => Stream.value(tasteProfile)),
    currentUidProvider.overrideWithValue(null),
  ]);
  // upcomingForYouProvider is autoDispose. Without an active listener the
  // provider gets disposed mid-load and the future read throws "disposed
  // during loading state". A no-op `container.listen` keeps it alive for
  // the duration of the test.
  container.listen<AsyncValue<List<UpcomingTitle>>>(
    upcomingForYouProvider,
    (_, _) {},
  );
  return container;
}

http.Response _json(Object payload) => http.Response(
      json.encode(payload),
      200,
      headers: const {'content-type': 'application/json'},
    );

String _futureDateStr(int daysFromToday) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = today.add(Duration(days: daysFromToday));
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

void main() {
  group('upcomingForYouProvider — All (filter null)', () {
    test('fans out to /discover/movie + /discover/tv and merges results',
        () async {
      final calls = <Uri>[];
      final client = MockClient((req) async {
        calls.add(req.url);
        if (req.url.path.endsWith('/discover/movie')) {
          return _json({
            'results': [
              {
                'id': 1,
                'title': 'Future Movie',
                'release_date': _futureDateStr(7),
                'genre_ids': const <int>[],
                'poster_path': '/m.jpg',
              },
            ],
          });
        }
        if (req.url.path.endsWith('/discover/tv')) {
          return _json({
            'results': [
              {
                'id': 2,
                'name': 'New Show',
                'first_air_date': _futureDateStr(14),
                'genre_ids': const <int>[],
                'poster_path': '/t.jpg',
              },
            ],
          });
        }
        return http.Response('not mocked: ${req.url}', 404);
      });

      final container = _container(client: client, mediaType: null);
      addTearDown(container.dispose);

      final out = await container.read(upcomingForYouProvider.future);
      expect(out.map((e) => e.key).toSet(), {'movie:1', 'tv:2'});
      final paths = calls.map((u) => u.path).toList();
      expect(paths.any((p) => p.endsWith('/discover/movie')), isTrue);
      expect(paths.any((p) => p.endsWith('/discover/tv')), isTrue);
      // Legacy curated endpoints must not be used post-broadening.
      expect(paths.any((p) => p.endsWith('/movie/upcoming')), isFalse);
      expect(paths.any((p) => p.endsWith('/tv/on_the_air')), isFalse);
    });
  });

  group('upcomingForYouProvider — Movies branch', () {
    test('hits /discover/movie with a (today-7d)→(today+90d) release window',
        () async {
      // The lookback grace lets just-released titles linger for a week
      // — they read as "new" to anyone not tracking the calendar and
      // dropping them the day after release felt abrupt.
      Uri? captured;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/discover/movie')) {
          captured = req.url;
          return _json({'results': const []});
        }
        return http.Response('unexpected: ${req.url}', 404);
      });
      final container = _container(
        client: client,
        mediaType: MediaTypeFilter.movie,
      );
      addTearDown(container.dispose);
      await container.read(upcomingForYouProvider.future);
      expect(captured, isNotNull);
      final q = captured!.queryParameters;
      expect(q['primary_release_date.gte'], _futureDateStr(-kUpcomingLookbackDays));
      expect(q['primary_release_date.lte'], _futureDateStr(kUpcomingWindowDays));
      expect(q['sort_by'], 'popularity.desc');
    });

    test('does not call /discover/tv on the Movies branch', () async {
      final calls = <Uri>[];
      final client = MockClient((req) async {
        calls.add(req.url);
        return _json({'results': const []});
      });
      final container = _container(
        client: client,
        mediaType: MediaTypeFilter.movie,
      );
      addTearDown(container.dispose);
      await container.read(upcomingForYouProvider.future);
      final paths = calls.map((u) => u.path).toList();
      expect(paths.any((p) => p.endsWith('/discover/tv')), isFalse);
      expect(paths.any((p) => p.endsWith('/discover/movie')), isTrue);
    });

    test('drops ancient re-releases but keeps titles within the lookback window',
        () async {
      // Defensive — TMDB's server-side date filter is normally tight,
      // but community-edited primary dates and theatrical re-releases
      // have leaked past it before. Client-side floor matches the
      // lookback constant so just-released titles (today-3d) survive
      // while genuine ancient fakes (1986) are dropped.
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/discover/movie')) {
          return _json({
            'results': [
              {
                'id': 1,
                'title': 'Re-release',
                'release_date': '1986-05-23',
                'genre_ids': const <int>[],
              },
              {
                'id': 2,
                'title': 'Just released',
                'release_date': _futureDateStr(-3),
                'genre_ids': const <int>[],
              },
              {
                'id': 3,
                'title': 'Genuinely upcoming',
                'release_date': _futureDateStr(10),
                'genre_ids': const <int>[],
              },
            ],
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        mediaType: MediaTypeFilter.movie,
      );
      addTearDown(container.dispose);
      final out = await container.read(upcomingForYouProvider.future);
      expect(out.map((e) => e.tmdbId).toSet(), {2, 3});
    });
  });

  group('upcomingForYouProvider — TV branch', () {
    test('hits /discover/tv with a (today-7d)→(today+90d) air_date window',
        () async {
      Uri? captured;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/discover/tv')) {
          captured = req.url;
          return _json({'results': const []});
        }
        return http.Response('unexpected: ${req.url}', 404);
      });
      final container = _container(
        client: client,
        mediaType: MediaTypeFilter.tv,
      );
      addTearDown(container.dispose);
      await container.read(upcomingForYouProvider.future);
      expect(captured, isNotNull);
      final q = captured!.queryParameters;
      expect(q['air_date.gte'], _futureDateStr(-kUpcomingLookbackDays));
      expect(q['air_date.lte'], _futureDateStr(kUpcomingWindowDays));
      expect(q['sort_by'], 'popularity.desc');
    });

    test('returns BOTH new series and returning shows in the window',
        () async {
      // /discover/tv?air_date.gte=…&air_date.lte=… returns both series
      // premiering in the window AND returning shows with a new episode
      // airing in the window. Both are valid "upcoming for you" rows.
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/discover/tv')) {
          return _json({
            'results': [
              {
                'id': 100,
                'name': 'Brand New Series',
                'first_air_date': _futureDateStr(20),
                'genre_ids': const <int>[],
              },
              {
                'id': 200,
                'name': 'Returning Show',
                'first_air_date': '2018-09-01',
                'genre_ids': const <int>[],
              },
            ],
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        mediaType: MediaTypeFilter.tv,
      );
      addTearDown(container.dispose);
      final out = await container.read(upcomingForYouProvider.future);
      expect(out.map((e) => e.tmdbId).toSet(), {100, 200});
    });

    test('does NOT filter against watched keys on the TV branch', () async {
      // The whole point of surfacing returning shows is that the
      // household may already follow them — a new season is the reason
      // to spotlight the title. Matching against watched-keys would
      // defeat the purpose.
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/discover/tv')) {
          return _json({
            'results': [
              {
                'id': 42,
                'name': 'Already Watching',
                'first_air_date': '2020-01-01',
                'genre_ids': const <int>[],
              },
            ],
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        mediaType: MediaTypeFilter.tv,
        watchedKeys: const {'tv:42'},
      );
      addTearDown(container.dispose);
      final out = await container.read(upcomingForYouProvider.future);
      expect(out.map((e) => e.tmdbId).toList(), [42]);
    });

    test('does not call /discover/movie on the TV branch', () async {
      final calls = <Uri>[];
      final client = MockClient((req) async {
        calls.add(req.url);
        return _json({'results': const []});
      });
      final container = _container(
        client: client,
        mediaType: MediaTypeFilter.tv,
      );
      addTearDown(container.dispose);
      await container.read(upcomingForYouProvider.future);
      final paths = calls.map((u) => u.path).toList();
      expect(paths.any((p) => p.endsWith('/discover/movie')), isFalse);
      expect(paths.any((p) => p.endsWith('/discover/tv')), isTrue);
    });
  });

  group('upcomingForYouProvider — taste-overlap re-rank', () {
    test('orders TV results by genre-overlap against the taste profile',
        () async {
      // Taste profile favours Drama heavily. The Drama-tagged candidate
      // ranks above the Comedy-only candidate even though TMDB returned
      // them in the opposite order.
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/discover/tv')) {
          return _json({
            'results': [
              {
                'id': 1,
                'name': 'Comedy Show',
                'first_air_date': _futureDateStr(5),
                'genre_ids': const [35], // Comedy
              },
              {
                'id': 2,
                'name': 'Drama Show',
                'first_air_date': _futureDateStr(5),
                'genre_ids': const [18], // Drama
              },
            ],
          });
        }
        return http.Response('unexpected', 404);
      });
      final container = _container(
        client: client,
        mediaType: MediaTypeFilter.tv,
        tasteProfile: const {
          'combined': {
            'top_genres': [
              {'genre': 'Drama', 'weight': 0.9},
            ],
          },
        },
      );
      addTearDown(container.dispose);
      final out = await container.read(upcomingForYouProvider.future);
      expect(out.map((e) => e.tmdbId).toList(), [2, 1]);
    });
  });
}
