import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/discover_provider.dart';
import '../../providers/include_watched_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/help_button.dart';
import '../../widgets/mode_toggle.dart';

const _discoverHelp =
    'Browse what\'s popular on TMDB without leaving the app.\n\n'
    '• Search — type any title, cast, or keyword; results span movies and TV.\n'
    '• Trending Movies / TV — what\'s hot this week.\n'
    '• New Releases — upcoming and recent.\n'
    '• Top Rated Movies — all-time TMDB highs.\n'
    '• Browse by Genre — tap a genre to open a horizontal row.\n'
    '• Include watched — toggle to show titles already in your history.\n\n'
    'Tap any poster to open its detail screen where you can watchlist or rate it.';

/// Pulls the "{mediaType}:{tmdbId}" identifier out of a TMDB JSON row. Shared
/// between poster sections, genre rows, and search — each passes a fallback
/// media type since only `/search/multi` carries `media_type` inline.
String? _rowKey(Map<String, dynamic> row, {required String fallbackMediaType}) {
  final id = (row['id'] as num?)?.toInt();
  if (id == null) return null;
  final mt = (row['media_type'] as String?) ?? fallbackMediaType;
  return '$mt:$id';
}

List<Map<String, dynamic>> _filterWatched(
  List<Map<String, dynamic>> rows,
  Set<String> watchedKeys, {
  required String fallbackMediaType,
}) {
  if (watchedKeys.isEmpty) return rows;
  return rows.where((r) {
    final key = _rowKey(r, fallbackMediaType: fallbackMediaType);
    return key == null || !watchedKeys.contains(key);
  }).toList();
}

const _searchDebounce = Duration(milliseconds: 350);

// TMDB movie genre definitions used for Browse by Genre.
const _kGenres = [
  (id: 28, name: 'Action'),
  (id: 12, name: 'Adventure'),
  (id: 16, name: 'Animation'),
  (id: 35, name: 'Comedy'),
  (id: 80, name: 'Crime'),
  (id: 99, name: 'Documentary'),
  (id: 18, name: 'Drama'),
  (id: 14, name: 'Fantasy'),
  (id: 27, name: 'Horror'),
  (id: 9648, name: 'Mystery'),
  (id: 10749, name: 'Romance'),
  (id: 878, name: 'Sci-Fi'),
  (id: 53, name: 'Thriller'),
  (id: 37, name: 'Western'),
];

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (!mounted) return;
      ref.read(searchQueryProvider.notifier).state = value.trim();
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchCtrl.clear();
    ref.read(searchQueryProvider.notifier).state = '';
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final searching = query.isNotEmpty;
    final includeWatched = ref.watch(includeWatchedProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 4),
            child: Center(child: ModeToggle()),
          ),
          HelpButton(title: 'Discover', body: _discoverHelp),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search movies & TV',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _clearSearch();
                          setState(() {});
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.visibility_outlined,
                    size: 16, color: Colors.white54),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Include watched',
                      style: TextStyle(fontSize: 13, color: Colors.white70)),
                ),
                Switch(
                  value: includeWatched,
                  onChanged: (v) =>
                      ref.read(includeWatchedProvider.notifier).set(v),
                ),
              ],
            ),
          ),
          Expanded(
            child: searching ? const _SearchResults() : const _BrowseContent(),
          ),
        ],
      ),
    );
  }
}

class _BrowseContent extends ConsumerWidget {
  const _BrowseContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final includeWatched = ref.watch(includeWatchedProvider);
    final watchedKeys = includeWatched
        ? const <String>{}
        : ref.watch(watchedKeysProvider);
    return ListView(
      children: [
        _PosterSection(
          title: 'TRENDING MOVIES',
          data: ref.watch(trendingMoviesProvider),
          mediaType: 'movie',
          watchedKeys: watchedKeys,
        ),
        _PosterSection(
          title: 'TRENDING TV',
          data: ref.watch(trendingTvProvider),
          mediaType: 'tv',
          watchedKeys: watchedKeys,
        ),
        _PosterSection(
          title: 'NEW RELEASES',
          data: ref.watch(upcomingMoviesProvider),
          mediaType: 'movie',
          watchedKeys: watchedKeys,
        ),
        _PosterSection(
          title: 'TOP RATED MOVIES',
          data: ref.watch(topRatedMoviesProvider),
          mediaType: 'movie',
          watchedKeys: watchedKeys,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            'BROWSE BY GENRE',
            style: TextStyle(
                letterSpacing: 1.2, fontSize: 12, color: Colors.white54),
          ),
        ),
        ..._kGenres.map((g) => _GenreRow(genreId: g.id, genreName: g.name)),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(searchResultsProvider);
    final includeWatched = ref.watch(includeWatchedProvider);
    final watchedKeys = includeWatched
        ? const <String>{}
        : ref.watch(watchedKeysProvider);
    return data.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, _) => const Center(
        child:
            Text('Search failed', style: TextStyle(color: Colors.white38)),
      ),
      data: (raw) {
        final items = _filterWatched(
          raw.cast<Map<String, dynamic>>(),
          watchedKeys,
          fallbackMediaType: 'movie',
        );
        if (items.isEmpty) {
          return const Center(
            child: Text('No matches',
                style: TextStyle(color: Colors.white38)),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2 / 3,
          ),
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final item = items[i];
            final tmdbId = (item['id'] as num?)?.toInt();
            if (tmdbId == null) return const SizedBox.shrink();
            final mt = (item['media_type'] as String?) ?? 'movie';
            final poster = TmdbService.imageUrl(
                item['poster_path'] as String?,
                size: 'w342');
            return _PosterTile(
              poster: poster,
              onTap: () => ctx.push('/title/$mt/$tmdbId'),
              fill: true,
            );
          },
        );
      },
    );
  }
}

// ─── Horizontal poster section ────────────────────────────────────────────────

class _PosterSection extends StatelessWidget {
  final String title;
  final AsyncValue<List<Map<String, dynamic>>> data;
  final String mediaType;
  final Set<String> watchedKeys;

  const _PosterSection({
    required this.title,
    required this.data,
    required this.mediaType,
    required this.watchedKeys,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            title,
            style: const TextStyle(
                letterSpacing: 1.2, fontSize: 12, color: Colors.white54),
          ),
        ),
        SizedBox(
          height: 160,
          child: data.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (_, _) => const Center(
              child: Text('Failed to load',
                  style: TextStyle(color: Colors.white38)),
            ),
            data: (raw) {
              final items = _filterWatched(raw, watchedKeys,
                  fallbackMediaType: mediaType);
              if (items.isEmpty) {
                return const Center(
                  child: Text("You've seen them all.",
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                );
              }
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final item = items[i];
                  final tmdbId = (item['id'] as num?)?.toInt();
                  final mt =
                      (item['media_type'] as String?) ?? mediaType;
                  if (tmdbId == null) return const SizedBox.shrink();
                  final poster = TmdbService.imageUrl(
                      item['poster_path'] as String?,
                      size: 'w185');
                  return _PosterTile(
                    poster: poster,
                    onTap: () => ctx.push('/title/$mt/$tmdbId'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─── Browse by genre expandable row ──────────────────────────────────────────
//
// Once the user expands the row, [_opened] sticks to true so the body stays
// mounted across collapse/re-expand cycles. Earlier the body lived inside an
// `if (_expanded) Consumer(...)` gate captured in the children list at build
// time; the rebuild after `setState` raced with ExpansionTile's expansion
// animation and the inner Consumer never observed the FutureProvider's
// resolution — the symptom was a spinner that never went away.

class _GenreRow extends ConsumerStatefulWidget {
  final int genreId;
  final String genreName;

  const _GenreRow({required this.genreId, required this.genreName});

  @override
  ConsumerState<_GenreRow> createState() => _GenreRowState();
}

class _GenreRowState extends ConsumerState<_GenreRow> {
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text(widget.genreName),
      childrenPadding: EdgeInsets.zero,
      onExpansionChanged: (v) {
        if (v && !_opened) setState(() => _opened = true);
      },
      children: _opened
          ? [_GenreRowBody(genreId: widget.genreId)]
          : const [],
    );
  }
}

class _GenreRowBody extends ConsumerWidget {
  final int genreId;
  const _GenreRowBody({required this.genreId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(discoverByGenreProvider(genreId));
    final includeWatched = ref.watch(includeWatchedProvider);
    final watchedKeys = includeWatched
        ? const <String>{}
        : ref.watch(watchedKeysProvider);
    return SizedBox(
      height: 172,
      child: data.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (_, _) => const Center(
          child:
              Text('Failed to load', style: TextStyle(color: Colors.white38)),
        ),
        data: (raw) {
          final items = _filterWatched(raw, watchedKeys,
              fallbackMediaType: 'movie');
          if (items.isEmpty) {
            return const Center(
              child: Text('No titles in this genre',
                  style: TextStyle(color: Colors.white38)),
            );
          }
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final item = items[i];
              final tmdbId = (item['id'] as num?)?.toInt();
              if (tmdbId == null) return const SizedBox.shrink();
              final poster = TmdbService.imageUrl(
                  item['poster_path'] as String?,
                  size: 'w185');
              return _PosterTile(
                poster: poster,
                onTap: () => ctx.push('/title/movie/$tmdbId'),
              );
            },
          );
        },
      ),
    );
  }
}

// ─── Single poster tile ───────────────────────────────────────────────────────

class _PosterTile extends StatelessWidget {
  final String? poster;
  final VoidCallback onTap;

  /// When true, the tile fills its parent (used by the search grid).
  /// When false, it renders at a fixed 107×160 (used by the browse rows).
  final bool fill;

  const _PosterTile({
    required this.poster,
    required this.onTap,
    this.fill = false,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: Colors.grey.shade900,
      alignment: Alignment.center,
      child: const Icon(Icons.movie, color: Colors.white24),
    );
    final image = poster != null
        ? Image.network(
            poster!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          )
        : placeholder;

    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: image,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: fill
          ? clipped
          : SizedBox(width: 107, height: 160, child: clipped),
    );
  }
}
