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
import '../utils/keyword_genre_augment.dart';
import '../utils/oscar_winners.dart';
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

  /// Hash of the last refresh's meaningful input state (filters + ratings +
  /// watch entries + mode). When a new `refresh(...)` call arrives with an
  /// identical hash, we short-circuit BEFORE any TMDB call, Firestore write,
  /// or background Claude scoring — nothing about the pool would change, so
  /// spending the budget is pure waste. The hash is supplied by the caller
  /// (the provider reads the live values and computes it) so the service
  /// stays thin. Null until the first successful refresh.
  String? _lastRefreshHash;

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
  /// TMDB keyword id for the "oscar-winning-film" keyword. No longer passed
  /// to discover (see gotcha 35c — the keyword is dominated by films that
  /// won technical/animated categories and was replaced with the baked
  /// Best Picture list). Kept for test back-compat.
  static const int kOscarKeywordId = 210024;

  Future<bool> refresh(
    String householdId, {
    required List<WatchlistItem> watchlist,
    int tmdbCap = 10,
    Set<String> genreFilters = const {},
    YearRange yearRange = const YearRange.unbounded(),
    RuntimeBucket? runtimeBucket,
    MediaTypeFilter? mediaTypeFilter,
    AwardCategory awardsFilter = AwardCategory.none,
    SortMode sortMode = SortMode.topRated,
    CuratedSource curatedSource = CuratedSource.none,
    bool forceTasteProfile = false,
    String? stateHash,
  }) async {
    // State-hash dedupe: when the caller's inputs hash identically to the
    // last successful refresh (filter state + ratings + watch entries +
    // mode), skip all work. Phase A (~18 TMDB calls) + Phase B (Claude CF,
    // ~$0.10-$0.20 in API tokens) would produce an identical pool, so firing
    // is pure waste. `forceTasteProfile=true` bypasses dedupe — callers
    // explicitly asked for a taste-profile regen, which is the only output
    // the hash doesn't fully capture. Returns false when deduped, true
    // otherwise — lets the UI distinguish "already fresh" from "refreshing"
    // and render different feedback.
    if (!forceTasteProfile &&
        stateHash != null &&
        stateHash == _lastRefreshHash) {
      return false;
    }
    final oscarOnly = awardsFilter != AwardCategory.none;
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
        sortMode != SortMode.topRated ||
        curatedSource != CuratedSource.none;
    final fetchMovies = mediaTypeFilter != MediaTypeFilter.tv;
    final fetchTv = mediaTypeFilter != MediaTypeFilter.movie;

    // Narrow-combo detection: when the user has stacked multiple orthogonal
    // filters (e.g. "War + 1970-1989" or "Comedy + 90-120min + Criterion"),
    // the default discoverPaged budget (poolFloor=40, maxPages=5,
    // minVoteCount=50) routinely exhausts without filling the pool —
    // obscure/older titles get cut by the 50-votes floor and there just
    // aren't enough popular entries to hit poolFloor. Widen the search
    // when that's likely: deeper fetch (more pages), looser vote floor
    // (let less-rated titles through), and a bigger target pool. Broad
    // queries stay on the default budget so they don't get slower.
    //
    // Must be paired with a matching bump to buildCandidates' `discoverCap`
    // — otherwise the extra 60 rows get fetched then thrown away.
    final narrow = isNarrowFilterCombo(
      genreFilters: genreFilters,
      yearRange: yearRange,
      runtimeBucket: runtimeBucket,
      oscarOnly: oscarOnly,
      curatedSource: curatedSource,
      sortMode: sortMode,
    );
    final dPoolFloor = narrow ? 100 : 40;
    final dMaxPages = narrow ? 10 : 5;
    final dMinVotes = narrow ? 10 : 50;
    final dDiscoverCap = narrow ? 100 : 40;

    if (hasFilters) {

      final movieIds = genreIdsFromNames(genreFilters, mediaType: 'movie');
      final tvIds = genreIdsFromNames(genreFilters, mediaType: 'tv');
      // Oscar keyword (210024) is TMDB-user-maintained and overwhelmingly
      // tagged with films that won technical/animated categories rather
      // than Best Picture — combining it with genre+year filters
      // routinely returns 0. We substitute a baked Best Picture winners
      // list below (`kBestPictureWinners`), so we deliberately DO NOT
      // pass `kOscarKeywordId` into the discover call anymore. Keeping
      // the constant around for back-compat (tests reference it) but
      // the refresh path no longer uses it.
      const List<int> keywordIds = <int>[];
      final discoverResults = await Future.wait([
        if (fetchMovies)
          _safeTmdb(() => _tmdb.discoverPaged(
                mediaType: 'movie',
                genreIds: movieIds,
                keywordIds: keywordIds,
                withCompanies: curatedSource.withCompanies,
                sortBy: sortMode.tmdbSortBy('movie'),
                maxVoteCount: sortMode.maxVoteCount,
                minYear: yearRange.minYear,
                maxYear: yearRange.maxYear,
                minRuntime: runtimeBucket?.minRuntime,
                maxRuntime: runtimeBucket?.maxRuntime,
                minVoteCount: dMinVotes,
                poolFloor: dPoolFloor,
                maxPages: dMaxPages,
              )),
        if (fetchTv)
          _safeTmdb(() => _tmdb.discoverPaged(
                mediaType: 'tv',
                genreIds: tvIds,
                keywordIds: keywordIds,
                withCompanies: curatedSource.withCompanies,
                sortBy: sortMode.tmdbSortBy('tv'),
                maxVoteCount: sortMode.maxVoteCount,
                minYear: yearRange.minYear,
                maxYear: yearRange.maxYear,
                minRuntime: runtimeBucket?.minRuntime,
                maxRuntime: runtimeBucket?.maxRuntime,
                minVoteCount: dMinVotes,
                poolFloor: dPoolFloor,
                maxPages: dMaxPages,
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
      tmdbCap: tmdbCap,
      discoverCap: dDiscoverCap,
      includeAwardsList: awardsFilter,
    );

    if (candidates.isEmpty) return false;

    // Epoch guard: if another refresh started after us, its Firestore write
    // is the authoritative one — bail before we stomp it. See `_refreshEpoch`
    // doc above for the race this prevents.
    if (myEpoch != _refreshEpoch) return false;

    // Phase A — sync: write the pool to Firestore with default scores so
    // the Home stream lights up immediately. This is the bit the user waits
    // on. Pre-existing rec keys keep their scores (merge skips score fields).
    final missingImdb = await writeCandidateDocs(householdId, candidates);

    // Re-check after the Firestore write: an even-newer refresh could have
    // landed while we were writing. Don't fire a stale Claude pass — its
    // candidate list is now out-of-date vs. the pool in Firestore.
    if (myEpoch != _refreshEpoch) return false;

    // Phase B — async: taste-profile refresh (if forced) + Claude scoring.
    // Fire-and-forget: any failure leaves the pool intact at default scores,
    // and `processRescoreQueue` re-scores on its 10-min sweep anyway.
    unawaited(_backgroundScore(
      householdId: householdId,
      candidates: candidates,
      forceTasteProfile: forceTasteProfile,
    ));

    // Phase B' — also async: resolve imdb_id for rec docs that don't have
    // it yet (new rows + any legacy rows pre-dating this feature). Stamps
    // them back onto the doc so the row-level IMDb rating chip can render
    // on subsequent renders. Independent of Claude scoring so a slow TMDB
    // response doesn't hold up rescoring.
    if (missingImdb.isNotEmpty) {
      unawaited(_backgroundResolveImdbIds(householdId, missingImdb));
    }

    // Phase B'' — fetch TMDB keywords for every rec doc missing the
    // `keywords_fetched` flag and augment `genres` via the keyword→genre
    // map. Fixes cold-start AND filter misses (e.g. Sci-Fi + War shows
    // Starship Troopers even though its canonical tags are Action+Sci-Fi).
    // Also fire-and-forget; swallows errors.
    unawaited(backfillMissingAugmentedGenres(householdId));

    // Commit the new hash only after the Phase A write has succeeded.
    // If Phase A threw (epoch race, Firestore error), we leave the old
    // hash in place so the next attempt actually runs.
    if (stateHash != null) _lastRefreshHash = stateHash;
    return true;
  }

  /// Writes each candidate to `/households/{hh}/recommendations/{key}`. For
  /// keys already present in the collection we merge only metadata fields —
  /// `match_score` / `ai_blurb` / `scored` are left alone so a previously
  /// Claude-scored rec doesn't visibly drop back to 50%. New keys get the
  /// default score seeded so they sort into the stream's top-120 window.
  ///
  /// Chunks writes into Firestore's 500-op batch limit. Exposed for tests.
  /// Writes candidate docs and returns the `(mediaType, tmdbId)` pairs that
  /// still need an `imdb_id` resolved — callers can fire `_backgroundResolveImdbIds`
  /// to backfill them. Set empty when every doc in the pool already carries
  /// an `imdb_id` from a prior refresh.
  Future<List<({String mediaType, int tmdbId})>> writeCandidateDocs(
    String householdId,
    List<Map<String, dynamic>> candidates,
  ) async {
    if (candidates.isEmpty) return const [];
    final col = _col(householdId);

    // Look up which candidate ids are already scored so we preserve their
    // score on merge. Cap matches the stream window so we don't accidentally
    // reset scores on recs the UI is actively showing. Also captures which
    // docs already carry `imdb_id` so the background resolver only re-hits
    // TMDB for rows that genuinely need it.
    final existingSnap = await col.limit(800).get();
    final existingIds = <String>{};
    final hasImdb = <String>{};
    for (final d in existingSnap.docs) {
      existingIds.add(d.id);
      final imdb = d.data()['imdb_id'];
      if (imdb is String && imdb.isNotEmpty) hasImdb.add(d.id);
    }

    final needsImdb = <({String mediaType, int tmdbId})>[];

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
        // Pre-stamp imdb_id when the candidate source already knows it
        // (e.g. the Best Picture winners baked list). Avoids a wasted
        // round-trip via `_backgroundResolveImdbIds` for these rows and
        // means the Home IMDb chip renders from the moment the doc hits
        // Firestore instead of waiting for TMDB lookup.
        final preImdb = c['imdb_id'];
        if (preImdb is String && preImdb.isNotEmpty) {
          data['imdb_id'] = preImdb;
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

        // Only enqueue for background resolution if neither the existing
        // Firestore doc nor this candidate row already carries imdb_id.
        final carriesImdb = preImdb is String && preImdb.isNotEmpty;
        if (!hasImdb.contains(key) && !carriesImdb) {
          needsImdb.add((mediaType: mediaType, tmdbId: tmdbId));
        }
      }
      await batch.commit();
    }

    return needsImdb;
  }

  /// Resolves `imdb_id` for each `(mediaType, tmdbId)` pair via TMDB's lean
  /// `/external_ids` endpoint and stamps it onto the matching rec doc.
  ///
  /// Fire-and-forget. Errors are swallowed (imdb_id is a nice-to-have; the
  /// row-level chip just stays hidden when resolution fails). Limits
  /// concurrency to avoid a thundering-herd on TMDB — the full candidate
  /// pool is usually 40–100 new rows and TMDB tolerates ~50 req/s, but we
  /// stay well under that so a background backfill can't starve the
  /// foreground refresh fan-out.
  ///
  /// The empty string is written on genuine TMDB misses so we don't
  /// retry forever; `Recommendation.imdbId` coerces empty → null.
  Future<void> _backgroundResolveImdbIds(
    String householdId,
    List<({String mediaType, int tmdbId})> pairs,
  ) async {
    const concurrency = 8;
    final col = _col(householdId);

    for (var i = 0; i < pairs.length; i += concurrency) {
      final slice = pairs.skip(i).take(concurrency).toList();
      await Future.wait(slice.map((p) async {
        try {
          final payload = await _tmdb.externalIds(p.mediaType, p.tmdbId);
          final imdb = payload['imdb_id'];
          if (imdb is String && imdb.isNotEmpty) {
            await col.doc('${p.mediaType}:${p.tmdbId}').update({
              'imdb_id': imdb,
            });
          }
        } catch (_) {
          // Silent — this is best-effort backfill.
        }
      }));
    }
  }

  /// Reads the top of the rec collection and fires a background resolver
  /// for every doc that doesn't yet carry `imdb_id`. Invoked from Home's
  /// initState so the row-level IMDb chip can start populating as soon as
  /// the user opens the app — without waiting for them to pull-to-refresh.
  ///
  /// Fire-and-forget. Bounds reads to [limit] (default: the stream window)
  /// so cold pools with hundreds of un-stamped legacy docs don't fan out
  /// into a huge TMDB burst. The background resolver that follows is
  /// already concurrency-limited.
  Future<void> backfillMissingImdbIds(
    String householdId, {
    int limit = 300,
  }) async {
    try {
      final snap = await _col(householdId).limit(limit).get();
      final missing = <({String mediaType, int tmdbId})>[];
      for (final d in snap.docs) {
        final data = d.data();
        final imdb = data['imdb_id'];
        if (imdb is String && imdb.isNotEmpty) continue;
        final mt = data['media_type'] as String?;
        final id = (data['tmdb_id'] as num?)?.toInt();
        if (mt == null || id == null) continue;
        missing.add((mediaType: mt, tmdbId: id));
      }
      if (missing.isNotEmpty) {
        await _backgroundResolveImdbIds(householdId, missing);
      }
    } catch (_) {
      // Best-effort — if this fails, pull-to-refresh will still fire the
      // same resolver with a fresh pool.
    }
  }

  /// Opportunistic imdb_id write — used by TitleDetail, which already has
  /// the imdb_id in its details payload. Zero-cost compared to the TMDB
  /// round-trip in `_backgroundResolveImdbIds`, so it's worth skipping the
  /// background resolver entirely for titles the user actually opens.
  Future<void> stampImdbId({
    required String householdId,
    required String mediaType,
    required int tmdbId,
    required String imdbId,
  }) async {
    if (imdbId.isEmpty) return;
    try {
      await _col(householdId).doc('$mediaType:$tmdbId').update({
        'imdb_id': imdbId,
      });
    } catch (_) {
      // Rec doc may not exist (not every title the user opens is in the
      // rec pool). `.update()` throws on missing docs — silent ignore.
    }
  }

  /// Opportunistic genre widening from TMDB keyword ids. See
  /// `utils/keyword_genre_augment.dart` — a keyword like "space marines"
  /// implies `{Science Fiction, War}` even when the title's canonical
  /// genre tags are only `{Action, Science Fiction}`, so an AND filter for
  /// Sci-Fi + War would otherwise drop Starship Troopers.
  ///
  /// Called from TitleDetail after the details payload (which already
  /// appends keywords) resolves — zero extra TMDB round-trip. Reads the
  /// current rec doc's genres, augments, writes back only when the set
  /// actually grew. Missing rec docs + Firestore errors are silently
  /// swallowed — augmentation is a nice-to-have, not UI-critical.
  Future<void> stampAugmentedGenres({
    required String householdId,
    required String mediaType,
    required int tmdbId,
    required List<int> keywordIds,
  }) async {
    if (keywordIds.isEmpty) return;
    try {
      final docRef = _col(householdId).doc('$mediaType:$tmdbId');
      final snap = await docRef.get();
      if (!snap.exists) return;
      final data = snap.data() ?? const <String, dynamic>{};
      final currentGenres = (data['genres'] as List? ?? const [])
          .whereType<String>()
          .toList();
      final augmented =
          augmentGenresWithKeywords(currentGenres, keywordIds);
      final storedVersion = (data['keywords_version'] as num?)?.toInt() ?? 0;
      final grew = augmented.length > currentGenres.length;
      final needsVersionBump = storedVersion < kKeywordsVersion;
      if (!grew && !needsVersionBump) return;
      final update = <String, dynamic>{
        'keywords_fetched': true,
        'keywords_version': kKeywordsVersion,
      };
      if (grew) update['genres'] = augmented;
      await docRef.update(update);
    } catch (_) {
      // Same rationale as stampImdbId — a missing doc or transient
      // Firestore error shouldn't bubble into the detail screen UI.
    }
  }

  /// Fetches TMDB keywords for rec docs missing the `keywords_fetched`
  /// flag, augments `genres` via `kKeywordToExtraGenres`, and stamps the
  /// flag so a future refresh doesn't re-hit TMDB for the same rows.
  /// Mirror of `_backgroundResolveImdbIds` — concurrency-limited
  /// fire-and-forget.
  ///
  /// Writes the `keywords_fetched: true` flag on every successful fetch,
  /// even when the map produces no extra genres (so we don't retry
  /// forever on rows with no interesting keywords). Genre write only
  /// happens when the set actually grew.
  ///
  /// Re-augmentation on map growth is handled via `kKeywordsVersion`:
  /// each write stamps the live version, and `backfillMissingAugmentedGenres`
  /// treats a doc as needing re-fetch whenever its stored version is older.
  /// Bumping the version in `utils/keyword_genre_augment.dart` is the
  /// mechanism for making new entries retroactive.
  Future<void> _backgroundAugmentGenres(
    String householdId,
    List<({String mediaType, int tmdbId})> pairs,
  ) async {
    const concurrency = 8;
    final col = _col(householdId);

    for (var i = 0; i < pairs.length; i += concurrency) {
      final slice = pairs.skip(i).take(concurrency).toList();
      await Future.wait(slice.map((p) async {
        try {
          final payload = await _tmdb.keywords(p.mediaType, p.tmdbId);
          // Movies carry `keywords: [...]`; TV carries `results: [...]`.
          final rawList =
              (payload['keywords'] ?? payload['results']) as List?;
          final keywordIds = (rawList ?? const [])
              .whereType<Map<String, dynamic>>()
              .map((k) => (k['id'] as num?)?.toInt())
              .whereType<int>()
              .toList();

          final docRef = col.doc('${p.mediaType}:${p.tmdbId}');
          final snap = await docRef.get();
          if (!snap.exists) return;
          final data = snap.data() ?? const <String, dynamic>{};
          final currentGenres = (data['genres'] as List? ?? const [])
              .whereType<String>()
              .toList();
          final augmented =
              augmentGenresWithKeywords(currentGenres, keywordIds);

          final update = <String, dynamic>{
            'keywords_fetched': true,
            'keywords_version': kKeywordsVersion,
          };
          if (augmented.length > currentGenres.length) {
            update['genres'] = augmented;
          }
          await docRef.update(update);
        } catch (_) {
          // Best-effort.
        }
      }));
    }
  }

  /// Reads the top of the rec collection and fires the background
  /// keyword-augmenter for every doc missing `keywords_fetched`. Invoked
  /// from Home's initState (alongside the IMDb backfill) + from refresh
  /// post-Phase-A, so cold pools enrich without the user having to pull
  /// the spinner.
  ///
  /// Bounds reads to [limit] to avoid a thundering TMDB burst on fresh
  /// installs; the background augmenter is already concurrency-limited
  /// but we don't need to re-check the entire rec history every session.
  Future<void> backfillMissingAugmentedGenres(
    String householdId, {
    int limit = 300,
  }) async {
    try {
      final snap = await _col(householdId).limit(limit).get();
      final missing = <({String mediaType, int tmdbId})>[];
      for (final d in snap.docs) {
        final data = d.data();
        final fetched = data['keywords_fetched'] == true;
        final version = (data['keywords_version'] as num?)?.toInt() ?? 0;
        if (fetched && version >= kKeywordsVersion) continue;
        final mt = data['media_type'] as String?;
        final id = (data['tmdb_id'] as num?)?.toInt();
        if (mt == null || id == null) continue;
        missing.add((mediaType: mt, tmdbId: id));
      }
      if (missing.isNotEmpty) {
        await _backgroundAugmentGenres(householdId, missing);
      }
    } catch (_) {
      // Best-effort — next refresh will retry.
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
  int tmdbCap = 20,
  int discoverCap = 40,
  AwardCategory includeAwardsList = AwardCategory.none,
  @Deprecated('Use includeAwardsList. Back-compat shim for tests.')
  bool includeOscarBakedList = false,
}) {
  final candidates = <Map<String, dynamic>>[];
  final seen = <String>{};

  // When the user turns on an award filter, inject the curated winners
  // list as a dedicated candidate source. TMDB's Oscar keyword (210024)
  // is unreliable — most entries are films that won technical/animated
  // categories rather than Best Picture — so the baked list is ground
  // truth, and the same splicing strategy extends to Palme d'Or / BAFTA /
  // Golden Globe. `AwardCategory.any` splices the deduped union across
  // every supported award. Every row carries enough metadata (genres,
  // year, runtime, poster, imdb_id) to survive the client-side filter
  // stack on its own. Placed first so these rows lead the merge order —
  // if one is also trending, it keeps the award tag.
  final awards = includeAwardsList != AwardCategory.none
      ? includeAwardsList
      : (includeOscarBakedList ? AwardCategory.bestPicture : AwardCategory.none);
  if (awards != AwardCategory.none) {
    final list = kAwardWinners[awards] ?? const <AwardWinner>[];
    for (final w in list) {
      final key = 'movie:${w.tmdbId}';
      if (!seen.add(key)) continue;
      candidates.add({
        'media_type': 'movie',
        'tmdb_id': w.tmdbId,
        'title': w.title,
        'year': w.year,
        'poster_path': w.posterPath,
        'genres': w.genres,
        'runtime': w.runtime,
        'overview': w.overview,
        // Storage uses `oscar` / `is_oscar_winner` for back-compat — the
        // existing Firestore merge semantics treat this as the generic
        // "won a pool-entry-worthy award" sticky tag. See gotcha 25.
        'source': 'oscar',
        'is_oscar_winner': true,
        'imdb_id': w.imdbId,
      });
    }
  }

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

/// Returns true when the user has stacked enough orthogonal filters that a
/// default-budget `discoverPaged` pass is likely to come back near-empty.
///
/// Each of these narrows the result set roughly multiplicatively:
/// - genre (user picked at least one)
/// - year range (at least one bound)
/// - runtime bucket
/// - Oscar-winners-only
/// - curated source (Criterion)
/// - "Underseen" sort mode (caps vote_count, aggressively thins the pool)
///
/// Two or more of those and we should widen the fetch — more pages, lower
/// vote floor, bigger target pool — so narrow combos don't just surface an
/// empty list. Media-type filter and Exclude-Animation aren't counted
/// because they only gate *which* side of the discover fan-out fires, not
/// how deep it goes. Sort modes other than topRated and underseen reshape
/// ranking but don't actually narrow the pool either.
///
/// Pure function — exposed for test coverage of every combination.
bool isNarrowFilterCombo({
  required Set<String> genreFilters,
  required YearRange yearRange,
  required RuntimeBucket? runtimeBucket,
  required bool oscarOnly,
  required CuratedSource curatedSource,
  required SortMode sortMode,
}) {
  var n = 0;
  if (genreFilters.isNotEmpty) n++;
  if (yearRange.hasAnyBound) n++;
  if (runtimeBucket != null) n++;
  if (oscarOnly) n++;
  if (curatedSource != CuratedSource.none) n++;
  if (sortMode == SortMode.underseen) n++;
  return n >= 2;
}

/// Pure hash over the full set of inputs that could change what a refresh
/// would produce. Any change to filters, ratings, watch entries, or mode
/// busts the hash; anything else means firing a new refresh would produce an
/// identical pool and should be short-circuited by `RecommendationsService`.
/// The genres Set is sorted into a deterministic list so element order
/// doesn't flip the hash spuriously.
String computeRefreshStateHash({
  required String householdId,
  required Set<String> genres,
  required int? yearMin,
  required int? yearMax,
  required String? runtime,
  required String? mediaType,
  required String? awards,
  required String sortMode,
  required String curatedSource,
  required bool includeWatched,
  required String mode,
  required String ratingSignature,
  required String watchSignature,
}) {
  final sortedGenres = (genres.toList()..sort()).join(',');
  return [
    householdId,
    sortedGenres,
    yearMin,
    yearMax,
    runtime,
    mediaType,
    awards,
    sortMode,
    curatedSource,
    includeWatched,
    mode,
    ratingSignature,
    watchSignature,
  ].join('|');
}
