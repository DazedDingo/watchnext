/// Maps TMDB keyword ids → extra genre names to union into a title's
/// `genres` set.
///
/// The problem this solves: genre filtering on Home + Decide is an AND
/// intersection (`selected.every(r.genres.contains)`). TMDB's canonical
/// genre taxonomy is narrow — e.g. "Firefly" is tagged `Sci-Fi & Fantasy`
/// only, not `Western`, so a Western + Sci-Fi filter drops it. TMDB's
/// keyword taxonomy is much richer (thousands of tags), so a keyword like
/// "space western" is a reliable signal that a title also deserves the
/// `Western` tag for intersection purposes.
///
/// **Scope**: this is additive only. We never remove canonical genres based
/// on keywords — a title that's canonically a Comedy stays a Comedy even
/// if a keyword says otherwise. The map only widens.
///
/// **Populating the map**: TMDB keyword ids are stable but not publicly
/// documented in bulk. Use `scripts/generate_keyword_genre_map.py` to look
/// up ids by name and emit entries. Each entry should be a keyword that
/// implies ≥1 canonical genre with high confidence (e.g. "cyberpunk" →
/// Science Fiction is safe; "based on novel" → no genre implication and
/// should NOT be in the map).
///
/// Keys are TMDB keyword ids; values are sets of canonical genre names
/// matching those in `utils/tmdb_genres.dart`. Unknown genre names are
/// harmless — `augmentGenresWithKeywords` just unions them in.
const Map<int, Set<String>> kKeywordToExtraGenres = <int, Set<String>>{
  // ---- seed entries (verified IDs) ----
  // 9951 "alien" — pulled in when sci-fi catalogued without the Sci-Fi genre
  //                tag (rare but happens on crossover titles).
  9951: {'Science Fiction'},
  // 4458 "post-apocalyptic future"
  4458: {'Science Fiction'},
  // 4565 "dystopia"
  4565: {'Science Fiction'},
  // 10084 "anime" — implies Animation on live-action-also-tagged titles
  10084: {'Animation'},
  // 9715 "superhero"
  9715: {'Action'},
  // 1721 "fight"
  //   Intentionally NOT here — too broad; would over-tag dramas as Action.
  //
  // TODO: populate further via scripts/generate_keyword_genre_map.py.
  // Candidates worth adding once id-verified:
  //   "space western"     → {Western, Science Fiction}
  //   "cyberpunk"         → {Science Fiction}
  //   "neo-noir"          → {Crime, Mystery}
  //   "slasher"           → {Horror}
  //   "found footage"     → {Horror}
  //   "heist"             → {Crime}
  //   "time travel"       → {Science Fiction}
  //   "kaiju"             → {Science Fiction}
  //   "cosmic horror"     → {Horror, Science Fiction}
};

/// Returns a genre list combining [currentGenres] with any extras implied
/// by [keywordIds] per [kKeywordToExtraGenres]. Order is preserved
/// (existing genres first, then new ones in keyword-iteration order) and
/// duplicates are dropped.
///
/// Unknown keyword ids are silently skipped — TMDB adds new keywords
/// regularly and we only care about the subset we've mapped.
List<String> augmentGenresWithKeywords(
  Iterable<String> currentGenres,
  Iterable<int> keywordIds,
) {
  final seen = <String>{};
  final out = <String>[];
  for (final g in currentGenres) {
    if (g.isEmpty) continue;
    if (seen.add(g)) out.add(g);
  }
  for (final id in keywordIds) {
    final extras = kKeywordToExtraGenres[id];
    if (extras == null) continue;
    for (final g in extras) {
      if (seen.add(g)) out.add(g);
    }
  }
  return out;
}
