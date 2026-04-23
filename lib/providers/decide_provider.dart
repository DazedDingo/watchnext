import 'dart:math' show Random;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recommendation.dart';
import '../models/watchlist_item.dart';
import '../services/decide_service.dart';
import '../services/recommendations_service.dart';
import '../services/tmdb_service.dart';
import '../utils/tmdb_genres.dart';
import 'household_provider.dart';
import 'media_type_filter_provider.dart';
import 'recommendations_provider.dart';
import 'runtime_filter_provider.dart';
import 'tmdb_provider.dart';

final decideServiceProvider = Provider<DecideService>((_) => DecideService());

enum DecidePhase { loading, negotiate, pick, compromise, tiebreak, decided }

/// Decades the "Surprise me" exploratory rung samples from. Excludes the
/// current decade — trending and the user's own watchlist already cover
/// recent content; this rung's job is to surface older catalog titles for
/// negotiation when neither side is biting on what's on screen.
const List<(int, int)> kExploratoryDecades = [
  (1970, 1979),
  (1980, 1989),
  (1990, 1999),
  (2000, 2009),
  (2010, 2019),
];

(int, int) _randomDecade() =>
    kExploratoryDecades[Random().nextInt(kExploratoryDecades.length)];

/// Minimal candidate shape the Decide screen works with. Wraps either a
/// `WatchlistItem` or a TMDB trending row behind the same fields so the rest
/// of the session logic doesn't care about the source.
class DecideCandidate {
  final String mediaType;
  final int tmdbId;
  final String title;
  final String? posterPath;
  final int? year;
  final List<String> genres;
  final int? runtime;
  final String source;

  const DecideCandidate({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.posterPath,
    this.year,
    this.genres = const [],
    this.runtime,
    this.source = 'watchlist',
  });

  String get key => '$mediaType:$tmdbId';

  factory DecideCandidate.fromWatchlist(WatchlistItem w) => DecideCandidate(
        mediaType: w.mediaType,
        tmdbId: w.tmdbId,
        title: w.title,
        posterPath: w.posterPath,
        year: w.year,
        genres: w.genres,
        runtime: w.runtime,
        source: 'watchlist',
      );

  factory DecideCandidate.fromRecommendation(Recommendation r) => DecideCandidate(
        mediaType: r.mediaType,
        tmdbId: r.tmdbId,
        title: r.title,
        posterPath: r.posterPath,
        year: r.year,
        genres: r.genres,
        source: r.source,
      );

  factory DecideCandidate.fromTmdb(Map<String, dynamic> m,
      {required String fallbackMediaType, String source = 'trending'}) {
    final mediaType = (m['media_type'] as String?) ?? fallbackMediaType;
    final title = (m['title'] ?? m['name']) as String? ?? 'Untitled';
    final date = (m['release_date'] ?? m['first_air_date']) as String?;
    final rawIds = (m['genre_ids'] as List?)
            ?.whereType<num>()
            .map((n) => n.toInt()) ??
        const <int>[];
    return DecideCandidate(
      mediaType: mediaType,
      tmdbId: (m['id'] as num).toInt(),
      title: title,
      posterPath: m['poster_path'] as String?,
      year: (date != null && date.length >= 4)
          ? int.tryParse(date.substring(0, 4))
          : null,
      genres: genreNamesFromIds(rawIds, mediaType: mediaType),
      source: source,
    );
  }
}

/// Snapshot of the Home filter state passed into a Decide session. Kept as a
/// plain data carrier so the controller stays framework-agnostic (tests don't
/// need a ProviderContainer just to exercise filter composition).
///
/// Scope is intentionally narrower than Home: awards / sort / curated are
/// deliberately omitted — awards lists rarely overlap with the watchlist +
/// trending pool Decide draws from, and sort/curated reshape the TMDB query
/// (no analogue here). Genre / year / runtime / media type compose cleanly
/// because they're orthogonal narrowing predicates.
class DecideFilters {
  final Set<String> genres;
  final int? minYear;
  final int? maxYear;
  final RuntimeBucket? runtime;
  final MediaTypeFilter? mediaType;

  const DecideFilters({
    this.genres = const {},
    this.minYear,
    this.maxYear,
    this.runtime,
    this.mediaType,
  });

  bool get isEmpty =>
      genres.isEmpty &&
      minYear == null &&
      maxYear == null &&
      runtime == null &&
      mediaType == null;

  /// Same "strict on unknowns" contract the Home filter uses:
  /// - year range drops null-year candidates when either bound is set
  /// - runtime bucket drops null-runtime candidates (matches Home semantics;
  ///   TMDB trending rows never carry runtime so they fall out automatically)
  /// - genre set requires at least one overlap
  /// - media type is straight equality against `recMediaType`
  bool matches(DecideCandidate c) {
    if (mediaType != null && c.mediaType != mediaType!.recMediaType) {
      return false;
    }
    if (minYear != null || maxYear != null) {
      if (c.year == null) return false;
      if (minYear != null && c.year! < minYear!) return false;
      if (maxYear != null && c.year! > maxYear!) return false;
    }
    if (runtime != null && !runtime!.matches(c.runtime)) return false;
    if (genres.isNotEmpty && !genres.every(c.genres.contains)) return false;
    return true;
  }
}

class DecideSessionState {
  final DecidePhase phase;
  final List<DecideCandidate> candidates;
  final DecideCandidate? pickA;
  final DecideCandidate? pickB;
  final DecideCandidate? currentCompromise;
  final int vetoesA;
  final int vetoesB;
  final Set<String> excluded;
  final DecideCandidate? winner;
  final bool wasCompromise;
  final bool wasTiebreak;
  final String? error;

  const DecideSessionState({
    this.phase = DecidePhase.loading,
    this.candidates = const [],
    this.pickA,
    this.pickB,
    this.currentCompromise,
    this.vetoesA = 0,
    this.vetoesB = 0,
    this.excluded = const {},
    this.winner,
    this.wasCompromise = false,
    this.wasTiebreak = false,
    this.error,
  });

  DecideSessionState copyWith({
    DecidePhase? phase,
    List<DecideCandidate>? candidates,
    DecideCandidate? pickA,
    DecideCandidate? pickB,
    DecideCandidate? currentCompromise,
    int? vetoesA,
    int? vetoesB,
    Set<String>? excluded,
    DecideCandidate? winner,
    bool? wasCompromise,
    bool? wasTiebreak,
    String? error,
    bool clearError = false,
    bool clearCompromise = false,
  }) {
    return DecideSessionState(
      phase: phase ?? this.phase,
      candidates: candidates ?? this.candidates,
      pickA: pickA ?? this.pickA,
      pickB: pickB ?? this.pickB,
      currentCompromise: clearCompromise
          ? null
          : (currentCompromise ?? this.currentCompromise),
      vetoesA: vetoesA ?? this.vetoesA,
      vetoesB: vetoesB ?? this.vetoesB,
      excluded: excluded ?? this.excluded,
      winner: winner ?? this.winner,
      wasCompromise: wasCompromise ?? this.wasCompromise,
      wasTiebreak: wasTiebreak ?? this.wasTiebreak,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class DecideController extends StateNotifier<DecideSessionState> {
  DecideController(
    this._tmdb,
    this._recs,
    this._householdId, {
    (int, int) Function()? decadePicker,
  })  : _pickDecade = decadePicker ?? _randomDecade,
        super(const DecideSessionState());

  final TmdbService _tmdb;
  final RecommendationsService _recs;
  final String? _householdId;
  final (int, int) Function() _pickDecade;

  /// Builds the negotiate candidate pool from the shared watchlist, topped up
  /// with TMDB trending if the watchlist has fewer than 5 items.
  ///
  /// [watchedKeys] (format `{mediaType}:{tmdbId}`) are seeded into the session's
  /// `excluded` set so every downstream pick path — compromise, similars,
  /// reroll — skips them without extra plumbing. Watchlist rows are also
  /// pre-filtered here so a watched entry doesn't eat a negotiate slot.
  Future<void> start(
    List<WatchlistItem> watchlist, {
    Set<String> watchedKeys = const {},
    DecideFilters filters = const DecideFilters(),
  }) async {
    state = DecideSessionState(
      phase: DecidePhase.loading,
      excluded: {...watchedKeys},
    );
    try {
      final fromWatchlist = watchlist
          .map(DecideCandidate.fromWatchlist)
          .where((c) => !watchedKeys.contains(c.key))
          .where(filters.matches)
          .toList();

      List<DecideCandidate> merged = fromWatchlist;
      if (merged.length < 5) {
        final trending = await _trendingFor(filters.mediaType);
        final rows = (trending['results'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final trendingMediaType =
            filters.mediaType?.recMediaType ?? 'movie';
        final extra = rows
            .take(15)
            .map((m) => DecideCandidate.fromTmdb(m,
                fallbackMediaType: trendingMediaType, source: 'trending'))
            .where((c) => !watchedKeys.contains(c.key))
            .where(filters.matches)
            .where((c) => !merged.any((w) => w.key == c.key))
            .take(5 - merged.length)
            .toList();
        merged = [...merged, ...extra];
      }

      state = state.copyWith(
        phase: DecidePhase.negotiate,
        candidates: merged.take(5).toList(),
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        phase: DecidePhase.negotiate,
        candidates: watchlist
            .map(DecideCandidate.fromWatchlist)
            .where((c) => !watchedKeys.contains(c.key))
            .where(filters.matches)
            .take(5)
            .toList(),
        error: 'Could not load trending titles — using watchlist only.',
      );
    }
  }

  Future<Map<String, dynamic>> _trendingFor(MediaTypeFilter? mt) {
    if (mt == MediaTypeFilter.tv) return _tmdb.trendingTv();
    return _tmdb.trendingMovies();
  }

  /// Both users agreed on this title in the negotiate view.
  void instantMatch(DecideCandidate c) {
    state = state.copyWith(phase: DecidePhase.decided, winner: c);
  }

  /// No agreement in negotiate — move to pass-and-play pick phase.
  void proceedToPick() {
    state = state.copyWith(phase: DecidePhase.pick);
  }

  void submitPickA(DecideCandidate c) {
    state = state.copyWith(pickA: c);
    _evaluatePicks();
  }

  void submitPickB(DecideCandidate c) {
    state = state.copyWith(pickB: c);
    _evaluatePicks();
  }

  void _evaluatePicks() {
    final a = state.pickA;
    final b = state.pickB;
    if (a == null || b == null) return;
    if (a.key == b.key) {
      state = state.copyWith(phase: DecidePhase.decided, winner: a);
    } else {
      _buildCompromise();
    }
  }

  /// Compromise picker. Preference order:
  ///   1. Top-scored title in `/recommendations` (Claude-ranked, Phase 7a).
  ///   2. Intersection of TMDB "similar" for both picks.
  ///   3. Highest-ranked TMDB-similar for either side.
  /// Each step excludes picks + anything already vetoed.
  Future<void> _buildCompromise() async {
    state = state.copyWith(phase: DecidePhase.compromise, clearCompromise: true);
    try {
      final a = state.pickA!;
      final b = state.pickB!;
      final exclude = {...state.excluded, a.key, b.key};

      DecideCandidate? chosen = await _chooseFromRecommendations(exclude);

      if (chosen == null) {
        final aSimilar = await _similar(a);
        final bSimilar = await _similar(b);
        final aIds = aSimilar.map((c) => c.key).toSet();
        final overlap = bSimilar
            .where((c) => aIds.contains(c.key))
            .where((c) => !exclude.contains(c.key))
            .toList();
        if (overlap.isNotEmpty) {
          chosen = overlap.first;
        } else {
          chosen = [...aSimilar, ...bSimilar]
              .cast<DecideCandidate?>()
              .firstWhere((c) => c != null && !exclude.contains(c.key),
                  orElse: () => null);
        }
      }

      if (chosen == null) {
        // Nothing left — force a tiebreak.
        state = state.copyWith(
          phase: DecidePhase.tiebreak,
          excluded: exclude,
          wasCompromise: true,
        );
        return;
      }

      state = state.copyWith(
        currentCompromise: chosen,
        excluded: exclude,
        wasCompromise: true,
      );
    } catch (e) {
      state = state.copyWith(
        error: 'Could not load similar titles.',
        phase: DecidePhase.tiebreak,
      );
    }
  }

  Future<DecideCandidate?> _chooseFromRecommendations(Set<String> exclude) async {
    final hh = _householdId;
    if (hh == null) return null;
    try {
      final recs = await _recs.fetchTopForDecide(hh, limit: 10, exclude: exclude);
      final best = recs.where((r) => r.scored).cast<Recommendation?>().firstWhere(
            (_) => true,
            orElse: () => null,
          );
      return best == null ? null : DecideCandidate.fromRecommendation(best);
    } catch (_) {
      return null;
    }
  }

  Future<List<DecideCandidate>> _similar(DecideCandidate c) async {
    final raw = c.mediaType == 'tv'
        ? await _tmdb.similarTv(c.tmdbId)
        : await _tmdb.similarMovies(c.tmdbId);
    final rows = (raw['results'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return rows
        .take(20)
        .map((m) => DecideCandidate.fromTmdb(m,
            fallbackMediaType: c.mediaType, source: 'similar'))
        .toList();
  }

  /// Either user accepted the current compromise.
  void acceptCompromise() {
    final c = state.currentCompromise;
    if (c == null) return;
    state = state.copyWith(phase: DecidePhase.decided, winner: c);
  }

  /// A user vetoed the current compromise; [userIsA] selects which counter
  /// increments. After 2 vetoes from one side the flow jumps to tiebreak.
  void veto({required bool userIsA}) {
    final c = state.currentCompromise;
    if (c == null) return;
    final vetoesA = state.vetoesA + (userIsA ? 1 : 0);
    final vetoesB = state.vetoesB + (userIsA ? 0 : 1);
    final newExcluded = {...state.excluded, c.key};

    if (vetoesA >= 2 || vetoesB >= 2) {
      state = state.copyWith(
        vetoesA: vetoesA,
        vetoesB: vetoesB,
        excluded: newExcluded,
        phase: DecidePhase.tiebreak,
        wasTiebreak: true,
      );
      return;
    }

    state = state.copyWith(
      vetoesA: vetoesA,
      vetoesB: vetoesB,
      excluded: newExcluded,
      clearCompromise: true,
    );
    _buildCompromise();
  }

  /// Tiebreak resolution — caller selects the winner's pick (determined by
  /// who has fewer lifetime wins in `gamification.whose_turn`).
  void resolveTiebreak(DecideCandidate winner) {
    state = state.copyWith(
      phase: DecidePhase.decided,
      winner: winner,
      wasTiebreak: true,
    );
  }

  /// "Shuffle candidates" during Negotiate. Folds the current pool into the
  /// excluded set and rebuilds a fresh batch from watchlist + TMDB trending,
  /// same as [start]. Used when neither user likes any of the shown options.
  ///
  /// If nothing new can be found, leaves the existing pool intact and sets
  /// an error so the UI can explain why nothing changed.
  Future<void> rerollCandidates(
    List<WatchlistItem> watchlist, {
    Set<String> watchedKeys = const {},
    DecideFilters filters = const DecideFilters(),
  }) async {
    final exclude = {
      ...state.excluded,
      ...watchedKeys,
      ...state.candidates.map((c) => c.key),
    };

    final fromWatchlist = watchlist
        .map(DecideCandidate.fromWatchlist)
        .where((c) => !exclude.contains(c.key))
        .where(filters.matches)
        .toList();

    List<DecideCandidate> merged = fromWatchlist;
    if (merged.length < 5) {
      try {
        final trending = await _trendingFor(filters.mediaType);
        final rows = (trending['results'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final trendingMediaType =
            filters.mediaType?.recMediaType ?? 'movie';
        final extra = rows
            .take(30)
            .map((m) => DecideCandidate.fromTmdb(m,
                fallbackMediaType: trendingMediaType, source: 'trending'))
            .where((c) => !exclude.contains(c.key))
            .where(filters.matches)
            .where((c) => !merged.any((w) => w.key == c.key))
            .take(5 - merged.length)
            .toList();
        merged = [...merged, ...extra];
      } catch (_) {
        // Fall through with whatever watchlist gave us.
      }
    }

    if (merged.isEmpty) {
      state = state.copyWith(
        excluded: exclude,
        error: 'No fresh titles left — add a few to your watchlist first.',
      );
      return;
    }

    state = state.copyWith(
      candidates: merged.take(5).toList(),
      excluded: exclude,
      clearError: true,
    );
  }

  /// "Surprise me" reroll. Replaces the negotiate pool with a fresh batch
  /// from a randomly-sampled older decade via TMDB `/discover`. Different
  /// from [rerollCandidates], which only ever pulls from watchlist + this
  /// week's trending — that path keeps showing the same current-year fare
  /// neither user is biting on. Exploratory deliberately fishes outside
  /// that pool so negotiation has fresh faces to react to.
  ///
  /// Opt-in only (button-driven from the Negotiate UI). Excludes the
  /// existing pool + watched titles so the user actually sees something new.
  /// Falls back to leaving the current pool intact + an error if TMDB
  /// returns nothing for the chosen decade.
  Future<void> rerollExploratory({
    Set<String> watchedKeys = const {},
  }) async {
    final exclude = {
      ...state.excluded,
      ...watchedKeys,
      ...state.candidates.map((c) => c.key),
    };

    final (minYear, maxYear) = _pickDecade();

    try {
      // Movies need vote_count.gte=300 to skip forgotten 70s/80s catalog
      // filler; TV at the same threshold returns almost nothing in older
      // decades, so it gets a lower floor.
      final results = await Future.wait([
        _tmdb.discoverPaged(
          mediaType: 'movie',
          minYear: minYear,
          maxYear: maxYear,
          minVoteCount: 300,
          poolFloor: 15,
          maxPages: 2,
        ),
        _tmdb.discoverPaged(
          mediaType: 'tv',
          minYear: minYear,
          maxYear: maxYear,
          minVoteCount: 100,
          poolFloor: 15,
          maxPages: 2,
        ),
      ]);

      final movies = (results[0]['results'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final tv = (results[1]['results'] as List? ?? const [])
          .cast<Map<String, dynamic>>();

      // Interleave so a TV-light decade doesn't crowd out the pool with all
      // movies (or vice versa). Negotiation is more interesting with mix.
      final pool = <DecideCandidate>[];
      final maxLen = movies.length > tv.length ? movies.length : tv.length;
      for (var i = 0; i < maxLen; i++) {
        if (i < movies.length) {
          pool.add(DecideCandidate.fromTmdb(movies[i],
              fallbackMediaType: 'movie', source: 'discover'));
        }
        if (i < tv.length) {
          pool.add(DecideCandidate.fromTmdb(tv[i],
              fallbackMediaType: 'tv', source: 'discover'));
        }
      }

      final fresh = pool.where((c) => !exclude.contains(c.key)).take(5).toList();

      if (fresh.isEmpty) {
        state = state.copyWith(
          excluded: exclude,
          error: 'No surprise titles found for ${minYear}s — try shuffle.',
        );
        return;
      }

      state = state.copyWith(
        candidates: fresh,
        excluded: exclude,
        clearError: true,
      );
    } catch (_) {
      state = state.copyWith(
        excluded: exclude,
        error: 'Couldn\'t reach TMDB for surprise titles.',
      );
    }
  }

  /// "Roll again" on the Decided screen. Keeps the current session (picks,
  /// vetoes, excluded set) but swaps the winner for a different title, trying
  /// in order: top scored recommendation → similar to pickA → similar to
  /// pickB → next negotiate-pool candidate. The current winner joins the
  /// excluded set so we don't loop back to it. If nothing else resolves, we
  /// surface an error without changing the winner.
  Future<void> reroll() async {
    final current = state.winner;
    if (current == null) return;
    final exclude = {...state.excluded, current.key};

    DecideCandidate? next = await _chooseFromRecommendations(exclude);

    if (next == null && state.pickA != null) {
      final sims = await _similar(state.pickA!);
      for (final c in sims) {
        if (!exclude.contains(c.key)) { next = c; break; }
      }
    }
    if (next == null && state.pickB != null) {
      final sims = await _similar(state.pickB!);
      for (final c in sims) {
        if (!exclude.contains(c.key)) { next = c; break; }
      }
    }
    if (next == null) {
      for (final c in state.candidates) {
        if (!exclude.contains(c.key)) { next = c; break; }
      }
    }

    if (next == null) {
      state = state.copyWith(
        excluded: exclude,
        error: 'No more titles to pick from. Add a few to your watchlist first.',
      );
      return;
    }

    state = state.copyWith(
      excluded: exclude,
      winner: next,
      clearError: true,
    );
  }

  void reset() {
    state = const DecideSessionState();
  }
}

final decideSessionProvider =
    StateNotifierProvider<DecideController, DecideSessionState>((ref) {
  return DecideController(
    ref.read(tmdbServiceProvider),
    ref.read(recommendationsServiceProvider),
    ref.watch(householdIdProvider).value,
  );
});
