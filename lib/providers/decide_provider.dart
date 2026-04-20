import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recommendation.dart';
import '../models/watchlist_item.dart';
import '../services/decide_service.dart';
import '../services/recommendations_service.dart';
import '../services/tmdb_service.dart';
import 'household_provider.dart';
import 'recommendations_provider.dart';
import 'tmdb_provider.dart';

final decideServiceProvider = Provider<DecideService>((_) => DecideService());

enum DecidePhase { loading, negotiate, pick, compromise, tiebreak, decided }

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
  final String source;

  const DecideCandidate({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.posterPath,
    this.year,
    this.genres = const [],
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
    return DecideCandidate(
      mediaType: mediaType,
      tmdbId: (m['id'] as num).toInt(),
      title: title,
      posterPath: m['poster_path'] as String?,
      year: (date != null && date.length >= 4)
          ? int.tryParse(date.substring(0, 4))
          : null,
      source: source,
    );
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
  DecideController(this._tmdb, this._recs, this._householdId)
      : super(const DecideSessionState());

  final TmdbService _tmdb;
  final RecommendationsService _recs;
  final String? _householdId;

  /// Builds the negotiate candidate pool from the shared watchlist, topped up
  /// with TMDB trending if the watchlist has fewer than 5 items.
  Future<void> start(List<WatchlistItem> watchlist) async {
    state = const DecideSessionState(phase: DecidePhase.loading);
    try {
      final fromWatchlist =
          watchlist.map(DecideCandidate.fromWatchlist).toList();

      List<DecideCandidate> merged = fromWatchlist;
      if (merged.length < 5) {
        final trending = await _tmdb.trendingMovies();
        final rows = (trending['results'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final extra = rows
            .take(10)
            .map((m) => DecideCandidate.fromTmdb(m,
                fallbackMediaType: 'movie', source: 'trending'))
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
        candidates: watchlist.take(5).map(DecideCandidate.fromWatchlist).toList(),
        error: 'Could not load trending titles — using watchlist only.',
      );
    }
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
