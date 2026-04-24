import 'dart:async';
import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/providers/curated_source_provider.dart';
import 'package:watchnext/providers/runtime_filter_provider.dart';
import 'package:watchnext/providers/sort_mode_provider.dart';
import 'package:watchnext/providers/year_filter_provider.dart';
import 'package:watchnext/services/recommendations_service.dart';
import 'package:watchnext/services/tmdb_service.dart';
import 'package:watchnext/utils/oscar_winners.dart';

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
      final out = buildCandidates(watchlist: const [], trendingMoviesPayload: const {
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
        trendingMoviesPayload: {'results': results},
        tmdbCap: 5,
      );
      expect(out, hasLength(5));
    });

    test('tv trending uses first_air_date for year', () {
      final out = buildCandidates(watchlist: const [], trendingMoviesPayload: const {
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
        trendingMoviesPayload: const {},
      );
      expect(out, isEmpty);
    });

    test('missing results key is tolerated', () {
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: const {'status': 'ok'},
      );
      expect(out, isEmpty);
    });

    test('malformed trending row (no id) is skipped', () {
      final out = buildCandidates(watchlist: const [], trendingMoviesPayload: const {
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
        trendingMoviesPayload: const {
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
        trendingMoviesPayload: const {
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
      final out = buildCandidates(watchlist: const [], trendingMoviesPayload: const {
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
        trendingMoviesPayload: const {
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
      final out = buildCandidates(watchlist: const [], trendingMoviesPayload: const {
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
      // End-to-end: the home filter uses `selected.every(r.genres.contains)`
      // (intersection). With a single-entry filter like 'Documentary' the
      // every/any outcomes coincide; this test locks the pipeline shape.
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
        trendingMoviesPayload: const {
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
        trendingMoviesPayload: const {
          'results': [
            {'id': 1, 'media_type': 'movie', 'title': 'X', 'genre_ids': [18]},
          ],
        },
        tmdbCap: 0,
      );
      expect(out, isEmpty);
    });
  });

  group('buildCandidates — expanded TMDB sources', () {
    test('trending TV payload produces tv-domain candidates', () {
      final out = buildCandidates(
        watchlist: const [],
        trendingTvPayload: const {
          'results': [
            {
              'id': 1,
              'name': 'Severance',
              'genre_ids': [9648, 18], // Mystery, Drama
              'first_air_date': '2022-02-18',
            },
          ],
        },
      );
      expect(out, hasLength(1));
      expect(out.first['media_type'], 'tv');
      expect(out.first['source'], 'trending');
      expect(out.first['genres'], ['Mystery', 'Drama']);
      expect(out.first['year'], 2022);
    });

    test('top-rated movies get source=top_rated and use the movie genre map',
        () {
      final out = buildCandidates(
        watchlist: const [],
        topRatedMoviesPayload: const {
          'results': [
            {
              'id': 2,
              'title': 'The Godfather',
              'genre_ids': [80, 18], // Crime, Drama
              'release_date': '1972-03-24',
            },
          ],
        },
      );
      expect(out.first['source'], 'top_rated');
      expect(out.first['media_type'], 'movie');
      expect(out.first['genres'], ['Crime', 'Drama']);
      expect(out.first['year'], 1972);
    });

    test('top-rated TV gets source=top_rated with tv genre map', () {
      final out = buildCandidates(
        watchlist: const [],
        topRatedTvPayload: const {
          'results': [
            {
              'id': 3,
              'name': 'Breaking Bad',
              'genre_ids': [18, 80], // Drama, Crime
              'first_air_date': '2008-01-20',
            },
          ],
        },
      );
      expect(out.first['source'], 'top_rated');
      expect(out.first['media_type'], 'tv');
      expect(out.first['genres'], ['Drama', 'Crime']);
    });

    test('all four TMDB sources contribute in declared order', () {
      // trending movies → trending TV → top-rated movies → top-rated TV
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: const {
          'results': [
            {'id': 1, 'title': 'TM', 'genre_ids': [18]},
          ],
        },
        trendingTvPayload: const {
          'results': [
            {'id': 2, 'name': 'TT', 'genre_ids': [18]},
          ],
        },
        topRatedMoviesPayload: const {
          'results': [
            {'id': 3, 'title': 'RM', 'genre_ids': [18]},
          ],
        },
        topRatedTvPayload: const {
          'results': [
            {'id': 4, 'name': 'RT', 'genre_ids': [18]},
          ],
        },
      );
      expect(out.map((c) => c['title']).toList(), ['TM', 'TT', 'RM', 'RT']);
      expect(out.map((c) => c['source']).toList(),
          ['trending', 'trending', 'top_rated', 'top_rated']);
    });

    test('dedup across TMDB sources — same id only ingested once', () {
      // Trending TV and top-rated TV often share popular shows; we should
      // keep the first (trending) and drop the later top-rated dupe.
      final out = buildCandidates(
        watchlist: const [],
        trendingTvPayload: const {
          'results': [
            {'id': 99, 'name': 'Shared Show', 'genre_ids': [18]},
          ],
        },
        topRatedTvPayload: const {
          'results': [
            {'id': 99, 'name': 'Shared Show', 'genre_ids': [18]},
          ],
        },
      );
      expect(out, hasLength(1));
      expect(out.first['source'], 'trending');
    });

    test('tmdbCap applies per source, not globally', () {
      // 5-cap × 4 sources should yield up to 20 distinct candidates.
      Map<String, dynamic> payload(int base) => {
            'results': List.generate(10, (i) => {
                  'id': base + i,
                  'title': 'X${base + i}',
                  'genre_ids': const [18],
                }),
          };
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: payload(1000),
        trendingTvPayload: payload(2000),
        topRatedMoviesPayload: payload(3000),
        topRatedTvPayload: payload(4000),
        tmdbCap: 5,
      );
      expect(out, hasLength(20));
    });

    test('mixed pool: mood filter finds hits across all four TMDB sources',
        () {
      // Exercises the full user story — a "Mind-Bending" pill should surface
      // Sci-Fi picks whether they came from trending or top-rated.
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: const {
          'results': [
            {'id': 1, 'title': 'Inception', 'genre_ids': [878]},
          ],
        },
        trendingTvPayload: const {
          'results': [
            {'id': 2, 'name': 'Devs', 'genre_ids': [10765]},
          ],
        },
        topRatedMoviesPayload: const {
          'results': [
            {'id': 3, 'title': '2001', 'genre_ids': [878]},
          ],
        },
        topRatedTvPayload: const {
          'results': [
            {'id': 4, 'name': 'Fringe', 'genre_ids': [10765]},
          ],
        },
      );
      const moodGenres = ['Science Fiction', 'Sci-Fi & Fantasy', 'Mystery'];
      final matched = out
          .where((c) =>
              (c['genres'] as List).any((g) => moodGenres.contains(g)))
          .map((c) => c['title'])
          .toList();
      expect(matched, containsAll(['Inception', 'Devs', '2001', 'Fringe']));
    });
  });

  // ─── Discover payload wiring ──────────────────────────────────────────────
  //
  // When the user narrows with genre filters or a year range, the service
  // fires `discoverPaged()` and passes the result into `buildCandidates` via
  // `discoverMoviesPayload` / `discoverTvPayload`. These tests pin down:
  //  - discover rows land with source=discover
  //  - they get the larger discoverCap (40 default) not the tmdbCap
  //  - they dedup across the baseline pool so a trending+discover overlap
  //    doesn't double-book the same title
  group('buildCandidates — discover payloads', () {
    test('discover movie payload produces source=discover candidates', () {
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: const {
          'results': [
            {
              'id': 1,
              'title': 'Apocalypse Now',
              'genre_ids': [10752, 18], // War, Drama
              'release_date': '1979-08-15',
            },
          ],
        },
      );
      expect(out, hasLength(1));
      expect(out.first['source'], 'discover');
      expect(out.first['media_type'], 'movie');
      expect(out.first['genres'], ['War', 'Drama']);
      expect(out.first['year'], 1979);
    });

    test('discover tv payload uses the tv genre map', () {
      final out = buildCandidates(
        watchlist: const [],
        discoverTvPayload: const {
          'results': [
            {
              'id': 2,
              'name': 'Band of Brothers',
              'genre_ids': [10768, 18], // War & Politics, Drama
              'first_air_date': '2001-09-09',
            },
          ],
        },
      );
      expect(out.first['source'], 'discover');
      expect(out.first['media_type'], 'tv');
      expect(out.first['genres'], ['War & Politics', 'Drama']);
      expect(out.first['year'], 2001);
    });

    test('discover gets a larger cap than the baseline tmdbCap', () {
      // tmdbCap=5 caps each baseline TMDB source, but discoverCap=40 applies
      // to discover specifically — the whole point of discover is to fill
      // the pool when the user narrowed the query.
      final discover = {
        'results':
            List.generate(50, (i) => {'id': 1000 + i, 'title': 'D$i'}),
      };
      final trending = {
        'results':
            List.generate(50, (i) => {'id': 2000 + i, 'title': 'T$i'}),
      };
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: trending,
        discoverMoviesPayload: discover,
        tmdbCap: 5,
        discoverCap: 40,
      );
      final discoverCount =
          out.where((c) => c['source'] == 'discover').length;
      final trendingCount =
          out.where((c) => c['source'] == 'trending').length;
      expect(discoverCount, 40);
      expect(trendingCount, 5);
    });

    test('discover wins dedup against baseline trending', () {
      // Discover is intentionally placed AHEAD of trending in the merge order
      // so a user-narrowed query (and any oscar tag stamped on the discover
      // row) survives dedup. If trending won, an Oscar Best Picture that
      // happens to be trending this week would lose its `is_oscar_winner`
      // tag and disappear under the Oscar filter.
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: const {
          'results': [
            {'id': 42, 'title': 'Shared', 'genre_ids': [18]},
          ],
        },
        discoverMoviesPayload: const {
          'results': [
            {'id': 42, 'title': 'Shared (from discover)', 'genre_ids': [18]},
          ],
        },
      );
      expect(out, hasLength(1));
      expect(out.first['source'], 'discover');
    });

    test('discover dedups within itself — movie + tv using same id', () {
      // Different media_types namespace the key so the same numeric id on
      // movie vs tv should both show up.
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: const {
          'results': [
            {'id': 10, 'title': 'Movie', 'genre_ids': [10752]},
          ],
        },
        discoverTvPayload: const {
          'results': [
            {'id': 10, 'name': 'Show', 'genre_ids': [10768]},
          ],
        },
      );
      expect(out, hasLength(2));
      expect(out.map((c) => c['media_type']).toList(), ['movie', 'tv']);
    });

    test('order: discover leads, then trending, then top_rated', () {
      // Discover is at the head of the TMDB merge so user-narrowed rows
      // (and oscar tags) win dedup. Baseline sources fill in afterwards.
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: const {
          'results': [
            {'id': 1, 'title': 'TM'},
          ],
        },
        topRatedMoviesPayload: const {
          'results': [
            {'id': 2, 'title': 'RM'},
          ],
        },
        discoverMoviesPayload: const {
          'results': [
            {'id': 3, 'title': 'DM'},
          ],
        },
      );
      expect(out.map((c) => c['source']).toList(),
          ['discover', 'trending', 'top_rated']);
    });

    test('empty discover payloads are tolerated', () {
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: const {},
        discoverTvPayload: const {'status': 'no results'},
      );
      expect(out, isEmpty);
    });

    test('war-in-70s-80s regression: a narrow filter pool is still built',
        () {
      // Simulates the scenario the user flagged: "war movies, 70s-80s".
      // The baseline pool is empty (no war films in trending this week) but
      // discoverPaged returned 20 matches — they should all land as candidates
      // so the scorer has real data to rank.
      final discover = {
        'results': List.generate(
            20,
            (i) => {
                  'id': 3000 + i,
                  'title': 'War flick ${1970 + (i % 20)}',
                  'genre_ids': const [10752, 18],
                  'release_date': '${1970 + (i % 20)}-01-01',
                }),
      };
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: discover,
      );
      expect(out, hasLength(20));
      expect(
          out.every((c) =>
              (c['genres'] as List).contains('War') &&
              (c['year'] as int) >= 1970 &&
              (c['year'] as int) <= 1989),
          isTrue);
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
        trendingMoviesPayload: const {
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

    test('discover rows pass through a stamped runtime', () {
      // The service stamps `runtime` on discover payloads when a bucket is
      // active (TMDB /discover filters server-side via with_runtime but
      // doesn't echo the field). buildCandidates must propagate that stamp so
      // the home-screen strict filter can match.
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: const {
          'results': [
            {
              'id': 1,
              'title': 'Short flick',
              'genre_ids': [18],
              'runtime': 45, // stamp from service
            },
          ],
        },
      );
      expect(out.single['runtime'], 45);
    });
  });

  // ─── writeCandidateDocs ────────────────────────────────────────────────
  //
  // The two-phase refresh relies on this method to drop the pool into
  // Firestore *before* Claude scoring runs so the Home stream can light up
  // within ~5s. Key invariants: new rec keys get seeded defaults, existing
  // rec keys keep their Claude-set match_score/ai_blurb on merge, and the
  // whole thing chunks cleanly past Firestore's 500-op batch cap.
  group('writeCandidateDocs', () {
    late FakeFirebaseFirestore db;
    late RecommendationsService svc;
    const hh = 'hh1';

    String path(String key) => 'households/$hh/recommendations/$key';

    Map<String, dynamic> candidate(
      String mediaType,
      int tmdbId, {
      String title = 'T',
      List<String> genres = const ['Drama'],
      int? runtime,
      String source = 'trending',
    }) {
      return {
        'media_type': mediaType,
        'tmdb_id': tmdbId,
        'title': title,
        'year': 2024,
        'poster_path': '/p.jpg',
        'genres': genres,
        'runtime': runtime,
        'overview': 'ov',
        'source': source,
      };
    }

    setUp(() {
      db = FakeFirebaseFirestore();
      svc = RecommendationsService(db: db);
    });

    test('empty candidate list is a no-op', () async {
      await svc.writeCandidateDocs(hh, const []);
      final snap = await db.collection('households/$hh/recommendations').get();
      expect(snap.size, 0);
    });

    test('new candidates are seeded with default score fields', () async {
      await svc.writeCandidateDocs(hh, [candidate('movie', 1)]);
      final doc = await db.doc(path('movie:1')).get();
      expect(doc.exists, isTrue);
      final data = doc.data()!;
      expect(data['match_score'], 50);
      expect(data['scored'], false);
      expect(data['ai_blurb'], '');
      expect(data['match_score_solo'], isEmpty);
      expect(data['ai_blurb_solo'], isEmpty);
      expect(data['title'], 'T');
      expect(data['genres'], ['Drama']);
      expect(data['source'], 'trending');
    });

    test('pre-existing scored rec preserves match_score + ai_blurb on merge',
        () async {
      // Claude previously scored this one — writing a fresh candidate pool
      // must not drop it back to 50%.
      await db.doc(path('movie:1')).set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'Old title',
        'match_score': 87,
        'ai_blurb': 'You will love this.',
        'scored': true,
      });

      await svc.writeCandidateDocs(
          hh, [candidate('movie', 1, title: 'Refreshed title')]);

      final doc = await db.doc(path('movie:1')).get();
      final data = doc.data()!;
      expect(data['match_score'], 87);
      expect(data['ai_blurb'], 'You will love this.');
      expect(data['scored'], true);
      // But metadata still refreshes.
      expect(data['title'], 'Refreshed title');
      expect(data['source'], 'trending');
    });

    test('skips candidates missing media_type or tmdb_id (defensive)',
        () async {
      await svc.writeCandidateDocs(hh, [
        {'media_type': 'movie'},
        {'tmdb_id': 1},
        candidate('movie', 42),
      ]);
      final snap = await db.collection('households/$hh/recommendations').get();
      expect(snap.size, 1);
      expect(snap.docs.first.id, 'movie:42');
    });

    test('stable key is "mediaType:tmdbId" — re-writing same key is idempotent',
        () async {
      await svc.writeCandidateDocs(hh, [candidate('movie', 1)]);
      await svc.writeCandidateDocs(hh, [candidate('movie', 1)]);
      final snap = await db.collection('households/$hh/recommendations').get();
      expect(snap.size, 1);
    });

    test('chunks a 1000-candidate pool past the 500-op batch cap', () async {
      // Sanity check that the chunking loop handles the Firestore limit.
      // 1000 unique rows should all land.
      final big = List.generate(
          1000, (i) => candidate('movie', i + 1, title: 'T$i'));
      await svc.writeCandidateDocs(hh, big);
      final snap = await db.collection('households/$hh/recommendations').get();
      expect(snap.size, 1000);
    });

    test('mixed new + existing: existing preserved, new seeded', () async {
      await db.doc(path('movie:1')).set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'match_score': 91,
        'ai_blurb': 'Keep me',
        'scored': true,
      });
      await svc.writeCandidateDocs(hh, [
        candidate('movie', 1),
        candidate('movie', 2),
      ]);
      final existing = (await db.doc(path('movie:1')).get()).data()!;
      final fresh = (await db.doc(path('movie:2')).get()).data()!;
      expect(existing['match_score'], 91);
      expect(existing['ai_blurb'], 'Keep me');
      expect(fresh['match_score'], 50);
      expect(fresh['ai_blurb'], '');
    });

    test('returns (mediaType, tmdbId) pairs for rec docs without imdb_id',
        () async {
      // Pre-seed one doc with imdb_id already resolved, one without.
      await db.doc(path('movie:1')).set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'imdb_id': 'tt0000001',
      });
      await db.doc(path('movie:2')).set({
        'media_type': 'movie',
        'tmdb_id': 2,
      });

      final missing = await svc.writeCandidateDocs(hh, [
        candidate('movie', 1), // has imdb_id — skip
        candidate('movie', 2), // existing but missing imdb_id — include
        candidate('movie', 3), // fresh — include
      ]);

      final keys = missing.map((p) => '${p.mediaType}:${p.tmdbId}').toSet();
      expect(keys, containsAll({'movie:2', 'movie:3'}));
      expect(keys, isNot(contains('movie:1')));
    });

    test('stampImdbId writes imdb_id on an existing rec doc', () async {
      await svc.writeCandidateDocs(hh, [candidate('movie', 10)]);
      await svc.stampImdbId(
        householdId: hh,
        mediaType: 'movie',
        tmdbId: 10,
        imdbId: 'tt1234567',
      );
      final doc = (await db.doc(path('movie:10')).get()).data()!;
      expect(doc['imdb_id'], 'tt1234567');
    });

    test('stampImdbId is a no-op for an empty imdb_id', () async {
      await svc.writeCandidateDocs(hh, [candidate('movie', 11)]);
      await svc.stampImdbId(
        householdId: hh,
        mediaType: 'movie',
        tmdbId: 11,
        imdbId: '',
      );
      final doc = (await db.doc(path('movie:11')).get()).data()!;
      expect(doc.containsKey('imdb_id'), isFalse);
    });

    test('stampImdbId silently ignores missing rec doc', () async {
      // No doc exists at movie:999 — update() would throw, the service
      // should swallow it.
      await svc.stampImdbId(
        householdId: hh,
        mediaType: 'movie',
        tmdbId: 999,
        imdbId: 'tt9999999',
      );
      final doc = await db.doc(path('movie:999')).get();
      expect(doc.exists, isFalse);
    });

    test('stampAugmentedGenres widens the genre set when a keyword matches',
        () async {
      await db.doc(path('movie:20')).set({
        'media_type': 'movie',
        'tmdb_id': 20,
        'title': 'Starship-ish',
        'genres': ['Action', 'Science Fiction'],
      });
      // 9951 (alien) → seeded in kKeywordToExtraGenres as Science Fiction,
      // which already exists. 4458 (post-apocalyptic) also → Science Fiction.
      // Nothing should change — this test covers the no-op branch.
      await svc.stampAugmentedGenres(
        householdId: hh,
        mediaType: 'movie',
        tmdbId: 20,
        keywordIds: const [9951, 4458],
      );
      final doc = (await db.doc(path('movie:20')).get()).data()!;
      expect(doc['genres'], ['Action', 'Science Fiction'],
          reason: 'no-op: every implied genre already present');
    });

    test('stampAugmentedGenres adds a new genre when keyword widens',
        () async {
      await db.doc(path('movie:21')).set({
        'media_type': 'movie',
        'tmdb_id': 21,
        'title': 'Kung Fu Dystopia',
        'genres': ['Action'],
      });
      // 4565 (dystopia) → {Science Fiction}. Action stays; Sci-Fi is added.
      await svc.stampAugmentedGenres(
        householdId: hh,
        mediaType: 'movie',
        tmdbId: 21,
        keywordIds: const [4565],
      );
      final doc = (await db.doc(path('movie:21')).get()).data()!;
      expect(doc['genres'], ['Action', 'Science Fiction']);
    });

    test('stampAugmentedGenres is a no-op when keywordIds empty', () async {
      await db.doc(path('movie:22')).set({
        'media_type': 'movie',
        'tmdb_id': 22,
        'title': 'T',
        'genres': ['Drama'],
      });
      await svc.stampAugmentedGenres(
        householdId: hh,
        mediaType: 'movie',
        tmdbId: 22,
        keywordIds: const [],
      );
      final doc = (await db.doc(path('movie:22')).get()).data()!;
      expect(doc['genres'], ['Drama']);
    });

    test('stampAugmentedGenres silently ignores missing rec doc', () async {
      await svc.stampAugmentedGenres(
        householdId: hh,
        mediaType: 'movie',
        tmdbId: 9001,
        keywordIds: const [9951],
      );
      expect((await db.doc(path('movie:9001')).get()).exists, isFalse);
    });

    test('backfillMissingImdbIds stamps every unstamped rec doc', () async {
      // Install a mock TMDB client that returns imdb_id based on tmdb_id.
      final mockClient = MockClient((req) async {
        final id =
            int.parse(req.url.pathSegments[req.url.pathSegments.length - 2]);
        return http.Response(
          jsonEncode({'imdb_id': 'tt$id'}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final tmdb = TmdbService(client: mockClient);
      final localSvc = RecommendationsService(db: db, tmdb: tmdb);

      // Pre-seed two unstamped rec docs and one that already has imdb_id.
      await db.doc(path('movie:1')).set({
        'media_type': 'movie', 'tmdb_id': 1, 'title': 'A',
      });
      await db.doc(path('tv:2')).set({
        'media_type': 'tv', 'tmdb_id': 2, 'title': 'B',
      });
      await db.doc(path('movie:3')).set({
        'media_type': 'movie', 'tmdb_id': 3, 'title': 'C',
        'imdb_id': 'tt_existing',
      });

      await localSvc.backfillMissingImdbIds(hh);

      expect((await db.doc(path('movie:1')).get()).data()!['imdb_id'], 'tt1');
      expect((await db.doc(path('tv:2')).get()).data()!['imdb_id'], 'tt2');
      // Existing imdb_id not overwritten.
      expect((await db.doc(path('movie:3')).get()).data()!['imdb_id'],
          'tt_existing');
    });

    test('backfillMissingImdbIds silently swallows a TMDB error', () async {
      final errorClient = MockClient((_) async => http.Response('boom', 500));
      final tmdb = TmdbService(client: errorClient);
      final localSvc = RecommendationsService(db: db, tmdb: tmdb);

      await db.doc(path('movie:1')).set({
        'media_type': 'movie', 'tmdb_id': 1, 'title': 'A',
      });

      // Must not throw.
      await localSvc.backfillMissingImdbIds(hh);
      expect((await db.doc(path('movie:1')).get()).data()!['imdb_id'],
          isNull);
    });
  });

  group('buildCandidates — oscar discover tagging', () {
    test(
        'tags discover_movie + discover_tv rows with is_oscar_winner when discoverIsOscar=true',
        () {
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: {
          'results': [
            {'id': 100, 'title': 'Schindler', 'release_date': '1993-12-15'},
          ],
        },
        discoverTvPayload: {
          'results': [
            {'id': 200, 'name': 'Crown', 'first_air_date': '2016-11-04'},
          ],
        },
        discoverIsOscar: true,
      );
      final byKey = {for (final c in out) '${c['media_type']}:${c['tmdb_id']}': c};
      expect(byKey['movie:100']?['is_oscar_winner'], true);
      expect(byKey['tv:200']?['is_oscar_winner'], true);
    });

    test('omits is_oscar_winner key entirely when discoverIsOscar=false', () {
      // Important: the key must be ABSENT (not just false) so the writeCandidateDocs
      // merge doesn't silently overwrite a previously-true flag in Firestore.
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: {
          'results': [
            {'id': 100, 'title': 'X', 'release_date': '2010-01-01'},
          ],
        },
        discoverIsOscar: false,
      );
      expect(out.first.containsKey('is_oscar_winner'), isFalse);
    });

    test(
        'discover wins source dedup over trending so an oscar-tagged hot title keeps the flag',
        () {
      // Same title (movie:777) in BOTH the trending and the oscar-discover
      // payloads. Without putting discover ahead of trending in the merge
      // order, dedup would keep `source: 'trending'` and drop the oscar tag —
      // exactly what would happen for a current-year Best Picture winner.
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: {
          'results': [
            {'id': 777, 'title': 'Hot Oscar Movie', 'release_date': '2024-12-01'},
          ],
        },
        discoverMoviesPayload: {
          'results': [
            {'id': 777, 'title': 'Hot Oscar Movie', 'release_date': '2024-12-01'},
          ],
        },
        discoverIsOscar: true,
      );
      final row = out.firstWhere((c) => c['tmdb_id'] == 777);
      expect(row['source'], 'discover');
      expect(row['is_oscar_winner'], true);
    });

    test('non-oscar baseline rows are not tagged even when oscar mode is on',
        () {
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: {
          'results': [
            {'id': 1, 'title': 'Trending only', 'release_date': '2024-01-01'},
          ],
        },
        topRatedMoviesPayload: {
          'results': [
            {'id': 2, 'title': 'Top rated only', 'release_date': '2024-01-01'},
          ],
        },
        discoverIsOscar: true,
      );
      // Both trending + top_rated rows survive dedup but should NOT carry the
      // oscar flag — only confirmed-via-discover rows do.
      for (final r in out) {
        expect(r.containsKey('is_oscar_winner'), isFalse,
            reason: 'baseline ${r['source']} rows must not be flagged');
      }
    });
  });

  group('buildCandidates — curator tagging', () {
    test('stamps curator only on discover rows when discoverCurator set', () {
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: const {
          'results': [
            {'id': 1, 'title': 'Crit', 'release_date': '1970-01-01'},
          ],
        },
        trendingMoviesPayload: const {
          'results': [
            {'id': 2, 'title': 'Hot', 'release_date': '2025-01-01'},
          ],
        },
        discoverCurator: 'criterion',
      );
      final crit = out.firstWhere((c) => c['tmdb_id'] == 1);
      final hot = out.firstWhere((c) => c['tmdb_id'] == 2);
      expect(crit['curator'], 'criterion');
      expect(hot.containsKey('curator'), isFalse,
          reason: 'baseline rows must not carry a curator tag');
    });

    test('omits curator field entirely when discoverCurator is empty', () {
      final out = buildCandidates(
        watchlist: const [],
        discoverMoviesPayload: const {
          'results': [
            {'id': 1, 'title': 'Plain', 'release_date': '2020-01-01'},
          ],
        },
      );
      expect(out.first.containsKey('curator'), isFalse);
    });
  });

  group('writeCandidateDocs — curator flag stickiness', () {
    test('writes curator on a fresh candidate', () async {
      final db = FakeFirebaseFirestore();
      final svc = RecommendationsService(db: db);
      const hh = 'h1';
      await svc.writeCandidateDocs(hh, [
        {
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Seven Samurai',
          'curator': 'criterion',
        },
      ]);
      final doc =
          await db.doc('households/$hh/recommendations/movie:1').get();
      expect(doc.data()!['curator'], 'criterion');
    });

    test('preserves existing curator when re-written without the field',
        () async {
      // Real-world sequence: Criterion refresh tags movie:1. Next refresh has
      // the curator toggle off, so movie:1 comes through trending without the
      // curator key. Merge semantics must leave `curator='criterion'` intact.
      final db = FakeFirebaseFirestore();
      final svc = RecommendationsService(db: db);
      const hh = 'h1';
      await svc.writeCandidateDocs(hh, [
        {
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Seven Samurai',
          'curator': 'criterion',
        },
      ]);
      await svc.writeCandidateDocs(hh, [
        {
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Seven Samurai',
          // no curator key this time
        },
      ]);
      final doc =
          await db.doc('households/$hh/recommendations/movie:1').get();
      expect(doc.data()!['curator'], 'criterion');
    });

    test('ignores empty-string curator (baseline rows)', () async {
      final db = FakeFirebaseFirestore();
      final svc = RecommendationsService(db: db);
      const hh = 'h1';
      await svc.writeCandidateDocs(hh, [
        {
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'x',
          'curator': '',
        },
      ]);
      final doc =
          await db.doc('households/$hh/recommendations/movie:1').get();
      expect(doc.data()!.containsKey('curator'), isFalse);
    });
  });

  group('buildCandidates — fuzz: every flag combo is crash-free', () {
    // Regression guard: exhaustively exercise the boolean/payload combinations
    // the service composes when the user stacks filters. A regression that
    // only triggers under, say, "discoverIsOscar=true + empty trending" would
    // otherwise slip through the single-concern tests above.
    final samplePayload = {
      'results': [
        {
          'id': 1,
          'title': 'Live',
          'release_date': '2020-01-01',
          'genre_ids': [80, 18],
        },
        {
          'id': 2,
          'title': 'Animated',
          'release_date': '2020-01-01',
          'genre_ids': [16, 80],
        },
      ],
    };
    final watchlist = [
      _w(mediaType: 'movie', id: 500, title: 'WL', genres: const ['Animation']),
    ];
    final reddit = [
      {
        'media_type': 'movie',
        'tmdb_id': 700,
        'title': 'R',
        'genre_ids': const [28],
      },
    ];

    for (final oscar in [false, true]) {
      for (final hasBaseline in [false, true]) {
        for (final hasDiscover in [false, true]) {
          test(
              'oscar=$oscar baseline=$hasBaseline discover=$hasDiscover',
              () {
            final out = buildCandidates(
              watchlist: watchlist,
              redditMentions: reddit,
              trendingMoviesPayload: hasBaseline ? samplePayload : const {},
              trendingTvPayload: hasBaseline ? samplePayload : const {},
              topRatedMoviesPayload: hasBaseline ? samplePayload : const {},
              topRatedTvPayload: hasBaseline ? samplePayload : const {},
              discoverMoviesPayload: hasDiscover ? samplePayload : const {},
              discoverTvPayload: hasDiscover ? samplePayload : const {},
              discoverIsOscar: oscar,
            );
            // Watchlist always survives — user-curated content always shows.
            expect(out.any((c) => c['tmdb_id'] == 500), isTrue,
                reason: 'watchlist always surfaces');
            // When any TMDB source fires AND oscar tag is on, the discover
            // rows must carry is_oscar_winner=true — nothing else should.
            if (hasDiscover && oscar) {
              final oscarTagged =
                  out.where((c) => c['is_oscar_winner'] == true).toList();
              expect(oscarTagged, isNotEmpty);
              expect(oscarTagged.every((c) => c['source'] == 'discover'),
                  isTrue);
            }
          });
        }
      }
    }
  });

  group('writeCandidateDocs — oscar flag stickiness', () {
    test('writes is_oscar_winner=true on a fresh candidate', () async {
      final db = FakeFirebaseFirestore();
      final svc = RecommendationsService(db: db);
      const hh = 'h1';
      await svc.writeCandidateDocs(hh, [
        {
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Casablanca',
          'is_oscar_winner': true,
        },
      ]);
      final doc = await db
          .doc('households/$hh/recommendations/movie:1')
          .get();
      expect(doc.data()!['is_oscar_winner'], true);
    });

    test('preserves existing is_oscar_winner=true when re-written without flag',
        () async {
      // Real-world sequence: oscar refresh tags movie:1 → next refresh has the
      // oscar toggle off, so movie:1 comes through trending without the flag.
      // The doc must NOT lose its `is_oscar_winner=true` — a movie doesn't
      // un-win an Oscar.
      final db = FakeFirebaseFirestore();
      final svc = RecommendationsService(db: db);
      const hh = 'h1';
      await svc.writeCandidateDocs(hh, [
        {
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Casablanca',
          'is_oscar_winner': true,
        },
      ]);
      // Second pass: same title, oscar flag absent (came through trending).
      await svc.writeCandidateDocs(hh, [
        {
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Casablanca',
          'source': 'trending',
        },
      ]);
      final doc = await db
          .doc('households/$hh/recommendations/movie:1')
          .get();
      expect(doc.data()!['is_oscar_winner'], true,
          reason: 'oscar flag should be sticky across refresh passes');
    });
  });

  // ─── RecommendationsService.refresh — epoch guard ──────────────────────
  //
  // The Home screen debounces filter changes at 700ms, but a user who flips
  // filters faster than TMDB can respond (fan-out is 1–3s) can still trigger
  // concurrent `refresh(...)` calls. Before the epoch guard, an older refresh
  // could finish its TMDB fetches AFTER a newer one already landed, and then
  // stomp the newer pool with its stale candidates — the user-visible symptom
  // was "the filter I picked flashes up, then gets overwritten a few seconds
  // later by the previous one".
  //
  // The guard: at the top of `refresh`, capture `myEpoch = ++_refreshEpoch`.
  // Before the Firestore write (and before firing the Claude background
  // score), check `myEpoch != _refreshEpoch` and bail silently. The stale
  // refresh still burns its TMDB quota (Dart Futures can't be cancelled),
  // but it does NOT mutate Firestore.
  group('RecommendationsService.refresh — epoch guard', () {
    /// Builds an `http.Client` that routes TMDB baseline endpoints
    /// (trending + top_rated for movie + tv) to caller-controlled payloads,
    /// but gates the FIRST `batchSize` requests on [stallUntil] so tests
    /// can interleave two concurrent `refresh()` calls. The count is tracked
    /// across all incoming requests; after `batchSize` requests have been
    /// seen, subsequent ones resolve immediately with [secondPayload].
    http.Client gatedClient({
      required Future<void> stallUntil,
      required Map<String, dynamic> stalePayload,
      required Map<String, dynamic> freshPayload,
      required int batchSize,
      required List<Uri> allRequests,
    }) {
      var seen = 0;
      return MockClient((req) async {
        allRequests.add(req.url);
        final isBatchOne = seen < batchSize;
        seen++;
        if (isBatchOne) {
          // Refresh 1's TMDB fetch — stall until the test releases it.
          await stallUntil;
          return http.Response(
            json.encode(stalePayload),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        // Refresh 2's TMDB fetch — resolve immediately with the fresh pool.
        return http.Response(
          json.encode(freshPayload),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
    }

    test(
        'stale refresh does NOT overwrite a newer refresh\'s Firestore pool',
        () async {
      // Stale payload carries `id=111`; fresh payload carries `id=222`.
      // After the race resolves, only the fresh rec key should exist.
      final stalePayload = {
        'results': [
          {
            'id': 111,
            'media_type': 'movie',
            'title': 'Stale Pick',
            'genre_ids': [18],
            'release_date': '2020-01-01',
          },
        ],
      };
      final freshPayload = {
        'results': [
          {
            'id': 222,
            'media_type': 'movie',
            'title': 'Fresh Pick',
            'genre_ids': [18],
            'release_date': '2024-01-01',
          },
        ],
      };

      // `refresh()` fires 4 baseline TMDB calls when filters are inactive
      // (trendingMovies, trendingTv, topRatedMovies, topRatedTv). Gate the
      // first 4 so refresh 1's whole batch waits for us to release them.
      final release = Completer<void>();
      final requests = <Uri>[];
      final client = gatedClient(
        stallUntil: release.future,
        stalePayload: stalePayload,
        freshPayload: freshPayload,
        batchSize: 4,
        allRequests: requests,
      );
      final tmdb = TmdbService(client: client);
      final db = FakeFirebaseFirestore();
      final svc = RecommendationsService(db: db, tmdb: tmdb);
      const hh = 'hh-race';

      // Start refresh 1 (stale). Its 4 TMDB calls block on `release`.
      final refresh1 = svc.refresh(hh, watchlist: const []);

      // Let refresh 1's TMDB calls get dispatched onto the mock client so
      // `seen` is advanced past the batch threshold before refresh 2 fires.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Start refresh 2 (fresh). Its TMDB calls resolve immediately; it
      // advances `_refreshEpoch` past refresh 1 and writes `movie:222` to
      // Firestore before refresh 1 has even seen its TMDB responses.
      await svc.refresh(hh, watchlist: const []);

      // Sanity: after refresh 2 lands, only `movie:222` is in Firestore.
      final midSnap =
          await db.collection('households/$hh/recommendations').get();
      expect(midSnap.docs.map((d) => d.id).toList(), ['movie:222'],
          reason: 'fresh refresh must have written its pool');

      // Now release refresh 1's TMDB responses. It will build its
      // candidate list (Stale Pick) and then hit the epoch guard — the
      // epoch has advanced, so it must bail WITHOUT writing to Firestore.
      release.complete();
      await refresh1;

      // Final assertion: Firestore still contains only the fresh refresh's
      // pool. If the epoch guard had not fired, `movie:111` would be here
      // (alongside `movie:222`) because the stale refresh's writeCandidateDocs
      // would have merged its own pool on top.
      final finalSnap =
          await db.collection('households/$hh/recommendations').get();
      final ids = finalSnap.docs.map((d) => d.id).toSet();
      expect(ids, {'movie:222'},
          reason:
              'stale refresh must not write its candidates after a newer refresh has committed');
      expect(ids.contains('movie:111'), isFalse,
          reason:
              'the "Stale Pick" from refresh 1 must never appear in Firestore');
    });

    test('non-overlapping refreshes both land (epoch guard is not a lock)',
        () async {
      // Sanity test: if refresh 1 finishes BEFORE refresh 2 starts, the
      // guard must not interfere. Refresh 2's pool merges with refresh 1's;
      // both rec keys end up in Firestore (the stream shows the union).
      final firstPayload = {
        'results': [
          {
            'id': 301,
            'media_type': 'movie',
            'title': 'First',
            'genre_ids': [18],
            'release_date': '2020-01-01',
          },
        ],
      };
      final secondPayload = {
        'results': [
          {
            'id': 302,
            'media_type': 'movie',
            'title': 'Second',
            'genre_ids': [18],
            'release_date': '2024-01-01',
          },
        ],
      };

      var callCount = 0;
      final client = MockClient((req) async {
        // First 4 requests return payload 1, next 4 return payload 2.
        final payload = callCount < 4 ? firstPayload : secondPayload;
        callCount++;
        return http.Response(
          json.encode(payload),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final tmdb = TmdbService(client: client);
      final db = FakeFirebaseFirestore();
      final svc = RecommendationsService(db: db, tmdb: tmdb);
      const hh = 'hh-sequential';

      await svc.refresh(hh, watchlist: const []);
      await svc.refresh(hh, watchlist: const []);

      final snap = await db.collection('households/$hh/recommendations').get();
      final ids = snap.docs.map((d) => d.id).toSet();
      expect(ids, containsAll(['movie:301', 'movie:302']),
          reason:
              'sequential (non-overlapping) refreshes must both land; guard only drops stale concurrent ones');
    });
  });

  // ─── buildCandidates — oscar baked list ────────────────────────────────
  //
  // The Oscar filter delegates to a curated Best Picture winners list
  // (lib/utils/oscar_winners.dart) instead of TMDB's unreliable keyword.
  // These tests lock down that contract so the Oscar filter can't silently
  // regress back to the keyword path, and so the baked entries survive
  // downstream writes with their imdb_id + oscar tag intact.
  group('buildCandidates — oscar baked list', () {
    test('includeOscarBakedList=true seeds Best Picture winners tagged', () {
      final out = buildCandidates(
        watchlist: const [],
        includeOscarBakedList: true,
      );
      expect(out.length, greaterThanOrEqualTo(90));
      for (final c in out) {
        expect(c['source'], 'oscar');
        expect(c['is_oscar_winner'], true);
        expect(c['media_type'], 'movie');
        expect((c['imdb_id'] as String).startsWith('tt'), isTrue);
      }
    });

    test('includeOscarBakedList=false omits the list', () {
      final out = buildCandidates(
        watchlist: const [],
        includeOscarBakedList: false,
      );
      expect(out.where((c) => c['source'] == 'oscar'), isEmpty);
    });

    test('oscar baked list leads merge order so tags survive trending dedup',
        () {
      // If The Godfather (tmdb=238) also comes through trending, the oscar
      // source must win dedup so it keeps is_oscar_winner=true.
      final out = buildCandidates(
        watchlist: const [],
        trendingMoviesPayload: {
          'results': [
            {'id': 238, 'title': 'The Godfather', 'release_date': '1972-03-14'},
          ],
        },
        includeOscarBakedList: true,
      );
      final row = out.firstWhere((c) => c['tmdb_id'] == 238);
      expect(row['source'], 'oscar');
      expect(row['is_oscar_winner'], true);
    });
  });

  // Award-specific splicing: when the user picks Palme d'Or or BAFTA Best
  // Film from the Awards dropdown, `buildCandidates` must splice the right
  // list rather than defaulting to Best Picture. These tests lock that
  // contract and verify the lists compose with genre/year/runtime filters
  // downstream on the Home screen.
  group('buildCandidates — Awards category routing', () {
    test('bestPicture routes the full Best Picture list', () {
      final out = buildCandidates(
        watchlist: const [],
        includeAwardsList: AwardCategory.bestPicture,
      );
      // Same contract as includeOscarBakedList=true: the baked list is the
      // full Best Picture canon (>=90 titles).
      expect(out.length, greaterThanOrEqualTo(90));
      expect(out.every((c) => c['is_oscar_winner'] == true), isTrue);
    });

    test('palmeDor routes only the Palme d\'Or cross-ref list', () {
      final out = buildCandidates(
        watchlist: const [],
        includeAwardsList: AwardCategory.palmeDor,
      );
      expect(out, isNotEmpty);
      expect(out.length, lessThan(10),
          reason:
              'Palme list is the small Best-Picture intersection, not the full canon');
      final titles = out.map((c) => c['title']).toSet();
      expect(titles, contains('Parasite'));
      expect(titles, contains('Marty'));
      expect(titles, contains('The Lost Weekend'));
      // Godfather isn't a Palme winner — must not leak across categories.
      expect(titles, isNot(contains('The Godfather')));
    });

    test('baftaBestFilm routes only the BAFTA cross-ref list', () {
      final out = buildCandidates(
        watchlist: const [],
        includeAwardsList: AwardCategory.baftaBestFilm,
      );
      expect(out, isNotEmpty);
      final titles = out.map((c) => c['title']).toSet();
      expect(titles, contains('Gandhi'));
      expect(titles, contains('Schindler\'s List'));
      // Parasite didn't win BAFTA Best Film — must not leak from Palme list.
      expect(titles, isNot(contains('Parasite')));
    });

    test('awards rows carry the genre/runtime/year metadata needed for '
        'client-side filter composition', () {
      // Regression guard for the Home filter stack: if an award row ships
      // without genres/runtime/year it'll silently drop out under a
      // narrowing filter (genre / runtime bucket / year range), and the
      // user will see an empty list instead of the winners they asked
      // for. Check every Palme row is fully populated.
      final out = buildCandidates(
        watchlist: const [],
        includeAwardsList: AwardCategory.palmeDor,
      );
      for (final c in out) {
        expect(c['genres'], isA<List>());
        expect((c['genres'] as List), isNotEmpty,
            reason: '${c['title']} has no genres — breaks genre filter');
        expect(c['runtime'], isA<int>(),
            reason: '${c['title']} has no runtime — breaks runtime filter');
        expect(c['year'], isA<int>(),
            reason: '${c['title']} has no year — breaks year filter');
      }
    });

    test('null includeAwardsList omits the list entirely', () {
      final out = buildCandidates(
        watchlist: const [],
        includeAwardsList: null,
      );
      expect(out.where((c) => c['source'] == 'oscar'), isEmpty);
    });
  });

  // ─── isNarrowFilterCombo ────────────────────────────────────────────────
  //
  // Locks in which filter combinations should trigger the widened-pool
  // discover fetch (bigger poolFloor, more pages, lower vote floor). If the
  // threshold changes we want tests to fail loudly — this directly shapes
  // how many TMDB pages fire per refresh.
  group('isNarrowFilterCombo', () {
    bool call({
      Set<String> genreFilters = const {},
      YearRange yearRange = const YearRange.unbounded(),
      RuntimeBucket? runtimeBucket,
      bool oscarOnly = false,
      CuratedSource curatedSource = CuratedSource.none,
      SortMode sortMode = SortMode.topRated,
    }) {
      return isNarrowFilterCombo(
        genreFilters: genreFilters,
        yearRange: yearRange,
        runtimeBucket: runtimeBucket,
        oscarOnly: oscarOnly,
        curatedSource: curatedSource,
        sortMode: sortMode,
      );
    }

    test('no filters → not narrow', () {
      expect(call(), isFalse);
    });

    test('one filter → not narrow (default pool budget is fine)', () {
      expect(call(genreFilters: {'War'}), isFalse);
      expect(call(yearRange: const YearRange(minYear: 1970, maxYear: 1989)),
          isFalse);
      expect(call(runtimeBucket: RuntimeBucket.medium), isFalse);
      expect(call(oscarOnly: true), isFalse);
      expect(call(curatedSource: CuratedSource.a24), isFalse);
      expect(call(sortMode: SortMode.underseen), isFalse);
    });

    test('two orthogonal filters → narrow', () {
      expect(
        call(
          genreFilters: {'War'},
          yearRange: const YearRange(minYear: 1970, maxYear: 1989),
        ),
        isTrue,
      );
      expect(
        call(genreFilters: {'Comedy'}, runtimeBucket: RuntimeBucket.medium),
        isTrue,
      );
      expect(
        call(oscarOnly: true, curatedSource: CuratedSource.a24),
        isTrue,
      );
    });

    test('underseen sort counts toward narrowness (thins pool via vote cap)',
        () {
      expect(
        call(genreFilters: {'Drama'}, sortMode: SortMode.underseen),
        isTrue,
      );
    });

    test('three+ filters are still just narrow (no further tiers)', () {
      expect(
        call(
          genreFilters: {'War'},
          yearRange: const YearRange(minYear: 1970, maxYear: 1989),
          runtimeBucket: RuntimeBucket.long_,
          oscarOnly: true,
        ),
        isTrue,
      );
    });

    test('non-narrowing knobs do not tip the score', () {
      // mediaType + non-default sort (other than underseen) don't shrink
      // the pool meaningfully — they just reshape it. Caller deliberately
      // excludes these from the narrowness detector.
      expect(call(sortMode: SortMode.popularity), isFalse);
      expect(call(sortMode: SortMode.recent), isFalse);
    });
  });
}
