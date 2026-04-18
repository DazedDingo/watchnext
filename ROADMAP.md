# WatchNext — Build Roadmap

Source of truth for the full 11-phase build plan from the original design spec.
**Status as of 2026-04-18** audited from the live codebase. Each phase marked
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
- Title detail screen — backdrop, poster, metadata, add/remove watchlist, rate button, household ratings list.
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

- **Negotiate** — top 5 per user from scored recommendations (mood-filtered). Side-by-side layout. Instant Match highlight on overlap (`decide_provider.dart` line 188).
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
- **Claude API batch scoring** — `scoreRecommendations` callable (`functions/src/scoreRecommendations.ts`, model `claude-sonnet-4-6`). Writes `match_score`/`match_score_solo` and `ai_blurb`/`ai_blurb_solo` to `/recommendations`. Invoked on-demand (no scheduled trigger).
- **Home screen** — Tonight's Pick hero (top rec from local sort, not a dedicated CF doc), mood selector pills (8 moods → TMDB genre map), runtime pills (`<90 / 90–120 / >2h`), "Surprise me" random-from-top, "Because you loved X" chip (`utils/rec_explainer.dart`).
- **Recommendation list** — poster + title + match score badge + AI blurb + source badge.

**Gaps vs spec:**
- **Tonight's Pick Cloud Function** — the daily Cloud Scheduler-driven pick that Phase 10's widget is supposed to consume is not exported from `functions/src/index.ts`. Home screen picks locally instead.
- **Curated Collections (Discover)** — "Best of A24", "Oscar Winners You Haven't Seen", "Reddit All-Time Favorites", etc. are not implemented. Discover currently offers Trending, New Releases, and Browse by Genre only.
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

**Gaps vs spec:**
- **Watch streak** and **prediction streak** — not yet derived. Same pure-function pattern will extend to `/watchEntries.completed_at` and predictions once we ship counters/buckets for those.
- **Badges** — all 13 from spec (First Watch, Century Club, Genre Explorer, Hidden Gem Hunter, Reddit Scout, Prediction Machine, Perfect Sync, Compromise Champ, Marathon Mode, Around the World, Binge Master, Rewatch Royalty, Collection Completionist) unimplemented. No badge collection, no condition checks, no FCM on unlock.
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
- `generateTasteProfile`, `scoreRecommendations`, `redditScraper`, `concierge`, `onRatingCreated`, `onRatingWritten`, `processRescoreQueue`, `submitIssue`, `drainIssueQueue`, `traktExchangeCode`, `traktRefreshToken`, `traktRevoke`.

Not yet exported but called out in the phase plan above: `tonightsPick`, `gamificationUpdater`, `releaseNotifications`, `wrappedGenerator`, `unratedQueueDigest`.

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
