# WatchNext

A shared movie & TV recommender for two-person households. Decide what to watch, together — backed by AI recommendations that learn from both partners' taste.

See [ROADMAP.md](ROADMAP.md) for the full 11-phase build plan. This repo currently contains **Phase 1: Foundation**, **Phase 2: Trakt Integration**, **Phase 3: Core UX**, and **Phase 4: Solo/Together + Share-to-Save**.

Trakt's `client_secret` lives only in Firebase Secrets Manager (`TRAKT_CLIENT_SECRET`); the client calls Cloud Function proxies (`traktExchangeCode`, `traktRefreshToken`, `traktRevoke`) for secret-dependent operations.

## Phase 4 status

| Layer | Status |
|-------|--------|
| Solo \| Together segmented control in Home + Discover AppBars | Done |
| Mode persisted per-device via SharedPreferences (`wn_view_mode`) | Done |
| Recommendation doc contract (`match_score` + `match_score_solo`, `ai_blurb` + `ai_blurb_solo`) | Reserved for Phase 7 engine |
| Android `SEND` + `text/plain` intent-filter on MainActivity | Done |
| Share-sheet URL parser (IMDb, TMDB, Letterboxd, Google, fallback) | Done |
| Share confirm bottom sheet → "Add to Watchlist" with `added_source: share_sheet` | Done |
| Warm- and cold-start share listeners in `ScaffoldWithNavBar` | Done |

## Phase 2 status

| Layer | Status |
|-------|--------|
| Trakt OAuth 2.0 (browser flow, CSRF-protected state) | Done |
| Token storage + automatic refresh | Done |
| `TraktService` (history, ratings, trending, recommendations, push) | Done |
| `TraktSyncService` — full sync + incremental sync | Done |
| TMDB cross-ref for entry metadata | Done |
| Per-episode watch timestamps for TV | Done |
| App-open incremental sync (>1hr since last) | Done |
| Unrated queue provider (show/movie level) | Done |
| Trakt link/unlink UI in Profile | Done |
| Trakt Client ID + Secret | **Needed — see below** |

## Phase 1 status

| Layer | Status |
|-------|--------|
| Flutter project scaffold (dark-mode Material 3) | Done |
| 5-tab bottom nav (Home • Discover • History • Stats • Profile) | Placeholder screens wired up |
| Firebase Auth (Google Sign-In) | Done |
| Household create / join with invite code (two-person cap) | Done |
| Firestore security rules (household-scoped) | Done |
| TMDB API service | Done (endpoints exposed, needs key) |
| Cloud Functions TypeScript scaffold | Done (empty placeholder) |
| Firebase project / Trakt / Claude / TMDB keys | **Needed — see below** |

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | Flutter (Dart) |
| State management | Riverpod |
| Routing | go_router |
| Backend | Firebase (Auth, Firestore, Cloud Functions, Cloud Messaging) |
| Cloud Functions | TypeScript (Node 22) |
| Auth | Google Sign-In via Firebase Auth |
| Movie data | TMDB API |
| Watch tracking | Trakt API (Phase 2) |
| Community | Reddit JSON API (Phase 7) |
| AI | Anthropic Claude API (Phase 7) |

## Getting Started

### Prerequisites
- Flutter SDK (^3.11) — already installed on this WSL box
- A Firebase project with Auth + Firestore + Cloud Functions + Cloud Messaging enabled
- TMDB API key ([themoviedb.org/settings/api](https://www.themoviedb.org/settings/api))

### Keys you'll need to supply

**Before the app will run**, you need to provide:

1. **`android/app/google-services.json`** — download from Firebase Console → Project settings → Android app
2. **`lib/firebase_options.dart`** — regenerate with:
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure --project=<your-firebase-project-id>
   ```
3. **`.firebaserc`** — replace `PLACEHOLDER_FIREBASE_PROJECT_ID` with your actual project ID
4. **TMDB API key** — passed at runtime via `--dart-define`:
   ```bash
   flutter run --dart-define=TMDB_API_KEY=your_tmdb_key_here
   ```

**Trakt Client ID + Secret** (Phase 2) — register an application at [trakt.tv/oauth/applications](https://trakt.tv/oauth/applications):

1. **Name**: WatchNext (or anything)
2. **Redirect URI**: `com.household.watchnext://trakt-callback`
3. **JavaScript (CORS) origins**: leave blank — only used for browser/SPA apps
4. **Permissions / scrobble**: leave unchecked — Phase 2 only reads history and pushes ratings, which standard OAuth tokens already cover. Enable later if/when we add live playback scrobbling.
5. Copy the Client ID + Client Secret into `env.json`:
   ```json
   {
     "TMDB_API_KEY": "…",
     "TRAKT_CLIENT_ID": "…",
     "TRAKT_CLIENT_SECRET": "…"
   }
   ```
6. Run via `./run.sh` so the keys are injected via `--dart-define-from-file=env.json`.

Keys needed for later phases:
- Anthropic API key (Phase 7) — set as Cloud Functions secret: `firebase functions:secrets:set ANTHROPIC_API_KEY`

### Run locally
```bash
flutter pub get
flutter run --dart-define=TMDB_API_KEY=xxx
```

### Deploy Firestore rules + Cloud Functions
```bash
firebase deploy --only firestore:rules
cd functions && npm install && cd ..
firebase deploy --only functions
```

## Project Structure

```
lib/
├── main.dart              # App entry + Firebase init
├── app.dart               # Router + bottom nav shell
├── firebase_options.dart  # Regenerated by flutterfire CLI
├── theme/                 # Dark-only Material 3 theme
├── models/                # Data models (added per phase)
├── providers/             # Riverpod providers
├── services/              # Firebase / TMDB / Trakt / Claude clients
└── screens/
    ├── auth/              # Login
    ├── household/         # Create / join via invite code
    ├── home/              # Tonight's Pick (Phase 7)
    ├── discover/          # Collections + trending (Phase 7)
    ├── history/           # Watched / In Progress / Unrated (Phase 3)
    ├── stats/             # Analytics dashboard (Phase 9)
    ├── profile/           # Settings + invite code
    └── shared/            # Reusable widgets

functions/src/             # Cloud Functions (empty scaffold)
firestore.rules            # Household-scoped security rules
firestore.indexes.json     # Composite indexes (empty for now)
firebase.json              # Firebase config
```

## Security notes

- Firestore rules scope all reads/writes to verified household membership.
- Two-person cap enforced in `HouseholdService.joinByInviteCode` (see `lib/services/household_service.dart`).
- `google-services.json`, `.env`, `local.properties` are gitignored. Never commit secrets.
- Trakt OAuth tokens (Phase 2) will be stored encrypted on the member document.

## License

This project is provided as-is for personal use.
