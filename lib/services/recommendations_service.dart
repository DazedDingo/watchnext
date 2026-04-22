import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/recommendation.dart';
import '../models/watchlist_item.dart';
import '../providers/curated_source_provider.dart';
import '../providers/media_type_filter_provider.dart';
import '../providers/runtime_filter_provider.dart';
import '../providers/sort_mode_provider.dart';
import '../providers/year_filter_provider.dart';
import '../utils/tmdb_genres.dart';
import 'tmdb_service.dart';

/// Client for Phase 7's scored-recommendations pipeline:
/// - `refreshTasteProfile` → CF that recomputes `/tasteProfile` from ratings.
/// - `refresh` → assembles candidates (watchlist + trending), writes them to
///   `/recommendations` directly with default scores so the Home stream has
///   a pool to show immediately, then fires the `scoreRecommendations` CF
///   in the background so Claude can replace the defaults with real scores
///   asynchronously.
///
/// Why the two-phase write: the Claude scorer takes 20–60s end-to-end
/// (sequential batches of 10 + a taste-profile refresh). Blocking the
/// pull-to-refresh spinner on that was the "refresh spins forever" UX — now
/// we return after the Firestore batch write (<5s) and let scoring catch up.
/// The scheduled `processRescoreQueue` CF mops up any batches that fail.
///
/// Streams + ad-hoc reads are kept here so providers stay thin.
class RecommendationsService {
  final FirebaseFirestore _db;
  final FirebaseFunctions? _fnsOverride;
  final TmdbService _tmdb;

  /// Monotonic refresh counter used to drop stale concurrent refreshes before
  /// they mutate Firestore. The Home screen debounces filter changes at 700ms
  /// but still permits concurrent `refresh(...)` calls when the user churns
  /// filters faster than TMDB can respond (TMDB fan-out is 1–3s). Without this
  /// guard, an older refresh could finish its TMDB fetches last, then
  /// overwrite the newer refresh's Firestore pool — the "options flip back a
  /// few seconds later" symptom. The guard is checked before the Firestore
  /// write and before kicking off background Claude scoring; the stale
  /// refresh's TMDB fetches still run but are discarded silently.
  int _refreshEpoch = 0;

  RecommendationsService({
    FirebaseFirestore? db,
    FirebaseFunctions? fns,
    TmdbService? tmdb,
  })  : _db = db ?? FirebaseFirestore.instance,
        _fnsOverride = fns,
        _tmdb = tmdb ?? TmdbService();

  // Lazy so pure Firestore-only paths (e.g. `writeCandidateDocs` in tests)
  // don't spin up a Firebase app just to construct the callables client.
  // Callables live in europe-west2 (co-located with Firestore in London).
  FirebaseFunctions get _fns =>
      _fnsOverride ?? FirebaseFunctions.instanceFor(region: 'europe-west2');

  CollectionReference<Map<String, dynamic>> _col(String hh) =>
      _db.collection('households/$hh/recommendations');

  /// Stream window is deliberately wide (300) because Phase A writes
  /// newly-discovered rows at `match_score=50` — if legacy Claude-scored
  /// recs fill the first 120 slots, a narrow filter (e.g. "Comedy + 1975-
  /// 2000 + 90-120min") would see nothing until Claude finishes scoring the
  /// new batch and bumps some above 50. Wider window keeps the new rows
  /// visible to the client-side filter from the moment Phase A lands.
  Stream<List<Recommendation>> stream(String householdId) {
    return _col(householdId)
        .orderBy('match_score', descending: true)
        .limit(300)
        .snapshots()
        .map((s) => s.docs.map(Recommendation.fromDoc).toList());
  }

  Future<List<Recommendation>> fetchTopForDecide(
    String householdId, {
    int limit = 20,
    Set<String> exclude = const {},
  }) async {
    final snap = await _col(householdId)
        .orderBy('match_score', descending: true)
        .limit(limit + exclude.length)
        .get();
    return snap.docs
        .map(Recommendation.fromDoc)
        .where((r) => !exclude.contains('${r.mediaType}:${r.tmdbId}'))
        .take(limit)
        .toList();
  }

  Future<void> refreshTasteProfile(String householdId) async {
    await _fns
        .httpsCallable('generateTasteProfile')
        .call({'householdId': householdId});
  }

  /// Builds a candidate pool from the shared watchlist plus four TMDB
  /// sources (trending movies + TV, top-rated movies + TV) and Reddit buzz,
  /// writes them to `/recommendations` with default scores so Home has a
  /// pool to show, then fires the Claude scorer in the background.
  ///
  /// Returns as soon as the Firestore batch write is done (typically <5s),
  /// so the pull-to-refresh spinner doesn't have to wait on the 20–60s
  /// Claude scoring loop. Pre-existing scored recs keep their scores
  /// (we skip score fields on merge for keys already in the collection);
  /// genuinely new candidates land at `match_score=50, scored=false` and
  /// get bumped by the background Claude pass.
  ///
  /// Each TMDB source is fetched independently and best-effort: a failure
  /// in one (e.g. TMDB rate-limit on top-rated) doesn't blank the pool.
  /// [tmdbCap] defaults to 10 per source — with four sources that's up to 40
  /// TMDB candidates, plus watchlist + Reddit + discover (when filters are
  /// active, the bigger `discoverCap` kicks in per source).
  ///
  /// When [forceTasteProfile] is true, the taste profile is regenerated
  /// alongside the background score pass — refresh UX: scores reflect the
  /// latest ratings on the *next* stream update after this pass.
  /// TMDB keyword id for the "oscar-winning-film" keyword. Used to narrow
  /// the discover pool to Academy-Award-winning titles when the user has
  /// the Oscar Winners filter on. Constant here (rather than buried in the
  /// caller) so tests can assert the param made it through.
  static const int kOscarKeywordId = 210024;

  /// TMDB's Animation genre id. Same id on movie + TV genre lists. Used by
  /// the `excludeAnimation` filter to pass `without_genres=16` to
  /// `/discover` and to drop animation-tagged rows from baseline TMDB
  /// sources in `buildCandidates`.
  static const int kAnimationGenreId = 16;

  Future<void> refresh(
    String householdId, {
    required List<WatchlistItem> watchlist,
    int tmdbCap = 10,
    Set<String> genreFilters = const {},
    YearRange yearRange = const YearRange.unbounded(),
    RuntimeBucket? runtimeBucket,
    MediaTypeFilter? mediaTypeFilter,
    bool oscarOnly = false,
    bool excludeAnimation = false,
    SortMode sortMode = SortMode.topRated,
    CuratedSource curatedSource = CuratedSource.none,
    bool forceTasteProfile = false,
  }) async {
    // Claim this refresh's epoch up-front. If a newer refresh starts before
    // our TMDB fetches return, `_refreshEpoch` will advance past `myEpoch`
    // and the guards below the TMDB fan-out will bail silently without
    // touching Firestore. Both refreshes finish fetching — we only short-
    // circuit the mutation side so the last-to-start refresh is the one
    // whose pool lands, regardless of which finishes TMDB first.
    final myEpoch = ++_refreshEpoch;

    List<Map<String, dynamic>> redditRows = const [];
    try {
      final snap = await _db
          .collection('redditMentions')
          .orderBy('mention_score', descending: true)
          .limit(20)
          .get();
      redditRows = snap.docs.map((d) => d.data()).toList();
    } catch (_) {
      // Best-effort; no Reddit data is fine.
    }

    // Baseline four sources: trending + top_rated per media type. Suppressed
    // when the user picks Underseen sort or a curated source — popularity-
    // driven baselines would dilute those signals.
    final suppressBaseline =
        sortMode.suppressBaseline || curatedSource != CuratedSource.none;
    final baseline = suppressBaseline
        ? const <Map<String, dynamic>>[{}, {}, {}, {}]
        : await Future.wait([
            _safeTmdb(() => _tmdb.trendingMovies()),
            _safeTmdb(() => _tmdb.trendingTv()),
            _safeTmdb(() => _tmdb.topRatedMovies()),
            _safeTmdb(() => _tmdb.topRatedTv()),
          ]);

    // Discover sources fire when the user has narrowed the request in any
    // way — including picking a runtime bucket or media type. Trending/
    // top-rated payloads strip runtime, so discover is the only source that
    // can guarantee a runtime-matching pool (TMDB server-side filters via
    // `with_runtime.*`). When a media-type filter is active we only fire the
    // matching discover request — no point spending TMDB quota on rows the
    // client-side filter will drop anyway.
    Map<String, dynamic> discoverMovies = const {};
    Map<String, dynamic> discoverTv = const {};
    final hasFilters = genreFilters.isNotEmpty ||
        yearRange.hasAnyBound ||
        runtimeBucket != null ||
        mediaTypeFilter != null ||
        oscarOnly ||
        excludeAnimation ||
        sortMode != SortMode.topRated ||
        curatedSource != CuratedSource.none;
    final fetchMovies = mediaTypeFilter != MediaTypeFilter.tv;
    final fetchTv = mediaTypeFilter != MediaTypeFilter.movie;
    if (hasFilters) {
      final movieIds = genreIdsFromNames(genreFilters, mediaType: 'movie');
      final tvIds = genreIdsFromNames(genreFilters, mediaType: 'tv');
      final keywordIds = oscarOnly ? const [kOscarKeywordId] : const <int>[];
      // If the user explicitly picked Animation as a genre, the exclude toggle
      // is self-contradictory — honour the explicit pick and skip the exclude.
      final excludeIds = (excludeAnimation &&
              !genreFilters.contains('Animation'))
          ? const [kAnimationGenreId]
          : const <int>[];
      final discoverResults = await Future.wait([
        if (fetchMovies)
          _safeTmdb(() => _tmdb.discoverPaged(
                mediaType: 'movie',
                genreIds: movieIds,
                keywordIds: keywordIds,
                excludeGenreIds: excludeIds,
                withCompanies: curatedSource.withCompanies,
                sortBy: sortMode.tmdbSortBy('movie'),
                maxVoteCount: sortMode.maxVoteCount,
                minYear: yearRange.minYear,
                maxYear: yearRange.maxYear,
                minRuntime: runtimeBucket?.minRuntime,
                maxRuntime: runtimeBucket?.maxRuntime,
              )),
        if (fetchTv)
          _safeTmdb(() => _tmdb.discoverPaged(
                mediaType: 'tv',
                genreIds: tvIds,
                keywordIds: keywordIds,
                excludeGenreIds: excludeIds,
                withCompanies: curatedSource.withCompanies,
                sortBy: sortMode.tmdbSortBy('tv'),
                maxVoteCount: sortMode.maxVoteCount,
                minYear: yearRange.minYear,
                maxYear: yearRange.maxYear,
                minRuntime: runtimeBucket?.minRuntime,
                maxRuntime: runtimeBucket?.maxRuntime,
              )),
      ]);
      var i = 0;
      if (fetchMovies) discoverMovies = discoverResults[i++];
      if (fetchTv) discoverTv = discoverResults[i++];

      // `/discover` filters server-side via `with_runtime.*` but doesn't echo
      // `runtime` in its result rows. Stamp a representative runtime so the
      // Home-screen runtime filter (strict mode when a bucket is active) can
      // match these candidates. The stamp is a server-truth: TMDB already
      // confirmed the runtime is in-bounds before returning the row.
      if (runtimeBucket != null) {
        final synthetic =
            runtimeBucket.minRuntime ?? (runtimeBucket.maxRuntime ?? 90) - 1;
        for (final payload in [discoverMovies, discoverTv]) {
          final rows = payload['results'] as List? ?? const [];
          for (final r in rows) {
            if (r is Map<String, dynamic>) r.putIfAbsent('runtime', () => synthetic);
          }
        }
      }
    }

    final candidates = buildCandidates(
      watchlist: watchlist,
      redditMentions: redditRows,
      trendingMoviesPayload: baseline[0],
      trendingTvPayload: baseline[1],
      topRatedMoviesPayload: baseline[2],
      topRatedTvPayload: baseline[3],
      discoverMoviesPayload: discoverMovies,
      discoverTvPayload: discoverTv,
      discoverIsOscar: oscarOnly,
      discoverCurator: curatedSource == CuratedSource.none
          ? ''
          : curatedSource.name,
      excludeAnimation:
          excludeAnimation && !genreFilters.contains('Animation'),
      tmdbCap: tmdbCap,
    );

    if (candidates.isEmpty) return;

    // Epoch guard: if another refresh started after us, its Firestore write
    // is the authoritative one — bail before we stomp it. See `_refreshEpoch`
    // doc above for the race this prevents.
    if (myEpoch != _refreshEpoch) return;

    // Phase A — sync: write the pool to Firestore with default scores so
    // the Home stream lights up immediately. This is the bit the user waits
    // on. Pre-existing rec keys keep their scores (merge skips score fields).
    await writeCandidateDocs(householdId, candidates);

    // Re-check after the Firestore write: an even-newer refresh could have
    // landed while we were writing. Don't fire a stale Claude pass — its
    // candidate list is now out-of-date vs. the pool in Firestore.
    if (myEpoch != _refreshEpoch) return;

    // Phase B — async: taste-profile refresh (if forced) + Claude scoring.
    // Fire-and-forget: any failure leaves the pool intact at default scores,
    // and `processRescoreQueue` re-scores on its 10-min sweep anyway.
    unawaited(_backgroundScore(
      householdId: householdId,
      candidates: candidates,
      forceTasteProfile: forceTasteProfile,
    ));
  }

  /// Writes each candidate to `/households/{hh}/recommendations/{key}`. For
  /// keys already present in the collection we merge only metadata fields —
  /// `match_score` / `ai_blurb` / `scored` are left alone so a previously
  /// Claude-scored rec doesn't visibly drop back to 50%. New keys get the
  /// default score seeded so they sort into the stream's top-120 window.
  ///
  /// Chunks writes into Firestore's 500-op batch limit. Exposed for tests.
  Future<void> writeCandidateDocs(
    String householdId,
    List<Map<String, dynamic>> candidates,
  ) async {
    if (candidates.isEmpty) return;
    final col = _col(householdId);

    // Look up which candidate ids are already scored so we preserve their
    // score on merge. Cap matches the stream window so we don't accidentally
    // reset scores on recs the UI is actively showing.
    final existingSnap = await col.limit(800).get();
    final existingIds = existingSnap.docs.map((d) => d.id).toSet();

    const chunkSize = 450; // stay below Firestore's 500-op batch limit
    for (var start = 0; start < candidates.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, candidates.length);
      final batch = _db.batch();
      for (var i = start; i < end; i++) {
        final c = candidates[i];
        final mediaType = c['media_type'];
        final tmdbId = c['tmdb_id'];
        if (mediaType is! String || tmdbId is! int) continue;
        final key = '$mediaType:$tmdbId';

        final data = <String, dynamic>{
          'media_type': mediaType,
          'tmdb_id': tmdbId,
          'title': c['title'],
          'year': c['year'],
          'poster_path': c['poster_path'],
          'genres': c['genres'] ?? const <String>[],
          'runtime': c['runtime'],
          'overview': c['overview'],
          'source': c['source'] ?? 'unknown',
          'generated_at': FieldValue.serverTimestamp(),
        };
        // Sticky tag: only write the oscar flag when this batch confirmed
        // it. A row that came through trending today won't have the field
        // and Firestore's merge semantics leave any previously-written
        // `is_oscar_winner=true` untouched.
        if (c['is_oscar_winner'] == true) {
          data['is_oscar_winner'] = true;
        }
        // Same sticky pattern for the curator tag — only write when this
        // batch's discover pass confirmed the curator. Baseline rows omit
        // the field so a prior `curator: 'criterion'` survives the merge.
        final curator = c['curator'];
        if (curator is String && curator.isNotEmpty) {
          data['curator'] = curator;
        }
        if (!existingIds.contains(key)) {
          // Seed default score fields only on first write — protects any
          // Claude-set match_score on a rec that's already been scored.
          data['match_score'] = 50;
          data['match_score_solo'] = const <String, int>{};
          data['ai_blurb'] = '';
          data['ai_blurb_solo'] = const <String, String>{};
          data['scored'] = false;
        }
        batch.set(col.doc(key), data, SetOptions(merge: true));
      }
      await batch.commit();
    }
  }

  Future<void> _backgroundScore({
    required String householdId,
    required List<Map<String, dynamic>> candidates,
    required bool forceTasteProfile,
  }) async {
    try {
      if (forceTasteProfile) {
        await refreshTasteProfile(householdId);
      }
      await _fns.httpsCallable('scoreRecommendations').call({
        'householdId': householdId,
        'candidates': candidates,
      });
    } catch (err, stack) {
      // Swallow — the default-scored pool from Phase A is still on screen,
      // and the scheduled rescore CF will pick up anything we miss. Logged
      // to devtools so we can spot systemic failures without spamming UI.
      developer.log(
        'background scoring failed',
        name: 'RecommendationsService',
        error: err,
        stackTrace: stack,
      );
    }
  }

  /// Runs a TMDB fetch and swallows any error into an empty payload so
  /// `Future.wait` never rejects on a single transient TMDB failure.
  Future<Map<String, dynamic>> _safeTmdb(
    Future<Map<String, dynamic>> Function() fetch,
  ) async {
    try {
      return await fetch();
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}

/// Pure candidate-list builder — exposed for testing. Merges watchlist,
/// Reddit mentions, and four TMDB sources (trending movies + TV, top-rated
/// movies + TV) into the payload shape the `scoreRecommendations` CF
/// expects. Handles genre resolution (id → name) so the mood-pill filter
/// has something to match against.
///
/// Order: watchlist first, then Reddit, then TMDB sources in declaration
/// order. Dedup by `{mediaType}:{tmdbId}`. Each TMDB source is capped to
/// [tmdbCap] rows individually so one noisy source can't crowd out the
/// others.
List<Map<String, dynamic>> buildCandidates({
  required List<WatchlistItem> watchlist,
  List<Map<String, dynamic>> redditMentions = const [],
  Map<String, dynamic> trendingMoviesPayload = const {},
  Map<String, dynamic> trendingTvPayload = const {},
  Map<String, dynamic> topRatedMoviesPayload = const {},
  Map<String, dynamic> topRatedTvPayload = const {},
  Map<String, dynamic> discoverMoviesPayload = const {},
  Map<String, dynamic> discoverTvPayload = const {},
  bool discoverIsOscar = false,
  String discoverCurator = '',
  bool excludeAnimation = false,
  int tmdbCap = 20,
  int discoverCap = 40,
}) {
  final candidates = <Map<String, dynamic>>[];
  final seen = <String>{};

  for (final w in watchlist) {
    final key = '${w.mediaType}:${w.tmdbId}';
    if (seen.add(key)) {
      candidates.add({
        'media_type': w.mediaType,
        'tmdb_id': w.tmdbId,
        'title': w.title,
        'year': w.year,
        'poster_path': w.posterPath,
        'genres': w.genres,
        'runtime': w.runtime,
        'overview': w.overview,
        'source': 'watchlist',
      });
    }
  }

  for (final m in redditMentions) {
    final id = (m['tmdb_id'] as num?)?.toInt();
    if (id == null) continue;
    final mediaType = (m['media_type'] as String?) ?? 'movie';
    final key = '$mediaType:$id';
    if (!seen.add(key)) continue;
    candidates.add({
      'media_type': mediaType,
      'tmdb_id': id,
      'title': m['title'] as String? ?? 'Untitled',
      'year': (m['year'] as num?)?.toInt(),
      'poster_path': m['poster_path'] as String?,
      'genres': coerceGenres(m['genres'] ?? m['genre_ids'], mediaType: mediaType),
      'runtime': (m['runtime'] as num?)?.toInt(),
      'overview': m['overview'] as String?,
      'source': 'reddit',
    });
  }

  // TMDB sources: each has a default media_type (used when the row shape
  // doesn't carry one), a source tag so the UI can badge it, and a per-
  // source row cap. Discover sources get a larger cap because the user
  // explicitly narrowed the query — crowding out baseline pool by up to
  // `discoverCap` rows each is the whole point.
  // Discover sources lead the TMDB merge order so a hot Oscar winner that
  // also happens to be trending wins the `is_oscar_winner` tag instead of
  // getting silently re-labelled as `source: 'trending'` by the dedup. The
  // user-narrowed query is more informative than a generic trending row.
  final tmdbSources = <(Map<String, dynamic>, String, String, int, bool, String)>[
    (discoverMoviesPayload, 'movie', 'discover', discoverCap, discoverIsOscar, discoverCurator),
    (discoverTvPayload, 'tv', 'discover', discoverCap, discoverIsOscar, discoverCurator),
    (trendingMoviesPayload, 'movie', 'trending', tmdbCap, false, ''),
    (trendingTvPayload, 'tv', 'trending', tmdbCap, false, ''),
    (topRatedMoviesPayload, 'movie', 'top_rated', tmdbCap, false, ''),
    (topRatedTvPayload, 'tv', 'top_rated', tmdbCap, false, ''),
  ];

  for (final (payload, defaultMediaType, source, cap, isOscar, curator) in tmdbSources) {
    final rows = (payload['results'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    for (final m in rows.take(cap)) {
      final id = (m['id'] as num?)?.toInt();
      if (id == null) continue;
      final mediaType = (m['media_type'] as String?) ?? defaultMediaType;
      final key = '$mediaType:$id';
      // Drop animation-tagged rows from baseline sources (trending/top_rated)
      // when the exclude toggle is on. Discover rows already had
      // `without_genres=16` applied server-side so this is a defensive
      // belt-and-braces pass. Watchlist + reddit rows skip this loop, which
      // is intentional — saved titles are user-curated and stay visible.
      if (excludeAnimation) {
        final raw = m['genre_ids'];
        if (raw is List && raw.any((g) => g is num && g.toInt() == 16)) {
          continue;
        }
      }
      if (!seen.add(key)) continue;
      final date = (m['release_date'] ?? m['first_air_date']) as String?;
      final row = <String, dynamic>{
        'media_type': mediaType,
        'tmdb_id': id,
        'title': (m['title'] ?? m['name']) as String? ?? 'Untitled',
        'year': (date != null && date.length >= 4)
            ? int.tryParse(date.substring(0, 4))
            : null,
        'poster_path': m['poster_path'] as String?,
        'genres': coerceGenres(m['genre_ids'], mediaType: mediaType),
        'overview': m['overview'] as String?,
        'source': source,
      };
      // Only stamp the oscar flag when true. False values are intentionally
      // omitted so `writeCandidateDocs` doesn't reset a previously-set
      // `is_oscar_winner=true` on a row that's now coming through trending.
      if (isOscar) row['is_oscar_winner'] = true;
      // Curator tag — same sticky-on-merge pattern as oscar. A row that came
      // through a Criterion discover carries `curator: 'criterion'`; baseline
      // rows carry nothing and the merge leaves any existing tag alone.
      if (curator.isNotEmpty) row['curator'] = curator;
      // Runtime comes through on discover payloads when the service stamped
      // a synthetic value (server confirmed in-bounds via with_runtime.*).
      // Trending / top-rated don't carry runtime, so the key stays absent
      // for those rows — matches the existing "null runtime" contract.
      final runtime = (m['runtime'] as num?)?.toInt();
      if (runtime != null) row['runtime'] = runtime;
      candidates.add(row);
    }
  }

  return candidates;
}
