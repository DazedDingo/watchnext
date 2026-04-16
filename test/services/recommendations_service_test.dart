import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/services/recommendations_service.dart';

WatchlistItem _w({
  required String mediaType,
  required int id,
  required String title,
  List<String> genres = const [],
  int? runtime,
}) {
  return WatchlistItem(
    id: '$mediaType:$id',
    mediaType: mediaType,
    tmdbId: id,
    title: title,
    genres: genres,
    runtime: runtime,
    addedBy: 'u1',
    addedAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('buildCandidates — watchlist', () {
    test('includes all watchlist items with source=watchlist', () {
      final out = buildCandidates(watchlist: [
        _w(mediaType: 'movie', id: 1, title: 'A', genres: const ['Drama']),
        _w(mediaType: 'tv', id: 2, title: 'B'),
      ]);
      expect(out, hasLength(2));
      expect(out.every((c) => c['source'] == 'watchlist'), isTrue);
      expect(out[0]['title'], 'A');
      expect(out[0]['genres'], ['Drama']);
    });

    test('dedups repeated watchlist entries by mediaType:tmdbId', () {
      final out = buildCandidates(watchlist: [
        _w(mediaType: 'movie', id: 1, title: 'A'),
        _w(mediaType: 'movie', id: 1, title: 'A duplicate'),
      ]);
      expect(out, hasLength(1));
      expect(out.first['title'], 'A');
    });
  });

  group('buildCandidates — reddit mentions', () {
    test('resolves genre_ids → names when scraper stored ids', () {
      final out = buildCandidates(watchlist: const [], redditMentions: [
        {
          'media_type': 'movie',
          'tmdb_id': 42,
          'title': 'Docu',
          'genre_ids': [99, 18], // Documentary, Drama
        },
      ]);
      expect(out.first['genres'], ['Documentary', 'Drama']);
      expect(out.first['source'], 'reddit');
    });

    test('prefers pre-resolved genres field over genre_ids', () {
      // Newer scraper writes resolved names under `genres`; fall back to
      // `genre_ids` only if `genres` is absent. Ensures we don't double-dip.
      final out = buildCandidates(watchlist: const [], redditMentions: [
        {
          'media_type': 'movie',
          'tmdb_id': 42,
          'title': 'Docu',
          'genres': ['Documentary'],
          'genre_ids': [28], // should be ignored because `genres` is set
        },
      ]);
      expect(out.first['genres'], ['Documentary']);
    });

    test('missing tmdb_id is dropped silently (defensive)', () {
      final out = buildCandidates(watchlist: const [], redditMentions: [
        {'media_type': 'movie', 'title': 'No id'},
        {'media_type': 'movie', 'tmdb_id': 1, 'title': 'Keep'},
      ]);
      expect(out, hasLength(1));
      expect(out.first['title'], 'Keep');
    });

    test('defaults media_type to movie when absent', () {
      final out = buildCandidates(watchlist: const [], redditMentions: [
        {'tmdb_id': 5, 'title': 'X', 'genre_ids': const [28]},
      ]);
      expect(out.first['media_type'], 'movie');
      expect(out.first['genres'], ['Action']);
    });

    test('empty genre_ids yields empty genres (no crash)', () {
      final out = buildCandidates(watchlist: const [], redditMentions: [
        {'media_type': 'movie', 'tmdb_id': 1, 'title': 'X'},
      ]);
      expect(out.first['genres'], isEmpty);
    });

    test('tv-domain mentions use the tv genre table', () {
      final out = buildCandidates(watchlist: const [], redditMentions: [
        {
          'media_type': 'tv',
          'tmdb_id': 1,
          'title': 'Show',
          'genre_ids': [10759, 99], // Action & Adventure, Documentary
        },
      ]);
      expect(out.first['genres'], ['Action & Adventure', 'Documentary']);
    });
  });

  group('buildCandidates — trending', () {
    test('resolves genre_ids from TMDB trending payload', () {
      final out = buildCandidates(watchlist: const [], trendingPayload: const {
        'results': [
          {
            'id': 7,
            'media_type': 'movie',
            'title': 'T',
            'genre_ids': [35, 18], // Comedy, Drama
            'release_date': '2025-05-10',
          },
        ],
      });
      expect(out, hasLength(1));
      expect(out.first['source'], 'trending');
      expect(out.first['genres'], ['Comedy', 'Drama']);
      expect(out.first['year'], 2025);
    });

    test('honors trendingCap to bound candidate pool', () {
      final results = List.generate(50, (i) => {
            'id': i + 1000,
            'media_type': 'movie',
            'title': 'T$i',
            'genre_ids': const [18],
          });
      final out = buildCandidates(
        watchlist: const [],
        trendingPayload: {'results': results},
        trendingCap: 5,
      );
      expect(out, hasLength(5));
    });

    test('tv trending uses first_air_date for year', () {
      final out = buildCandidates(watchlist: const [], trendingPayload: const {
        'results': [
          {
            'id': 9,
            'media_type': 'tv',
            'name': 'Show',
            'genre_ids': [10759],
            'first_air_date': '2024-09-01',
          },
        ],
      });
      expect(out.first['title'], 'Show');
      expect(out.first['year'], 2024);
      expect(out.first['genres'], ['Action & Adventure']);
    });

    test('empty trending payload is tolerated', () {
      final out = buildCandidates(
        watchlist: const [],
        trendingPayload: const {},
      );
      expect(out, isEmpty);
    });

    test('missing results key is tolerated', () {
      final out = buildCandidates(
        watchlist: const [],
        trendingPayload: const {'status': 'ok'},
      );
      expect(out, isEmpty);
    });

    test('malformed trending row (no id) is skipped', () {
      final out = buildCandidates(watchlist: const [], trendingPayload: const {
        'results': [
          {'title': 'no id'},
          {'id': 7, 'title': 'kept', 'genre_ids': [18]},
        ],
      });
      expect(out, hasLength(1));
      expect(out.first['title'], 'kept');
    });
  });

  group('buildCandidates — cross-source dedup + ordering', () {
    test('watchlist trumps reddit trumps trending for the same id', () {
      final out = buildCandidates(
        watchlist: [
          _w(
              mediaType: 'movie',
              id: 1,
              title: 'from watchlist',
              genres: const ['Drama']),
        ],
        redditMentions: [
          {
            'media_type': 'movie',
            'tmdb_id': 1,
            'title': 'from reddit',
            'genre_ids': [28],
          },
        ],
        trendingPayload: const {
          'results': [
            {
              'id': 1,
              'media_type': 'movie',
              'title': 'from trending',
              'genre_ids': [99],
            },
          ],
        },
      );
      expect(out, hasLength(1));
      expect(out.first['source'], 'watchlist');
      expect(out.first['title'], 'from watchlist');
    });

    test('order: watchlist, then reddit, then trending', () {
      final out = buildCandidates(
        watchlist: [_w(mediaType: 'movie', id: 1, title: 'W')],
        redditMentions: [
          {'media_type': 'movie', 'tmdb_id': 2, 'title': 'R'},
        ],
        trendingPayload: const {
          'results': [
            {'id': 3, 'media_type': 'movie', 'title': 'T', 'genre_ids': []},
          ],
        },
      );
      expect(out.map((c) => c['source']).toList(),
          ['watchlist', 'reddit', 'trending']);
    });

    test('all-empty input yields empty candidate list', () {
      expect(buildCandidates(watchlist: const []), isEmpty);
    });

    test('a mood matching Documentary would now have candidates to filter on',
        () {
      // Regression guard for the root cause of the "empty mood pill" bug.
      // Trending rows previously had no genres → mood filter killed them.
      final out = buildCandidates(watchlist: const [], trendingPayload: const {
        'results': [
          {
            'id': 100,
            'media_type': 'movie',
            'title': 'Planet Earth III',
            'genre_ids': [99], // Documentary
          },
          {
            'id': 101,
            'media_type': 'movie',
            'title': 'Action Flick',
            'genre_ids': [28], // Action
          },
        ],
      });
      final docs = out
          .where((c) =>
              (c['genres'] as List).contains('Documentary'))
          .toList();
      expect(docs, hasLength(1));
      expect(docs.first['title'], 'Planet Earth III');
    });
  });

  group('buildCandidates — realistic payload regression', () {
    test('every candidate carries a non-null List<String> genres field', () {
      // Ensures downstream filter `.any(moodGenres.contains)` never crashes
      // and never silently nukes a candidate because we forgot to populate
      // genres on one source.
      final out = buildCandidates(
        watchlist: [
          _w(mediaType: 'movie', id: 1, title: 'W', genres: const ['Drama']),
        ],
        redditMentions: [
          {
            'media_type': 'movie',
            'tmdb_id': 2,
            'title': 'R',
            'genre_ids': [99],
          },
        ],
        trendingPayload: const {
          'results': [
            {
              'id': 3,
              'media_type': 'movie',
              'title': 'T',
              'genre_ids': [18],
            },
          ],
        },
      );
      for (final c in out) {
        expect(c['genres'], isA<List>(),
            reason: 'genres must always be a list for source ${c['source']}');
        expect(c['genres'], isNotNull);
      }
    });

    test('realistic TMDB trending payload resolves every known genre id', () {
      // Snapshot-ish payload derived from TMDB /trending/all/week response
      // shape. Tests that the builder doesn't choke on extra fields.
      final out = buildCandidates(watchlist: const [], trendingPayload: const {
        'page': 1,
        'results': [
          {
            'id': 693134,
            'media_type': 'movie',
            'title': 'Dune: Part Two',
            'overview': 'Paul Atreides unites with Chani...',
            'poster_path': '/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg',
            'genre_ids': [878, 12],
            'release_date': '2024-02-27',
            'popularity': 1234.5,
            'vote_average': 8.2,
          },
          {
            'id': 85271,
            'media_type': 'tv',
            'name': 'WandaVision',
            'overview': 'Wanda Maximoff and Vision live idealized...',
            'poster_path': '/gl9Y9ZKJIZQPBaU6mBLNnQZUkoF.jpg',
            'genre_ids': [10765, 18],
            'first_air_date': '2021-01-15',
            'popularity': 567.8,
          },
        ],
        'total_pages': 1000,
        'total_results': 20000,
      });
      expect(out, hasLength(2));
      expect(out[0]['genres'], ['Science Fiction', 'Adventure']);
      expect(out[0]['year'], 2024);
      expect(out[1]['genres'], ['Sci-Fi & Fantasy', 'Drama']);
      expect(out[1]['year'], 2021);
      expect(out[1]['title'], 'WandaVision');
    });

    test('reddit mention stored as string ids (defensive coerce)', () {
      // Firestore sometimes round-trips numeric arrays as List<num>; this
      // mirrors that to make sure buildCandidates → coerceGenres survives.
      final out = buildCandidates(watchlist: const [], redditMentions: [
        {
          'media_type': 'movie',
          'tmdb_id': 77,
          'title': 'Some Doc',
          'genre_ids': <num>[99, 18],
          'mention_score': 42,
        },
      ]);
      expect(out.first['genres'], ['Documentary', 'Drama']);
    });

    test('mood filter simulation — Documentary now hits reddit+trending+watchlist',
        () {
      // End-to-end: the actual predicate the UI runs to populate a mood pill
      // is `r.genres.any(moodGenres.contains)`. Simulate it over a mixed pool.
      final candidates = buildCandidates(
        watchlist: [
          _w(
              mediaType: 'movie',
              id: 10,
              title: 'Man on Wire',
              genres: const ['Documentary']),
        ],
        redditMentions: [
          {
            'media_type': 'tv',
            'tmdb_id': 20,
            'title': 'Planet Earth',
            'genre_ids': [99],
          },
          {
            'media_type': 'movie',
            'tmdb_id': 21,
            'title': 'Fast Car',
            'genre_ids': [28],
          },
        ],
        trendingPayload: const {
          'results': [
            {
              'id': 30,
              'media_type': 'movie',
              'title': 'Free Solo',
              'genre_ids': [99, 12],
            },
            {
              'id': 31,
              'media_type': 'movie',
              'title': 'Romcom',
              'genre_ids': [35, 10749],
            },
          ],
        },
      );
      const moodGenres = ['Documentary'];
      final matched = candidates
          .where((c) =>
              (c['genres'] as List).any((g) => moodGenres.contains(g)))
          .map((c) => c['title'])
          .toList();
      expect(matched, ['Man on Wire', 'Planet Earth', 'Free Solo']);
    });

    test('trendingCap=0 yields zero trending candidates even if results present',
        () {
      final out = buildCandidates(
        watchlist: const [],
        trendingPayload: const {
          'results': [
            {'id': 1, 'media_type': 'movie', 'title': 'X', 'genre_ids': [18]},
          ],
        },
        trendingCap: 0,
      );
      expect(out, isEmpty);
    });
  });

  group('buildCandidates — runtime passthrough', () {
    test('watchlist candidates carry runtime from the WatchlistItem', () {
      final out = buildCandidates(watchlist: [
        _w(mediaType: 'movie', id: 1, title: 'Short', runtime: 85),
        _w(mediaType: 'movie', id: 2, title: 'Long', runtime: 175),
        _w(mediaType: 'movie', id: 3, title: 'Unknown'),
      ]);
      expect(out[0]['runtime'], 85);
      expect(out[1]['runtime'], 175);
      expect(out[2]['runtime'], isNull);
    });

    test('reddit candidates pass runtime through when present', () {
      final out = buildCandidates(watchlist: const [], redditMentions: [
        {
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Doc',
          'runtime': 95,
        },
        {
          'media_type': 'movie',
          'tmdb_id': 2,
          'title': 'No-rt doc',
        },
      ]);
      expect(out[0]['runtime'], 95);
      expect(out[1]['runtime'], isNull);
    });

    test('trending candidates leave runtime null (TMDB trending has no rt)',
        () {
      final out = buildCandidates(
        watchlist: const [],
        trendingPayload: const {
          'results': [
            {
              'id': 1,
              'media_type': 'movie',
              'title': 'T',
              'genre_ids': [18],
            },
          ],
        },
      );
      expect(out.single.containsKey('runtime'), isFalse,
          reason: 'trending rows should not inject a phantom runtime key');
    });
  });
}
