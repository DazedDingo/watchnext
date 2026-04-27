import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/watch_entry.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/providers/library_filter_provider.dart';
import 'package:watchnext/providers/media_type_filter_provider.dart';

/// Pure pipeline applied to the Library Saved tab: media type → genre AND →
/// case-insensitive title search → sort. Guards the contract that:
///   * media type / genre / search compose without bleeding into each other,
///   * cross-taxonomy genre synonyms (movie ↔ TV vocab) match transparently,
///   * unknown values (null year, null runtime) sort last regardless of
///     direction so they don't masquerade as smallest/largest.
void main() {
  WatchlistItem item({
    required int id,
    required String title,
    String mediaType = 'movie',
    int? year,
    int? runtime,
    List<String> genres = const [],
    DateTime? addedAt,
  }) =>
      WatchlistItem(
        id: '$mediaType:$id',
        mediaType: mediaType,
        tmdbId: id,
        title: title,
        addedBy: 'u1',
        addedAt: addedAt ?? DateTime.utc(2025, 1, 1),
        year: year,
        runtime: runtime,
        genres: genres,
      );

  group('applyLibraryFilters — media type', () {
    test('null media type preserves all', () {
      final input = [
        item(id: 1, title: 'Movie A'),
        item(id: 2, title: 'Show B', mediaType: 'tv'),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.length, 2);
    });

    test('movie filter excludes tv', () {
      final input = [
        item(id: 1, title: 'Movie A'),
        item(id: 2, title: 'Show B', mediaType: 'tv'),
        item(id: 3, title: 'Movie C'),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: MediaTypeFilter.movie,
        genres: const {},
        query: '',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.map((w) => w.tmdbId), [1, 3]);
    });

    test('tv filter excludes movie', () {
      final input = [
        item(id: 1, title: 'Movie A'),
        item(id: 2, title: 'Show B', mediaType: 'tv'),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: MediaTypeFilter.tv,
        genres: const {},
        query: '',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.map((w) => w.tmdbId), [2]);
    });
  });

  group('applyLibraryFilters — genres', () {
    test('AND intersection — every selected genre must be satisfied', () {
      final input = [
        item(id: 1, title: 'A', genres: ['Drama', 'War']),
        item(id: 2, title: 'B', genres: ['Drama']),
        item(id: 3, title: 'C', genres: ['War']),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: {'Drama', 'War'},
        query: '',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.map((w) => w.tmdbId), [1]);
    });

    test('cross-taxonomy synonym: TV "Sci-Fi & Fantasy" matches movie '
        '"Science Fiction" pick', () {
      final input = [
        item(
          id: 1,
          title: 'Westworld',
          mediaType: 'tv',
          genres: ['Sci-Fi & Fantasy', 'Western'],
        ),
        item(
          id: 2,
          title: 'Starship Troopers',
          genres: ['Science Fiction', 'Action'],
        ),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: {'Science Fiction'},
        query: '',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.map((w) => w.tmdbId), containsAll([1, 2]));
    });

    test('items with empty genres drop out under an active filter', () {
      final input = [
        item(id: 1, title: 'A', genres: ['Drama']),
        item(id: 2, title: 'B', genres: const []),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: {'Drama'},
        query: '',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.map((w) => w.tmdbId), [1]);
    });

    test('empty genre set is a no-op', () {
      final input = [
        item(id: 1, title: 'A', genres: const []),
        item(id: 2, title: 'B', genres: const ['Drama']),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.length, 2);
    });
  });

  group('applyLibraryFilters — search', () {
    test('case-insensitive substring match', () {
      final input = [
        item(id: 1, title: 'The Godfather'),
        item(id: 2, title: 'Goodfellas'),
        item(id: 3, title: 'Pulp Fiction'),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: 'GOOD',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.map((w) => w.tmdbId), [2]);
    });

    test('trims whitespace from query', () {
      final input = [
        item(id: 1, title: 'Inception'),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '   incep   ',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.map((w) => w.tmdbId), [1]);
    });

    test('whitespace-only query is a no-op', () {
      final input = [
        item(id: 1, title: 'A'),
        item(id: 2, title: 'B'),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '   ',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.length, 2);
    });
  });

  group('applyLibraryFilters — sort', () {
    test('dateAddedDesc — newest first (default)', () {
      final input = [
        item(id: 1, title: 'A', addedAt: DateTime.utc(2025, 1, 1)),
        item(id: 2, title: 'B', addedAt: DateTime.utc(2025, 6, 1)),
        item(id: 3, title: 'C', addedAt: DateTime.utc(2025, 3, 1)),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.dateAddedDesc,
      );
      expect(out.map((w) => w.tmdbId), [2, 3, 1]);
    });

    test('dateAddedAsc — oldest first', () {
      final input = [
        item(id: 1, title: 'A', addedAt: DateTime.utc(2025, 1, 1)),
        item(id: 2, title: 'B', addedAt: DateTime.utc(2025, 6, 1)),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.dateAddedAsc,
      );
      expect(out.map((w) => w.tmdbId), [1, 2]);
    });

    test('titleAsc strips leading "The"/"A"/"An" articles', () {
      final input = [
        item(id: 1, title: 'The Matrix'),
        item(id: 2, title: 'An Education'),
        item(id: 3, title: 'A Beautiful Mind'),
        item(id: 4, title: 'Zodiac'),
        item(id: 5, title: 'Beetlejuice'),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.titleAsc,
      );
      expect(
        out.map((w) => w.title),
        ['A Beautiful Mind', 'Beetlejuice', 'An Education', 'The Matrix', 'Zodiac'],
      );
    });

    test('yearDesc — newest year first; null years sort last', () {
      final input = [
        item(id: 1, title: 'A', year: 2020),
        item(id: 2, title: 'B', year: null),
        item(id: 3, title: 'C', year: 2024),
        item(id: 4, title: 'D', year: 2018),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.yearDesc,
      );
      expect(out.map((w) => w.tmdbId), [3, 1, 4, 2]);
    });

    test('yearAsc — oldest year first; null years still sort last', () {
      final input = [
        item(id: 1, title: 'A', year: 2020),
        item(id: 2, title: 'B', year: null),
        item(id: 3, title: 'C', year: 1995),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.yearAsc,
      );
      expect(out.map((w) => w.tmdbId), [3, 1, 2]);
    });

    test('runtimeAsc — shortest first; null runtimes sort last', () {
      final input = [
        item(id: 1, title: 'A', runtime: 120),
        item(id: 2, title: 'B', runtime: null),
        item(id: 3, title: 'C', runtime: 90),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.runtimeAsc,
      );
      expect(out.map((w) => w.tmdbId), [3, 1, 2]);
    });

    test('runtimeDesc — longest first; null runtimes still sort last', () {
      final input = [
        item(id: 1, title: 'A', runtime: 120),
        item(id: 2, title: 'B', runtime: null),
        item(id: 3, title: 'C', runtime: 180),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: LibrarySort.runtimeDesc,
      );
      expect(out.map((w) => w.tmdbId), [3, 1, 2]);
    });
  });

  WatchEntry entry({
    required int id,
    required String title,
    String mediaType = 'movie',
    int? year,
    int? runtime,
    List<String> genres = const [],
    DateTime? lastWatchedAt,
  }) =>
      WatchEntry(
        id: WatchEntry.buildId(mediaType, id),
        mediaType: mediaType,
        tmdbId: id,
        title: title,
        year: year,
        runtime: runtime,
        genres: genres,
        lastWatchedAt: lastWatchedAt,
      );

  group('applyWatchedFilters — empty input', () {
    test('empty entries list → empty result', () {
      final out = applyWatchedFilters(
        entries: const [],
        mediaType: null,
        genres: const {},
        query: '',
        sort: WatchedSort.lastWatchedDesc,
      );
      expect(out, isEmpty);
    });
  });

  group('applyWatchedFilters — media type', () {
    test('movie filter excludes tv', () {
      final input = [
        entry(id: 1, title: 'Movie A'),
        entry(id: 2, title: 'Show B', mediaType: 'tv'),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: MediaTypeFilter.movie,
        genres: const {},
        query: '',
        sort: WatchedSort.lastWatchedDesc,
      );
      expect(out.map((e) => e.tmdbId), [1]);
    });

    test('tv filter excludes movie', () {
      final input = [
        entry(id: 1, title: 'Movie A'),
        entry(id: 2, title: 'Show B', mediaType: 'tv'),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: MediaTypeFilter.tv,
        genres: const {},
        query: '',
        sort: WatchedSort.lastWatchedDesc,
      );
      expect(out.map((e) => e.tmdbId), [2]);
    });
  });

  group('applyWatchedFilters — genres', () {
    test('AND intersection drops empty-genre entries', () {
      final input = [
        entry(id: 1, title: 'Tagged', genres: ['Drama', 'War']),
        entry(id: 2, title: 'Untagged', genres: const []),
        entry(id: 3, title: 'Partial', genres: ['Drama']),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: null,
        genres: {'Drama', 'War'},
        query: '',
        sort: WatchedSort.lastWatchedDesc,
      );
      expect(out.map((e) => e.tmdbId), [1]);
    });

    test('cross-taxonomy synonym: TV "Sci-Fi & Fantasy" matches movie '
        '"Science Fiction" pick', () {
      final input = [
        entry(
          id: 1,
          title: 'Westworld',
          mediaType: 'tv',
          genres: ['Sci-Fi & Fantasy'],
        ),
        entry(
          id: 2,
          title: 'Starship Troopers',
          genres: ['Science Fiction', 'Action'],
        ),
        entry(id: 3, title: 'Romance Pick', genres: ['Romance']),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: null,
        genres: {'Science Fiction'},
        query: '',
        sort: WatchedSort.lastWatchedDesc,
      );
      expect(out.map((e) => e.tmdbId), containsAll([1, 2]));
      expect(out.map((e) => e.tmdbId), isNot(contains(3)));
    });
  });

  group('applyWatchedFilters — search', () {
    test('case-insensitive title substring', () {
      final input = [
        entry(id: 1, title: 'The Godfather'),
        entry(id: 2, title: 'Goodfellas'),
        entry(id: 3, title: 'Pulp Fiction'),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: null,
        genres: const {},
        query: 'GOOD',
        sort: WatchedSort.lastWatchedDesc,
      );
      expect(out.map((e) => e.tmdbId), [2]);
    });
  });

  group('applyWatchedFilters — sort', () {
    test('titleAsc strips leading articles', () {
      final input = [
        entry(id: 1, title: 'The Matrix'),
        entry(id: 2, title: 'A Beautiful Mind'),
        entry(id: 3, title: 'Zodiac'),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: WatchedSort.titleAsc,
      );
      expect(out.map((e) => e.title),
          ['A Beautiful Mind', 'The Matrix', 'Zodiac']);
    });

    test('lastWatchedDesc — most recent first; null pins last', () {
      final input = [
        entry(
          id: 1,
          title: 'Older',
          lastWatchedAt: DateTime.utc(2024, 1, 1),
        ),
        entry(id: 2, title: 'Unknown', lastWatchedAt: null),
        entry(
          id: 3,
          title: 'Newer',
          lastWatchedAt: DateTime.utc(2025, 6, 1),
        ),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: WatchedSort.lastWatchedDesc,
      );
      expect(out.map((e) => e.tmdbId), [3, 1, 2]);
    });

    test('lastWatchedAsc — oldest first; null still pins last', () {
      final input = [
        entry(
          id: 1,
          title: 'Older',
          lastWatchedAt: DateTime.utc(2024, 1, 1),
        ),
        entry(id: 2, title: 'Unknown', lastWatchedAt: null),
        entry(
          id: 3,
          title: 'Newer',
          lastWatchedAt: DateTime.utc(2025, 6, 1),
        ),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: WatchedSort.lastWatchedAsc,
      );
      expect(out.map((e) => e.tmdbId), [1, 3, 2]);
    });

    test('yearDesc — newest year first; null years sort last', () {
      final input = [
        entry(id: 1, title: 'A', year: 2020),
        entry(id: 2, title: 'B', year: null),
        entry(id: 3, title: 'C', year: 2024),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: null,
        genres: const {},
        query: '',
        sort: WatchedSort.yearDesc,
      );
      expect(out.map((e) => e.tmdbId), [3, 1, 2]);
    });
  });

  group('applyWatchedFilters — composition', () {
    test('media + genre + search + sort all chain', () {
      final input = [
        entry(
          id: 1,
          title: 'The Matrix',
          year: 1999,
          genres: ['Action', 'Science Fiction'],
          lastWatchedAt: DateTime.utc(2025, 1, 1),
        ),
        entry(
          id: 2,
          title: 'Matrix Reloaded',
          year: 2003,
          genres: ['Action', 'Science Fiction'],
          lastWatchedAt: DateTime.utc(2025, 6, 1),
        ),
        entry(
          id: 3,
          title: 'Westworld',
          mediaType: 'tv',
          year: 2016,
          genres: ['Sci-Fi & Fantasy'],
        ),
        entry(
          id: 4,
          title: 'The Godfather',
          year: 1972,
          genres: ['Drama', 'Crime'],
        ),
      ];
      final out = applyWatchedFilters(
        entries: input,
        mediaType: MediaTypeFilter.movie,
        genres: {'Science Fiction'},
        query: 'matrix',
        sort: WatchedSort.yearAsc,
      );
      expect(out.map((e) => e.tmdbId), [1, 2]);
    });
  });

  group('applyLibraryFilters — composition', () {
    test('media + genre + search + sort all chain', () {
      final input = [
        item(
          id: 1,
          title: 'The Matrix',
          year: 1999,
          genres: ['Action', 'Science Fiction'],
        ),
        item(
          id: 2,
          title: 'Matrix Reloaded',
          year: 2003,
          genres: ['Action', 'Science Fiction'],
        ),
        item(
          id: 3,
          title: 'Westworld',
          mediaType: 'tv',
          year: 2016,
          genres: ['Sci-Fi & Fantasy'],
        ),
        item(
          id: 4,
          title: 'The Godfather',
          year: 1972,
          genres: ['Drama', 'Crime'],
        ),
      ];
      final out = applyLibraryFilters(
        items: input,
        mediaType: MediaTypeFilter.movie,
        genres: {'Science Fiction'},
        query: 'matrix',
        sort: LibrarySort.yearAsc,
      );
      expect(out.map((w) => w.tmdbId), [1, 2]);
    });
  });
}
