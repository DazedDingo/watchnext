# WatchNext — Build Roadmap

Source of truth for the full 11-phase build plan from the original design spec.
**Status as of 2026-04-21** audited from the live codebase. Each phase marked
Shipped ✅ / Partial 🟡 / Not started ⬜ with explicit gaps listed where the
shipped implementation diverges from the original intent.

For the authoritative design spec (screens, data model, flows, gamification, all copy), see the PDF: `WatchNext_Design.pdf` (kept alongside this file or in your notes).

---

## Phase 1 — Foundation ✅

- Flutter project scaffold (Kotlin-native was considered; Flutter chosen for consistency with `groceries-app`; widget will be a native Kotlin side-module in Phase 10).
- Dark-mode Material 3 theme only.
- 5-tab bottom nav: Home / Discover / History / Stats / Profile.
- Firebase: Auth (Google Sign-In), Firestore (rules deployed), Cloud Functions stub, Cloud Messaging package wired.
- Household model: create → invite code → partner joins (two-person cap).
- TMDB API service (search, details, similar, trending, upcoming, top-rated, list, image URLs).
- Firestore security rules scoped to household membership for every collection in the spec's data model.

---

## Phase 2 — Trakt Integration ✅

- Trakt OAuth 2.0 per user. Browser auth (CSRF state-protected), token exchange, tokens on member doc.
- `TraktService` — history, ratings, trending, recommendations, push ratings, token refresh.
- Full sync on first link: paginated pull of entire watch history, TMDB cross-ref, per-episode sub-docs for TV.
- Incremental sync on app open (>1hr since last `last_trakt_sync`).
- Push WatchNext ratings to Trakt via `TraktService.pushRating`.
- **Unrated Queue** provider exposed in `lib/providers/watch_entries_provider.dart`.
- Client-side sync (no Cloud Function dependency) — no Blaze-plan server push on sync.

**Deferred (not yet shipped):** per-episode Unrated Queue pass (show-level only today).

---

## Phase 3 — Core UX ✅

- History screen — Watched / In progress / Unrated tabs, swipe-to-rate on Unrated.
- Rating flow modal sheet — 1–5 stars + tag chips + note. Movie/show/season/episode levels. Pushes to Trakt on save when linked.
- Watchlist screen — shared queue, swipe to remove, tap → title detail.
- Title detail screen — backdrop, poster, metadata, add/remove watchlist, rate button, household ratings list, and a manual watch-status control. Movies get a 2-state Mark-watched toggle; TV gets a 3-state `Not / Watching / Watched` SegmentedButton that drives `WatchEntryService.markWatching` / `markWatched` / `unmarkWatching` / `unmarkWatched` for users who aren't Trakt-linked.
- Home screen assembly now lives in Phase 7 (Tonight's Pick, mood, rec list); Phase 3's placeholder is superseded.
- Real-time Firestore listeners via Riverpod StreamProviders.

**Deferred (not yet shipped):**
- Search + filters on Watched tab.
- Per-episode Unrated Queue with "Rate All" batch mode.
- "Resume" nudge after 2 weeks of inactivity on In-Progress (blocked on Phase 10 notifications).
- Prediction accuracy badge on Watched rows (blocked on Phase 9 streak/badge infra).

---

## Phase 4 — Solo / Together mode + Share-to-Save ✅

- Segmented control at top of Home and Discover: Solo | Together. Persists per-device in SharedPreferences (`wn_view_mode`).
- Recommendation doc contract: `match_score` + `match_score_solo` per-user, `ai_blurb` + `ai_blurb_solo` per-user (populated by Phase 7's scoring CF).
- Android share-sheet intent filter (`SEND` + `text/plain`). `ShareParser` resolves incoming URLs via TMDB/IMDb/Letterboxd/Google/fallback lookup.
- Confirmation bottom sheet stores items with `added_source: "share_sheet"`.
- Listeners wired in `ScaffoldWithNavBar` for both warm (`getMediaStream`) and cold (`getInitialMedia`) starts via `receive_sharing_intent`.

**Deferred (not yet shipped):** default-mode per-user (from `members/{uid}.default_mode` during onboarding) — blocked on Phase 11 onboarding flow.

---

## Phase 5 — Decide Together ✅

- **Negotiate** — top 5 per user from scored recommendations (mood-filtered). Side-by-side layout. Instant Match highlight on overlap (`decide_provider.dart` line 188). "None of these — shuffle" button rerolls the five candidates (`rerollCandidates` in `decide_provider.dart`); exclusions are session-only and cleared on close / new session. **"Surprise me — fish older catalog"** button (`rerollExploratory`) opt-in fishes a random pre-2020 decade via `/discover` so negotiation has fresh faces from outside the trending pool when neither user is biting; sees `kExploratoryDecades`. Decade-sampled rather than user-selected to keep the surprise pop.
- Match → suggest. No match → each picks #1.
- Different picks → **compromise pick**. Three-tier fallback: top scored rec → TMDB `similar` overlap → any similar. Current implementation uses TMDB-similar rather than the Claude-scored compromise the spec described — downgrade-in-place; the Claude upgrade is a straight swap of the candidate source.
- **Veto** — max 2 per user (`vetoesA >= 2 || vetoesB >= 2 → tiebreak`).
- **Tiebreaker** — resolves to the user with fewer lifetime wins in `gamification.whose_turn`. `DecisionPick.wasTiebreak` flagged for Phase 9 stats.
- Decision logged to `decisionHistory`. `whose_turn` counters updated in `DecideService.recordDecision`.
- Optional Predict & Rate trigger after selection (wired via Predict flow; not enforced).

**Gaps vs spec:**
- Compromise picks use TMDB similar, not a Claude call with both taste profiles. Swap when appetite / API budget is there.

---

## Phase 6 — Predict & Rate ✅

- Pre-watch prediction sheet — 1–5 stars, skip always available. Hidden from partner until both submit.
- Post-watch rating via Phase 3 flow. Two-way Trakt sync on the rating (prediction itself is WatchNext-only).
- Show-level prediction only (spec matches this — prediction operates at show level, episodes rated via Phase 3).
- Reveal screen — side-by-side predicted vs actual, delta display, winner highlighted (`reveal_screen.dart` lines 43–80).
- Counters on member doc: `predict_total`, `predict_wins` (fed by `PredictionService.markRevealSeen`).
- FCM nudge on `ratings/{id}` creation via `onRatingCreated` Cloud Function (`notifications.ts`) — pings partner when a rating posts after a shared prediction.

**Gaps vs spec:**
- Prediction accuracy badge on Watched rows (blocked on Phase 9).
- Running streak / current-accuracy leaderboard display (blocked on Phase 9 streaks).

---

## Phase 7 — AI & Discovery 🟡

**Shipped:**
- **Reddit scraper Cloud Function** — weekly Sunday 03:00 UTC. Scrapes 7 configured subreddits, TMDB cross-refs, writes `/redditMentions` (`functions/src/redditScraper.ts`).
- **Taste profile generation** — `generateTasteProfile` callable (`functions/src/tasteProfile.ts`). Produces per-user + combined top genres, decades, liked/disliked titles. Currently mode-unaware (see signal-separation work below).
- **Claude API batch scoring** — `scoreRecommendations` callable (`functions/src/scoreRecommendations.ts`, model `claude-sonnet-4-6`, `MAX_CANDIDATES=100`). Writes `match_score`/`match_score_solo` and `ai_blurb`/`ai_blurb_solo` to `/recommendations`. Invoked on-demand via fire-and-forget `unawaited()` — the client now writes the candidate pool with default scores to Firestore synchronously first (so Home's stream lights up in <5s) then kicks off scoring in the background; see Known Gotcha #13 in CLAUDE.md. If the background scoring call fails, `processRescoreQueue` covers it on the next 10-min sweep.
- **Home screen** — Tonight's Pick hero (top rec from local sort, not a dedicated CF doc), mood selector pills (8 moods → TMDB genre map), collapsible Filters panel containing free-form genre multi-select + media-type pills (Movies / TV; per-mode persisted under `wn_media_type_{solo,together}`) + runtime pills (`<90 / 90–120 / >2h`) + year range slider (inclusive `[minYear, maxYear]`, null bound = "Any") + Oscar-winners-only switch (per-mode persisted under `wn_oscar_winners_{solo,together}`; backed by TMDB keyword `210024` and a sticky `is_oscar_winner` flag on rec docs), live title search field, "Surprise me" random-from-top, "Because you loved X" chip (`utils/rec_explainer.dart`). Mood filter is graceful on empty-genre recs — it keeps them in the pool instead of dropping pre-`coerceGenres` docs entirely. Runtime filter is strict (drops null-runtime recs when a bucket is active); the service fires a runtime-aware `/discover` pass (`with_runtime.gte/lte`) and stamps a representative runtime on discover rows so the pool is non-empty. Media-type and Oscar filters are strict too; when set, the service narrows the discover call accordingly (skipping the unwanted media type, passing the Oscar keyword).
- **Recommendation list** — poster + title + match score badge + AI blurb + source badge. Stream limit is 120 so the chained mood+runtime+year+search filters have room to breathe.
- **Candidate pool** — four parallel TMDB sources per refresh (trending movies, trending TV, top-rated movies, top-rated TV) plus watchlist + Reddit + discover (when filters are active). Each TMDB source is capped separately via `tmdbCap` (default 10 on the client) and `discoverCap` (40 per discover source) so one noisy source can't crowd out the others; dedup by `{mediaType}:{tmdbId}` keeps the earlier source (watchlist > reddit > **discover** > trending > top_rated). Discover leads the TMDB merge so a row that's both narrowed (genre/oscar/etc) and trending keeps its discover tag — needed for the sticky `is_oscar_winner` flag to survive when an Oscar Best Picture is also trending. Each source fetch is wrapped in a typed `_safeTmdb` try/catch. `discoverPaged` uses `poolFloor=40, maxPages=5` per media type with a three-rung fallback (OR-joined genres + years → per-genre fallback → drop-year fallback); the `with_keywords` param (e.g. Oscar keyword `210024`) is preserved across every rung. Narrow filters ("War, 1970-1989") still land sizable pools. Every TMDB call is `.timeout(15s)` wrapped; a single stuck request no longer hangs the refresh spinner.

**Gaps vs spec:**
- **Tonight's Pick Cloud Function** — the daily Cloud Scheduler-driven pick that Phase 10's widget is supposed to consume is not exported from `functions/src/index.ts`. Home screen picks locally instead.
- **Curated Collections (Discover)** — "Best of A24", "Reddit All-Time Favorites", etc. are not implemented. Discover currently offers Trending, New Releases, and Browse by Genre only. ("Oscar Winners You Haven't Seen" is partially covered by the Home Oscar-winners-only filter — combine it with the "hide watched" default to get the same effect.)
- **Rewatch suggestions** — occasional "Rewatch?" card for highly-rated + mood-matching titles not yet in home rotation.

**Shipped (scheduled re-scoring):**
- `onRatingWritten` Firestore trigger stamps `/rescoreQueue/{householdId}` whenever a rating doc is created/updated/deleted.
- `processRescoreQueue` scheduled CF (every 10 min) drains dirty households: regenerates the taste profile via the shared `buildAndWriteTasteProfile` helper, loads the household's current `/recommendations` docs as the candidate list (most-recent 50), and re-scores them in place using the shared `scoreAndWriteCandidates` helper.
- Natural debounce: many rating writes in a 10-min window collapse into one drain pass (marker is overwritten, not appended). Transient Claude errors leave the household marked dirty so the next sweep retries. Background-triggered re-scoring of new Reddit mentions or watchlist arrivals is still not hooked up — those still require a client `refresh`.

---

## Phase 8 — Conversational Concierge ✅

- Full-screen draggable bottom sheet (`concierge_sheet.dart`).
- `concierge` Cloud Function (`functions/src/concierge.ts`) — Claude API with household context (taste profile, last 50 history, watchlist, active mode, mood, ratings).
- Multi-turn chat, session persistence in `/conciergeHistory`.
- Tappable title suggestion cards in responses.
- `cache_control` on context block for prompt caching.

**Gaps vs spec:** none meaningful — UX matches the spec.

---

## Phase 9 — Analytics & Gamification 🟡

**Shipped:**
- **Stats dashboard** (`stats_screen.dart`) — total titles, movies/TV counts, runtime, compatibility %, per-user rating distributions, top genres.
- **Per-mode rating + predict breakdown** — Ratings card shows small Solo/Together avg+count chips per member (from `Rating.context`); Predict & Rate cards show Solo/Together % and wins-over-total sub-rows when that member has context-tagged predictions. Null-context ratings/predictions are kept out of the breakouts so the split numbers reflect post-rollout activity only.
- **Predict leaderboard** — populated by `PredictionService.markRevealSeen` incrementing `predict_total` / `predict_wins` on member doc (plus the split-context counters used by the breakout).
- **`whose_turn` counters** — updated in `DecideService.recordDecision` for tiebreak fairness.
- **Rating streak** — `ratingStreakForUser` (pure, UTC-day bucketed, 1-day grace) derives current + best from `/ratings` with no schema change. Surfaced as a `_StreakChip` next to the Solo/Together chips on the Ratings card — flame 🔥 styling when `current >= 3`, shows "best N" when the historical run beats the active one.
- **Watch streak** — `watchStreakHousehold` (pure, same UTC-day bucketing + 1-day grace as rating streak) derives current + best from `/watchEntries.last_watched_at`. Household-level so shared-Trakt setups don't double-count via `watched_by`. Surfaced under the summary cards as a `_WatchStreakRow` — only rendered when `current > 0` or `best > 1`, flame 🔥 styling at `current >= 3`.
- **Badges** — `computeBadges` (pure, in `stats_provider.dart`) derives twelve achievements with no schema change: First Watch (1 title), Century Club (100 titles), Genre Explorer (5 distinct genres), Binge Master (10 TV shows), Marathon Mode (5 watches in a UTC day), Compromise Champ (5 decisions via the compromise flow), Show Finisher (5 TV shows with `in_progress_status='completed'`), Perfect Sync (90% within-1-star compatibility), Prediction Machine (per-user, 80% accuracy over 20+ predictions), Five Star Fan (per-user, 10 five-star ratings), Critic (per-user, 10 ratings with a note), Tagger (per-user, 10 ratings with ≥1 tag). `_BadgesCard` on Stats screen shows earned/locked state with a progress bar per row; Prediction Machine swaps its progress line to `{n}% accuracy · need 80%` once volume is cleared.
- **`gamificationUpdater` CF** — `onWatchEntryWrittenBadges` + `onMemberWrittenBadges` + `onTasteProfileWrittenBadges` + `onRatingWrittenBadges` + `onDecisionWrittenBadges` Firestore triggers run the TS port of `computeBadges` (`evaluateBadges` in `functions/src/gamificationUpdater.ts`), persist deltas to `/households/{hh}/badges/{badgeId}`, and fire FCM (`type: badge_unlocked`) the moment a badge flips locked → earned. Household badges notify both members; per-user badges notify only the earner. Unchanged progress/earned state skips the write to stay cheap.

**Gaps vs spec:**
- **Prediction streak** — not yet derived. Same pure-function pattern would extend to predictions once we ship per-prediction submission timestamps.
- **Badges (remaining from spec)** — Hidden Gem Hunter, Reddit Scout, Around the World, Rewatch Royalty, Collection Completionist. Foundation is in place (client eval + server persistence + FCM); adding each one now is ~a pair of functions on both sides.
- **Home-screen counters** — "Movies watched together", watch streak, Predict & Rate record not displayed on Home.
- **`gamificationUpdater` Cloud Function** — not exported. Current counter updates are inline in service-layer code, which is fine for `whose_turn` + predict counters but doesn't scale to streaks / badges that need cross-collection triggers.

---

## Phase 10 — Widget, Wrapped & Notifications 🟡

**Shipped:**
- **Rating-nudge FCM** (partial) — `onRatingCreated` trigger in `functions/src/notifications.ts`. Pings partner when a rating posts after a shared prediction. This is the spec's "Rating nudge" item in slightly different form (predict-paired instead of 24-hour-lag).

**Gaps vs spec:**
- **Android home-screen widget** — not started. No `home_widget` package. `MainActivity.kt` is a bare `FlutterActivity` stub. No Jetpack Glance module.
- **Tonight's Pick Cloud Function** — not scheduled (called out under Phase 7 too).
- **Release notifications CF** — not implemented.
- **Wrapped generator CF** — not implemented.
- **Unrated Queue weekly digest CF** — not implemented.
- **Rating nudge (24-hour flavor)** — the current `onRatingCreated` trigger covers the predict-paired case; the spec also calls for a nudge when a `watchEntry` flips to "watched" and only one rating lands within 24h. Not implemented.

---

## Phase 11 — Polish ⬜

Nothing shipped. Specifically:

- **Poster grid onboarding** — 15 intelligently-chosen titles with 1–5 star overlay + skip. Pre-fills from Trakt. No onboarding beyond household setup exists today.
- **Offline caching** — `sqflite` / `drift` not in `pubspec.yaml`. No local DB.
- **Export watch history (CSV)** — not implemented.
- **Collection completionist tracking** — not tracked (blocked on Phase 7's curated collections).
- **Error states, sync conflict handling, empty states, performance pass** — not audited as a batch.
- **Trusted circle schema** — firestore rules carry the `/trustedCircle` + `/friendSuggestions` placeholders; no app logic.

---

## Current shipped Cloud Functions

For reference, `functions/src/index.ts` exports:
- `generateTasteProfile`, `scoreRecommendations`, `redditScraper`, `concierge`, `onRatingCreated`, `onRatingWritten`, `processRescoreQueue`, `onWatchEntryWrittenBadges`, `onMemberWrittenBadges`, `onTasteProfileWrittenBadges`, `submitIssue`, `drainIssueQueue`, `traktExchangeCode`, `traktRefreshToken`, `traktRevoke`.

Not yet exported but called out in the phase plan above: `tonightsPick`, `releaseNotifications`, `wrappedGenerator`, `unratedQueueDigest`.

---

## Signal-separation track (Solo vs Together — cross-phase)

Decisions made 2026-04-18. These are all foundational changes the Phase 7
scorer and Phase 9 stats depend on, so they come before any new feature work.

- [x] **`Rating.context` field** (`solo` / `together` / `null`) — shipped. Write-path defaults from `viewModeProvider` at save time; legacy rows and Trakt historicals stay `null` (treated as shared signal). Rating sheet has a Solo/Together segmented toggle to override. Downstream scorers do not yet filter on it — that lands with the Batch 2 taste-profile engine.
- [x] **`WatchlistItem.scope` + `owner_uid`** — shipped. Share-confirm sheet has a Shared/Solo toggle (defaults to shared). Solo-scoped items visible only to owner + only in Solo mode via `visibleWatchlistProvider`. `buildId` is `{scope}:{owner_uid_or_shared}:{mediaType}:{tmdbId}`. Title-detail watchlist button is mode-aware (Solo mode prefers solo entry, falls back to shared). Decide screen candidate pool uses the visible list.
- [x] **Per-mode filter state** — shipped. `moodProvider` / `runtimeFilterProvider` are now `Provider<T?>` that read from `modeMoodProvider` / `modeRuntimeProvider` (`StateNotifierProvider<_, Map<ViewMode, T?>>`). Writes route to the active mode only; SharedPreferences keys: `wn_mood_solo`, `wn_mood_together`, `wn_runtime_solo`, `wn_runtime_together`. Mode switch preserves the other mode's selection.
- [x] **`tasteProfile` schema** — shipped. `functions/src/tasteProfile.ts` now writes `per_user_solo` and `per_user_together` slots alongside the existing cross-context `per_user`. Null-context ratings fold into both slots as shared backdrop (`matchesContextFilter` treats `null` as match-any). `scoreRecommendations` feeds both taste contexts per member into the prompt and instructs Claude to route them into the `together`/`solo` scores respectively. Concierge solo mode prefers `per_user_solo[uid]` with fallback to `per_user[uid]` for legacy docs. `combined_together` derivation still deferred (not a simple average); scorer uses the cross-context `combined.top_genres` for the shared-genre prompt line.
- [x] **`Prediction.context` + split prediction counters** — shipped. `PredictionEntry.context` carries `solo` / `together` / `null`; `markRevealSeen` routes increments to `predict_total_solo` / `predict_wins_solo`, `_together` variants, or legacy `predict_total` / `predict_wins` fields. `HouseholdMember.predictTotal`/`predictWins` are now sum-across-contexts getters for back-compat. Reveal screen reads the entry's own context (not current mode) so a prediction made in Solo still counts as solo even if the user flips mode before revealing.
- [x] **Trakt-scope flag** — shipped. `members/{uid}.trakt_history_scope: 'shared'|'personal'|'mixed'` (defaults to mixed). User picks on the Trakt link screen after linking. `TraktSyncService.runSync` reads the flag and stamps `Rating.context` on Trakt-imported ratings: shared→together, personal→solo, mixed→null. Historical ratings imported before the flag existed stay null (treated as shared signal).

---

## Stremio integration — optimisation track

- [x] **Deep-link from title detail** — shipped 2026-04-20. `stremio:///detail/{type}/{imdb_id}` button on the title screen with web fallback.
- [x] **WatchNext-as-Stremio-addon (watchlist catalog)** — shipped 2026-04-20. `functions/src/stremio.ts` exposes an HTTP endpoint implementing the Stremio addon protocol (manifest / catalog / meta). Profile → Stremio mints a per-household token via the `provisionStremioToken` callable; the resulting URL installs a household-private catalog of the shared watchlist into Stremio. Imdb ids missing from watchlist docs are resolved on demand via TMDB `external_ids` and cached back onto the doc.
- [x] **User-selectable accent + animated WatchNext wordmark + flat nav bar** — shipped 2026-04-21. `AppAccent` enum (seven seeds, default Streaming red) drives `ColorScheme.fromSeed` at runtime via `accentProvider` (persisted under `wn_accent`). Profile → Preferences surfaces a bottom-sheet colour picker. The AppBar / splash / login logo is a single reusable `WatchNextLogo` that renders "Watch" static and "**Next**" under an animated L→R gradient ShaderMask in the current accent. Bottom navigation flattened to 56px icon-only (`labelBehavior: alwaysHide`).
- [x] **3-state watch status on TV title detail** — shipped 2026-04-21. Title detail replaces the binary Mark-watched toggle for TV with a `Not / Watching / Watched` SegmentedButton. `WatchEntryService` grew `markWatching` + `unmarkWatching` siblings to `markWatched` + `unmarkWatched`. All four mutations route through `.update()` (never `.set(merge:true)`) so Firestore honours the `watched_by.<uid>` dot-notation path instead of creating a literal dotted key — root-causing two bugs where watched/unwatched silently no-op'd.
- [ ] **Recommendations + Next Up catalogs** — add two more catalog ids (`wn_recs`, `wn_nextup`) sourcing from `/recommendations` (mode-aware per the caller's uid) and `watchEntries where inProgressStatus=='watching'`. Recs catalog needs per-user scoping; the token carries `uid` already, so the addon server just has to read that row.
- [ ] **Pretty URL via Firebase Hosting** — today the install URL is the raw CF endpoint. A Hosting rewrite → `https://watchnext.web.app/stremio/{token}/manifest.json` would be nicer to share and more durable if we ever migrate regions.
- [ ] **Write-back actions** — let the user mark-watched / add-to-watchlist from inside Stremio. Stremio's protocol doesn't define these hooks on the addon side; this would have to go through a custom deep-link-out-to-the-app round-trip.

---

## Out of scope (for reference)

These features from the spec are deliberately not in any phase above:

- iOS build (Android-only per spec).
- Light theme (dark-only per spec).
- Social sharing beyond Wrapped image cards.
- Manual title entry (everything flows through TMDB search / share sheet / Trakt sync).

---

## API keys checklist

- [x] Firebase project ID → `.firebaserc` + `firebase_options.dart`
- [x] `google-services.json` → `android/app/`
- [x] TMDB API key
- [x] Trakt Client ID + Secret
- [x] Anthropic API key (`firebase functions:secrets:set ANTHROPIC_API_KEY`)

## Model versioning note

Phase 7 currently uses `claude-sonnet-4-6`. Update when a newer Sonnet lands.
Opus 4.7 (`claude-opus-4-7`) and Haiku 4.5 (`claude-haiku-4-5-20251001`) are the
other families available for cost/quality trades — Concierge and batch scoring
have different latencies and could split model choice if scoring cost becomes
an issue.
