# WatchNext — Build Roadmap

Source of truth for the full 11-phase build plan from the original design spec.
Phase 1 is complete. Phases 2–11 are **to do** — this document preserves the intent so nothing gets lost.

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
- Push WatchNext ratings to Trakt: wired in `TraktService.pushRating` — called from the rating flow in Phase 3.
- **Unrated Queue** provider exposed in `lib/providers/watch_entries_provider.dart`.
- Client-side sync (no Cloud Function dependency / Blaze plan) — the spec mentioned a `traktSync` Cloud Function; revisit if we need server-side push notifications on sync completion later.

**Deferred to Phase 3:** the Unrated Queue UI and the per-episode unrated pass.

---

## Phase 3 — Core UX ✅

- History screen with 3 tabs: Watched / In progress / Unrated. Poster rows, average household rating badge, tap → title detail, swipe-to-rate on Unrated.
- Rating flow modal sheet — 1–5 stars + tag chips + note. Movie/show/season/episode levels. Pushes to Trakt on save when linked.
- Watchlist screen — shared queue, swipe to remove, tap → title detail.
- Title detail screen — backdrop, poster, metadata, add/remove watchlist, rate button, household ratings list.
- Home — watchlist summary + recently-watched carousel (placeholder until Phase 7's Tonight's Pick).
- Real-time Firestore listeners via Riverpod StreamProviders.

**Deferred to later phases (as originally spec'd):**
- Search + filters on Watched tab (cheap follow-up once history volume justifies it).
- Per-episode Unrated Queue section with "Rate All" batch mode (Phase 3.1 follow-up — current pass exposes show-level only).
- "Resume" nudge after 2 weeks of inactivity on In-Progress (Phase 10 notifications).
- Prediction accuracy badge on Watched rows (Phase 6 Predict & Rate).
- AI blurb on title detail (Phase 7).

---

## Phase 4 — Solo / Together mode + Share-to-Save

- Segmented control at top of Home and Discover: Solo | Together. Solo filters to individual taste; Together optimizes overlap. Persists per session, default from profile.
- Recommendation docs store both `match_score` (together) and `match_score_solo` per-user, plus `ai_blurb` and `ai_blurb_solo` per-user. Home reads the appropriate field by active mode.
- **Android share sheet intent filter** — register WatchNext to receive `text/plain` + URLs.
  Parse incoming URLs:
  - `imdb.com/title/tt*` → extract IMDb ID → look up on TMDB
  - `letterboxd.com/film/*` → extract slug → search TMDB by title
  - `themoviedb.org/movie/*` or `/tv/*` → extract ID directly
  - Google search URL → extract title → search TMDB
  - Fallback: extract page title, search TMDB, confirm match
- Confirmation bottom sheet with poster + metadata + "Add to Watchlist". Store `added_source` as `"share_sheet"`.

---

## Phase 5 — Decide Together

- **Negotiate** — generate top 5 for each user from recommendations (filtered by active mood). Side-by-side card layout. Highlight overlapping titles as "Instant Match".
- If match → suggest it. If none → each person taps their #1.
- If different picks → **Claude API compromise pick** (query with both taste profiles, exclude picked titles, find best mutual fit). Show with explanation.
- **Veto** — either person can veto (max 2 per session). After veto → next compromise. After vetoes exhausted → tiebreaker to person with fewer lifetime wins in `gamification.whose_turn` map.
- Log decision in `decisionHistory`. Update `whose_turn` counters.
- After selection: optionally trigger Predict & Rate flow.

---

## Phase 6 — Predict & Rate

- Before watching: both prompted "Predict your rating" → 1-5 stars. Predictions hidden from each other until both submitted (or skipped). Skip option always available.
- After watching: 1-5 star tap (required, large), optional quick-tag chips, optional one-line note, both prompted independently. Two-way Trakt sync.
- **For TV** — separate rating levels (show / season / episode). Predict & Rate operates at show level (predict before starting a new series).
- **Reveal screen** — side-by-side predicted vs actual for each person. Delta display ("Off by 1" / "Spot on!"). Winner highlight for closer prediction. Running score update.

---

## Phase 7 — AI & Discovery

- **Reddit scraper Cloud Function** — weekly. Scrape configured subreddits (r/MovieSuggestions, r/televisionsuggestions, r/flicks, r/movies, r/television, r/Letterboxd) via public JSON API. Extract titles from post titles + top comments → match to TMDB. Aggregate mention counts, store as recommendation candidates.
- **Taste profile generation** — derived from history + ratings. Store in `/households/{id}/tasteProfile` with per-user and combined sections.
- **Claude API batch scoring + blurbs** — together + solo variants.
  Model: `claude-sonnet-4-5` (or whatever is current at build time — spec named `claude-sonnet-4-20250514`; latest Sonnet as of 2026-04 is `claude-sonnet-4-6`). Configure via env var in Cloud Function.
- **Home screen**:
  - Top bar: Solo | Together toggle.
  - Hero: Tonight's Pick (poster card, match score, AI blurb, "Let's watch this" / "Not tonight").
  - "Decide Together" button (Together mode only).
  - Mood selector pills: Date Night | Chill | Intense | Laugh | Mind-Bending | Feel-Good | Custom.
  - Recommendation list (vertical cards: poster, title, year, runtime, genres, match score badge, source badge — AI Pick / Trending / Reddit Hype / Hidden Gem, AI one-liner).
  - Rewatch suggestions (occasional "Rewatch?" card for highly-rated titles matching current mood; toggle in settings).
- **Discover screen**:
  - Curated Collections (carousel) — "Best of A24", "Oscar Winners You Haven't Seen", "Reddit All-Time Favorites", etc. Sources: curated seed + TMDB lists + AI-generated + Reddit "best of". Tap → grid with match scores. Watched titles dimmed + checkmark.
  - Trending Now (Trakt + Reddit combined, sorted by recency).
  - New Releases (TMDB upcoming/recent, highlight matches, "On your list" badge).
  - Browse by Genre (expandable sections).

---

## Phase 8 — Conversational Concierge

- Floating "Ask AI" button on Home → bottom sheet chat.
- Claude API with full context: user's message + household taste profile + watch history (last 50) + current watchlist + active mode (solo/together) + both users' genre prefs + recently watched + in-progress shows + active mood filter if set.
- Responses: 3–5 tappable title cards with explanation.
- Multi-turn ("actually make it sci-fi", "something shorter"). Session persistence in `/conciergeHistory`.
- UX: clean text bubbles + tappable title cards. No personality — helpful and straightforward.

---

## Phase 9 — Analytics & Gamification

- **Stats dashboard** (Stats tab):
  - Watching habits (totals, hours, avg rating, genre distribution, pace trend, busiest day, avg length).
  - Couple compatibility (% within 1 star, by genre, guilty pleasures, compromise success rate).
  - Predict & Rate leaderboard (lifetime accuracy, current streak, W/L, biggest surprise, genre-level accuracy).
  - Discovery stats (source breakdown, hidden gems, genre breadth, countries).
- **Streaks**: watch streak (consecutive weeks with ≥1 title watched together), rating streak (24hr turnaround), prediction streak (within 1 star).
- **Badges** (list in spec §Gamification): First Watch, Century Club, Genre Explorer, Hidden Gem Hunter, Reddit Scout, Prediction Machine, Perfect Sync, Compromise Champ, Marathon Mode, Around the World, Binge Master, Rewatch Royalty, Collection Completionist.
- **Home-screen counters**: "Movies watched together", current watch streak (with 🔥), Predict & Rate record.

**Cloud Function:** `gamificationUpdater` — triggered on writes to ratings, predictions, decisionHistory. Updates streaks, counters, checks badge conditions. FCM on badge unlock.

---

## Phase 10 — Widget, Wrapped & Notifications

- **Tonight's Pick Cloud Function** — daily Cloud Scheduler (early evening). Selects top rec (match score + freshness + variety, no back-to-back genre repeats). Writes to dedicated document for widget consumption.
- **Android home-screen widget** — Jetpack Glance (native Kotlin module alongside the Flutter app; use `home_widget` package as the bridge). Compact card: poster thumbnail, title, match score, one-line AI blurb. Tap → app → title detail. Refreshes daily. Respects Solo/Together mode.
- **Release notification Cloud Function** — weekly. Check TMDB upcoming for watchlist titles. Check new seasons of in-progress TV. Send FCM push when release within 7 days ("X releases this week — it's on your watchlist!").
- **Wrapped generator Cloud Function** — scheduled Dec 1 (or manual). Query full year, compute stats, send to Claude for narrative. Store cards in Firestore. Cards: "Your year in numbers", "Top genre was ___", "You agreed on __% of movies this year", "Best prediction: ___", "Most controversial take", "Hidden gem of the year", "Reddit pick that delivered", "If you were a genre, you'd be ___" (AI persona). Shareable as images (Instagram stories / WhatsApp) — only sharing feature in app.
- **Unrated Queue weekly digest** — FCM push when Unrated Queue > 10.
- **Rating nudge** — `watchEntry` status → "watched" trigger. If only one rating after 24hr → FCM push to other user.

---

## Phase 11 — Polish

- **Poster grid onboarding** — 15 titles chosen intelligently (widely-known films + genre variety). Tap → 1-5 star overlay. Swipe to skip / "haven't seen it". Progress bar. Pre-fill from Trakt if sync finished during setup. Triggers first recommendation batch.
- Offline caching — equivalent of Room in Flutter = `sqflite` or `drift`. Cache watch history + recommendations for offline reads.
- Export watch history (CSV).
- Collection completionist tracking (% watched per collection, badge trigger).
- Error states, sync conflict handling, empty states.
- Performance optimization.
- Trusted circle schema (UI deferred — future-proofing only).

---

## Out of scope (for reference)

These features from the spec are deliberately not in any phase above, matching the spec's intent:

- iOS build (Android-only per spec).
- Light theme (dark-only per spec).
- Social sharing beyond Wrapped image cards.
- Manual title entry (everything flows through TMDB search / share sheet / Trakt sync).

---

## API keys checklist

Track here as you acquire them:

- [ ] Firebase project ID → update `.firebaserc` + `firebase_options.dart`
- [ ] `google-services.json` → `android/app/`
- [ ] TMDB API key → `--dart-define=TMDB_API_KEY=xxx` at build (or put in `local.properties`)
- [ ] Trakt Client ID + Secret (Phase 2) → Cloud Functions secret + app config
- [ ] Anthropic API key (Phase 7) → `firebase functions:secrets:set ANTHROPIC_API_KEY`

## Model versioning note

The spec called out `claude-sonnet-4-20250514`. That appears to be an earlier internal ID. Current Anthropic model families as of this scaffold:
- Opus 4.6 — `claude-opus-4-6`
- Sonnet 4.6 — `claude-sonnet-4-6`
- Haiku 4.5 — `claude-haiku-4-5-20251001`

For WatchNext recommendations and concierge, Sonnet gives the right cost/quality balance. Use whatever's current when Phase 7 lands.
