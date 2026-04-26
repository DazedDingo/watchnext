import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/watchlist_item.dart';
import '../utils/tmdb_genres.dart';
import 'media_type_filter_provider.dart';

/// Sort order for the Library Saved tab. Default is `dateAddedDesc` — the
/// natural "what did we just save" reading order. The other modes cover the
/// common "scan for what we want tonight" needs (alphabetical, by year, by
/// runtime).
enum LibrarySort {
  dateAddedDesc('Recently added'),
  dateAddedAsc('Oldest first'),
  titleAsc('Title (A–Z)'),
  yearDesc('Year (newest)'),
  yearAsc('Year (oldest)'),
  runtimeAsc('Shortest first'),
  runtimeDesc('Longest first');

  final String label;
  const LibrarySort(this.label);
}

/// Library Saved-tab filter state. Session-scoped — deliberately not persisted
/// to SharedPreferences. Library filters are scoped to "what am I looking for
/// right now"; persisting them would surprise the user the next time they open
/// the tab. Home filters persist because they shape the recommendation pool;
/// Library filters just narrow an existing list.
final libraryMediaTypeProvider = StateProvider<MediaTypeFilter?>((_) => null);
final librarySortProvider =
    StateProvider<LibrarySort>((_) => LibrarySort.dateAddedDesc);
final libraryGenresProvider = StateProvider<Set<String>>((_) => const {});
final librarySearchProvider = StateProvider<String>((_) => '');

/// Pure pipeline applied to the Saved-tab list after the watched-filter pass.
/// Order: media type → genre AND-intersection (with cross-taxonomy synonyms via
/// `genreMatches`) → case-insensitive title substring search → sort. Items
/// without genres always drop out under an active genre filter — "tagged with
/// all of these" can't be verified for an empty list (mirrors Home gotcha 10).
List<WatchlistItem> applyLibraryFilters({
  required List<WatchlistItem> items,
  required MediaTypeFilter? mediaType,
  required Set<String> genres,
  required String query,
  required LibrarySort sort,
}) {
  var pool = items;
  if (mediaType != null) {
    pool = pool.where((w) => w.mediaType == mediaType.recMediaType).toList();
  }
  if (genres.isNotEmpty) {
    pool = pool
        .where((w) =>
            w.genres.isNotEmpty &&
            genres.every((g) => genreMatches(w.genres, g)))
        .toList();
  }
  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    pool = pool.where((w) => w.title.toLowerCase().contains(q)).toList();
  }
  final sorted = List<WatchlistItem>.from(pool);
  sorted.sort((a, b) {
    switch (sort) {
      case LibrarySort.dateAddedDesc:
        return b.addedAt.compareTo(a.addedAt);
      case LibrarySort.dateAddedAsc:
        return a.addedAt.compareTo(b.addedAt);
      case LibrarySort.titleAsc:
        return _normalisedTitle(a.title).compareTo(_normalisedTitle(b.title));
      case LibrarySort.yearDesc:
        return _compareNullLast(a.year, b.year, descending: true);
      case LibrarySort.yearAsc:
        return _compareNullLast(a.year, b.year, descending: false);
      case LibrarySort.runtimeAsc:
        return _compareNullLast(a.runtime, b.runtime, descending: false);
      case LibrarySort.runtimeDesc:
        return _compareNullLast(a.runtime, b.runtime, descending: true);
    }
  });
  return sorted;
}

String _normalisedTitle(String t) {
  final lower = t.trim().toLowerCase();
  if (lower.startsWith('the ')) return lower.substring(4);
  if (lower.startsWith('a ')) return lower.substring(2);
  if (lower.startsWith('an ')) return lower.substring(3);
  return lower;
}

/// Comparator that pins nulls to the end regardless of sort direction.
/// Naive `_compareNullableInt(b, a)` swap-for-desc breaks null-last because
/// the swap moves nulls to the beginning instead. Handle nulls explicitly,
/// then pick ascending vs descending only for the value-vs-value branch.
int _compareNullLast(int? a, int? b, {required bool descending}) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return descending ? b.compareTo(a) : a.compareTo(b);
}
