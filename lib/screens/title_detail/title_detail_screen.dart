import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/rating.dart';
import '../../models/watch_entry.dart';
import '../../providers/household_provider.dart';
import '../../providers/ratings_provider.dart';
import '../../providers/tmdb_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../providers/watchlist_provider.dart';
import '../../services/tmdb_service.dart';
import '../rating/rating_sheet.dart';

/// Self-loading title detail screen. Route: /title/{mediaType}/{tmdbId}
class TitleDetailScreen extends ConsumerStatefulWidget {
  final String mediaType; // 'movie' | 'tv'
  final int tmdbId;

  const TitleDetailScreen({super.key, required this.mediaType, required this.tmdbId});

  @override
  ConsumerState<TitleDetailScreen> createState() => _TitleDetailScreenState();
}

class _TitleDetailScreenState extends ConsumerState<TitleDetailScreen> {
  Future<Map<String, dynamic>>? _details;

  @override
  void initState() {
    super.initState();
    final tmdb = ref.read(tmdbServiceProvider);
    _details = widget.mediaType == 'movie'
        ? tmdb.movieDetails(widget.tmdbId)
        : tmdb.tvDetails(widget.tmdbId);
  }

  String get _entryId => WatchEntry.buildId(widget.mediaType == 'movie' ? 'movie' : 'tv', widget.tmdbId);
  String get _ratingLevel => widget.mediaType == 'movie' ? 'movie' : 'show';

  Future<void> _addToWatchlist(Map<String, dynamic> d) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final householdId = await ref.read(householdIdProvider.future);
    if (householdId == null) return;
    await ref.read(watchlistServiceProvider).add(
          householdId: householdId,
          uid: uid,
          mediaType: widget.mediaType == 'movie' ? 'movie' : 'tv',
          tmdbId: widget.tmdbId,
          title: (d['title'] ?? d['name']) as String,
          year: _parseYear(d),
          posterPath: d['poster_path'] as String?,
          genres: ((d['genres'] as List?) ?? const []).map((g) => (g as Map)['name'] as String).toList(),
          runtime: _parseRuntime(d),
          overview: d['overview'] as String?,
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to watchlist')));
    }
  }

  Future<void> _removeFromWatchlist() async {
    final householdId = await ref.read(householdIdProvider.future);
    if (householdId == null) return;
    await ref.read(watchlistServiceProvider).remove(
          householdId: householdId,
          id: '${widget.mediaType == 'movie' ? 'movie' : 'tv'}:${widget.tmdbId}',
        );
  }

  Future<void> _openRatingSheet(Map<String, dynamic> d) async {
    await RatingSheet.show(
      context,
      level: _ratingLevel,
      targetId: _entryId,
      title: (d['title'] ?? d['name']) as String,
      posterPath: d['poster_path'] as String?,
      traktId: null, // we don't have the Trakt id here unless we pulled it via /search/tmdb
    );
  }

  int? _parseYear(Map<String, dynamic> d) {
    final s = (d['release_date'] ?? d['first_air_date']) as String?;
    return s == null || s.isEmpty ? null : int.tryParse(s.split('-').first);
  }

  int? _parseRuntime(Map<String, dynamic> d) {
    final r = d['runtime'] as num?;
    if (r != null) return r.toInt();
    final erts = d['episode_run_time'] as List?;
    if (erts != null && erts.isNotEmpty) return (erts.first as num).toInt();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(watchEntriesProvider).value ?? const [];
    final watchEntry = entries.cast<WatchEntry?>().firstWhere(
          (e) => e?.id == _entryId,
          orElse: () => null,
        );
    final ratingsByTarget = ref.watch(ratingsByTargetProvider);
    final ratings = ratingsByTarget[_entryId] ?? const <Rating>[];
    final watchlist = ref.watch(watchlistProvider).value ?? const [];
    final onWatchlist = watchlist.any((w) => w.id == '${widget.mediaType == 'movie' ? 'movie' : 'tv'}:${widget.tmdbId}');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        title: const Text('Title'),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _details,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          final d = snap.data!;
          final title = (d['title'] ?? d['name']) as String;
          final poster = TmdbService.imageUrl(d['poster_path'] as String?, size: 'w342');
          final backdrop = TmdbService.imageUrl(d['backdrop_path'] as String?, size: 'w780');
          final overview = d['overview'] as String?;
          final year = _parseYear(d);
          final runtime = _parseRuntime(d);
          final genres = ((d['genres'] as List?) ?? const []).map((g) => (g as Map)['name'] as String).toList();

          return ListView(
            padding: EdgeInsets.zero,
            children: [
              if (backdrop != null)
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(backdrop, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (poster != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(poster, width: 100, height: 150, fit: BoxFit.cover),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text([
                        if (year != null) '$year',
                        if (runtime != null) '${runtime}m',
                        if (genres.isNotEmpty) genres.take(2).join(' · '),
                      ].join(' · '), style: Theme.of(context).textTheme.labelMedium),
                      if (watchEntry != null) ...[
                        const SizedBox(height: 8),
                        Chip(label: Text(watchEntry.inProgressStatus == 'watching' ? 'In progress' : 'Watched')),
                      ],
                    ]),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, children: [
                  if (onWatchlist)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.bookmark_remove),
                      label: const Text('On watchlist'),
                      onPressed: _removeFromWatchlist,
                    )
                  else
                    FilledButton.icon(
                      icon: const Icon(Icons.bookmark_add),
                      label: const Text('Add to watchlist'),
                      onPressed: () => _addToWatchlist(d),
                    ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.star_outline),
                    label: const Text('Rate'),
                    onPressed: () => _openRatingSheet(d),
                  ),
                ]),
              ),
              if (overview != null && overview.isNotEmpty) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(overview, style: Theme.of(context).textTheme.bodyMedium),
                ),
              ],
              if (ratings.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Household ratings', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                for (final r in ratings.where((r) => r.level == _ratingLevel))
                  ListTile(
                    leading: const Icon(Icons.person),
                    title: Row(children: [
                      for (var i = 0; i < 5; i++)
                        Icon(i < r.stars ? Icons.star : Icons.star_border, size: 16, color: Colors.amber),
                    ]),
                    subtitle: r.note != null ? Text(r.note!) : null,
                    trailing: Text(r.uid == FirebaseAuth.instance.currentUser?.uid ? 'You' : 'Partner'),
                  ),
              ],
              const SizedBox(height: 40),
            ],
          );
        },
      ),
    );
  }
}
