# WatchNext — Roadmap

Where the project is, where it's going, and what's still in the wishlist.

**Audited against the live codebase on 2026-04-22.**

---

## At a glance

| Phase | Theme | Status |
|-------|-------|--------|
| 1 | Foundation | ✅ Shipped |
| 2 | Trakt integration | ✅ Shipped |
| 3 | Core UX | ✅ Shipped |
| 4 | Solo / Together + share sheet | ✅ Shipped |
| 5 | Decide Together | ✅ Shipped |
| 6 | Predict & Rate | ✅ Shipped |
| 7 | AI & Discovery | 🟡 Mostly shipped |
| 8 | Conversational Concierge | ✅ Shipped |
| 9 | Analytics & Gamification | 🟡 Mostly shipped |
| 10 | Widget, Wrapped, notifications | 🟡 Partial |
| 11 | Polish | ⬜ Not started |

**Legend:** ✅ Shipped · 🟡 Partial — some gaps · ⬜ Not started.

The full design spec (screens, data model, flows, copy) lives in `WatchNext_Design.pdf` — this roadmap tracks implementation against it.

---

## Phase 1 — Foundation ✅

The bones of the app.

- Flutter project scaffold, dark-only Material 3.
- Six-tab bottom navigation: Home / Discover / Watchlist / History / Stats / Profile.
- Firebase wired up: Auth (Google Sign-In), Firestore, Cloud Functions, Cloud Messaging.
- **Household model** — create, invite code, partner joins. Two-person cap enforced.
- **TMDB API service** — search, details, similar, trending, upcoming, top-rated.
- **Firestore security rules** — every collection scoped to household membership.

---

## Phase 2 — Trakt Integration ✅

Per-user watch tracking and rating sync.

- **OAuth 2.0 per user** — browser-based, CSRF protected.
- **Full sync on first link** — every title in your Trakt history, cross-referenced against TMDB.
- **Incremental sync on app open** (>1 hour since last sync).
- **Push ratings to Trakt** — rate a title here, it appears on your Trakt profile.
- **Unrated Queue** — catch-up for titles you've watched but never scored.

*Deferred:* per-episode Unrated Queue (currently show-level only).

---

## Phase 3 — Core UX ✅

The screens you actually use.

- **History** — Watched / In progress / Unrated tabs, swipe-to-rate.
- **Rating sheet** — 1–5 stars, tag chips, optional note. Movie / show / season / episode.
- **Watchlist** — shared queue with swipe to remove.
- **Title detail** — backdrop, poster, metadata, household ratings, watch-status controls. Movies get a 2-state Mark-watched; TV gets 3-state *Not / Watching / Watched*.
- **Real-time Firestore listeners** — changes land instantly on both devices.

*Deferred:*
- Search + filters on Watched tab
- Per-episode Unrated Queue with batch rate-all
- "Resume" nudge after 2 weeks of inactivity (waits on Phase 10 notifications)
- Prediction-accuracy badge on Watched rows (waits on Phase 9 badge infra)

---

## Phase 4 — Solo / Together + Share-to-Save ✅

Shared life, separate tastes.

- **Solo / Together segmented control** at the top of Home and Discover; persists per-device.
- **Recommendation docs carry dual scores** (`match_score` + `match_score_solo`) populated by the Phase 7 scorer.
- **Android share sheet** — receive "Share" intents from any app. `ShareParser` resolves IMDb, TMDB, Letterboxd, and Google URLs and offers a confirmation sheet.

*Deferred:* per-user default mode from onboarding (waits on Phase 11).

---

## Phase 5 — Decide Together ✅

How you actually pick something tonight.

- **Negotiate** — top 5 per user, side by side. Instant Match highlight on overlap. "None of these — shuffle" rerolls the pool.
- **"Surprise me — fish older catalog"** — opt-in button that samples a random pre-2020 decade when the trending pool feels stale.
- **Compromise pick** — three-tier fallback (top scored rec → TMDB "similar" overlap → any similar) when neither partner agrees.
- **Veto** — max 2 per user before we go to tiebreak.
- **Tiebreaker** — whoever has fewer lifetime wins picks. Tiebreak picks flagged for future stats.
- **Decision history** — every pick logged, "whose turn" counters updated automatically.
- **Predict & Rate** trigger after a decision — optional but encouraged.

*Gaps:* compromise picks could use a Claude call with both taste profiles instead of TMDB similar — straight swap when appetite permits.

---

## Phase 6 — Predict & Rate ✅

Calibrate taste by guessing before you watch.

- **Pre-watch prediction sheet** — 1–5 stars (skip always available). Partner's guess hidden until both submit.
- **Post-watch rating** via the standard Phase 3 flow, with two-way Trakt sync.
- **Reveal screen** — side-by-side predicted vs actual, delta, winner highlighted.
- **Member-doc counters** — total and wins, so your accuracy % is always derivable.
- **FCM nudge** — partner gets a push when you rate after a shared prediction.

*Gaps:* prediction-accuracy badge on Watched rows + running-streak leaderboard (both wait on Phase 9).

---

## Phase 7 — AI & Discovery 🟡

The brain.

**Shipped:**
- **Claude batch scoring** — a Cloud Function scores up to 100 candidates per refresh, writing `match_score` / `match_score_solo` + an AI blurb to each rec.
- **Taste profile generation** — per-user + combined top genres, decades, and liked/disliked titles. Two slots (solo vs together) so a partner's solo-horror weekends don't contaminate the shared profile.
- **Background rescoring** — whenever anyone rates a title, a scheduled CF (every 10 min) regenerates the taste profile and rescores the 50 most recent recs.
- **Home screen** — Tonight's Pick hero, Upcoming-for-you carousel, scored rec list (120 items, streamed in real time).
- **Filters panel** — compact, collapsible. Free-form genre multi-select, media type (Movies / TV), runtime bucket (<90 / 90–120 / >2h), year range slider, Oscar-winners-only toggle, "Sort" picker (Top rated / Popularity / Recent / Underseen), and curated source (Criterion). All filters persist per mode.
- **Narrow-filter discover** — a fallback ladder keeps the candidate pool healthy even for tight queries like "War, 1970–1989".
- **Reddit scraper** — weekly (Sunday 03:00 UTC) pull from 7 film-centric subreddits, TMDB cross-referenced, written to `/redditMentions`.
- **Race-safe refresh** — an epoch counter drops stale fan-outs so a slow older refresh can't overwrite a newer pool.

*Gaps:*
- **Home-screen uses the CF pick** — currently Home picks locally from the top of its filtered rec list so "Not tonight" dismissals work. The new `/tonightsPick/current` doc (Phase 10) is there for the widget. Could optionally have Home surface the CF pick as a "Today's pick (from both of you)" header.
- **Curated Collections in Discover** — "Best of A24", "Reddit All-Time Favorites", "Oscar Winners You Haven't Seen" aren't implemented as dedicated surfaces. (The Oscar-winners filter on Home covers the third.)
- **"Rewatch?" card** — occasional highly-rated mood-matching resurface hasn't shipped.

---

## Phase 8 — Conversational Concierge ✅

Chat with an AI that knows your household.

- **Full-screen chat sheet.**
- **Claude-powered** — the Cloud Function sends your taste profile, last 50 history rows, watchlist, current mode and mood into the prompt.
- **Multi-turn chat with session persistence.**
- **Tappable title cards** in responses — Claude suggestions that don't resolve on TMDB are silently dropped so we never show a broken tile.
- **Prompt caching** on the context block.

---

## Phase 9 — Analytics & Gamification 🟡

Make watching feel like an activity.

**Shipped:**
- **Stats dashboard** — total titles, movies/TV, runtime, compatibility %, per-user rating distributions, top genres.
- **Per-mode breakdowns** — Solo/Together rating avg + count chips, Solo/Together predict accuracy with wins-over-total sub-rows.
- **Rating streak & watch streak** — pure-function derivations, 1-day grace, 🔥 icon at 3+.
- **Twelve badges** — First Watch, Century Club, Genre Explorer, Binge Master, Marathon Mode, Compromise Champ, Show Finisher, Perfect Sync, Prediction Machine, Five-Star Fan, Critic, Tagger. Progress bar per row.
- **Server-side badge evaluator** — Firestore triggers on watchEntry / member / ratings / taste / decision writes re-run a pure evaluator and push FCM the moment a badge flips earned.
- **Predict leaderboard** + `whose_turn` tiebreak counters.

*Gaps:*
- **Prediction streak** — not yet derived.
- **Spec badges still to come** — Hidden Gem Hunter, Reddit Scout, Around the World, Rewatch Royalty, Collection Completionist.
- **Home-screen counters** — "Movies watched together", current watch streak, Predict & Rate record not yet surfaced on Home.

---

## Phase 10 — Widget, Wrapped & Notifications 🟡

**Shipped:**
- **Rating-nudge push** — partner gets a notification when you rate a title you both predicted on.
- **Tonight's Pick Cloud Function** — `updateTonightsPickDaily` runs at 08:00 UTC, picks each household's top unwatched scored rec, writes to `/households/{hh}/tonightsPick/current`. Household-scoped read, admin-only write. Home screen still picks locally (interactive, respects "Not tonight" dismissals); this doc is for the widget + future surfaces that want a deterministic daily pick.

*Gaps:*
- **Android home-screen widget** — the Kotlin/Glance module that consumes `/tonightsPick/current`. Scaffolding TBD.
- **Release-day notifications** — watchlist items becoming available.
- **Wrapped generator** — annual recap with sharable image cards.
- **Unrated Queue weekly digest** — reminder to catch up on missed ratings.
- **24-hour rating-nudge flavor** — when a partner marks something watched without rating it within 24h.

---

## Phase 11 — Polish 🟡

**Shipped:**
- **Poster-grid onboarding** — 15 curated seed titles, 1–5 star picker on tap, "Skip" / "Done" footer. Gated by a local `wn_onboarding_done` flag + household emptiness check so existing users aren't forced through it after updates. Ratings written with `context: null` so they seed both Solo and Together taste profiles as shared backdrop.
- **Consistent error + empty states across screens** — shared `EmptyState` widget (icon + title + subtitle + optional action), `AsyncErrorView` now supports a `compact` variant for in-section use. Watchlist, History (all 3 tabs), Discover (search + browse rows + genre rows) + Profile (invite code + Trakt) replaced their bare `Text('Error: $e')` with proper error surfaces and their ad-hoc empty-string placeholders with `EmptyState`.

On the list:
- **Offline caching** — local SQLite of the most-recent recs + history.
- **Export watch history** (CSV).
- **Collection Completionist tracking** — waits on curated collections above.
- **Error states, empty states, sync conflict handling, and a general performance pass.**
- **Trusted circle** — rules placeholders exist but no app-side logic.

---

## Signal separation — Solo vs Together

Cross-cutting work to make sure your solo tastes and your shared tastes stay cleanly separated. Foundational — Phase 7's scorer and Phase 9's stats depend on it.

- [x] **`Rating.context` field** — every rating stamped `solo` / `together` / `null` (legacy). Rating sheet has an override toggle.
- [x] **`WatchlistItem.scope` + `owner_uid`** — share-confirm sheet picks Shared or Solo; solo items only visible to owner in solo mode.
- [x] **Per-mode filter state** — mood, runtime, media type, Oscar filter, sort, and curated source all persist independently for solo and together.
- [x] **Taste profile schema** — `per_user_solo` and `per_user_together` alongside the legacy cross-context slot. Scorer feeds both into Claude.
- [x] **Prediction counters split** — `predict_total_solo/_together` and `predict_wins_solo/_together` on member doc; a prediction made in solo stays solo even if you flip mode before revealing.
- [x] **Trakt scope flag** — Shared / Personal / Mixed per user. Imported Trakt ratings get stamped accordingly so the taste engine learns cleanly.

---

## Stremio track

Extra mileage from Stremio integration.

- [x] **Deep-link from title detail** — `stremio://` button with a web fallback.
- [x] **WatchNext as a Stremio addon** — Profile → Stremio mints a household-private install URL; your shared watchlist appears as a Stremio catalog.
- [x] **Accent picker + animated wordmark + flat nav bar** — 18 named colour seeds, live recolour on select.
- [x] **3-state watch status for TV** — title detail uses *Not / Watching / Watched*.
- [x] **Inline trailer** — tap *Watch trailer* on the title screen and YouTube plays right there (16:9, autoplay on expand).
- [x] **Upcoming for you** — Home carousel of soon-releasing titles ranked by your taste.
- [x] **External ratings + reviews on title detail** — IMDb / Rotten Tomatoes / Metascore shown inline via OMDb (7-day Firestore cache), plus an expandable TMDB Reviews section.
- [x] **IMDb-★ chip on list rows** — `Recommendation.imdbId` stamped onto rec docs by a background resolver after Phase A; Home rows render an inline IMDb rating chip next to the match score once it resolves.
- [x] **Narrow-filter auto-widen** — stacked filter combos (e.g. "War + 1970-1989") trigger a deeper `discoverPaged` pass (2.5× pool target, 2× pages, lower vote floor) so narrow queries stop coming back near-empty. Broad queries stay on the default budget.
- [ ] **Extra Stremio catalogs** — Recommendations and Next-Up, on top of Watchlist.
- [ ] **Pretty Stremio URL** via Firebase Hosting rewrite.
- [ ] **Write-back actions** — mark-watched / add-to-watchlist from inside Stremio (likely via a deep-link round-trip).

---

## Out of scope

These are deliberately *not* planned:

- **iOS build** — Android-only by design.
- **Light theme** — dark-only by design.
- **Social sharing** beyond Wrapped image cards.
- **Manual title entry** — everything flows through TMDB search / share sheet / Trakt sync.

---

## Notes for future me

**API keys currently in play:**
- Firebase project → `.firebaserc` + `firebase_options.dart`
- `google-services.json` → `android/app/`
- TMDB API key (dart-define + Firebase secret for server-side Stremio addon)
- Trakt Client ID + Secret
- Anthropic API key (Firebase secret)

**Model versioning:**
Phase 7 batch scoring + Phase 8 concierge currently use **`claude-sonnet-4-6`**. Update when a newer Sonnet lands. Opus 4.7 (`claude-opus-4-7`) and Haiku 4.5 (`claude-haiku-4-5-20251001`) are the other families — could split model choice for cost/quality trades if scoring cost becomes an issue.
