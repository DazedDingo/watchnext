import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/rating.dart';
import '../../models/watch_entry.dart';
import '../../models/watchlist_item.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/ratings_provider.dart';
import '../../providers/prediction_provider.dart';
import '../../providers/recommendations_provider.dart';
import '../../providers/tmdb_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../providers/watchlist_provider.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/async_error.dart';
import '../../widgets/help_button.dart';
import '../predict/prediction_sheet.dart';
import '../rating/rating_sheet.dart';

const _titleDetailHelp =
    'Everything you can do with a title lives here.\n\n'
    '• Add to watchlist — saves it so both members can see.\n'
    '• Rate — rate 1–5 stars once you\'ve watched. Trakt-linked? Ratings push automatically.\n'
    '• Predict — guess how many stars you\'ll give it before watching, for the prediction game.\n'
    '• See Reveal — shown when you\'ve both predicted and rated, to see who was closer.\n'
    '• AI blurb — a one-liner from the recommender explaining why this one landed on your list.\n'
    '• Household ratings — what each member gave it.';

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
  String? _title;

  @override
  void initState() {
    super.initState();
    final tmdb = ref.read(tmdbServiceProvider);
    _details = widget.mediaType == 'movie'
        ? tmdb.movieDetails(widget.tmdbId)
        : tmdb.tvDetails(widget.tmdbId);
    _details!.then((d) {
      if (mounted) setState(() => _title = (d['title'] ?? d['name']) as String);
    });
  }

  String get _entryId => WatchEntry.buildId(widget.mediaType == 'movie' ? 'movie' : 'tv', widget.tmdbId);
  String get _ratingLevel => widget.mediaType == 'movie' ? 'movie' : 'show';

  bool _watchlistBusy = false;
  bool _watchedBusy = false;

  Future<void> _toggleWatched(Map<String, dynamic> d, {required bool currentlyWatched}) async {
    if (_watchedBusy) return;
    setState(() => _watchedBusy = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final householdId = await ref.read(householdIdProvider.future);
      if (!mounted || uid == null || householdId == null) return;
      final svc = ref.read(watchEntryServiceProvider);
      final mt = widget.mediaType == 'movie' ? 'movie' : 'tv';
      if (currentlyWatched) {
        await svc.unmarkWatched(
          householdId: householdId, uid: uid,
          mediaType: mt, tmdbId: widget.tmdbId,
        );
      } else {
        await svc.markWatched(
          householdId: householdId, uid: uid,
          mediaType: mt, tmdbId: widget.tmdbId,
          details: d,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(currentlyWatched ? 'Marked as unwatched' : 'Marked as watched'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Mark watched failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _watchedBusy = false);
    }
  }

  /// Diffs current-vs-desired scope states and applies add/remove deltas so a
  /// single sheet can promote a title from "nothing" → "both lists" (or any
  /// other combination) in one round-trip.
  Future<void> _applyWatchlistScopes(
    Map<String, dynamic> d, {
    required bool wantShared,
    required bool wantSolo,
    required WatchlistItem? currentShared,
    required WatchlistItem? currentSolo,
  }) async {
    if (_watchlistBusy) return;
    setState(() => _watchlistBusy = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final householdId = await ref.read(householdIdProvider.future);
      if (!mounted || householdId == null) return;
      final svc = ref.read(watchlistServiceProvider);
      final mt = widget.mediaType == 'movie' ? 'movie' : 'tv';
      final title = (d['title'] ?? d['name']) as String;
      final year = _parseYear(d);
      final poster = d['poster_path'] as String?;
      final genres = ((d['genres'] as List?) ?? const [])
          .map((g) => (g as Map)['name'] as String)
          .toList();
      final runtime = _parseRuntime(d);
      final overview = d['overview'] as String?;

      final ops = <Future<void>>[];
      if (wantShared && currentShared == null) {
        ops.add(svc.add(
          householdId: householdId, uid: uid, mediaType: mt,
          tmdbId: widget.tmdbId, title: title, year: year,
          posterPath: poster, genres: genres, runtime: runtime,
          overview: overview, scope: 'shared',
        ));
      } else if (!wantShared && currentShared != null) {
        ops.add(svc.remove(householdId: householdId, id: currentShared.id));
      }
      if (wantSolo && currentSolo == null) {
        ops.add(svc.add(
          householdId: householdId, uid: uid, mediaType: mt,
          tmdbId: widget.tmdbId, title: title, year: year,
          posterPath: poster, genres: genres, runtime: runtime,
          overview: overview, scope: 'solo',
        ));
      } else if (!wantSolo && currentSolo != null) {
        ops.add(svc.remove(householdId: householdId, id: currentSolo.id));
      }
      await Future.wait(ops);

      if (mounted) {
        final msg = !wantShared && !wantSolo
            ? 'Removed from watchlist'
            : 'Watchlist updated';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Watchlist update failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _watchlistBusy = false);
    }
  }

  Future<void> _openScopeSheet(
    Map<String, dynamic> d, {
    required WatchlistItem? currentShared,
    required WatchlistItem? currentSolo,
  }) async {
    final result = await WatchlistScopeSheet.show(
      context,
      initialShared: currentShared != null,
      initialSolo: currentSolo != null,
    );
    if (result == null || !mounted) return;
    await _applyWatchlistScopes(
      d,
      wantShared: result.shared,
      wantSolo: result.solo,
      currentShared: currentShared,
      currentSolo: currentSolo,
    );
  }

  Future<void> _openRatingSheet(Map<String, dynamic> d) async {
    final saved = await RatingSheet.show(
      context,
      level: _ratingLevel,
      targetId: _entryId,
      title: (d['title'] ?? d['name']) as String,
      posterPath: d['poster_path'] as String?,
      traktId: null,
    );
    if (saved == true && mounted) {
      _showRatingSavedSnack();
      // Check if a reveal is now ready for this title.
      final prediction = ref.read(predictionProvider(_entryId)).value;
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (prediction != null && uid != null) {
        final myEntry = prediction.entryFor(uid);
        if (myEntry != null && !myEntry.skipped && !prediction.revealSeenBy(uid)) {
          context.push('/reveal/${widget.mediaType}/${widget.tmdbId}');
        }
      }
    }
  }

  /// Offer an Undo for the rating we just wrote. Delete runs in a fresh
  /// async frame so a stale `mounted` check doesn't swallow it.
  void _showRatingSavedSnack() {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Rating saved'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: _undoRating,
        ),
      ),
    );
  }

  Future<void> _undoRating() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) return;
      await ref.read(ratingServiceProvider).delete(
            householdId: householdId,
            uid: uid,
            level: _ratingLevel,
            targetId: _entryId,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rating removed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Undo failed: $e')),
        );
      }
    }
  }

  Future<void> _openPredictionSheet(Map<String, dynamic> d) async {
    await PredictionSheet.show(
      context,
      mediaType: widget.mediaType,
      tmdbId: widget.tmdbId,
      title: (d['title'] ?? d['name']) as String,
      posterPath: d['poster_path'] as String?,
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
    // Watch the async values directly so a Firestore PERMISSION_DENIED
    // surfaces as a readable error instead of an empty-list silent fail.
    final entriesAsync = ref.watch(watchEntriesProvider);
    final ratingsAsync = ref.watch(ratingsProvider);
    final watchlistAsync = ref.watch(watchlistProvider);
    final firestoreError = entriesAsync.hasError
        ? entriesAsync.error
        : ratingsAsync.hasError
            ? ratingsAsync.error
            : watchlistAsync.hasError
                ? watchlistAsync.error
                : null;
    if (firestoreError != null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.pop()),
          title: Text(_title ?? 'Title'),
          actions: const [
            HelpButton(title: 'Title details', body: _titleDetailHelp)
          ],
        ),
        body: AsyncErrorView(
          error: firestoreError,
          onRetry: () {
            ref.invalidate(watchEntriesProvider);
            ref.invalidate(ratingsProvider);
            ref.invalidate(watchlistProvider);
          },
        ),
      );
    }

    final entries = entriesAsync.value ?? const [];
    final watchEntry = entries.cast<WatchEntry?>().firstWhere(
          (e) => e?.id == _entryId,
          orElse: () => null,
        );
    final ratingsByTarget = ref.watch(ratingsByTargetProvider);
    final ratings = ratingsByTarget[_entryId] ?? const <Rating>[];
    final watchlist = watchlistAsync.value ?? const [];
    final mode = ref.watch(viewModeProvider);
    final uid = ref.watch(authStateProvider).value?.uid;
    final mt = widget.mediaType == 'movie' ? 'movie' : 'tv';
    // Shared copy is visible to both; my solo copy is visible only to me, in Solo mode.
    final sharedEntry = watchlist.cast<WatchlistItem?>().firstWhere(
          (w) => w!.scope == 'shared' && w.mediaType == mt && w.tmdbId == widget.tmdbId,
          orElse: () => null,
        );
    final mySoloEntry = uid == null
        ? null
        : watchlist.cast<WatchlistItem?>().firstWhere(
              (w) => w!.scope == 'solo' &&
                  w.ownerUid == uid &&
                  w.mediaType == mt &&
                  w.tmdbId == widget.tmdbId,
              orElse: () => null,
            );
    final rec = ref.watch(singleRecProvider(_entryId)).value;
    final prediction = ref.watch(predictionProvider(_entryId)).value;
    final myPredEntry = uid != null ? prediction?.entryFor(uid) : null;
    final watchedByMe = uid != null && (watchEntry?.watchedBy[uid] ?? false);
    final hasWatched = watchedByMe;
    // Show Predict button when: not yet watched AND no prediction submitted yet.
    final canPredict = !hasWatched && myPredEntry == null;
    // Show Reveal button when: user predicted (not skipped), has rated, hasn't seen reveal.
    final myRatingLevel = ratings.where((r) => r.uid == uid && r.level == _ratingLevel);
    final canReveal = myPredEntry != null &&
        !myPredEntry.skipped &&
        myRatingLevel.isNotEmpty &&
        !(prediction?.revealSeenBy(uid ?? '') ?? true);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        title: Text(_title ?? (widget.mediaType == 'movie' ? 'Movie' : 'TV Show')),
        actions: const [HelpButton(title: 'Title details', body: _titleDetailHelp)],
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
                  child: Image.network(backdrop, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (poster != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(poster, width: 100, height: 150, fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 100, height: 150,
                          color: const Color(0xFF1A1A1A),
                          child: const Icon(Icons.movie_outlined, color: Colors.white24),
                        )),
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
                      if (watchEntry != null && watchEntry.inProgressStatus == 'watching') ...[
                        const SizedBox(height: 8),
                        const Chip(label: Text('In progress')),
                      ],
                    ]),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, children: [
                  _WatchlistButton(
                    onShared: sharedEntry != null,
                    onSolo: mySoloEntry != null,
                    busy: _watchlistBusy,
                    onTap: () => _openScopeSheet(
                      d,
                      currentShared: sharedEntry,
                      currentSolo: mySoloEntry,
                    ),
                  ),
                  _WatchedButton(
                    watched: watchedByMe,
                    busy: _watchedBusy,
                    onTap: () => _toggleWatched(d, currentlyWatched: watchedByMe),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.star_outline),
                    label: const Text('Rate'),
                    onPressed: () => _openRatingSheet(d),
                  ),
                  if (canPredict)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.psychology_outlined),
                      label: const Text('Predict'),
                      onPressed: () => _openPredictionSheet(d),
                    ),
                  if (canReveal)
                    FilledButton.icon(
                      icon: const Icon(Icons.emoji_events_outlined),
                      label: const Text('See Reveal'),
                      onPressed: () => context.push(
                          '/reveal/${widget.mediaType}/${widget.tmdbId}'),
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
              // AI blurb from Phase 7 scoring — shown when available.
              if (rec != null) ...() {
                final blurb = mode == ViewMode.solo
                    ? rec.blurbFor(uid)
                    : rec.aiBlurb;
                if (blurb.isEmpty) return const <Widget>[];
                return [
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.auto_awesome, size: 14, color: Colors.white38),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            blurb,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Colors.white54, fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    ),
                  ),
                ];
              }(),
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
              // TMDB ships `similar.results` when the detail call uses
              // `append_to_response=similar`, so this is free — no extra fetch.
              _SimilarTitlesSection(
                mediaType: widget.mediaType,
                similar: (d['similar'] as Map<String, dynamic>?)?['results']
                        as List? ??
                    const [],
              ),
              const SizedBox(height: 40),
            ],
          );
        },
      ),
    );
  }
}

// ─── Similar titles carousel ──────────────────────────────────────────────────

/// Horizontal poster carousel of titles TMDB considers similar. Shares the
/// `mediaType` of its parent (TMDB's `/similar` only returns same-type rows).
/// Tapping a card pushes a new TitleDetail onto the stack so the user can
/// drill in, then back out to the original.
class _SimilarTitlesSection extends StatelessWidget {
  final String mediaType;
  final List<dynamic> similar;

  const _SimilarTitlesSection({
    required this.mediaType,
    required this.similar,
  });

  @override
  Widget build(BuildContext context) {
    final rows = similar.whereType<Map<String, dynamic>>().toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Similar titles',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'No similar titles from TMDB for this one.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          )
        else
          SizedBox(
            height: 210,
            child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final row = rows[i];
              final id = (row['id'] as num?)?.toInt();
              if (id == null) return const SizedBox.shrink();
              final title = (row['title'] ?? row['name']) as String? ?? '';
              final poster = TmdbService.imageUrl(
                  row['poster_path'] as String?,
                  size: 'w342');
              final date = (row['release_date'] ?? row['first_air_date'])
                  as String?;
              final year = (date != null && date.length >= 4)
                  ? date.substring(0, 4)
                  : null;
              return GestureDetector(
                onTap: () => context.push('/title/$mediaType/$id'),
                child: SizedBox(
                  width: 110,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: poster != null
                              ? Image.network(poster,
                                  fit: BoxFit.cover,
                                  width: 110,
                                  errorBuilder: (_, _, _) => Container(
                                        color: Colors.white10,
                                        child: const Icon(
                                            Icons.broken_image_outlined,
                                            color: Colors.white30),
                                      ))
                              : Container(
                                  color: Colors.white10,
                                  child: const Icon(Icons.movie_outlined,
                                      color: Colors.white30)),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        year != null ? '$title ($year)' : title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─── Watchlist add/manage button ──────────────────────────────────────────────

/// Single button that reflects the title's combined state across both scopes
/// and opens the scope picker sheet. Replaces the previous split add/remove
/// button so users can toggle Shared and Solo independently.
class _WatchlistButton extends StatelessWidget {
  final bool onShared;
  final bool onSolo;
  final bool busy;
  final VoidCallback onTap;

  const _WatchlistButton({
    required this.onShared,
    required this.onSolo,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final anyScope = onShared || onSolo;
    final icon = anyScope ? Icons.bookmark : Icons.bookmark_add_outlined;
    final label = switch ((onShared, onSolo)) {
      (true, true) => 'On both lists',
      (true, false) => 'On Shared list',
      (false, true) => 'On Solo list',
      (false, false) => 'Add to watchlist',
    };
    if (anyScope) {
      return OutlinedButton.icon(
        icon: Icon(icon),
        label: Text(label),
        onPressed: busy ? null : onTap,
      );
    }
    return FilledButton.icon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: busy ? null : onTap,
    );
  }
}

// ─── Mark-as-watched button ──────────────────────────────────────────────────

class _WatchedButton extends StatelessWidget {
  final bool watched;
  final bool busy;
  final VoidCallback onTap;

  const _WatchedButton({
    required this.watched,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (watched) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.check_circle),
        label: const Text('Watched'),
        onPressed: busy ? null : onTap,
      );
    }
    return FilledButton.tonalIcon(
      icon: const Icon(Icons.visibility_outlined),
      label: const Text('Mark watched'),
      onPressed: busy ? null : onTap,
    );
  }
}

// ─── Scope picker sheet ──────────────────────────────────────────────────────

class WatchlistScopeResult {
  final bool shared;
  final bool solo;
  const WatchlistScopeResult({required this.shared, required this.solo});
}

/// Bottom sheet that lets the user pick which watchlists (Shared, Solo, or
/// both) a title should appear on. Returns null if dismissed without saving
/// so the caller can skip the diff/apply step.
class WatchlistScopeSheet extends StatefulWidget {
  final bool initialShared;
  final bool initialSolo;

  const WatchlistScopeSheet({
    super.key,
    required this.initialShared,
    required this.initialSolo,
  });

  static Future<WatchlistScopeResult?> show(
    BuildContext context, {
    required bool initialShared,
    required bool initialSolo,
  }) =>
      showModalBottomSheet<WatchlistScopeResult>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => WatchlistScopeSheet(
          initialShared: initialShared,
          initialSolo: initialSolo,
        ),
      );

  @override
  State<WatchlistScopeSheet> createState() => _WatchlistScopeSheetState();
}

class _WatchlistScopeSheetState extends State<WatchlistScopeSheet> {
  late bool _shared = widget.initialShared;
  late bool _solo = widget.initialSolo;

  bool get _dirty =>
      _shared != widget.initialShared || _solo != widget.initialSolo;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('Save to watchlist',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Text(
              'Pick one or both. Shared is visible to both members. '
              'Solo is visible only to you, only in Solo mode.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _shared,
              onChanged: (v) => setState(() => _shared = v ?? false),
              title: const Text('Shared watchlist'),
              subtitle: const Text('Both members see it'),
              secondary: const Icon(Icons.group),
              controlAffinity: ListTileControlAffinity.trailing,
            ),
            CheckboxListTile(
              value: _solo,
              onChanged: (v) => setState(() => _solo = v ?? false),
              title: const Text('Solo watchlist'),
              subtitle: const Text('Only you see it, only in Solo mode'),
              secondary: const Icon(Icons.person_outline),
              controlAffinity: ListTileControlAffinity.trailing,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _dirty
                      ? () => Navigator.of(context).pop(
                            WatchlistScopeResult(shared: _shared, solo: _solo),
                          )
                      : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
