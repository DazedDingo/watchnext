import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/discover_provider.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/mode_toggle.dart';

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

class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: ModeToggle()),
          ),
        ],
      ),
      body: ListView(
        children: [
          _PosterSection(
            title: 'TRENDING MOVIES',
            data: ref.watch(trendingMoviesProvider),
            mediaType: 'movie',
          ),
          _PosterSection(
            title: 'TRENDING TV',
            data: ref.watch(trendingTvProvider),
            mediaType: 'tv',
          ),
          _PosterSection(
            title: 'NEW RELEASES',
            data: ref.watch(upcomingMoviesProvider),
            mediaType: 'movie',
          ),
          _PosterSection(
            title: 'TOP RATED MOVIES',
            data: ref.watch(topRatedMoviesProvider),
            mediaType: 'movie',
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
      ),
    );
  }
}

// ─── Horizontal poster section ────────────────────────────────────────────────

class _PosterSection extends StatelessWidget {
  final String title;
  final AsyncValue<List<Map<String, dynamic>>> data;
  final String mediaType;

  const _PosterSection({
    required this.title,
    required this.data,
    required this.mediaType,
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
            data: (items) => ListView.separated(
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
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Browse by genre expandable row ──────────────────────────────────────────

class _GenreRow extends ConsumerStatefulWidget {
  final int genreId;
  final String genreName;

  const _GenreRow({required this.genreId, required this.genreName});

  @override
  ConsumerState<_GenreRow> createState() => _GenreRowState();
}

class _GenreRowState extends ConsumerState<_GenreRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text(widget.genreName),
      onExpansionChanged: (v) => setState(() => _expanded = v),
      children: [
        if (_expanded)
          Consumer(
            builder: (ctx, ref, _) {
              final data = ref.watch(discoverByGenreProvider(widget.genreId));
              return SizedBox(
                height: 172,
                child: data.when(
                  loading: () => const Center(
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  error: (_, _) => const Center(
                    child: Text('Failed to load',
                        style: TextStyle(color: Colors.white38)),
                  ),
                  data: (items) => ListView.separated(
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
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

// ─── Single poster tile ───────────────────────────────────────────────────────

class _PosterTile extends StatelessWidget {
  final String? poster;
  final VoidCallback onTap;

  const _PosterTile({required this.poster, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: poster != null
            ? Image.network(poster!, width: 107, height: 160, fit: BoxFit.cover)
            : Container(
                width: 107,
                height: 160,
                color: Colors.grey.shade900,
                child: const Icon(Icons.movie, color: Colors.white24),
              ),
      ),
    );
  }
}
