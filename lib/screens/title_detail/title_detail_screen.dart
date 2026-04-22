import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../../models/external_ratings.dart';
import '../../models/rating.dart';
import '../../models/review.dart';
import '../../models/watch_entry.dart';
import '../../models/watchlist_item.dart';
import '../../providers/auth_provider.dart';
import '../../providers/external_ratings_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/include_watched_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/ratings_provider.dart';
import '../../providers/prediction_provider.dart';
import '../../providers/recommendations_provider.dart';
import '../../providers/reviews_provider.dart';
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
    '• Prediction game (more-menu, "⋯") — optional. Predict stars before watching; a dot appears on the menu when a Reveal is ready.\n'
    '• Stremio — opens the title in the Stremio app so you can play it (falls back to the web player if the app isn\'t installed).\n'
    '• IMDb — opens the title in the IMDb app or website.\n'
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
    _details!.then((d) async {
      if (!mounted) return;
      setState(() => _title = (d['title'] ?? d['name']) as String);

      // Opportunistic imdb_id stamp on the rec doc — we already have it
      // from the details payload, so the chip on Home can render without
      // waiting for the background TMDB resolver next refresh.
      final imdb = _imdbIdFor(d);
      if (imdb == null) return;
      final hh = await ref.read(householdIdProvider.future);
      if (hh == null || !mounted) return;
      unawaited(ref
          .read(recommendationsServiceProvider)
          .stampImdbId(
            householdId: hh,
            mediaType: widget.mediaType,
            tmdbId: widget.tmdbId,
            imdbId: imdb,
          ));
    });
  }

  String get _entryId => WatchEntry.buildId(widget.mediaType == 'movie' ? 'movie' : 'tv', widget.tmdbId);
  String get _ratingLevel => widget.mediaType == 'movie' ? 'movie' : 'show';

  bool _watchlistBusy = false;
  bool _watchedBusy = false;
  bool _trailerPlaying = false;

  Widget _dimmable(Widget child) {
    return AnimatedOpacity(
      opacity: _trailerPlaying ? 0.3 : 1.0,
      duration: const Duration(milliseconds: 220),
      child: IgnorePointer(
        ignoring: _trailerPlaying,
        child: child,
      ),
    );
  }

  /// Movies carry `imdb_id` at the top level; TV carries it under
  /// `external_ids.imdb_id` (tvDetails appends `external_ids` to pick it up).
  String? _imdbIdFor(Map<String, dynamic> d) {
    final topLevel = d['imdb_id'] as String?;
    if (topLevel != null && topLevel.isNotEmpty) return topLevel;
    final ext = d['external_ids'] as Map<String, dynamic>?;
    final tvImdb = ext?['imdb_id'] as String?;
    return (tvImdb != null && tvImdb.isNotEmpty) ? tvImdb : null;
  }

  Future<void> _openInStremio(Map<String, dynamic> d) async {
    final imdb = _imdbIdFor(d);
    if (imdb == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No IMDb id — can\'t open in Stremio.')),
      );
      return;
    }
    // Stremio's URL scheme uses "series" for TV, "movie" for movies. The app
    // registers stremio:// on Android; if it isn't installed we fall back to
    // the web player so the user at least lands on the title.
    final type = widget.mediaType == 'tv' ? 'series' : 'movie';
    final appUri = Uri.parse('stremio:///detail/$type/$imdb/$imdb');
    final webUri = Uri.parse('https://web.stremio.com/#/detail/$type/$imdb/$imdb');
    try {
      if (await canLaunchUrl(appUri)) {
        await launchUrl(appUri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open in Stremio failed: $e')),
      );
    }
  }

  Future<void> _openOnImdb(Map<String, dynamic> d) async {
    final imdb = _imdbIdFor(d);
    if (imdb == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No IMDb id available.')),
      );
      return;
    }
    final appUri = Uri.parse('imdb:///title/$imdb/');
    final webUri = Uri.parse('https://www.imdb.com/title/$imdb/');
    try {
      if (await canLaunchUrl(appUri)) {
        await launchUrl(appUri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open in IMDb failed: $e')),
      );
    }
  }

  Future<void> _setWatchStatus(
    Map<String, dynamic> d, {
    required _WatchStatus target,
    required _WatchStatus current,
  }) async {
    if (_watchedBusy || target == current) return;
    setState(() => _watchedBusy = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final householdId = await ref.read(householdIdProvider.future);
      if (!mounted || uid == null || householdId == null) return;
      final svc = ref.read(watchEntryServiceProvider);
      final mt = widget.mediaType == 'movie' ? 'movie' : 'tv';
      String message;
      switch (target) {
        case _WatchStatus.notWatched:
          // Coming from "watched" → clear watched_by[uid].
          // Coming from "watching" → clear in_progress_status.
          if (current == _WatchStatus.watched) {
            await svc.unmarkWatched(
              householdId: householdId, uid: uid,
              mediaType: mt, tmdbId: widget.tmdbId,
            );
          }
          if (current == _WatchStatus.watching) {
            await svc.unmarkWatching(
              householdId: householdId, mediaType: mt, tmdbId: widget.tmdbId,
            );
          }
          message = 'Marked as unwatched';
          break;
        case _WatchStatus.watching:
          await svc.markWatching(
            householdId: householdId, uid: uid,
            mediaType: mt, tmdbId: widget.tmdbId,
            details: d,
          );
          message = 'Marked as watching';
          break;
        case _WatchStatus.watched:
          await svc.markWatched(
            householdId: householdId, uid: uid,
            mediaType: mt, tmdbId: widget.tmdbId,
            details: d,
          );
          // Finishing a title also clears any in-progress flag.
          if (current == _WatchStatus.watching) {
            await svc.unmarkWatching(
              householdId: householdId, mediaType: mt, tmdbId: widget.tmdbId,
            );
          }
          message = 'Marked as watched';
          break;
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
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
    final watchStatus = watchedByMe
        ? _WatchStatus.watched
        : (watchEntry?.inProgressStatus == 'watching'
            ? _WatchStatus.watching
            : _WatchStatus.notWatched);
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
                _dimmable(AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(backdrop, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                )),
              _dimmable(Padding(
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
              )),
              _dimmable(_ActionRow(
                mediaType: widget.mediaType,
                watchStatus: watchStatus,
                watchedBusy: _watchedBusy,
                watchlistBusy: _watchlistBusy,
                onShared: sharedEntry != null,
                onSolo: mySoloEntry != null,
                canPredict: canPredict,
                canReveal: canReveal,
                hasImdb: _imdbIdFor(d) != null,
                onWatchlistTap: () => _openScopeSheet(
                  d,
                  currentShared: sharedEntry,
                  currentSolo: mySoloEntry,
                ),
                onWatchStatus: (target) => _setWatchStatus(
                  d,
                  target: target,
                  current: watchStatus,
                ),
                onRate: () => _openRatingSheet(d),
                onPredict: () => _openPredictionSheet(d),
                onReveal: () =>
                    context.push('/reveal/${widget.mediaType}/${widget.tmdbId}'),
                onStremio: () => _openInStremio(d),
                onImdb: () => _openOnImdb(d),
              )),
              if (overview != null && overview.isNotEmpty)
                _dimmable(Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(overview, style: Theme.of(context).textTheme.bodyMedium),
                )),
              _TrailerSection(
                details: d,
                onPlayingChanged: (playing) {
                  if (!mounted) return;
                  setState(() => _trailerPlaying = playing);
                },
              ),
              _dimmable(_RatingsSourcesSection(
                details: d,
                mediaType: widget.mediaType,
                imdbId: _imdbIdFor(d),
              )),
              _dimmable(_ReviewsSection(
                mediaType: widget.mediaType,
                tmdbId: widget.tmdbId,
              )),
              // AI blurb from Phase 7 scoring — shown when available.
              if (rec != null) ...() {
                final blurb = mode == ViewMode.solo
                    ? rec.blurbFor(uid)
                    : rec.aiBlurb;
                if (blurb.isEmpty) return const <Widget>[];
                return [
                  _dimmable(Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
                  )),
                ];
              }(),
              if (ratings.isNotEmpty)
                _dimmable(Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                )),
              // TMDB ships `similar.results` when the detail call uses
              // `append_to_response=similar`, so this is free — no extra fetch.
              _dimmable(_SimilarTitlesSection(
                mediaType: widget.mediaType,
                similar: (d['similar'] as Map<String, dynamic>?)?['results']
                        as List? ??
                    const [],
              )),
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
class _SimilarTitlesSection extends ConsumerWidget {
  final String mediaType;
  final List<dynamic> similar;

  const _SimilarTitlesSection({
    required this.mediaType,
    required this.similar,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final includeWatched = ref.watch(includeWatchedProvider);
    final watchedKeys =
        includeWatched ? const <String>{} : ref.watch(watchedKeysProvider);
    final rows = similar
        .whereType<Map<String, dynamic>>()
        .where((r) {
          final id = (r['id'] as num?)?.toInt();
          if (id == null) return false;
          return !watchedKeys.contains('$mediaType:$id');
        })
        .toList();
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
/// and opens the scope picker sheet.
enum _WatchStatus { notWatched, watching, watched }

/// Flattened action row — unified compact `OutlinedButton` pills for every
/// primary action, plus an icon-only trailing strip for external deep links.
/// Replaces the previous mix of Filled / FilledTonal / Outlined styles that
/// visually pushed the action area to ~3 rows tall.
class _ActionRow extends StatelessWidget {
  final String mediaType;
  final _WatchStatus watchStatus;
  final bool watchedBusy;
  final bool watchlistBusy;
  final bool onShared;
  final bool onSolo;
  final bool canPredict;
  final bool canReveal;
  final bool hasImdb;
  final VoidCallback onWatchlistTap;
  final ValueChanged<_WatchStatus> onWatchStatus;
  final VoidCallback onRate;
  final VoidCallback onPredict;
  final VoidCallback onReveal;
  final VoidCallback onStremio;
  final VoidCallback onImdb;

  const _ActionRow({
    required this.mediaType,
    required this.watchStatus,
    required this.watchedBusy,
    required this.watchlistBusy,
    required this.onShared,
    required this.onSolo,
    required this.canPredict,
    required this.canReveal,
    required this.hasImdb,
    required this.onWatchlistTap,
    required this.onWatchStatus,
    required this.onRate,
    required this.onPredict,
    required this.onReveal,
    required this.onStremio,
    required this.onImdb,
  });

  String get _watchlistLabel => switch ((onShared, onSolo)) {
        (true, true) => 'On both lists',
        (true, false) => 'On Shared',
        (false, true) => 'On Solo',
        (false, false) => 'Watchlist',
      };

  IconData get _watchlistIcon =>
      (onShared || onSolo) ? Icons.bookmark : Icons.bookmark_add_outlined;

  @override
  Widget build(BuildContext context) {
    final buttonStyle = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      minimumSize: const Size(0, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    Widget pill({
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
    }) =>
        OutlinedButton.icon(
          style: buttonStyle,
          icon: Icon(icon, size: 16),
          label: Text(label, style: const TextStyle(fontSize: 12)),
          onPressed: onPressed,
        );

    Widget watchControl;
    if (mediaType != 'tv') {
      watchControl = pill(
        icon: watchStatus == _WatchStatus.watched
            ? Icons.check_circle
            : Icons.visibility_outlined,
        label:
            watchStatus == _WatchStatus.watched ? 'Watched' : 'Mark watched',
        onPressed: watchedBusy
            ? null
            : () => onWatchStatus(watchStatus == _WatchStatus.watched
                ? _WatchStatus.notWatched
                : _WatchStatus.watched),
      );
    } else {
      watchControl = SegmentedButton<_WatchStatus>(
        segments: const [
          ButtonSegment(
              value: _WatchStatus.notWatched,
              icon: Icon(Icons.radio_button_unchecked, size: 14)),
          ButtonSegment(
              value: _WatchStatus.watching,
              icon: Icon(Icons.play_circle_outline, size: 14)),
          ButtonSegment(
              value: _WatchStatus.watched,
              icon: Icon(Icons.check_circle, size: 14)),
        ],
        selected: {watchStatus},
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 6, vertical: 0)),
          minimumSize: WidgetStatePropertyAll(Size(0, 36)),
        ),
        onSelectionChanged: watchedBusy
            ? null
            : (sel) {
                if (sel.isEmpty) return;
                onWatchStatus(sel.first);
              },
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          pill(
            icon: _watchlistIcon,
            label: _watchlistLabel,
            onPressed: watchlistBusy ? null : onWatchlistTap,
          ),
          watchControl,
          pill(
            icon: Icons.star_outline,
            label: 'Rate',
            onPressed: onRate,
          ),
          if (canPredict || canReveal)
            _PredictOverflowMenu(
              canPredict: canPredict,
              canReveal: canReveal,
              onPredict: onPredict,
              onReveal: onReveal,
            ),
          if (hasImdb) ...[
            _ExternalLinkButton(
              icon: Icons.play_circle_outline,
              label: 'Stremio',
              tooltip: 'Open in Stremio',
              onPressed: onStremio,
            ),
            _ExternalLinkButton(
              icon: Icons.open_in_new,
              label: 'IMDb',
              tooltip: 'Open on IMDb',
              onPressed: onImdb,
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Predict / Reveal overflow menu ──────────────────────────────────────────

/// Demoted entry point for the Predict "game". Predict + See Reveal used to
/// sit as primary action pills, but the flow requires both a pre-watch
/// commitment and a post-watch return visit — friction most sessions skip.
/// Keeping them reachable without eating primary real estate. A small accent
/// dot draws attention when a Reveal is actually waiting (both members have
/// predicted + rated), which is the only state that actively wants the user.
class _PredictOverflowMenu extends StatelessWidget {
  final bool canPredict;
  final bool canReveal;
  final VoidCallback onPredict;
  final VoidCallback onReveal;

  const _PredictOverflowMenu({
    required this.canPredict,
    required this.canReveal,
    required this.onPredict,
    required this.onReveal,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: 'Prediction game',
      padding: EdgeInsets.zero,
      offset: const Offset(0, 36),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.more_horiz, size: 20),
          if (canReveal)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: cs.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
      itemBuilder: (_) => [
        if (canPredict)
          const PopupMenuItem(
            value: 'predict',
            child: Row(
              children: [
                Icon(Icons.psychology_outlined, size: 18),
                SizedBox(width: 12),
                Text('Predict'),
              ],
            ),
          ),
        if (canReveal)
          const PopupMenuItem(
            value: 'reveal',
            child: Row(
              children: [
                Icon(Icons.emoji_events_outlined, size: 18),
                SizedBox(width: 12),
                Text('See Reveal'),
              ],
            ),
          ),
      ],
      onSelected: (v) {
        if (v == 'predict') onPredict();
        if (v == 'reveal') onReveal();
      },
    );
  }
}

// ─── External link button ────────────────────────────────────────────────────

/// Compact icon + tiny label for Stremio / IMDb deep-links. Kept intentionally
/// small (36px tap target, 10.5pt label) so the trailing link strip stays
/// visually subordinate to the primary action pills — the label just removes
/// the "what are those icons?" guessing game.
class _ExternalLinkButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  const _ExternalLinkButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.2,
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ),
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

// ─── Trailer section — expandable in-window YouTube player ───────────────────

/// Picks the best trailer key from TMDB's `videos.results` array.
/// Preference order: official YouTube Trailer → any YouTube Trailer → any
/// YouTube Teaser → any YouTube video. Returns null if nothing usable found.
/// Exposed for unit tests.
String? pickTrailerKey(List<dynamic>? videos) {
  if (videos == null) return null;
  final youTubeVideos = videos
      .whereType<Map<String, dynamic>>()
      .where((v) =>
          (v['site'] as String?)?.toLowerCase() == 'youtube' &&
          (v['key'] as String?)?.isNotEmpty == true)
      .toList();
  if (youTubeVideos.isEmpty) return null;

  String? pick(bool Function(Map<String, dynamic>) matcher) {
    for (final v in youTubeVideos) {
      if (matcher(v)) return v['key'] as String;
    }
    return null;
  }

  return pick((v) =>
          (v['type'] as String?) == 'Trailer' && v['official'] == true) ??
      pick((v) => (v['type'] as String?) == 'Trailer') ??
      pick((v) => (v['type'] as String?) == 'Teaser') ??
      youTubeVideos.first['key'] as String?;
}

class _TrailerSection extends StatefulWidget {
  final Map<String, dynamic> details;
  final ValueChanged<bool>? onPlayingChanged;
  const _TrailerSection({required this.details, this.onPlayingChanged});

  @override
  State<_TrailerSection> createState() => _TrailerSectionState();
}

class _TrailerSectionState extends State<_TrailerSection> {
  YoutubePlayerController? _ctrl;

  String? get _key {
    final videos =
        (widget.details['videos'] as Map<String, dynamic>?)?['results']
            as List?;
    return pickTrailerKey(videos);
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _expand() {
    final key = _key;
    if (key == null) return;
    setState(() {
      _ctrl = YoutubePlayerController(
        initialVideoId: key,
        flags: const YoutubePlayerFlags(
          autoPlay: true,
          mute: false,
        ),
      );
    });
    widget.onPlayingChanged?.call(true);
  }

  void _collapse() {
    _ctrl?.pause();
    _ctrl?.dispose();
    setState(() => _ctrl = null);
    widget.onPlayingChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    if (_key == null) return const SizedBox.shrink();
    if (_ctrl == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: OutlinedButton.icon(
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('Watch trailer'),
          onPressed: _expand,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: YoutubePlayer(
              controller: _ctrl!,
              showVideoProgressIndicator: true,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Hide trailer'),
              onPressed: _collapse,
            ),
          ),
        ],
      ),
    );
  }
}

class _RatingsSourcesSection extends ConsumerWidget {
  final Map<String, dynamic> details;
  final String mediaType;
  final String? imdbId;

  const _RatingsSourcesSection({
    required this.details,
    required this.mediaType,
    required this.imdbId,
  });

  double? get _tmdbAverage {
    final v = details['vote_average'];
    if (v is num) return v.toDouble();
    return null;
  }

  int? get _tmdbVoteCount {
    final v = details['vote_count'];
    if (v is num) return v.toInt();
    return null;
  }

  String get _title {
    final t = (details['title'] ?? details['name']) as String?;
    return t ?? '';
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open link: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tmdbAvg = _tmdbAverage;
    final tmdbVotes = _tmdbVoteCount;
    final title = _title;
    if (tmdbAvg == null && title.isEmpty && imdbId == null) {
      return const SizedBox.shrink();
    }

    // Fetch external ratings (IMDb / RT / Metascore) when we have an imdb id.
    final externalAsync = imdbId != null
        ? ref.watch(externalRatingsProvider(imdbId!))
        : const AsyncValue<ExternalRatings?>.data(null);
    final ext = externalAsync.asData?.value;

    final encodedTitle = Uri.encodeComponent(title);
    final rtUri = Uri.parse(
        'https://www.rottentomatoes.com/search?search=$encodedTitle');
    final letterboxdUri =
        Uri.parse('https://letterboxd.com/search/films/$encodedTitle/');
    final imdbTitleUri = imdbId != null
        ? Uri.parse('https://www.imdb.com/title/$imdbId/')
        : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ratings & reviews',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          // Primary ratings row — IMDb / RT / Metascore / TMDB. Each tile is
          // silent when the corresponding score is missing so sparsely-rated
          // titles don't leave awkward empty boxes.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (ext?.imdbRating != null)
                _ScoreTile(
                  label: 'IMDb',
                  value: ext!.imdbRating!.toStringAsFixed(1),
                  suffix: '/ 10',
                  sub: ext.imdbVotes != null
                      ? _fmtVotes(ext.imdbVotes!)
                      : null,
                  color: const Color(0xFFF5C518),
                  onTap: imdbTitleUri != null
                      ? () => _open(context, imdbTitleUri)
                      : null,
                ),
              if (ext?.rtRating != null)
                _ScoreTile(
                  label: 'Rotten Tomatoes',
                  value: '${ext!.rtRating!.toInt()}',
                  suffix: '%',
                  color: (ext.rtRating! >= 60)
                      ? const Color(0xFFFA320A)
                      : const Color(0xFF00B04F),
                  onTap: () => _open(context, rtUri),
                ),
              if (ext?.metascore != null)
                _ScoreTile(
                  label: 'Metacritic',
                  value: '${ext!.metascore!.toInt()}',
                  suffix: '/ 100',
                  color: _metascoreColor(ext.metascore!),
                ),
              if (tmdbAvg != null)
                _ScoreTile(
                  label: 'TMDB',
                  value: tmdbAvg.toStringAsFixed(1),
                  suffix: '/ 10',
                  sub: tmdbVotes != null ? _fmtVotes(tmdbVotes) : null,
                  color: const Color(0xFF01B4E4),
                ),
            ],
          ),
          if (externalAsync.isLoading && imdbId != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('Loading IMDb & Rotten Tomatoes…',
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (mediaType == 'movie')
                _RatingLinkChip(
                  label: 'Letterboxd',
                  onTap: () => _open(context, letterboxdUri),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmtVotes(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  Color _metascoreColor(double score) {
    if (score >= 61) return const Color(0xFF66CC33);
    if (score >= 40) return const Color(0xFFFFCC33);
    return const Color(0xFFFF0000);
  }
}

/// A compact ratings tile with a coloured accent strip and the score inline.
/// Tappable when [onTap] is non-null — the IMDb and Rotten Tomatoes tiles
/// route to their respective sites when pressed.
class _ScoreTile extends StatelessWidget {
  final String label;
  final String value;
  final String suffix;
  final String? sub;
  final Color color;
  final VoidCallback? onTap;

  const _ScoreTile({
    required this.label,
    required this.value,
    required this.suffix,
    required this.color,
    this.sub,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2),
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 3),
              Text(
                suffix,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              if (sub != null) ...[
                const SizedBox(width: 6),
                Text(
                  sub!,
                  style:
                      const TextStyle(fontSize: 11, color: Colors.white38),
                ),
              ],
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return tile;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: tile,
      ),
    );
  }
}

/// Expandable reviews section — TMDB reviews, collapsed by default so they
/// don't dominate the screen. Shows up to 5 reviews; each is a card with
/// author, rating (if present), and the body (expandable on tap).
class _ReviewsSection extends ConsumerStatefulWidget {
  final String mediaType;
  final int tmdbId;

  const _ReviewsSection({required this.mediaType, required this.tmdbId});

  @override
  ConsumerState<_ReviewsSection> createState() => _ReviewsSectionState();
}

class _ReviewsSectionState extends ConsumerState<_ReviewsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(
      reviewsProvider(TitleRef(widget.mediaType, widget.tmdbId)),
    );
    final reviews = async.asData?.value ?? const <Review>[];

    // Stay silent while loading or when empty — avoids a hollow section on
    // titles TMDB has no reviews for.
    if (reviews.isEmpty) return const SizedBox.shrink();

    final preview = reviews.take(5).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text(
                    'Reviews (${reviews.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            for (final r in preview)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _ReviewCard(review: r),
              ),
        ],
      ),
    );
  }
}

class _ReviewCard extends StatefulWidget {
  final Review review;
  const _ReviewCard({required this.review});

  @override
  State<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends State<_ReviewCard> {
  bool _full = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.review;
    final long = r.content.length > 320;
    final body = (_full || !long) ? r.content : '${r.content.substring(0, 320)}…';
    final date = r.createdAt;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.author,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (r.rating != null) ...[
                const Icon(Icons.star_rounded,
                    size: 14, color: Color(0xFFFFB300)),
                const SizedBox(width: 2),
                Text(
                  '${r.rating!.toStringAsFixed(1)} / 10',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
          if (date != null)
            Text(
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(fontSize: 13, height: 1.35)),
          if (long)
            TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _full = !_full),
              child: Text(_full ? 'Show less' : 'Read more'),
            ),
        ],
      ),
    );
  }
}

class _RatingLinkChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _RatingLinkChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.open_in_new, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
    );
  }
}
